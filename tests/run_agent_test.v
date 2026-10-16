module main

import agent { run_agent }
import app as appmod { App }
import config { Config }
import proto { Message }
import net
import time

// End-to-end agent-loop test with a mock SSE server: the first request returns
// a bash tool call, the second returns a plain answer. Verifies tool dispatch,
// the result round-trip, and that the loop ends on the final message.

__global g_agent_listener &net.TcpListener = unsafe { nil }
__global g_agent_responses []string
__global g_seen_tokens []string

fn collect_token(kind string, text string) {
	g_seen_tokens << '${kind}:${text}'
}

fn agent_serve_many() {
	for resp in g_agent_responses {
		mut conn := g_agent_listener.accept() or { return }
		mut buf := []u8{len: 16384}
		conn.read(mut buf) or {}
		conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n') or {
			return
		}
		conn.write_string(resp) or { return }
		conn.close() or {}
	}
}

fn test_run_agent_executes_tool_then_finishes() {
	port := 18772
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_agent_listener = listener
	g_agent_responses = [
		'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"bash","arguments":"{\\"command\\":\\"echo hi\\"}"}}]}}]}\n\n' +
		'data: [DONE]\n\n',
		'data: {"choices":[{"delta":{"content":"done"}}]}\n\n' + 'data: [DONE]\n\n',
	]
	spawn agent_serve_many()
	time.sleep(50 * time.millisecond)
	cfg := Config{
		base_url:       'http://127.0.0.1:${port}/v1'
		model:          'mock'
		stream_options: false
		read_timeout:   5
	}
	app := App{
		cfg: cfg
		url: 'http://127.0.0.1:${port}/v1/chat/completions'
	}
	mut messages := [
		Message{
			role:    'user'
			content: 'run echo hi'
		},
	]
	res := run_agent(app, mut messages, unsafe { nil }) or { panic('run_agent failed: ${err}') }
	mut found_tool := false
	mut found_final := false
	for m in res.messages {
		if m.role == 'tool' && m.content.contains('hi') {
			found_tool = true
		}
		if m.role == 'assistant' && m.content == 'done' {
			found_final = true
		}
	}
	assert found_tool
	assert found_final
}

fn test_run_agent_recovers_from_invalid_tool_call() {
	// First attempt streams reasoning, then the server rejects the tool call as
	// unparseable (omlx invalid_tool_call). The agent must rewind that attempt
	// and nudge once, then finish on the retry.
	port := 18773
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_agent_listener = listener
	g_agent_responses = [
		'data: {"choices":[{"delta":{"reasoning_content":"thinking hard"}}]}\n\n' +
		'data: {"error":{"code":"invalid_tool_call","message":"Model output contains an unrecoverable tool call."}}\n\n',
		'data: {"choices":[{"delta":{"content":"done"}}]}\n\n' + 'data: [DONE]\n\n',
	]
	g_seen_tokens = []
	spawn agent_serve_many()
	time.sleep(50 * time.millisecond)
	cfg := Config{
		base_url:       'http://127.0.0.1:${port}/v1'
		model:          'mock'
		stream_options: false
		read_timeout:   5
	}
	app := App{
		cfg: cfg
		url: 'http://127.0.0.1:${port}/v1/chat/completions'
	}
	mut messages := [
		Message{
			role:    'user'
			content: 'fix it'
		},
	]
	res := run_agent(app, mut messages, collect_token) or { panic('run_agent failed: ${err}') }
	mut rewound := false
	for s in g_seen_tokens {
		if s.starts_with('rewind:') {
			rewound = true
		}
	}
	mut found_final := false
	for m in res.messages {
		if m.role == 'assistant' && m.content == 'done' {
			found_final = true
		}
	}
	assert rewound
	assert found_final
}

fn test_run_agent_salvages_bare_string_tool_call() {
	// A small model emits a bare string as the tool arguments ("echo hi"
	// instead of {"command":"echo hi"}); the server aborts the stream with an
	// invalid_tool_call error. The client must wrap the raw string into the
	// tool's single parameter and run it instead of failing the turn.
	port := 18774
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_agent_listener = listener
	g_agent_responses = [
		'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"bash","arguments":"echo hi"}}]}}]}\n\n' +
		'data: {"error":{"code":"invalid_tool_call","message":"Model output contains an unrecoverable tool call."}}\n\n',
		'data: {"choices":[{"delta":{"content":"done"}}]}\n\n' + 'data: [DONE]\n\n',
	]
	g_seen_tokens = []
	spawn agent_serve_many()
	time.sleep(50 * time.millisecond)
	cfg := Config{
		base_url:       'http://127.0.0.1:${port}/v1'
		model:          'mock'
		stream_options: false
		read_timeout:   5
	}
	app := App{
		cfg: cfg
		url: 'http://127.0.0.1:${port}/v1/chat/completions'
	}
	mut messages := [
		Message{
			role:    'user'
			content: 'run echo hi'
		},
	]
	res := run_agent(app, mut messages, collect_token) or { panic('run_agent failed: ${err}') }
	mut found_tool := false
	mut found_final := false
	for m in res.messages {
		if m.role == 'tool' && m.content.contains('hi') {
			found_tool = true
		}
		if m.role == 'assistant' && m.content == 'done' {
			found_final = true
		}
	}
	assert found_tool
	assert found_final
}
