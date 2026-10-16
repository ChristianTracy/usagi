module main

import app as appmod { App }
import client
import config { Config }
import proto { Message }
import net
import time

// Integration test for the streaming client: a tiny one-shot SSE server on a
// loopback port serves a content delta and a truncated tool-call, and chat()
// must assemble the reply and salvage the broken JSON. No model required.

__global g_sse_listener &net.TcpListener = unsafe { nil }
__global g_sse_body string

fn sse_serve_one() {
	mut conn := g_sse_listener.accept() or { return }
	mut buf := []u8{len: 8192}
	// Read the request (headers, maybe part of the body) then answer.
	conn.read(mut buf) or {}
	conn.write_string('HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n') or {
		return
	}
	conn.write_string(g_sse_body) or { return }
	conn.close() or {}
}

fn test_chat_with_mock_sse() {
	port := 18771
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or {
		// Port busy in this environment: skip rather than fail.
		return
	}
	g_sse_listener = listener
	// A content chunk, a tool call whose arguments JSON is cut off, then a final
	// usage chunk carrying the prefix-cache hit.
	g_sse_body = 'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n' +
		'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\\"path\\":\\"a.tx"}}]}}]}\n\n' +
		'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":10,"total_tokens":110,"prompt_tokens_details":{"cached_tokens":64},"time_to_first_token":0.15}}\n\n' +
		'data: [DONE]\n\n'
	spawn sse_serve_one()
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
	reply := client.chat(app, [
		Message{
			role:    'user'
			content: 'hi'
		},
	], unsafe { nil }) or { panic('chat failed: ${err}') }
	assert reply.content == 'hello'
	assert reply.tool_calls.len == 1
	assert reply.tool_calls[0].name == 'read_file'
	assert reply.salvaged == true
	// prompt_tokens_details.cached_tokens is surfaced for cache measurement.
	assert reply.has_usage
	assert reply.usage.has_cached
	assert reply.usage.cached_tokens == 64
	assert reply.usage.prompt_tokens == 100
	// omlx reports TTFT in seconds.
	assert reply.usage.has_ttft
	assert reply.usage.ttft_ms == 150
}

fn test_chat_llamacpp_timings() {
	// llama.cpp reports the reused prefix (cache_n) and the prompt/first-token
	// time (prompt_ms) in a top-level `timings` object.
	port := 18774
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_sse_listener = listener
	g_sse_body = 'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n' +
		'data: {"choices":[],"timings":{"cache_n":900,"prompt_ms":250.0}}\n\n' + 'data: [DONE]\n\n'
	spawn sse_serve_one()
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
	reply := client.chat(app, [
		Message{
			role:    'user'
			content: 'hi'
		},
	], unsafe { nil }) or { panic('chat failed: ${err}') }
	assert reply.content == 'ok'
	assert reply.usage.has_cached && reply.usage.cached_tokens == 900
	assert reply.usage.has_ttft && reply.usage.ttft_ms == 250
}
