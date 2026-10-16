module main

import tools
import x.json2
import client { handle_sse_line, salvage_args, salvage_from_error }

fn test_salvage_args() {
	m := salvage_args('{"command": "ls') or { panic('salvage failed') }
	assert tools.jstr(m, 'command') == 'ls'
	m2 := salvage_args('{"path": "a.txt", "content": "hello') or { panic('salvage2 failed') }
	assert tools.jstr(m2, 'path') == 'a.txt'
	assert tools.jstr(m2, 'content') == 'hello'
	m3 := salvage_args('{"path": "a.txt", "content": "x",') or { panic('salvage3 failed') }
	assert tools.jstr(m3, 'content') == 'x'
	assert salvage_args('not json at all') == none
}

fn test_salvage_from_error() {
	mut msg := map[string]json2.Any{}
	msg['message'] = 'failed to parse tool call arguments, last read: \'{"path":"note.txt","content":"hel'
	mut e := map[string]json2.Any{}
	e['error'] = msg
	s := salvage_from_error(json2.encode(e)) or { panic('expected salvage') }
	assert s.name == 'write_file'
	assert tools.jstr(s.args, 'path') == 'note.txt'
	assert tools.jstr(s.args, 'content') == 'hel'
}

fn test_jstr_missing() {
	mut m := map[string]json2.Any{}
	m['a'] = 'x'
	m['n'] = 3
	assert tools.jstr(m, 'a') == 'x'
	assert tools.jstr(m, 'nope') == ''
	assert tools.jstr(m, 'n') == ''
	assert tools.jint(m, 'n') == 3
	assert tools.jint(m, 'nope') == 0
	assert tools.jarr(m, 'nope').len == 0
	assert tools.jmap(m, 'nope') == none
}

fn test_sse_invalid_tool_call_error() {
	handle_sse_line('data: {"error":{"message":"Model output contains an unrecoverable tool call.","code":"invalid_tool_call"}}') or {
		assert err.msg().starts_with('invalid_tool_call:')
		return
	}
	assert false
}

fn test_sse_generic_error() {
	handle_sse_line('data: {"error":{"message":"boom"}}') or {
		assert err.msg().contains('server error')
		return
	}
	assert false
}
