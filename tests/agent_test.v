module main

import json2
import agent { prior_error_count }
import client { build_body, salvage_args }
import config { Config }
import ctx { age_old_tool_results, trim_old_turns }
import proto { Message, ToolCall, message_to_any }
import server { resolve_server_profile, set_server_profile }
import tools

fn m(role string, content string) Message {
	return Message{
		role:    role
		content: content
	}
}

fn body_map(body string) map[string]json2.Any {
	return json2.decode[json2.Any](body) or { panic(err) }.as_map()
}

fn test_build_body_default_sampling() {
	// Every sampling knob is omitted by default (the server/preset decides);
	// stream_options is still sent and reasoning on means no reasoning_effort.
	cfg := Config{
		model: 'm'
	}
	m := body_map(build_body([], cfg, []))
	assert 'temperature' !in m
	assert 'top_p' !in m
	assert 'max_tokens' !in m
	assert 'stream_options' in m
	assert 'reasoning_effort' !in m
}

fn test_build_body_with_sampling() {
	cfg := Config{
		model:           'm'
		temperature:     0.7
		top_p:           0.9
		max_tokens:      256
		stream_options:  false
		reasoning:       false
		reasoning_effort: 'none'
	}
	m := body_map(build_body([], cfg, []))
	assert tools.jget(m, 'temperature').f64() > 0.69 && tools.jget(m, 'temperature').f64() < 0.71
	assert tools.jget(m, 'top_p').f64() > 0.89 && tools.jget(m, 'top_p').f64() < 0.91
	assert tools.jget(m, 'max_tokens').int() == 256
	assert 'stream_options' !in m
	assert tools.jstr(m, 'reasoning_effort') == 'none'
}

fn test_message_to_any_tool_call() {
	mm := message_to_any(Message{
		role:       'assistant'
		content:    ''
		tool_calls: [
			ToolCall{
				id:        'c1'
				name:      'read_file'
				arguments: '{"path":"a"}'
			},
		]
	}).as_map()
	assert tools.jstr(mm, 'role') == 'assistant'
	assert 'content' !in mm // no empty content alongside tool_calls
	assert 'tool_calls' in mm
	calls := tools.jarr(mm, 'tool_calls')
	assert calls.len == 1
	assert tools.jstr(calls[0].as_map(), 'id') == 'c1'
}

fn test_age_old_tool_results() {
	mut msgs := [
		m('system', 'sys'),
		m('user', 'u1'),
		m('assistant', 'a1'),
		Message{
			role:         'tool'
			content:      'x'.repeat(500)
			tool_call_id: 't1'
		},
		m('user', 'u2'),
		m('assistant', 'a2'),
		Message{
			role:         'tool'
			content:      'y'.repeat(500)
			tool_call_id: 't2'
		},
	]
	age_old_tool_results(mut msgs)
	assert msgs[3].content.starts_with('[tool result omitted')
	assert msgs[6].content.len == 500 // last turn untouched
}

fn test_trim_old_turns_keeps_current() {
	mut msgs := [
		m('system', 's'),
		m('user', 'u1'),
		m('assistant', 'a1'),
		m('user', 'u2'),
		m('assistant', 'a2'),
	]
	trim_old_turns(mut msgs, 0)
	assert msgs.len == 3
	assert msgs[0].role == 'system'
	assert msgs[1].content == 'u2'
	assert msgs[2].content == 'a2'
}

fn test_prior_error_count() {
	msgs := [
		m('system', 's'),
		Message{
			role:       'assistant'
			tool_calls: [
				ToolCall{
					id:        'c1'
					name:      'read_file'
					arguments: '{"path":"a"}'
				},
			]
		},
		Message{
			role:         'tool'
			content:      'ERROR: nope'
			tool_call_id: 'c1'
		},
		Message{
			role:       'assistant'
			tool_calls: [
				ToolCall{
					id:        'c2'
					name:      'read_file'
					arguments: '{"path":"a"}'
				},
			]
		},
		Message{
			role:         'tool'
			content:      'ERROR: nope'
			tool_call_id: 'c2'
		},
	]
	assert prior_error_count(msgs, 'read_file', '{"path":"a"}') == 2
	assert prior_error_count(msgs, 'read_file', '{"path":"b"}') == 0
	assert prior_error_count(msgs, 'bash', '{"command":"ls"}') == 0
}

fn test_truncated_stream_args_are_salvageable() {
	// The assembled-slot salvage path: broken JSON -> salvage_args -> parseable.
	fragment := '{"path":"a.txt","content":"hello'
	assert tools.parse_args(fragment) == none
	repaired := salvage_args(fragment) or { panic('salvage failed') }
	encoded := json2.encode(repaired)
	assert tools.parse_args(encoded) != none
	assert tools.jstr(tools.parse_args(encoded) or { map[string]json2.Any{} }, 'content') == 'hello'
}

fn test_build_body_extra_sampling() {
	cfg := Config{
		model:             'm'
		top_k:             64
		min_p:             0.05
		repeat_penalty:    1.1
		frequency_penalty: 0.2
		presence_penalty:  0.3
		seed:              7
		max_tokens:        128
	}
	// Generic/OpenAI: standard fields are sent, llama.cpp extensions are not.
	set_server_profile(resolve_server_profile(Config{
		server: 'openai'
	}))
	body := build_body([], cfg, [])
	assert body.contains('"frequency_penalty":0.2')
	assert body.contains('"presence_penalty":0.3')
	assert body.contains('"seed":7')
	assert body.contains('"max_tokens":128')
	assert !body.contains('"top_k"')
	assert !body.contains('"min_p"')
	assert !body.contains('"repeat_penalty"')
	// llama.cpp: the extensions are sent.
	set_server_profile(resolve_server_profile(Config{
		server: 'llamacpp'
	}))
	body2 := build_body([], cfg, [])
	assert body2.contains('"top_k":64')
	assert body2.contains('"min_p":0.05')
	assert body2.contains('"repeat_penalty":1.1')
	// Omitted values (sentinels) are not sent at all.
	empty := Config{}
	set_server_profile(resolve_server_profile(Config{
		server: 'llamacpp'
	}))
	body3 := build_body([], empty, [])
	assert !body3.contains('"top_k"')
	assert !body3.contains('"min_p"')
	assert !body3.contains('"repeat_penalty"')
	assert !body3.contains('"seed"')
	assert !body3.contains('"frequency_penalty"')
	assert !body3.contains('"max_tokens"')
}
