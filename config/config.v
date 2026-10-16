module config

import json2
import os

// ANSI SGR codes, overridable from config.json under "colors".
// content = the answer, thinking = inner monologue, debug = tool/debug lines.
pub struct Colors {
	pub mut:
	content  string = '32'
	thinking string = '2'
	tool     string = '2'
	debug    string = '2'
}

// TuiConfig holds optional terminal-UI tunables. Defaults match the
// hard-coded behaviour of the TUI, so configs without a "tui" block keep
// working unchanged.
pub struct TuiConfig {
pub mut:
	bell             bool
	timestamps       bool = true
	thinking_default bool = true
	input_history    bool = true
	theme            string = 'dark'
	mouse            bool
	// colors overrides individual theme entries by name, e.g.
	// {"content": "#78dc78", "accent": "#d787ff"}.
	colors map[string]string
	// animation controls motion in the status bar / pet: 'full' (default),
	// 'calm' (slower spinner, no pet flapping) or 'off' (static). Setting
	// NO_COLOR or TERM=dumb forces 'off'.
	animation string = 'full'
	// pet selects the status-bar companion: 'pixel' (half-block rabbit sprite,
	// default), 'ascii' (pet.txt frames) or 'off'.
	pet string = 'pixel'
}

// SessionsConfig holds the saved-sessions tunables.
pub struct SessionsConfig {
pub mut:
	dir               string // '' = ~/.usagi/sessions (or USAGI_SESSIONS_DIR)
	autosave          bool   = true
	restore_workspace bool   = true // /resume restores the stored workspace
	max               int    = 50 // cap of saved sessions (prunes the oldest)
	max_age_days      int // 0 = off; prune sessions idle for N days
}

pub struct Config {
pub mut:
	base_url       string
	model          string
	api_key        string = 'none'
	system         string = 'You are a coding assistant.'
	reasoning      bool   = true
	context_length int
	colors         Colors = Colors{}
	tui            TuiConfig = TuiConfig{}
	sessions       SessionsConfig = SessionsConfig{}
	// --- request / agent tuning (all optional) ---------------------------
	// Every sampling knob defaults to "omit" so the server/preset decides;
	// override a value (config.json, env or `/samplings`) to send it.
	temperature      f64    = -1.0 // negative = omit
	top_p            f64    = 1.0
	max_tokens       int    // 0 = server default
	// Extra sampling overrides, editable at runtime with `/samplings` (session
	// only). Each follows the "omit" convention so the server/preset default
	// applies when unset: temperature < 0, top_p <= 0 or >= 1, top_k <= 0,
	// min_p < 0, repeat_penalty <= 0, frequency/presence_penalty == 0,
	// seed < 0. top_k/min_p/repeat_penalty are llama.cpp-only and are gated by
	// the server profile in build_body.
	top_k             int
	min_p             f64 = -1.0
	repeat_penalty    f64
	frequency_penalty f64
	presence_penalty  f64
	seed              int = -1
	stream_options   bool   = true // send stream_options.include_usage
	reasoning_effort string // effort when reasoning is on: '', none, low, medium, high (or a model-specific value). 'none' disables thinking.
	// thinking_budget caps the thinking tokens (omlx); 0 = server default.
	thinking_budget int
	read_timeout     int    = 300  // seconds for one streaming request
	single_tool_call bool   = true // reject >1 tool call in one assistant message
	// --- tool limits ---
	max_tool_output int    = 6000 // max chars in one tool result
	tool_timeout    int    = 120  // max seconds for one bash command
	// workspace overrides the folder the file tools are fenced to (and bash's
	// cwd). '' = the folder where config.json lives.
	workspace string
	// --- server dialect ---------------------------------------------------
	// server selects the request dialect: 'auto' (probe /v1/models + /props),
	// 'omlx', 'llamacpp' or 'openai'. See server/server.v for why this exists.
	server string = 'auto'
	// models_cache_ttl is how many seconds the `/v1/models` list is reused
	// before the model selector refetches it. 0 = always refetch.
	models_cache_ttl int = 300
	// tool_choice is sent as-is when schemas are present and the server profile
	// supports it: 'auto', 'required', 'none' (or a JSON object for a specific
	// tool). '' omits the field. Note 'required' is ignored by some servers.
	tool_choice string
	// parallel_tool_calls is only sent when the server profile supports it
	// (llama.cpp); omlx has no such field. The agent still enforces one tool
	// call at a time via single_tool_call.
	parallel_tool_calls bool
}

pub fn load_config(root string) Config {
	load_env_file(root)
	path := os.join_path(root, 'config.json')
	mut cfg := Config{}
	if os.exists(path) {
		text := os.read_file(path) or {
			eprintln('error: cannot read ${path}: ${err}')
			exit(1)
		}
		cfg = json2.decode[Config](text) or {
			eprintln('error: invalid config ${path}: ${err}')
			exit(1)
		}
	}
	apply_env_overrides(mut cfg)
	return cfg
}

// --- .env / environment overrides ------------------------------------------
// Secrets and machine-specific values (endpoint, model, api key) belong in a
// .env file next to config.json. .env is gitignored; .env.example is committed
// as a template. Real process environment variables win over .env, and both
// win over config.json, so CI/production can inject them without a file.

// load_env_file reads `<root>/.env` (if present) and exports each KEY=VALUE
// that is not already set in the real environment. Blank lines, `#` comments,
// an optional leading `export `, and single/double quoted values are handled.
pub fn load_env_file(root string) {
	path := os.join_path(root, '.env')
	if !os.exists(path) {
		return
	}
	text := os.read_file(path) or { return }
	for raw in text.split('\n') {
		line := raw.trim_right('\r').trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		mut body := line
		if body.starts_with('export ') {
			body = body[7..].trim_left(' \t')
		}
		eq := body.index('=') or { continue }
		if eq <= 0 {
			continue
		}
		key := body[..eq].trim_space()
		mut val := body[eq + 1..].trim_space()
		if val.len >= 2
			&& ((val.starts_with('"') && val.ends_with('"')) || (val.starts_with("'") && val.ends_with("'"))) {
			val = val[1..val.len - 1]
		}
		if key == '' || os.getenv(key) != '' {
			continue // never overwrite a real environment variable
		}
		os.setenv(key, val, true)
	}
}

fn env_str(key string, fallback string) string {
	v := os.getenv(key).trim_space()
	return if v != '' { v } else { fallback }
}

fn env_bool(key string, fallback bool) bool {
	v := os.getenv(key).trim_space().to_lower()
	if v == '' {
		return fallback
	}
	return v in ['1', 'true', 'yes', 'on']
}

fn env_int(key string, fallback int) int {
	v := os.getenv(key).trim_space()
	if v == '' {
		return fallback
	}
	return v.int()
}

fn env_f64(key string, fallback f64) f64 {
	v := os.getenv(key).trim_space()
	if v == '' {
		return fallback
	}
	return v.f64()
}

// apply_env_overrides layers environment variables on top of config.json.
fn apply_env_overrides(mut cfg Config) {
	cfg.base_url = env_str('BASE_URL', cfg.base_url)
	cfg.model = env_str('MODEL', cfg.model)
	cfg.api_key = env_str('API_KEY', cfg.api_key)
	cfg.system = env_str('SYSTEM', cfg.system)
	cfg.reasoning = env_bool('REASONING', cfg.reasoning)
	cfg.context_length = env_int('CONTEXT_LENGTH', cfg.context_length)
	cfg.temperature = env_f64('TEMPERATURE', cfg.temperature)
	cfg.top_p = env_f64('TOP_P', cfg.top_p)
	cfg.max_tokens = env_int('MAX_TOKENS', cfg.max_tokens)
	cfg.top_k = env_int('TOP_K', cfg.top_k)
	cfg.min_p = env_f64('MIN_P', cfg.min_p)
	cfg.repeat_penalty = env_f64('REPEAT_PENALTY', cfg.repeat_penalty)
	cfg.frequency_penalty = env_f64('FREQUENCY_PENALTY', cfg.frequency_penalty)
	cfg.presence_penalty = env_f64('PRESENCE_PENALTY', cfg.presence_penalty)
	cfg.seed = env_int('SEED', cfg.seed)
	cfg.stream_options = env_bool('STREAM_OPTIONS', cfg.stream_options)
	cfg.reasoning_effort = env_str('REASONING_EFFORT', cfg.reasoning_effort)
	cfg.read_timeout = env_int('READ_TIMEOUT', cfg.read_timeout)
	cfg.single_tool_call = env_bool('SINGLE_TOOL_CALL', cfg.single_tool_call)
	cfg.max_tool_output = env_int('MAX_TOOL_OUTPUT', cfg.max_tool_output)
	cfg.tool_timeout = env_int('TOOL_TIMEOUT', cfg.tool_timeout)
	cfg.workspace = env_str('WORKSPACE', cfg.workspace)
	cfg.tui.animation = env_str('TUI_ANIMATION', cfg.tui.animation)
	cfg.tui.pet = env_str('TUI_PET', cfg.tui.pet)
	cfg.server = env_str('SERVER', cfg.server)
	cfg.models_cache_ttl = env_int('MODELS_CACHE_TTL', cfg.models_cache_ttl)
	cfg.tool_choice = env_str('TOOL_CHOICE', cfg.tool_choice)
	cfg.parallel_tool_calls = env_bool('PARALLEL_TOOL_CALLS', cfg.parallel_tool_calls)
	cfg.reasoning_effort = env_str('REASONING_EFFORT', cfg.reasoning_effort)
	cfg.thinking_budget = env_int('THINKING_BUDGET', cfg.thinking_budget)
	cfg.sessions.dir = env_str('USAGI_SESSIONS_DIR', cfg.sessions.dir)
	cfg.sessions.autosave = env_bool('USAGI_AUTOSAVE', cfg.sessions.autosave)
	cfg.sessions.restore_workspace = env_bool('USAGI_RESTORE_WORKSPACE', cfg.sessions.restore_workspace)
	cfg.sessions.max = env_int('USAGI_SESSIONS_MAX', cfg.sessions.max)
	cfg.sessions.max_age_days = env_int('USAGI_SESSIONS_MAX_AGE_DAYS', cfg.sessions.max_age_days)
}

// system.md wins over the "system" key in config.json, so it is easier to
// edit than JSON.
pub fn load_system_prompt(root string, cfg Config) string {
	path := os.join_path(root, 'system.md')
	if os.exists(path) {
		text := os.read_file(path) or { return cfg.system }
		return text.trim_space()
	}
	return cfg.system
}
