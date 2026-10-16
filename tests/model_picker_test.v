module main

import server { ModelEntry, ctx_size_from_args, ctx_size_from_preset, parse_models }
import tui { filter_models, model_meta, picker_clamp }

// Unit tests for the model selector: `/v1/models` parsing (pure) and the
// picker's filtering / cursor helpers.

const models_body = '{"data":[' +
	'{"id":"qwen3-8b","owned_by":"omlx","created":1700000000,"max_model_len":32768},' +
	'{"id":"qwen3-8b:thinking","owned_by":"omlx","created":1700000001},' +
	'{"id":"llama-3.2-3b","owned_by":"llamacpp","created":1700000002}' +
	']}'

fn test_parse_models() {
	entries := parse_models(models_body)
	assert entries.len == 3
	base := entries[0]
	assert base.id == 'qwen3-8b'
	assert base.owned_by == 'omlx'
	assert base.context_len == 32768
	// A base model inherits thinking from its `:profile` sibling.
	assert base.thinking
	assert 'thinking' in base.profiles
	variant := entries[1]
	assert variant.thinking
	assert variant.profiles == ['thinking']
	plain := entries[2]
	assert plain.id == 'llama-3.2-3b'
	assert !plain.thinking
	assert plain.context_len == 0
}

fn test_parse_models_nested_model_info() {
	// llama.cpp nests the context under model_info.
	body := '{"data":[{"id":"m","owned_by":"llama.cpp","model_info":{"max_context_length":4096}}]}'
	entries := parse_models(body)
	assert entries.len == 1
	assert entries[0].context_len == 4096
}

fn test_parse_models_bad_input() {
	assert parse_models('not json').len == 0
	assert parse_models('{}').len == 0
	assert parse_models('{"data":[]}').len == 0
}

fn test_filter_models() {
	entries := parse_models(models_body)
	assert filter_models(entries, '').len == 3
	assert filter_models(entries, 'qwen').len == 2
	assert filter_models(entries, 'QWEN').len == 2
	assert filter_models(entries, 'llama').len == 1 // matches id and owner
	assert filter_models(entries, 'nope').len == 0
}

fn test_picker_clamp() {
	assert picker_clamp(-1, 3) == 0
	assert picker_clamp(0, 3) == 0
	assert picker_clamp(2, 3) == 2
	assert picker_clamp(9, 3) == 2
	assert picker_clamp(4, 0) == 0
}

fn test_model_meta() {
	e := ModelEntry{
		id:          'qwen3-8b'
		owned_by:    'omlx'
		context_len: 32768
		thinking:    true
	}
	assert model_meta(e) == 'ctx 32.7k · omlx · think'
	bare := ModelEntry{
		id: 'x'
	}
	assert model_meta(bare) == ''
}

fn test_ctx_size_from_args() {
	assert ctx_size_from_args(['--ctx-size', '131072']) == 131072
	assert ctx_size_from_args(['--ctx-size=32768']) == 32768
	assert ctx_size_from_args(['-c', '65536']) == 65536
	// --parallel slots share the KV pool: per-request window is ctx / slots.
	assert ctx_size_from_args(['--ctx-size', '262144', '--parallel', '4']) == 65536
	assert ctx_size_from_args(['-c', '262144', '-np', '4']) == 65536
	assert ctx_size_from_args(['--model', 'x']) == 0
}

fn test_ctx_size_from_preset() {
	preset := '[m]\njinja = true\nctx-size = 262144\nparallel = 4\nmodel = x\n'
	assert ctx_size_from_preset(preset) == 65536
	assert ctx_size_from_preset('') == 0
}

fn test_parse_models_router_args() {
	body := '{"data":[{"id":"router-model","owned_by":"llamacpp","status":{"value":"loaded",' +
		'"args":["-c","262144","-np","4"]}}]}'
	entries := parse_models(body)
	assert entries.len == 1
	assert entries[0].context_len == 65536
	assert entries[0].loaded
}
