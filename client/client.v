module client

import net.http
import os
import strings
import term
import time
import tools
import x.json2
import app as appmod { App }
import config { Config }
import ctx { trim_for_request }
import proto { ChatReply, Message, TokenFn, ToolCall, Usage, message_to_any }
import server { degrade_server_profile, server_profile }
import state
import ui { Ui }

// emit_phase notifies the UI of a request lifecycle change, as a
// `('phase', '<phase>[ <detail>]')` token. The TUI renders it in the status
// bar; the line REPL ignores it.
fn emit_phase(on_token TokenFn, text string) {
	if on_token != unsafe { nil } {
		on_token('phase', text)
	}
}

// last_stream_streamed reports whether the most recent chat() attempt produced
// any streamed output (reasoning, content, or a tool-call fragment). Retrying
// after that point is unsafe: several servers reject it with "previously
// delivered tool calls must not be executed again on retry", and it would
// replay the partial answer in the UI.
pub fn last_stream_streamed() bool {
	return g_stream.first_token_ms > 0
}

// --- Streaming state --------------------------------------------------------
// net.http's progress callback carries no user-data argument, so the state it
// fills lives in a module global (enabled with -enable-globals).

pub struct ToolCallSlot {
pub mut:
	id        string
	name      string
	arguments string
	live      bool
}

pub struct StreamState {
pub mut:
	content        strings.Builder
	tool_calls     map[int]ToolCallSlot
	usage          Usage
	has_usage      bool
	on_token       TokenFn = unsafe { nil }
	show_reasoning bool
	rest           string
	body_started   bool // first body chunk seen (headers received)
	first_token_ms i64 // stream window: first token -> last token
	last_token_ms  i64
}

__global g_stream = StreamState{}

// mark_token records the streaming window (first -> last token) so tok/s can
// be reported the way a server logs it, without tool/network time.
fn (mut s StreamState) mark_token() {
	now := time.ticks()
	if s.first_token_ms == 0 {
		s.first_token_ms = now
	}
	s.last_token_ms = now
}

// --- Request body -----------------------------------------------------------

pub fn build_body(messages []Message, cfg Config, schemas []json2.Any) string {
	trimmed := trim_for_request(messages, cfg)
	mut msgs := []json2.Any{}
	for m in trimmed {
		msgs << message_to_any(m)
	}
	mut body := map[string]json2.Any{}
	body['model'] = cfg.model
	body['messages'] = msgs
	body['stream'] = true
	// Deterministic sampling is a big reliability win for small models, but by
	// default the agent omits temperature so the server/preset decides. Set it
	// (e.g. 0 for deterministic tool calls) to override; negative = omit.
	if cfg.temperature >= 0 {
		body['temperature'] = json2.Any(cfg.temperature)
	}
	if cfg.top_p > 0 && cfg.top_p < 1.0 {
		body['top_p'] = json2.Any(cfg.top_p)
	}
	if cfg.max_tokens > 0 {
		body['max_tokens'] = json2.Any(cfg.max_tokens)
	}
	if cfg.frequency_penalty != 0 {
		body['frequency_penalty'] = json2.Any(cfg.frequency_penalty)
	}
	if cfg.presence_penalty != 0 {
		body['presence_penalty'] = json2.Any(cfg.presence_penalty)
	}
	if cfg.seed >= 0 {
		body['seed'] = json2.Any(cfg.seed)
	}
	if cfg.stream_options {
		// Ask the server to append a final chunk with token usage.
		mut stream_opts := map[string]json2.Any{}
		stream_opts['include_usage'] = true
		body['stream_options'] = stream_opts
	}
	// Optional, server-specific fields. `profile.degraded` means the endpoint
	// already rejected one of them, so we stop sending the whole group rather
	// than risk failing every turn (see chat()'s 400/422 fallback).
	profile := server_profile()
	if schemas.len > 0 {
		body['tools'] = schemas
		if profile.tool_choice && !profile.degraded && cfg.tool_choice != '' {
			body['tool_choice'] = cfg.tool_choice
		}
		if profile.parallel_tool_calls && !profile.degraded && cfg.parallel_tool_calls {
			body['parallel_tool_calls'] = true
		}
	}
	// llama.cpp-only sampling extensions (top_k/min_p/repeat_penalty). omlx
	// does not understand them, so they are gated by the server profile.
	if profile.kind == 'llamacpp' && !profile.degraded {
		if cfg.top_k > 0 {
			body['top_k'] = json2.Any(cfg.top_k)
		}
		if cfg.min_p >= 0 {
			body['min_p'] = json2.Any(cfg.min_p)
		}
		if cfg.repeat_penalty > 0 {
			body['repeat_penalty'] = json2.Any(cfg.repeat_penalty)
		}
	}
	// Thinking controls: `reasoning` is the on/off switch and `reasoning_effort`
	// its depth. When off we send 'none' (and, for templates that understand the
	// key, enable_thinking=false). `thinking_budget` is omlx-only.
	effort := if cfg.reasoning { cfg.reasoning_effort } else { 'none' }
	if effort != '' && !profile.degraded {
		body['reasoning_effort'] = effort
	}
	if !cfg.reasoning && !profile.degraded && profile.chat_template_kwargs
		&& profile.kind in ['omlx', 'llamacpp'] {
		mut kwargs := map[string]json2.Any{}
		kwargs['enable_thinking'] = false
		body['chat_template_kwargs'] = kwargs
	}
	if cfg.thinking_budget > 0 && !profile.degraded && profile.thinking_budget {
		body['thinking_budget'] = cfg.thinking_budget
	}
	return json2.encode(body)
}

// --- SSE parsing ------------------------------------------------------------

pub fn handle_tool_call_deltas(delta map[string]json2.Any) {
	if 'tool_calls' !in delta {
		return
	}
	for tc_any in tools.jarr(delta, 'tool_calls') {
		tcm := tc_any.as_map()
		idx := tools.jint(tcm, 'index')
		mut slot := g_stream.tool_calls[idx] or { ToolCallSlot{} }
		if tools.jstr(tcm, 'id') != '' {
			slot.id = tools.jstr(tcm, 'id')
		}
		if fm := tools.jmap(tcm, 'function') {
			slot.name += tools.jstr(fm, 'name')
			frag := tools.jstr(fm, 'arguments')
			if frag != '' {
				if !slot.live {
					// First fragment of this call: open the stream.
					// Routed through on_token so TUI mode never writes raw
					// to stdout (that would corrupt the frame).
					slot.live = true
					if g_stream.on_token != unsafe { nil } {
						g_stream.on_token('tool', '\n❯❯❯❯ ${slot.name}')
					}
				}
				if g_stream.on_token != unsafe { nil } {
					g_stream.on_token('debug', frag)
				}
				g_stream.mark_token()
			}
			slot.arguments += frag
		}
		g_stream.tool_calls[idx] = slot
	}
}

// handle_sse_line processes one complete "data: ..." line from the stream.
pub fn handle_sse_line(line string) ! {
	// Tolerate both `data: {...}` and `data:{...}`; some servers omit the space.
	if !line.starts_with('data:') {
		return
	}
	mut payload := line[5..]
	if payload.starts_with(' ') {
		payload = payload[1..]
	}
	if ui.g_ui.debug && !state.g_tui { // stderr would corrupt the TUI frame
		preview := if payload.len > 400 { payload[..400] } else { payload }
		ui.g_ui.dbg('<- ${preview}')
	}
	if payload == '[DONE]' { // standard end-of-stream marker
		return
	}
	obj := json2.decode[json2.Any](payload) or { return }
	if obj !is map[string]json2.Any {
		return
	}
	m := obj.as_map()
	if 'error' in m {
		em := tools.jmap(m, 'error') or { map[string]json2.Any{} }
		code := tools.jstr(em, 'code')
		msg := tools.jstr(em, 'message')
		if code != '' {
			short := if msg.len > 200 { msg[..200] } else { msg }
			return error('${code}: ${short}')
		}
		return error('server error: ${tools.jget(m, 'error').str()}')
	}
	if um := tools.jmap(m, 'usage') {
		// Prefer the OpenAI/omlx field; fall back to DeepSeek's naming.
		mut cached := tools.jint(um, 'prompt_cache_hit_tokens')
		mut has_cached := 'prompt_cache_hit_tokens' in um
		if pd := tools.jmap(um, 'prompt_tokens_details') {
			if 'cached_tokens' in pd {
				has_cached = true
			}
			c := tools.jint(pd, 'cached_tokens')
			if c > cached {
				cached = c
			}
		}
		// omlx's TTFT fields are in seconds.
		mut ttft_ms := 0
		mut has_ttft := false
		for key in ['time_to_first_token', 'time_to_first_visible_token', 'prompt_eval_duration'] {
			secs := tools.jget(um, key).f64()
			if secs > 0 {
				ttft_ms = int(secs * 1000.0)
				has_ttft = true
				break
			}
		}
		g_stream.usage = Usage{
			prompt_tokens:     tools.jint(um, 'prompt_tokens')
			completion_tokens: tools.jint(um, 'completion_tokens')
			total_tokens:      tools.jint(um, 'total_tokens')
			cached_tokens:     cached
			has_cached:        has_cached
			ttft_ms:           ttft_ms
			has_ttft:          has_ttft
		}
		g_stream.has_usage = true
	}
	// llama.cpp reports the reused-prefix length as timings.cache_n and the
	// prompt (first-token) time as timings.prompt_ms.
	if tm := tools.jmap(m, 'timings') {
		if 'cache_n' in tm {
			g_stream.usage.has_cached = true
		}
		cn := tools.jint(tm, 'cache_n')
		if cn > g_stream.usage.cached_tokens {
			g_stream.usage.cached_tokens = cn
		}
		if !g_stream.usage.has_ttft {
			ms := tools.jget(tm, 'prompt_ms').f64()
			if ms > 0 {
				g_stream.usage.ttft_ms = int(ms)
				g_stream.usage.has_ttft = true
			}
		}
	}
	choices := tools.jarr(m, 'choices')
	if choices.len == 0 {
		return
	}
	cm := choices[0].as_map()
	if 'delta' !in cm {
		return
	}
	delta := tools.jmap(cm, 'delta') or { return }
	// Thinking models put the inner monologue in delta.reasoning (llama.cpp)
	// or delta.reasoning_content (vLLM/omlx); the answer is delta.content.
	fields := if g_stream.show_reasoning {
		['content', 'reasoning', 'reasoning_content']
	} else {
		['content']
	}
	for field in fields {
		if field !in delta {
			continue
		}
		token := tools.jstr(delta, field)
		if token == '' {
			continue
		}
		kind := if field == 'content' { 'content' } else { 'thinking' }
		if field == 'content' {
			g_stream.content.write_string(token)
		}
		// The TUI derives the phase (thinking vs writing) from this token's
		// kind, so there is nothing to emit here.
		g_stream.mark_token()
		if g_stream.on_token != unsafe { nil } {
			g_stream.on_token(kind, token)
		}
	}
	handle_tool_call_deltas(delta)
}

// on_body_chunk is called by net.http for every chunk of the response body.
// It also polls the keyboard so Escape (or Ctrl-C) cancels the stream.
pub fn on_body_chunk(mut req &http.Request, chunk []u8, body_so_far u64, _ u64, _ int) ! {
	// Esc interrupts the stream. In TUI mode the TUI event handler sets
	// g_interrupt (term.ui owns stdin, so raw key polling is not possible).
	mut interrupted := false
	if state.g_tui {
		interrupted = state.g_interrupt
	} else if os.is_atty(0) > 0 {
		key := term.key_pressed(blocking: false, echo: false)
		interrupted = key == 27 || key == 3
	}
	if interrupted {
		// Don't just return an error here: that would leak the socket and
		// let the server keep generating into an open pipe. Instead cap the
		// receive so the http stack breaks out of its read loop and closes
		// the connection — the server then sees the disconnect and stops
		// generating.
		req.stop_receiving_limit = i64(body_so_far) + 1
		state.g_aborted = true
		return
	}
	if !g_stream.body_started {
		// Headers are in and the body is streaming: waiting for the first token.
		g_stream.body_started = true
		emit_phase(g_stream.on_token, 'waiting')
	}
	g_stream.rest += chunk.bytestr()
	for {
		nl := g_stream.rest.index_u8(`\n`)
		if nl < 0 {
			break
		}
		line := g_stream.rest[..nl].trim_right('\r')
		g_stream.rest = g_stream.rest[nl + 1..]
		handle_sse_line(line)!
	}
}

// --- Model call (streaming) -------------------------------------------------

pub fn chat(app App, messages []Message, on_token TokenFn) !ChatReply {
	header := http.new_header_from_map({
		http.CommonHeader.content_type:  'application/json'
		http.CommonHeader.authorization: 'Bearer ${app.cfg.api_key}'
	})
	mut attempt := 0
	for {
		// app.tool_choice is a per-turn override set by run_agent (e.g. force a
		// tool call after a malformed one); it wins over the config default.
		mut cfg := app.cfg
		if app.tool_choice != '' {
			cfg.tool_choice = app.tool_choice
		}
		body := build_body(messages, cfg, tools.tool_schemas())
		app.ui.dbg('-> POST ${app.url}  (${messages.len} messages, ${body.len} bytes)')
		if app.ui.debug {
			req_any := json2.decode[json2.Any](body) or { json2.Any('') }
			app.ui.dbg(req_any.json_str())
		}
		g_stream = StreamState{
			tool_calls:     map[int]ToolCallSlot{}
			on_token:       on_token
			show_reasoning: app.cfg.reasoning
		}
		emit_phase(on_token, 'connecting')
		// A manual Request because 0.5.0's FetchConfig does not expose
		// read_timeout. max_retries: 1 -> no silent retry of an interrupted stream.
		mut req := http.new_request(.post, app.url, body)
		req.header = header
		req.read_timeout = app.cfg.read_timeout * time.second
		req.write_timeout = app.cfg.read_timeout * time.second
		req.max_retries = 1
		// omlx closes idle keep-alive connections; the client's connection pool
		// would then reuse the dead socket ("response does not start with HTTP/").
		req.disable_connection_reuse = true
		req.on_progress_body = on_body_chunk
		state.g_aborted = false
		resp := req.do() or {
			if err.msg() == 'interrupted' {
				return error('interrupted')
			}
			// The server aborted the stream because it could not parse a tool
			// call. Before giving up, try to rescue the call the model did emit
			// (truncated JSON, or a bare string for a one-arg tool).
			if err.msg().contains('invalid_tool_call') || err.msg().contains('incomplete_tool_call') {
				app.ui.dbg('stream tool-call error (${g_stream.tool_calls.len} slot(s) buffered): ${err.msg()}')
				if calls := salvage_stream_tool_calls() {
					app.ui.dbg('salvaged tool call after stream error')
					return ChatReply{
						tool_calls: calls
						salvaged:   true
					}
				}
			}
			// Retry a transient connection failure ONLY if nothing was streamed:
			// once the server has produced output (above all a tool call), a
			// retry is rejected with "previously delivered tool calls must not
			// be executed again on retry", and it replays the partial answer.
			if attempt < 2 && g_stream.first_token_ms == 0 {
				attempt++
				emit_phase(on_token, 'retrying ${attempt}/2')
				time.sleep(attempt * time.second)
				continue
			}
			return err
		}
		if state.g_aborted {
			return error('interrupted')
		}
		// The server rejected an optional request field (tool_choice /
		// parallel_tool_calls / chat_template_kwargs). Degrade the profile for
		// the rest of the session and retry once without them; otherwise the
		// turn would fail for a purely cosmetic incompatibility.
		if (resp.status_code == 400 || resp.status_code == 422) && !server_profile().degraded {
			degrade_server_profile()
			app.ui.dbg('server rejected optional fields (HTTP ${resp.status_code}); retrying without them')
			emit_phase(on_token, 'retrying (compat)')
			continue
		}
		// A local server that is still loading or busy returns 503/504. Retry
		// only when nothing streamed yet, so a partial answer is never replayed.
		if (resp.status_code == 503 || resp.status_code == 504) && attempt < 2
			&& g_stream.first_token_ms == 0 {
			attempt++
			emit_phase(on_token, 'retrying ${attempt}/2')
			time.sleep(attempt * time.second)
			continue
		}
		if resp.status_code >= 400 {
			// The server answered but failed (500 bad tool-call JSON, 503
			// overloaded, ...). Try the echoed-fragment salvage first.
			if resp.status_code == 500 && resp.body.contains('parse') {
				if salvaged := salvage_from_error(resp.body) {
					return ChatReply{
						tool_calls: [
							ToolCall{
								id:        'salvaged'
								name:      salvaged.name
								arguments: json2.encode(salvaged.args)
							},
						]
						salvaged:   true
					}
				}
			}
			if resp.body.contains('invalid_tool_call') || resp.body.contains('incomplete_tool_call') {
				return error('invalid_tool_call: the model produced a malformed tool call (HTTP ${resp.status_code})')
			}
			return error('server returned ${resp.status_code} ${resp.status_msg} — the request may have been too big; try smaller chunks')
		}
		mut reply := ChatReply{
			content:   g_stream.content.str()
			usage:     g_stream.usage
			has_usage: g_stream.has_usage
		}
		if g_stream.first_token_ms > 0 && g_stream.last_token_ms > g_stream.first_token_ms {
			reply.gen_ms = g_stream.last_token_ms - g_stream.first_token_ms
		}
		mut indices := g_stream.tool_calls.keys()
		indices.sort()
		for i in indices {
			slot := g_stream.tool_calls[i]
			id := if slot.id != '' { slot.id } else { 'call_${i}' }
			mut args := slot.arguments
			// A stream that simply ends mid-tool-call (no HTTP 500) leaves
			// truncated JSON here; rescue it the same way the 500 path does.
			mut salvaged := false
			if args != '' && tools.parse_args(args) == none {
				if repaired := salvage_args(args) {
					args = json2.encode(repaired)
					salvaged = true
				}
			}
			reply.tool_calls << ToolCall{
				id:        id
				name:      slot.name
				arguments: args
			}
			if slot.live {
				reply.live = true
			}
			if salvaged {
				reply.salvaged = true
			}
		}
		return reply
	}
}
