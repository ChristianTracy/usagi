module tools

import os

import x.json2

fn edit_file_schema() json2.Any {
	desc := 'Replace one exact, unique match of old_text. Example: {"path":"a.py","old_text":"x = 1","new_text":"x = 2"}'
	schema := '{"type":"function","function":{"name":"edit_file","description":${json2.encode(desc)},"parameters":{"type":"object","properties":{"path":{"type":"string","description":"File to edit"},"old_text":{"type":"string","description":"Exact text to replace (must be unique)"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path","old_text","new_text"]}}}'
	return json2.decode[json2.Any](schema) or { json2.Any(map[string]json2.Any{}) }
}

// leading_ws returns the run of spaces/tabs at the start of a line.
fn leading_ws(s string) string {
	mut i := 0
	for i < s.len && (s[i] == ` ` || s[i] == `\t`) {
		i++
	}
	return s[..i]
}

// fuzzy_replace is the whitespace-tolerant fallback for edit_file. It finds a
// block of lines whose *trimmed* content equals old_text's trimmed lines and
// replaces it with new_text, re-applying the file's indentation to lines the
// model left unindented. Returns none unless the match is unique.
pub fn fuzzy_replace(text string, old string, newt string) ?string {
	text_lines := text.split('\n')
	mut old_lines := []string{}
	for l in old.split('\n') {
		old_lines << l.trim_space()
	}
	mut olen := old_lines.len
	for olen > 0 && old_lines[olen - 1] == '' {
		olen--
	}
	if olen == 0 {
		return none
	}
	mut matches := []int{}
	for i := 0; i + olen <= text_lines.len; i++ {
		mut ok := true
		for k in 0 .. olen {
			if text_lines[i + k].trim_space() != old_lines[k] {
				ok = false
				break
			}
		}
		if ok {
			matches << i
		}
	}
	if matches.len != 1 {
		return none
	}
	start := matches[0]
	indent := leading_ws(text_lines[start])
	mut rebuilt := []string{}
	for nl in newt.split('\n') {
		if nl == '' || nl.starts_with(' ') || nl.starts_with('\t') {
			rebuilt << nl
		} else {
			rebuilt << indent + nl
		}
	}
	mut result := []string{}
	result << text_lines[..start]
	result << rebuilt
	result << text_lines[start + olen..]
	return result.join('\n')
}

fn edit_file_exec(args map[string]json2.Any) string {
	if 'path' !in args || 'old_text' !in args || 'new_text' !in args {
		return "ERROR: 'path', 'old_text' and 'new_text' are all required. Resend the tool call."
	}
	path := jstr(args, 'path')
	old := jstr(args, 'old_text')
	newt := jstr(args, 'new_text')
	if path == '' {
		return "ERROR: 'path' is required. Resend the tool call."
	}
	p := safe_path(path, true) or { return 'ERROR: ${err.msg()}' }
	text := os.read_file(p) or { return 'ERROR: ${err.msg()}' }
	count := text.count(old)
	if count == 0 {
		// Whitespace-only mismatch: try the line-normalized fallback before
		// sending the model back to re-read.
		fixed := fuzzy_replace(text, old, newt) or {
			return 'ERROR: old_text was not found in the file (exact or whitespace-normalized). Read the file again and copy the exact text.'
		}
		os.write_file(p, fixed) or {
			return 'ERROR: cannot write ${path}: ${err.msg()}'
		}
		return 'Edited ${path} (matched after normalizing whitespace): replaced ${old.len} chars with ${newt.len} chars.'
	}
	if count > 1 {
		return 'ERROR: old_text matches ${count} places. Include more surrounding lines so it is unique.'
	}
	os.write_file(p, text.replace_once(old, newt)) or {
		return 'ERROR: cannot write ${path}: ${err.msg()}'
	}
	return 'Edited ${path}: replaced ${old.len} chars with ${newt.len} chars.'
}
