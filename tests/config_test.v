module main

import json2
import os
import term.ui as termui
import config { Config, load_config, sampling_apply, sampling_fields, sampling_value }
import tui { theme_for }

// Config decoding tests for the Phase 3 theming additions: the `tui.colors`
// override map and the new scalar fields must decode, including when absent.

fn test_decode_tui_config_with_colors() {
	text := '{"model":"m","tui":{"theme":"light","mouse":true,"colors":{"content":"#010203","accent":"#abcdef"}}}'
	cfg := json2.decode[Config](text) or { panic('decode failed: ${err}') }
	assert cfg.tui.theme == 'light'
	assert cfg.tui.mouse == true
	assert cfg.tui.colors['content'] == '#010203'
	assert cfg.tui.colors['accent'] == '#abcdef'
	th := theme_for(cfg.tui)
	assert th.color_for('content') == termui.Color{r: 1, g: 2, b: 3}
	assert th.c('accent') == termui.Color{r: 171, g: 205, b: 239}
}

fn test_decode_tui_config_without_colors() {
	text := '{"model":"m","tui":{"bell":false,"timestamps":false}}'
	cfg := json2.decode[Config](text) or { panic('decode failed: ${err}') }
	assert cfg.tui.bell == false
	assert cfg.tui.timestamps == false
	assert cfg.tui.animation == 'full'
	assert cfg.tui.colors.len == 0
	// a missing colors map still resolves to the dark defaults
	assert theme_for(cfg.tui).color_for('content') == termui.Color{r: 120, g: 220, b: 120}
}

// --- .env / environment overrides -----------------------------------------

fn env_test_dir(name string) string {
	dir := os.join_path(os.temp_dir(), name)
	os.rmdir_all(dir) or {}
	os.mkdir_all(dir) or { panic(err) }
	return dir
}

fn clear_env(keys []string) {
	for k in keys {
		os.unsetenv(k)
	}
}

fn test_env_file_overrides_config() {
	dir := env_test_dir('mla_cfg_env_test')
	os.write_file(os.join_path(dir, 'config.json'), '{"model":"from_json","api_key":"jsonkey","temperature":0.1}') or {
		panic(err)
	}
	os.write_file(os.join_path(dir, '.env'), '# comment\nMODEL=from_env\nexport API_KEY="secret 123"\nTEMPERATURE=0.2\nTUI_ANIMATION=off\n') or {
		panic(err)
	}
	clear_env(['MODEL', 'API_KEY', 'TEMPERATURE', 'TUI_ANIMATION'])
	cfg := load_config(dir)
	assert cfg.model == 'from_env'
	assert cfg.api_key == 'secret 123'
	assert cfg.temperature > 0.19 && cfg.temperature < 0.21
	assert cfg.tui.animation == 'off'
	clear_env(['MODEL', 'API_KEY', 'TEMPERATURE', 'TUI_ANIMATION'])
	os.rmdir_all(dir) or {}
}

fn test_real_env_wins_over_dotenv() {
	dir := env_test_dir('mla_cfg_env_prec_test')
	os.write_file(os.join_path(dir, '.env'), 'MODEL=from_env\n') or { panic(err) }
	os.setenv('MODEL', 'from_real', true)
	cfg := load_config(dir)
	clear_env(['MODEL'])
	os.rmdir_all(dir) or {}
	assert cfg.model == 'from_real'
}

fn test_config_json_is_optional() {
	dir := env_test_dir('mla_cfg_env_only_test')
	os.write_file(os.join_path(dir, '.env'), 'BASE_URL=http://x:1/v1\nMODEL=m1\nAPI_KEY=k1\n') or {
		panic(err)
	}
	clear_env(['BASE_URL', 'MODEL', 'API_KEY'])
	cfg := load_config(dir)
	clear_env(['BASE_URL', 'MODEL', 'API_KEY'])
	os.rmdir_all(dir) or {}
	assert cfg.base_url == 'http://x:1/v1'
	assert cfg.model == 'm1'
	assert cfg.api_key == 'k1'
}

// --- /samplings -----------------------------------------------------------

fn test_sampling_fields_gating() {
	llama := sampling_fields('llamacpp')
	llama_keys := llama.map(it.key)
	assert 'temperature' in llama_keys
	assert 'top_k' in llama_keys && 'min_p' in llama_keys && 'repeat_penalty' in llama_keys
	// omlx/openai do not accept the llama.cpp-only extensions.
	for kind in ['omlx', 'openai'] {
		keys := sampling_fields(kind).map(it.key)
		assert 'temperature' in keys
		assert 'top_k' !in keys && 'min_p' !in keys && 'repeat_penalty' !in keys
	}
}

fn test_sampling_apply_roundtrip() {
	mut cfg := Config{}
	sampling_apply(mut cfg, 'temperature', '0.7')
	assert cfg.temperature == 0.7
	assert sampling_value(cfg, 'temperature') == '0.7'
	// empty clears the override (server default).
	sampling_apply(mut cfg, 'temperature', '')
	assert cfg.temperature < 0
	assert sampling_value(cfg, 'temperature') == ''
	// ints
	assert sampling_apply(mut cfg, 'top_k', 'abc') != ''
	sampling_apply(mut cfg, 'top_k', '64')
	assert cfg.top_k == 64 && sampling_value(cfg, 'top_k') == '64'
	sampling_apply(mut cfg, 'seed', '7')
	assert cfg.seed == 7
	sampling_apply(mut cfg, 'seed', '')
	assert cfg.seed == -1 && sampling_value(cfg, 'seed') == ''
	// floats
	sampling_apply(mut cfg, 'min_p', '0.05')
	assert cfg.min_p == 0.05
	assert sampling_apply(mut cfg, 'min_p', 'x') != ''
	sampling_apply(mut cfg, 'repeat_penalty', '1.1')
	assert cfg.repeat_penalty == 1.1
}
