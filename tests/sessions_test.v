module main

import os
import proto { Message }
import sessions
import tui { filter_sessions, picker_clamp }

fn sys_msg() Message {
	return Message{
		role:    'system'
		content: 'You are a coding assistant.'
	}
}

fn user_msg(s string) Message {
	return Message{
		role:    'user'
		content: s
	}
}

// roundtrip: create -> append -> load keeps every message and meta counters.
fn test_sessions_roundtrip() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	assert meta.id != ''
	assert os.exists(os.join_path(d, '${meta.id}.jsonl'))
	sessions.append(meta.id, [user_msg('hola'), Message{
		role:    'assistant'
		content: 'hola!'
	}], 10, 5) or { panic(err) }
	msgs := sessions.load(meta.id) or { panic(err) }
	assert msgs.len == 3
	assert msgs[0].role == 'system'
	assert msgs[1].content == 'hola'
	assert msgs[2].content == 'hola!'
	m := sessions.list()
	assert m.sessions.len == 1
	assert m.sessions[0].messages == 3
	assert m.sessions[0].tokens_in == 10
	assert m.sessions[0].tokens_out == 5
}

// multiline content stays on one physical line (JSON escapes the newline).
fn test_sessions_multiline_content() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	sessions.append(meta.id, [user_msg('linea1\nlinea2')], 0, 0) or { panic(err) }
	text := os.read_file(os.join_path(d, '${meta.id}.jsonl')) or { panic(err) }
	assert text.split('\n').len == 3 // system + user (one line) + trailing ''
	msgs := sessions.load(meta.id) or { panic(err) }
	assert msgs[1].content == 'linea1\nlinea2'
}

// find resolves by unique id prefix and unique name; fails when not found.
fn test_sessions_find() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	m1 := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	m2 := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	sessions.rename(m1.id, 'alpha') or { panic(err) }
	sessions.rename(m2.id, 'beta') or { panic(err) }
	f := sessions.find(m1.id) or { panic(err) }
	assert f.id == m1.id
	f2 := sessions.find('alpha') or { panic(err) }
	assert f2.id == m1.id
	mut err_ok := false
	sessions.find('no-existe') or { err_ok = true }
	assert err_ok
	// ambiguous: two sessions with the same name -> find errors.
	sessions.rename(m1.id, 'dup') or { panic(err) }
	sessions.rename(m2.id, 'dup') or { panic(err) }
	mut amb := false
	sessions.find('dup') or { amb = true }
	assert amb
}

// remove deletes the file and the manifest entry; cleanup removes orphans.
fn test_sessions_remove_and_cleanup() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	sessions.remove(meta.id) or { panic(err) }
	assert sessions.list().sessions.len == 0
	assert !os.exists(os.join_path(d, '${meta.id}.jsonl'))
	// orphan: a .jsonl file with no manifest entry must be removed by cleanup().
	os.write_file(os.join_path(d, '1730000000-aaaa.jsonl'), '{}') or { panic(err) }
	sessions.cleanup() or { panic(err) }
	assert !os.exists(os.join_path(d, '1730000000-aaaa.jsonl'))
}

// prune keeps at most `max` sessions, oldest first out.
fn test_sessions_prune() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	for _ in 0 .. 3 {
		sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	}
	sessions.prune(1, 0) or { panic(err) }
	assert sessions.list().sessions.len == 1
}

// the session picker filters by name, id, model or workspace and clamps its
// cursor like the model picker.
fn test_sessions_picker_filter() {
	items := [
		sessions.Meta{
			id:        '1-a'
			name:      'fix login'
			workspace: '/proj/a'
			model:     'qwen'
		}
		sessions.Meta{
			id:        '2-b'
			name:      'docs'
			workspace: '/proj/b'
			model:     'llama'
		}
	]
	assert filter_sessions(items, '').len == 2
	assert filter_sessions(items, 'login').len == 1
	assert filter_sessions(items, 'LOGIN')[0].id == '1-a'
	assert filter_sessions(items, 'llama')[0].id == '2-b'
	assert filter_sessions(items, '/proj/b')[0].id == '2-b'
	assert filter_sessions(items, 'nope').len == 0
	assert picker_clamp(5, 2) == 1
	assert picker_clamp(-1, 2) == 0
	assert picker_clamp(0, 0) == 0
}

// a trailing incomplete line (crash mid-write) is ignored by load().
fn test_sessions_trailing_line_ignored() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	p := os.join_path(d, '${meta.id}.jsonl')
	os.write_file(p, os.read_file(p) or { panic(err) } + '{"role":"user","content":"par') or {
		panic(err)
	}
	msgs := sessions.load(meta.id) or { panic(err) }
	assert msgs.len == 1 // only the valid system line
}
