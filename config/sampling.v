module config

// Sampling knobs editable at runtime with `/samplings`. The overlay is
// session-only (nothing is written back to config.json), and each knob follows
// the "omit == server default" convention documented on Config.

// SamplingField describes one editable decoding knob. `scopes` lists the
// server kinds it applies to (empty = all).
pub struct SamplingField {
pub:
	key    string
	kind   string // 'float' | 'int'
	scopes []string
	help   string
}

// sampling_specs is the ordered list of knobs the overlay shows.
pub fn sampling_specs() []SamplingField {
	return [
		SamplingField{
			key:  'temperature'
			kind: 'float'
			help: '0 = deterministic · empty = server default'
		},
		SamplingField{
			key:  'top_p'
			kind: 'float'
			help: 'nucleus · empty = server default'
		},
		SamplingField{
			key:  'max_tokens'
			kind: 'int'
			help: '0/empty = server default'
		},
		SamplingField{
			key:    'top_k'
			kind:   'int'
			scopes: ['llamacpp']
			help:   'llama.cpp only · empty = server default'
		},
		SamplingField{
			key:    'min_p'
			kind:   'float'
			scopes: ['llamacpp']
			help:   'llama.cpp only · 0..1 · empty = server default'
		},
		SamplingField{
			key:    'repeat_penalty'
			kind:   'float'
			scopes: ['llamacpp']
			help:   'llama.cpp only · 1.0 = off · empty = server default'
		},
		SamplingField{
			key:  'frequency_penalty'
			kind: 'float'
			help: 'OpenAI · 0 = off · empty = server default'
		},
		SamplingField{
			key:  'presence_penalty'
			kind: 'float'
			help: 'OpenAI · 0 = off · empty = server default'
		},
		SamplingField{
			key:  'seed'
			kind: 'int'
			help: 'empty = random'
		},
	]
}

// sampling_fields returns the knobs that apply to a server kind.
pub fn sampling_fields(kind string) []SamplingField {
	mut out := []SamplingField{}
	for s in sampling_specs() {
		if s.scopes.len > 0 && kind !in s.scopes {
			continue
		}
		out << s
	}
	return out
}

// sampling_value is the display/edit text for a knob: '' means "omit" (use the
// server/preset default).
pub fn sampling_value(cfg Config, key string) string {
	return match key {
		'temperature' { if cfg.temperature >= 0 { '${cfg.temperature}' } else { '' } }
		'top_p' { if cfg.top_p > 0 && cfg.top_p < 1.0 { '${cfg.top_p}' } else { '' } }
		'max_tokens' { if cfg.max_tokens > 0 { '${cfg.max_tokens}' } else { '' } }
		'top_k' { if cfg.top_k > 0 { '${cfg.top_k}' } else { '' } }
		'min_p' { if cfg.min_p >= 0 { '${cfg.min_p}' } else { '' } }
		'repeat_penalty' { if cfg.repeat_penalty > 0 { '${cfg.repeat_penalty}' } else { '' } }
		'frequency_penalty' {
			if cfg.frequency_penalty != 0 { '${cfg.frequency_penalty}' } else { '' }
		}
		'presence_penalty' { if cfg.presence_penalty != 0 { '${cfg.presence_penalty}' } else { '' } }
		'seed' { if cfg.seed >= 0 { '${cfg.seed}' } else { '' } }
		else { '' }
	}
}

// valid_float / valid_int are strict parsers: V's `.f64()`/`.int()` silently
// return 0 on garbage, so the text is validated first.
fn valid_float(s string) bool {
	if s == '' {
		return false
	}
	mut dot := false
	mut exp := false
	for i, c in s {
		if c.is_digit() {
			continue
		}
		if c == `-` || c == `+` {
			if i != 0 && !(i > 0 && (s[i - 1] == `e` || s[i - 1] == `E`)) {
				return false
			}
			continue
		}
		if c == `.` {
			if dot || exp {
				return false
			}
			dot = true
			continue
		}
		if c == `e` || c == `E` {
			if exp {
				return false
			}
			exp = true
			continue
		}
		return false
	}
	return true
}

fn valid_int(s string) bool {
	if s == '' {
		return false
	}
	for i, c in s {
		if c.is_digit() {
			continue
		}
		if (c == `-` || c == `+`) && i == 0 {
			continue
		}
		return false
	}
	return true
}

// sampling_apply parses `text` ('' = omit / server default) into the matching
// Config field. Returns an error message when the text is not a valid number.
pub fn sampling_apply(mut cfg Config, key string, text string) string {
	t := text.trim_space()
	empty := t == ''
	match key {
		'temperature' {
			if empty {
				cfg.temperature = -1.0
				return ''
			}
			if !valid_float(t) {
				return 'temperature must be a number'
			}
			cfg.temperature = t.f64()
		}
		'top_p' {
			if empty {
				cfg.top_p = 1.0
				return ''
			}
			if !valid_float(t) {
				return 'top_p must be a number'
			}
			cfg.top_p = t.f64()
		}
		'max_tokens' {
			if empty {
				cfg.max_tokens = 0
				return ''
			}
			if !valid_int(t) {
				return 'max_tokens must be an integer'
			}
			cfg.max_tokens = t.int()
		}
		'top_k' {
			if empty {
				cfg.top_k = 0
				return ''
			}
			if !valid_int(t) {
				return 'top_k must be an integer'
			}
			cfg.top_k = t.int()
		}
		'min_p' {
			if empty {
				cfg.min_p = -1.0
				return ''
			}
			if !valid_float(t) {
				return 'min_p must be a number'
			}
			cfg.min_p = t.f64()
		}
		'repeat_penalty' {
			if empty {
				cfg.repeat_penalty = 0.0
				return ''
			}
			if !valid_float(t) {
				return 'repeat_penalty must be a number'
			}
			cfg.repeat_penalty = t.f64()
		}
		'frequency_penalty' {
			if empty {
				cfg.frequency_penalty = 0.0
				return ''
			}
			if !valid_float(t) {
				return 'frequency_penalty must be a number'
			}
			cfg.frequency_penalty = t.f64()
		}
		'presence_penalty' {
			if empty {
				cfg.presence_penalty = 0.0
				return ''
			}
			if !valid_float(t) {
				return 'presence_penalty must be a number'
			}
			cfg.presence_penalty = t.f64()
		}
		'seed' {
			if empty {
				cfg.seed = -1
				return ''
			}
			if !valid_int(t) {
				return 'seed must be an integer'
			}
			cfg.seed = t.int()
		}
		else { return 'unknown sampling parameter' }
	}
	return ''
}
