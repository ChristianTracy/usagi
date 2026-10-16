module tools

import os

import x.json2

const default_limit = 400

// max_line_bytes caps how much one physical line may contribute before the
// reader gives up, so a pathological (or binary) file cannot exhaust memory.
const max_line_bytes = 1000000

// read_chunk_size is the per-read buffer for the streaming line reader.
const read_chunk_size = 4096

fn read_file_schema() json2.Any {
	desc := 'Read a file (up to \'limit\' lines from \'offset\'). For big files read in chunks and follow the truncation notice. Paths must be inside the workspace. Example: {"path":"main.py","offset":200,"limit":100}'
	schema := '{"type":"function","function":{"name":"read_file","description":${json2.encode(desc)},"parameters":{"type":"object","properties":{"path":{"type":"string","description":"File to read"},"offset":{"type":"integer","description":"Start line (default 1)"},"limit":{"type":"integer","description":"Max lines (default 400)"}},"required":["path"]}}}'
	return json2.decode[json2.Any](schema) or { json2.Any(map[string]json2.Any{}) }
}

// next_line reads one logical line (without its terminator) from an open file.
// It streams through a fixed buffer, so it never loads the whole file, and it
// keeps reading until a newline or EOF so a line longer than the buffer is not
// silently split. Returns none at EOF (or on a read error).
fn next_line(mut f os.File) ?string {
	mut buf := []u8{len: read_chunk_size}
	mut acc := []u8{}
	mut got := false
	for {
		n := f.read_bytes_with_newline(mut buf) or { return none }
		if n == 0 {
			break
		}
		got = true
		acc << buf[..n]
		if acc[acc.len - 1] == `\n` || acc.len > max_line_bytes {
			break
		}
	}
	if !got {
		return none
	}
	mut end := acc.len
	if end > 0 && acc[end - 1] == `\n` {
		end--
	}
	if end > 0 && acc[end - 1] == `\r` {
		end--
	}
	return acc[..end].bytestr()
}

fn read_file_exec(args map[string]json2.Any) string {
	if 'path' !in args || jstr(args, 'path') == '' {
		return "ERROR: 'path' is required. Resend the tool call."
	}
	path := jstr(args, 'path')
	p := safe_path(path, true) or { return 'ERROR: ${err.msg()}' }
	if !os.is_file(p) {
		return 'ERROR: ${path} is not a file. List the folder with bash ls.'
	}
	mut offset := jint(args, 'offset')
	if offset < 1 {
		offset = 1
	}
	mut limit := jint(args, 'limit')
	if limit < 1 {
		limit = default_limit
	}
	mut f := os.open(p) or { return 'ERROR: cannot read ${path}: ${err.msg()}' }
	defer {
		f.close()
	}
	mut lineno := 0
	mut out := []string{}
	mut has_more := false
	for {
		line := next_line(mut f) or { break }
		lineno++
		if lineno < offset {
			continue
		}
		if out.len >= limit {
			has_more = true
			break
		}
		if line.contains('\x00') { // NUL byte: not a text file
			return 'ERROR: ${path} looks like a binary file. Use bash to inspect it.'
		}
		out << line
	}
	if out.len == 0 {
		return ''
	}
	text := out.join('\n')
	if text.len > max_output() { // char backstop for very wide lines
		return text[..max_output()] + "\n…truncated by size. Re-read with a smaller 'limit'."
	}
	if has_more {
		last := offset + out.len - 1 // last line returned
		return '${text}\n…truncated at line ${last}. Call read_file with offset=${
			last + 1} to continue.'
	}
	return text
}
