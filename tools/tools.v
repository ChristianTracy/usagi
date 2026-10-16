module tools


import x.json2

// A tool call, as returned by the model.
pub struct ToolCall {
pub:
	id        string
	name      string
	arguments string
}

pub struct Salvaged {
pub:
	name string
	args map[string]json2.Any
}

const tool_names = ['bash', 'read_file', 'write_file', 'edit_file']

// The full tool list sent to the server.
pub fn tool_schemas() []json2.Any {
	return [bash_schema(), read_file_schema(), write_file_schema(),
		edit_file_schema()]
}

// parse_args parses a tool call's arguments JSON; returns none if broken.
pub fn parse_args(s string) ?map[string]json2.Any {
	if s.trim_space() == '' {
		return map[string]json2.Any{}
	}
	obj := json2.decode[json2.Any](s) or { return none }
	if obj is map[string]json2.Any {
		return obj
	}
	return none
}

// infer_tool routes a salvaged argument object to the tool whose parameters
// match its keys.
pub fn infer_tool(args map[string]json2.Any) ?string {
	keys := args.keys()
	for t in tool_schemas() {
		tm := t.as_map()
		fm := jmap(tm, 'function') or { continue }
		pm := jmap(fm, 'parameters') or { continue }
		props := jmap(pm, 'properties') or { continue }
		mut ok := true
		for k in keys {
			if k !in props {
				ok = false
				break
			}
		}
		if ok && 'name' in fm {
			return jstr(fm, 'name')
		}
	}
	return none
}

// single_string_param returns the sole required parameter of a tool when its
// schema has exactly one required field and it is a string. Used to recover a
// tool call whose arguments arrived as a bare string instead of a JSON object
// (small models sometimes emit `echo hi` instead of `{"command":"echo hi"}`).
pub fn single_string_param(name string) ?string {
	for t in tool_schemas() {
		tm := t.as_map()
		fm := jmap(tm, 'function') or { continue }
		if jstr(fm, 'name') != name {
			continue
		}
		pm := jmap(fm, 'parameters') or { continue }
		req := jarr(pm, 'required')
		if req.len != 1 {
			return none
		}
		key := req[0].str()
		props := jmap(pm, 'properties') or { return none }
		if key !in props {
			return none
		}
		prop := props[key] or { return none }
		if jstr(prop.as_map(), 'type') != 'string' {
			return none
		}
		return key
	}
	return none
}

// strip_outer_quotes removes one layer of surrounding double quotes. Some
// models hand a JSON string with the quotes still inside the value
// (`"path": "\"index.html\""`), which parses as valid JSON but names a file
// called `"index.html"`.
fn strip_outer_quotes(s string) string {
	if s.len >= 2 && s.starts_with('"') && s.ends_with('"') {
		return s[1..s.len - 1]
	}
	return s
}

// normalize_args repairs the argument shapes small models get subtly wrong.
// It is deliberately limited to path-like and command-like parameters:
// content/old_text/new_text are left alone, because a leading and trailing
// quote can be meaningful there (editing a string literal).
pub fn normalize_args(mut args map[string]json2.Any) {
	for key in ['path', 'command'] {
		raw := args[key] or { continue }
		s := raw.str()
		fixed := strip_outer_quotes(s)
		if fixed != s {
			args[key] = fixed
		}
	}
}

// execute dispatches a tool call to its executor and returns the result string.
pub fn execute(tc ToolCall, debug bool) string {
	mut args := parse_args(tc.arguments) or {
		return 'ERROR: arguments were not valid JSON. Resend the tool call.'
	}
	normalize_args(mut args)
	result := match tc.name {
		'bash' { bash_exec(args) }
		'read_file' { read_file_exec(args) }
		'write_file' { write_file_exec(args) }
		'edit_file' { edit_file_exec(args) }
		else { "ERROR: unknown tool '${tc.name}'. Available tools: ${tool_names.join(', ')}." }
	}
	if debug {
		preview := if result.len > 300 { result[..300] } else { result }
		eprintln('[debug] tool ${tc.name} -> ${preview}')
	}
	return result
}
