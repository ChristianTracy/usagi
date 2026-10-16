module main

import app as appmod { App }
import client { build_body }
import config { Config }
import proto { Message }
import server { cached_models, fetch_models, looks_like_thinking_model, next_thinking_level, resolve_default_model, resolve_server_profile, server_profile, set_server_profile, thinking_levels }
import net
import time
import tools

// Tests for the server compatibility layer: profile selection, request-field
// gating, and the 400/422 fallback that drops optional fields.

__global g_st_listener &net.TcpListener = unsafe { nil }
__global g_st_responses []string

fn st_serve() {
	for resp in g_st_responses {
		mut conn := g_st_listener.accept() or { return }
		mut buf := []u8{len: 16384}
		conn.read(mut buf) or {}
		conn.write_string(resp) or { return }
		conn.close() or {}
	}
}

fn test_server_profile_override() {
	// An explicit cfg.server must be honored without any network probe.
	o := resolve_server_profile(Config{
		server: 'omlx'
	})
	assert o.kind == 'omlx'
	assert o.tool_choice == true
	assert o.parallel_tool_calls == false // not in omlx's request model

	l := resolve_server_profile(Config{
		server: 'llamacpp'
	})
	assert l.kind == 'llamacpp'
	assert l.parallel_tool_calls == true

	g := resolve_server_profile(Config{
		server: 'openai'
	})
	assert g.kind == 'openai'
}

fn test_optional_fields_gated_by_profile() {
	// Generic OpenAI: tool_choice and parallel_tool_calls are sent.
	set_server_profile(resolve_server_profile(Config{
		server: 'openai'
	}))
	body := build_body([], Config{
		tool_choice:         'auto'
		parallel_tool_calls: true
	}, tools.tool_schemas())
	assert body.contains('tool_choice')
	assert body.contains('parallel_tool_calls')

	// omlx: tool_choice yes, but no parallel_tool_calls field.
	set_server_profile(resolve_server_profile(Config{
		server: 'omlx'
	}))
	body2 := build_body([], Config{
		tool_choice:         'auto'
		parallel_tool_calls: true
	}, tools.tool_schemas())
	assert body2.contains('tool_choice')
	assert !body2.contains('parallel_tool_calls')

	// chat_template_kwargs only for servers known to understand the key.
	set_server_profile(resolve_server_profile(Config{
		server: 'openai'
	}))
	assert !build_body([], Config{
		reasoning: false
	}, []).contains('chat_template_kwargs')
	set_server_profile(resolve_server_profile(Config{
		server: 'llamacpp'
	}))
	assert build_body([], Config{
		reasoning: false
	}, []).contains('chat_template_kwargs')
}

fn test_compat_fallback_on_422() {
	port := 18790
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_st_listener = listener
	// First request: the server rejects an optional field. Second: a normal
	// stream, which chat() must reach after degrading the profile.
	g_st_responses = [
		'HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"error":"unknown field tool_choice"}',
		'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n' +
		'data: {"choices":[{"delta":{"content":"hola"}}]}\n\n' + 'data: [DONE]\n\n',
	]
	set_server_profile(resolve_server_profile(Config{
		server: 'openai'
	}))
	spawn st_serve()
	time.sleep(50 * time.millisecond)
	cfg := Config{
		base_url:       'http://127.0.0.1:${port}/v1'
		model:          'mock'
		stream_options: false
		read_timeout:   5
		tool_choice:    'auto'
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
	assert reply.content == 'hola'
	assert server_profile().degraded == true
	// After degradation the optional field is no longer part of the body.
	body := build_body([], cfg, tools.tool_schemas())
	assert !body.contains('tool_choice')
}

fn test_thinking_controls_gated() {
	// Generic profile: reasoning_effort is sent when set; when reasoning is off
	// it becomes 'none'. No chat_template_kwargs (unknown template).
	set_server_profile(resolve_server_profile(Config{
		server: 'openai'
	}))
	on := build_body([], Config{
		reasoning:        true
		reasoning_effort: 'low'
	}, [])
	assert on.contains('"reasoning_effort":"low"')
	assert !on.contains('chat_template_kwargs')

	off := build_body([], Config{
		reasoning: true
	}, [])
	assert !off.contains('reasoning_effort') // empty effort -> omitted

	// omlx: explicit enable_thinking=false plus thinking_budget.
	set_server_profile(resolve_server_profile(Config{
		server: 'omlx'
	}))
	omlx := build_body([], Config{
		reasoning:       false
		thinking_budget: 512
	}, [])
	assert omlx.contains('chat_template_kwargs')
	assert omlx.contains('"enable_thinking":false')
	assert omlx.contains('"thinking_budget":512')

	// llama.cpp does not support thinking_budget.
	set_server_profile(resolve_server_profile(Config{
		server: 'llamacpp'
	}))
	lc := build_body([], Config{
		reasoning:       false
		thinking_budget: 512
	}, [])
	assert lc.contains('"enable_thinking":false')
	assert !lc.contains('thinking_budget')
}

fn test_thinking_model_heuristic() {
	assert looks_like_thinking_model('Qwen3-8B-MLX-4bit')
	assert looks_like_thinking_model('deepseek-r1-distill')
	assert !looks_like_thinking_model('llama-3.2-3b-instruct')
	assert !looks_like_thinking_model('qwen2.5-coder-7b')
}

fn test_thinking_cycle() {
	levels := thinking_levels(['low', 'medium', 'high'])
	assert levels == ['none', 'low', 'medium', 'high']
	assert next_thinking_level(levels, 'none') == 'low'
	assert next_thinking_level(levels, 'low') == 'medium'
	assert next_thinking_level(levels, 'medium') == 'high'
	assert next_thinking_level(levels, 'high') == 'none'
	// 'auto' (the empty-effort default) starts the cycle at off.
	assert next_thinking_level(levels, 'auto') == 'none'
	// A server-provided list without 'none' gets it prepended, once.
	assert thinking_levels(['none', 'high']) == ['none', 'high']
}

fn test_fetch_models_from_endpoint() {
	port := 18791
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_st_listener = listener
	g_st_responses = [
		'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n' +
		'{"data":[{"id":"qwen3-8b","owned_by":"omlx","max_model_len":32768},' +
		'{"id":"qwen3-8b:thinking","owned_by":"omlx"}]}',
		// /props is probed too; a 404 means "no template signal".
		'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}',
	]
	spawn st_serve()
	time.sleep(50 * time.millisecond)
	cfg := Config{
		base_url:     'http://127.0.0.1:${port}/v1'
		model:        'mock'
		read_timeout: 5
	}
	entries := fetch_models(cfg)
	assert entries.len == 2
	assert entries[0].id == 'qwen3-8b'
	assert entries[0].context_len == 32768
	assert entries[0].owned_by == 'omlx'
	assert entries[0].thinking // inherited from the :thinking sibling
}

fn test_fetch_models_llamacpp_context_from_props() {
	port := 18792
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_st_listener = listener
	// llama.cpp /v1/models carries no context; /props does.
	g_st_responses = [
		'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n' +
		'{"data":[{"id":"local-model","owned_by":"llama.cpp"}]}',
		'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n' +
		'{"default_generation_settings":{"n_ctx":4096,"params":{"seed":-1}},' +
		'"chat_template":"{% if enable_thinking %}...{% endif %}"}',
	]
	spawn st_serve()
	time.sleep(50 * time.millisecond)
	cfg := Config{
		base_url:     'http://127.0.0.1:${port}/v1'
		model:        'local-model'
		read_timeout: 5
	}
	entries := fetch_models(cfg)
	assert entries.len == 1
	assert entries[0].context_len == 4096
	assert entries[0].thinking
}

fn test_resolve_default_model_prefers_loaded() {
	port := 18793
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	g_st_listener = listener
	g_st_responses = [
		'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n' +
		'{"data":[' +
		'{"id":"first","owned_by":"llamacpp","status":{"value":"unloaded","args":["-c","4096"]}},' +
		'{"id":"second","owned_by":"llamacpp","status":{"value":"loaded","args":["-c","8192"]}}' +
		']}',
		'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}',
	]
	spawn st_serve()
	time.sleep(50 * time.millisecond)
	cfg := Config{
		base_url:     'http://127.0.0.1:${port}/v1'
		model:        ''
		read_timeout: 5
	}
	cached_models(cfg, true) // warm the cache from the mock
	assert resolve_default_model(cfg) == 'second'
}
