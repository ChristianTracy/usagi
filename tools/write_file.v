module tools

import os

import x.json2

// max_write is a sanity cap on one write_file call: a runaway model that
// dumps a whole codebase into a single call is stopped before it floods the
// context (the result is an ERROR it can act on, not a silent truncation).
const max_write = 500000

fn write_file_schema() json2.Any {
	desc := 'Create or replace a file; append=true adds to the end (write big files in small chunks). Paths inside the workspace. Example: {"path":"notes.txt","content":"hi\\n"}'
	schema := '{"type":"function","function":{"name":"write_file","description":${json2.encode(desc)},"parameters":{"type":"object","properties":{"path":{"type":"string","description":"File to write"},"content":{"type":"string","description":"Text to write"},"append":{"type":"boolean","description":"true = append, false = replace"}},"required":["path","content"]}}}'
	return json2.decode[json2.Any](schema) or { json2.Any(map[string]json2.Any{}) }
}

fn write_file_exec(args map[string]json2.Any) string {
	if 'path' !in args || 'content' !in args {
		return "ERROR: 'path' and 'content' are required. Resend the tool call."
	}
	path := jstr(args, 'path')
	content := jstr(args, 'content')
	if path == '' {
		return "ERROR: 'path' is required. Resend the tool call."
	}
	if content.len > max_write {
		return 'ERROR: content is ${content.len} chars, over the ${max_write}-char limit. Split it into smaller write_file calls (append=true for the rest).'
	}
	p := safe_path(path, true) or { return 'ERROR: ${err.msg()}' }
	os.mkdir_all(os.dir(p)) or { return 'ERROR: cannot create parent folders: ${err.msg()}' }
	if jbool(args, 'append') {
		mut f := os.open_file(p, 'a') or { return 'ERROR: cannot open ${path}: ${err.msg()}' }
		f.write_string(content) or { return 'ERROR: cannot write ${path}: ${err.msg()}' }
		f.close()
		return 'Appended ${content.len} chars to ${path}.${preview_suffix(content)}'
	}
	os.write_file(p, content) or { return 'ERROR: cannot write ${path}: ${err.msg()}' }
	return 'Wrote ${content.len} chars to ${path}.${preview_suffix(content)}'
}

// preview_suffix returns a short ' first line: ...' tail for a tool result, so
// the model (and the transcript) can see what was actually written without
// echoing the whole content back into the context.
fn preview_suffix(content string) string {
	if content == '' {
		return ''
	}
	mut first := content.split('\n')[0].trim_space()
	if first.len > 80 {
		first = first[..80] + '…'
	}
	if first == '' {
		return ''
	}
	return ' First line: ${first}'
}
