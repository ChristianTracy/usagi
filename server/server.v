module server

import net.http
import sync
import time
import tools
import x.json2
import config { Config }

// Server compatibility layer.
//
// "OpenAI-compatible" is a spectrum. omlx and llama.cpp overlap on `tools` and
// `tool_choice`, but differ elsewhere:
//   * constrained JSON uses different field names (`structured_outputs` vs
//     `grammar`/`json_schema`);
//   * `parallel_tool_calls` exists on llama.cpp but not on omlx;
//   * `strict` inside a tool definition is not enforced by either.
// Rather than guess, we resolve a ServerProfile once (by config override or by
// probing) and use it to shape the request body. If the server still rejects an
// optional field, chat() degrades the profile for the rest of the session and
// retries once without those fields.

pub struct ServerProfile {
pub mut:
	kind                 string = 'openai' // 'omlx' | 'llamacpp' | 'openai'
	tool_choice          bool   = true
	parallel_tool_calls  bool   = true
	chat_template_kwargs bool   = true
	thinking_budget      bool   // omlx-only: caps thinking tokens
	degraded             bool // optional fields were rejected once; omit them
}

// g_profile is process-wide because chat() runs on the turn goroutine while the
// startup probe fills it in. The mutex keeps the read/write race out.
__global g_profile = ServerProfile{
	kind:                 'openai'
	tool_choice:          true
	parallel_tool_calls:  true
	chat_template_kwargs: true
	thinking_budget:      false
}
__global g_profile_mu sync.Mutex

// server_profile returns the resolved profile.
pub fn server_profile() ServerProfile {
	g_profile_mu.lock()
	p := g_profile
	g_profile_mu.unlock()
	return p
}

// set_server_profile installs a profile (used by the probe and by tests).
pub fn set_server_profile(p ServerProfile) {
	g_profile_mu.lock()
	g_profile = p
	g_profile_mu.unlock()
}

// degrade_server_profile marks that the server rejected an optional field, so
// later requests omit them instead of failing the turn.
pub fn degrade_server_profile() {
	g_profile_mu.lock()
	g_profile.degraded = true
	g_profile_mu.unlock()
}

// profile_for maps a known server kind to its capabilities. The generic profile
// assumes plain OpenAI semantics (tool_choice yes, parallel yes).
fn profile_for(kind string) ServerProfile {
	return match kind {
		'omlx' {
			ServerProfile{
				kind:                 'omlx'
				tool_choice:          true
				parallel_tool_calls:  false // not in omlx's request model
				chat_template_kwargs: true
				thinking_budget:      true
			}
		}
		'llamacpp' {
			ServerProfile{
				kind:                 'llamacpp'
				tool_choice:          true
				parallel_tool_calls:  true
				chat_template_kwargs: true
			}
		}
		else {
			ServerProfile{
				kind:                 'openai'
				tool_choice:          true
				parallel_tool_calls:  true
				chat_template_kwargs: true
			}
		}
	}
}

// resolve_server_profile picks the request dialect. An explicit cfg.server wins
// without probing; 'auto' (or empty) probes the endpoint and falls back to the
// generic OpenAI profile.
pub fn resolve_server_profile(cfg Config) ServerProfile {
	if cfg.server != '' && cfg.server != 'auto' {
		return profile_for(cfg.server)
	}
	if kind := probe_server_kind(cfg) {
		return profile_for(kind)
	}
	return profile_for('openai')
}

// probe_server_kind asks the endpoint to identify itself:
//   * GET /v1/models -> omlx reports owned_by == 'omlx'
//   * GET /props     -> a llama.cpp-only endpoint
// Both probes are best-effort with a short timeout: an unreachable or
// uncooperative server just yields the generic profile.
fn probe_server_kind(cfg Config) ?string {
	base := cfg.base_url.trim_right('/')
	if resp := http_get(cfg, base + '/models') {
		if resp.status_code == 200 {
			if obj := json2.decode[json2.Any](resp.body) {
				if obj is map[string]json2.Any {
					for item in tools.jarr(obj.as_map(), 'data') {
						if tools.jstr(item.as_map(), 'owned_by') == 'omlx' {
							return 'omlx'
						}
					}
				}
			}
		}
	}
	// /props lives at the server root, not under /v1.
	root := if base.ends_with('/v1') { base[..base.len - 3] } else { base }
	if resp := http_get(cfg, root.trim_right('/') + '/props') {
		if resp.status_code == 200
			&& (resp.body.contains('chat_template') || resp.body.contains('default_generation_settings')) {
			return 'llamacpp'
		}
	}
	return none
}

// models_url is the endpoint's model list.
pub fn models_url(cfg Config) string {
	return cfg.base_url.trim_right('/') + '/models'
}

// server_context_length asks the server for the model's context size, if it
// reports one. Config wins when set. omlx exposes it in /v1/models; llama.cpp
// keeps it in /props (`default_generation_settings.n_ctx`), so the cached list
// (which reads both) is tried first and /props is the fallback.
pub fn server_context_length(cfg Config) int {
	if cfg.context_length > 0 {
		return cfg.context_length
	}
	entries := cached_models(cfg, false)
	for e in entries {
		if e.id == cfg.model && e.context_len > 0 {
			return e.context_len
		}
	}
	// The configured name did not match: fall back to the loaded model on a
	// multi-model router, or to the only entry (single-model llama.cpp).
	for e in entries {
		if e.loaded && e.context_len > 0 {
			return e.context_len
		}
	}
	if entries.len == 1 && entries[0].context_len > 0 {
		return entries[0].context_len
	}
	// Older servers keep the context outside /models.
	return fetch_props(cfg).n_ctx
}

// http_get is a tiny helper for the probe requests.
fn http_get(cfg Config, url string) ?http.Response {
	header := http.new_header_from_map({
		http.CommonHeader.authorization: 'Bearer ${cfg.api_key}'
	})
	mut req := http.new_request(.get, url, '')
	req.header = header
	req.read_timeout = 3 * time.second
	req.max_retries = 1
	req.disable_connection_reuse = true
	resp := req.do() or { return none }
	return resp
}

// --- model capabilities ------------------------------------------------------
//
// The server profile says what request *fields* the endpoint understands; the
// model capabilities say whether this particular model can think at all. They
// are separate concerns: a thinking-capable model behind a generic server still
// needs the effort/`enable_thinking` knobs, while a non-thinking model should
// not pretend to (the status bar shows `think:n/a`).

pub struct ModelCapabilities {
pub mut:
	id            string
	owned_by      string
	max_model_len int
	thinking      bool     // the model can manage thinking on/off
	profiles      []string // omlx profile suffixes exposed for this model
	effort_levels []string // accepted reasoning_effort values (best effort)
	source        string   // 'models' | 'props' | 'heuristic' | 'unknown'
}

__global g_caps = ModelCapabilities{
	source: 'unknown'
}
__global g_caps_mu sync.Mutex

// model_capabilities returns the resolved (or last-known) model capabilities.
pub fn model_capabilities() ModelCapabilities {
	g_caps_mu.lock()
	c := g_caps
	g_caps_mu.unlock()
	return c
}

pub fn set_model_capabilities(c ModelCapabilities) {
	g_caps_mu.lock()
	g_caps = c
	g_caps_mu.unlock()
}

// thinking_effort_levels is the UX list offered when the server does not
// advertise its own. The vocabulary is model/template-specific (Qwen uses
// strings, some models numbers), so values are passed through untouched.
pub fn thinking_effort_levels() []string {
	return ['none', 'low', 'medium', 'high']
}

// thinking_levels builds the ctrl-t cycle: 'none' (off) always first, then the
// model's levels in order, de-duplicated.
pub fn thinking_levels(model_levels []string) []string {
	mut levels := ['none']
	for l in model_levels {
		if l !in levels {
			levels << l
		}
	}
	return levels
}

// next_thinking_level returns the level after `cur`, wrapping around. An
// unknown `cur` (e.g. the 'auto' default) starts the cycle at 'none'.
pub fn next_thinking_level(levels []string, cur string) string {
	if levels.len == 0 {
		return 'none'
	}
	mut idx := -1
	for i, l in levels {
		if l == cur {
			idx = i
			break
		}
	}
	return levels[(idx + 1) % levels.len]
}

// looks_like_thinking_model is a name heuristic, used only when the server does
// not report capabilities: these families ship a reasoning/thinking mode.
pub fn looks_like_thinking_model(id string) bool {
	l := id.to_lower()
	for key in ['qwen3', 'deepseek-r', 'deepseek-v3', 'deepseek-v4', 'glm-4.5', 'glm-4.6',
		'glm-5', 'magistral', 'phi-4-reasoning', 'granite', 'seed-oss', 'kimi', 'minimax',
		'inkling'] {
		if l.contains(key) {
			return true
		}
	}
	return false
}

// probe_model_capabilities reads what the endpoint says about the configured
// model. omlx only exposes id/owned_by/max_model_len, but it can list profile
// variants named `<model>:thinking`; llama.cpp reports the chat template via
// /props, which we inspect for thinking controls. Anything else falls back to
// the name heuristic.
fn probe_model_capabilities(cfg Config) ModelCapabilities {
	mut caps := ModelCapabilities{
		id:     cfg.model
		source: 'unknown'
	}
	base := cfg.base_url.trim_right('/')
	if resp := http_get(cfg, base + '/models') {
		if resp.status_code == 200 {
			if obj := json2.decode[json2.Any](resp.body) {
				if obj is map[string]json2.Any {
					for item in tools.jarr(obj.as_map(), 'data') {
						im := item.as_map()
						id := tools.jstr(im, 'id')
						if id != cfg.model && !id.starts_with(cfg.model + ':') {
							continue
						}
						if caps.owned_by == '' {
							caps.owned_by = tools.jstr(im, 'owned_by')
						}
						n := tools.jint(im, 'max_model_len')
						if n > caps.max_model_len {
							caps.max_model_len = n
						}
						if id == cfg.model {
							caps.source = 'models'
						} else {
							caps.profiles << id[cfg.model.len + 1..]
							caps.thinking = true
							caps.source = 'models'
						}
					}
				}
			}
		}
	}
	// llama.cpp: the jinja chat template tells us whether thinking is a knob.
	if !caps.thinking {
		root := if base.ends_with('/v1') { base[..base.len - 3] } else { base }
		if resp := http_get(cfg, root.trim_right('/') + '/props') {
			if resp.status_code == 200 && resp.body.contains('chat_template') {
				if resp.body.contains('enable_thinking') || resp.body.contains('reasoning_effort')
					|| resp.body.contains('thinking') {
					caps.thinking = true
					if caps.source == 'unknown' {
						caps.source = 'props'
					}
				}
			}
		}
	}
	if !caps.thinking && looks_like_thinking_model(cfg.model) {
		caps.thinking = true
		caps.source = 'heuristic'
	}
	if caps.thinking {
		caps.effort_levels = thinking_effort_levels()
	}
	return caps
}

// probe_backend resolves the server profile and the model capabilities at
// startup, in the background so neither blocks the first frame. It also warms
// the model-list cache the selector reads.
pub fn probe_backend(cfg Config) {
	cached_models(cfg, false) // warm the `/v1/models` cache for the selector
	set_server_profile(resolve_server_profile(cfg))
	set_model_capabilities(probe_model_capabilities(cfg))
}
// --- model list + cache ---------------------------------------------------
//
// `GET /v1/models` is the one place a realistic OpenAI-compatible server
// reports per-model data (context length, owner, thinking profile variants).
// The model selector reads it from a session cache so it never hits the
// network on every keypress; `ctrl-r` in the picker forces a refetch.

pub struct ModelEntry {
pub mut:
	id          string
	owned_by    string
	created     i64
	context_len int
	thinking    bool
	loaded      bool
	profiles    []string
	source      string // 'models' | 'props' | 'heuristic' | 'unknown'
}

// parse_models reads the /v1/models body into entries. Pure, so it can be
// unit-tested. It only understands what servers actually report; unknown
// fields are ignored.
// ctx_size_from_args reads the context size from a llama.cpp launch-arg list.
// `--parallel`/`-np` slots share the KV pool, so the per-request window is
// `--ctx-size` divided by the slot count.
pub fn ctx_size_from_args(args []string) int {
	mut ctx := 0
	mut parallel := 1
	mut i := 0
	for i < args.len {
		a := args[i]
		next := if i + 1 < args.len { args[i + 1] } else { '' }
		match a {
			'--ctx-size', '-c' { ctx = next.int() }
			'--parallel', '-np' { parallel = next.int() }
			else {
				if a.starts_with('--ctx-size=') {
					ctx = a.all_after('=').int()
				} else if a.starts_with('--parallel=') {
					parallel = a.all_after('=').int()
				}
			}
		}
		i += 1
	}
	return per_slot_ctx(ctx, parallel)
}

// ctx_size_from_preset reads `ctx-size = N` / `parallel = N` from the router's
// preset text, used when the args array is absent.
pub fn ctx_size_from_preset(preset string) int {
	mut ctx := 0
	mut parallel := 1
	for raw in preset.split_into_lines() {
		line := raw.trim_space()
		if line.starts_with('ctx-size') {
			ctx = line.all_after('=').trim_space().int()
		} else if line.starts_with('parallel') {
			parallel = line.all_after('=').trim_space().int()
		}
	}
	return per_slot_ctx(ctx, parallel)
}

fn per_slot_ctx(ctx int, parallel int) int {
	if ctx <= 0 {
		return 0
	}
	if parallel > 1 {
		return ctx / parallel
	}
	return ctx
}

pub fn parse_models(body string) []ModelEntry {
	mut out := []ModelEntry{}
	obj := json2.decode[json2.Any](body) or { return out }
	if obj !is map[string]json2.Any {
		return out
	}
	m := obj.as_map()
	for item in tools.jarr(m, 'data') {
		im := item.as_map()
		id := tools.jstr(im, 'id')
		if id == '' {
			continue
		}
		mut e := ModelEntry{
			id:       id
			owned_by: tools.jstr(im, 'owned_by')
			created:  i64(tools.jint(im, 'created'))
			source:   'models'
		}
		// llama.cpp nests context in model_info; omlx/vLLM expose it flat.
		info := tools.jmap(im, 'model_info') or { im }
		for key in ['max_model_len', 'max_context_length', 'max_context_size', 'context_length', 'n_ctx'] {
			n := tools.jint(info, key)
			if n > e.context_len {
				e.context_len = n
			}
		}
		// llama.cpp's router reports each model's launch args (and preset);
		// /props only describes the router, so the per-model context lives here.
		if e.context_len == 0 {
			if status := tools.jmap(im, 'status') {
				e.loaded = tools.jstr(status, 'value') == 'loaded'
				mut args := []string{}
				for a in tools.jarr(status, 'args') {
					if a is string {
						args << a
					}
				}
				e.context_len = ctx_size_from_args(args)
				if e.context_len == 0 {
					e.context_len = ctx_size_from_preset(tools.jstr(status, 'preset'))
				}
			}
		}
		// omlx lists a thinking variant as `<model>:<profile>`.
		if p := id.index(':') {
			e.profiles << id[p + 1..]
			e.thinking = true
		}
		out << e
	}
	// A base model is thinking-capable when any of its `:profile` siblings is.
	for i in 0 .. out.len {
		if out[i].thinking {
			continue
		}
		prefix := out[i].id + ':'
		for other in out {
			if other.id.starts_with(prefix) {
				out[i].thinking = true
				out[i].profiles << other.profiles
				break
			}
		}
	}
	return out
}

// PropsInfo is what llama.cpp's `/props` tells us: whether the chat template
// exposes a thinking knob, the loaded model alias, and the per-slot context
// size (`default_generation_settings.n_ctx`).
struct PropsInfo {
mut:
	thinking    bool
	model_alias string
	n_ctx       int
}

// fetch_props GETs /props once. It returns ok=false for servers that do not
// implement it (omlx answers 404).
fn fetch_props(cfg Config) PropsInfo {
	base := cfg.base_url.trim_right('/')
	root := if base.ends_with('/v1') { base[..base.len - 3] } else { base }
	resp := http_get(cfg, root.trim_right('/') + '/props') or { return PropsInfo{} }
	if resp.status_code != 200 {
		return PropsInfo{}
	}
	body := resp.body
	if !body.contains('chat_template') && !body.contains('default_generation_settings') {
		return PropsInfo{}
	}
	obj := json2.decode[json2.Any](body) or { return PropsInfo{} }
	if obj !is map[string]json2.Any {
		return PropsInfo{}
	}
	m := obj.as_map()
	// The template only counts when it carries a real thinking control.
	mut thinking := false
	if body.contains('chat_template') {
		thinking = body.contains('enable_thinking') || body.contains('reasoning_effort')
			|| body.contains('thinking')
	}
	// llama.cpp reports the per-slot context as default_generation_settings.n_ctx;
	// the router exposes it (or the alias) at the top level too.
	mut n_ctx := tools.jint(m, 'n_ctx')
	if n_ctx <= 0 {
		if dg := tools.jmap(m, 'default_generation_settings') {
			n_ctx = tools.jint(dg, 'n_ctx')
			if n_ctx <= 0 {
				if params := tools.jmap(dg, 'params') {
					n_ctx = tools.jint(params, 'n_ctx')
				}
			}
		}
	}
	return PropsInfo{
		thinking:    thinking
		model_alias: tools.jstr(m, 'model_alias')
		n_ctx:       n_ctx
	}
}

// fetch_models performs the GET and enriches the entries with the /props data
// and the name heuristic, so the picker shows context and thinking per model.
pub fn fetch_models(cfg Config) []ModelEntry {
	resp := http_get(cfg, models_url(cfg)) or { return [] }
	mut entries := parse_models(resp.body)
	if entries.len == 0 {
		return entries
	}
	props := fetch_props(cfg)
	single := entries.len == 1
	for i in 0 .. entries.len {
		// /props describes the loaded model: apply it to the only entry, or to
		// the one whose id matches the alias on a multi-model server.
		applies := single || (props.model_alias != '' && entries[i].id == props.model_alias)
		if applies {
			if props.thinking && !entries[i].thinking {
				entries[i].thinking = true
				entries[i].source = 'props'
			}
			if props.n_ctx > 0 && entries[i].context_len == 0 {
				entries[i].context_len = props.n_ctx
			}
		}
		if !entries[i].thinking && looks_like_thinking_model(entries[i].id) {
			entries[i].thinking = true
			entries[i].source = 'heuristic'
		}
	}
	return entries
}

struct ModelCache {
mut:
	base_url   string
	entries    []ModelEntry
	fetched_ms i64
}

__global g_models = ModelCache{}
__global g_models_mu sync.Mutex

// resolve_default_model picks a model when MODEL is not configured: the loaded
// one on a llama.cpp router, otherwise the only model, otherwise the first the
// endpoint advertises. '' means the list was empty (or unreachable).
pub fn resolve_default_model(cfg Config) string {
	entries := cached_models(cfg, false)
	if entries.len == 0 {
		return ''
	}
	for e in entries {
		if e.loaded {
			return e.id
		}
	}
	return entries[0].id
}

// cached_models returns the /v1/models list, refetching only when the cache is
// empty, stale (`models_cache_ttl`, 0 = always) or `force` is set. The mutex is
// held across the request so two callers never fetch at once.
pub fn cached_models(cfg Config, force bool) []ModelEntry {
	g_models_mu.lock()
	now := time.ticks()
	ttl := i64(cfg.models_cache_ttl) * 1000
	fresh := g_models.base_url == cfg.base_url && g_models.entries.len > 0
		&& (cfg.models_cache_ttl <= 0 || now - g_models.fetched_ms < ttl)
	if !fresh || force {
		entries := fetch_models(cfg)
		g_models = ModelCache{
			base_url:   cfg.base_url
			entries:    entries
			fetched_ms: now
		}
	}
	entries := g_models.entries.clone()
	g_models_mu.unlock()
	return entries
}

// capabilities_for_entry turns a list entry into the model capabilities used by
// the thinking UI, without any extra request.
pub fn capabilities_for_entry(e ModelEntry) ModelCapabilities {
	mut c := ModelCapabilities{
		id:            e.id
		owned_by:      e.owned_by
		max_model_len: e.context_len
		thinking:      e.thinking
		profiles:      e.profiles
		source:        e.source
	}
	if c.thinking {
		c.effort_levels = thinking_effort_levels()
	}
	return c
}
