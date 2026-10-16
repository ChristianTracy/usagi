module client

import tools
import x.json2
import proto { ToolCall }

// --- Tool-call JSON salvage -------------------------------------------------

// salvage_args rescues a tool call whose JSON arguments were cut off mid-stream.
// Scan the fragment tracking string/bracket state and close whatever is left
// open. Returns a map, or none.
pub fn salvage_args(fragment string) ?map[string]json2.Any {
	for cut in 0 .. 3 {
		if cut >= fragment.len {
			continue
		}
		mut tail := if cut > 0 { fragment[..fragment.len - cut] } else { fragment }
		mut in_str := false
		mut esc := false
		mut stack := []u8{}
		for ch in tail {
			if in_str {
				if esc {
					esc = false
				} else if ch == `\\` {
					esc = true
				} else if ch == `"` {
					in_str = false
				}
			} else if ch == `"` {
				in_str = true
			} else if ch == `{` || ch == `[` {
				stack << ch
			} else if (ch == `}` || ch == `]`) && stack.len > 0 {
				stack.pop()
			}
		}
		if esc && tail.len > 0 { // dangling backslash at the cut point
			tail = tail[..tail.len - 1]
		}
		if in_str { // close the unterminated string
			tail += '"'
		}
		tail = tail.trim_right(' \t\r\n')
		for tail.ends_with(',') || tail.ends_with(':') { // dangling key/colon
			tail = tail[..tail.len - 1].trim_right(' \t\r\n')
		}
		for i := stack.len - 1; i >= 0; i-- {
			closer := if stack[i] == `{` { '}' } else { ']' }
			tail += closer
		}
		obj := json2.decode[json2.Any](tail) or { continue }
		if obj is map[string]json2.Any {
			return obj
		}
	}
	return none
}

pub struct SalvagedCall {
	pub mut:
	name string
	args map[string]json2.Any
}

// salvage_from_error ports the last-ditch rescue for servers that 500 with
// "failed to parse tool call arguments" and echo the truncated fragment in the
// body. Two stages: close the server's own JSON, then close the echoed
// fragment, then route it to the tool whose parameters match.
pub fn salvage_from_error(body string) ?SalvagedCall {
	outer := salvage_args(body) or { return none }
	if 'error' !in outer {
		return none
	}
	em := tools.jmap(outer, 'error') or { return none }
	if 'message' !in em {
		return none
	}
	msg := tools.jstr(em, 'message')
	a := msg.index("last read: '") or { return none }
	frag := msg[a + 12..]
	saved := salvage_args(frag) or { return none }
	name := tools.infer_tool(saved) or { return none }
	return SalvagedCall{
		name: name
		args: saved
	}
}

// wrap_bare_string_args wraps a raw, non-JSON argument string into the single
// required parameter of a one-argument tool (bash -> command, read_file ->
// path). Small models sometimes emit `head -20 index.html` instead of
// `{"command":"head -20 index.html"}`; the server rejects that before the
// client ever sees a complete call.
fn wrap_bare_string_args(name string, raw string) ?map[string]json2.Any {
	param := tools.single_string_param(name) or { return none }
	mut s := raw.trim_space()
	if s == '' || s.starts_with('{') || s.starts_with('[') {
		return none
	}
	if s.starts_with('"') {
		if s.len < 2 || !s.ends_with('"') {
			return none
		}
		s = s[1..s.len - 1]
	}
	if s == '' {
		return none
	}
	mut obj := map[string]json2.Any{}
	obj[param] = s
	return obj
}

// salvage_stream_tool_calls rescues the tool calls accumulated in the stream
// when the server aborted it with a tool-parse error. It reuses the normal
// repair (truncated JSON via salvage_args) and additionally wraps a bare
// non-JSON argument string into the tool's single required parameter.
fn salvage_stream_tool_calls() ?[]ToolCall {
	mut indices := g_stream.tool_calls.keys()
	if indices.len == 0 {
		return none
	}
	indices.sort()
	mut calls := []ToolCall{}
	for i in indices {
		slot := g_stream.tool_calls[i]
		if slot.name == '' {
			continue
		}
		mut args := slot.arguments.trim_space()
		if args != '' && tools.parse_args(args) == none {
			if repaired := salvage_args(args) {
				args = json2.encode(repaired)
			} else if wrapped := wrap_bare_string_args(slot.name, args) {
				args = json2.encode(wrapped)
			} else {
				return none
			}
		}
		if args == '' {
			continue
		}
		calls << ToolCall{
			id:        if slot.id != '' { slot.id } else { 'salvaged' }
			name:      slot.name
			arguments: args
		}
	}
	if calls.len == 0 {
		return none
	}
	return calls
}

