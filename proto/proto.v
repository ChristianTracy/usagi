module proto

import x.json2

// Data model: the wire-shaped types shared by the client, the agent loop and
// the TUI. Everything here is plain data plus one converter to the JSON the
// server expects.

pub struct ToolCall {
	pub mut:
	id        string
	name      string
	arguments string
}

pub struct Message {
pub mut:
	role         string
	content      string
	tool_calls   []ToolCall
	tool_call_id string
}

pub struct Usage {
	pub mut:
	prompt_tokens     int
	completion_tokens int
	total_tokens      int
	// cached_tokens is how much of the prompt hit the server's KV/prefix
	// cache. Reported by omlx/OpenAI as prompt_tokens_details.cached_tokens,
	// by DeepSeek as prompt_cache_hit_tokens, and by llama.cpp as
	// timings.cache_n. has_cached distinguishes "server reported 0" from
	// "server does not report it at all".
	cached_tokens int
	has_cached    bool
	// ttft_ms is the time to first token. omlx reports it in seconds as
	// usage.time_to_first_token; llama.cpp reports prompt_ms in its timings.
	// has_ttft distinguishes "reported" from "not reported".
	ttft_ms  int
	has_ttft bool
}

pub struct ChatReply {
pub mut:
	content    string
	tool_calls []ToolCall
	live       bool
	salvaged   bool
	usage      Usage
	has_usage  bool
	gen_ms     i64 // time from first to last streamed token (server-like T/S)
}

// show_token is the live-stream sink: kind is "content", "thinking" or "debug".
pub type TokenFn = fn (kind string, text string)

// message_to_any converts one history entry to the JSON the server expects.
pub fn message_to_any(m Message) json2.Any {
	mut o := map[string]json2.Any{}
	o['role'] = m.role
	if m.content != '' || m.tool_calls.len == 0 {
		o['content'] = m.content
	}
	if m.tool_calls.len > 0 {
		mut calls := []json2.Any{}
		for tc in m.tool_calls {
			mut fn_map := map[string]json2.Any{}
			fn_map['name'] = tc.name
			fn_map['arguments'] = tc.arguments
			mut call := map[string]json2.Any{}
			call['id'] = tc.id
			call['type'] = 'function'
			call['function'] = fn_map
			calls << call
		}
		o['tool_calls'] = calls
	}
	if m.tool_call_id != '' {
		o['tool_call_id'] = m.tool_call_id
	}
	return o
}
