module sessions

// Saved sessions: a lightweight JSONL store (one file per session, one JSON
// line per message) plus a small index.json manifest for O(1) listing.
// Stdlib only — no new dependencies.

import os
import rand
import time
import x.json2
import proto { Message }

__global g_dir string

pub struct Meta {
pub mut:
	id         string
	name       string
	created    i64
	updated    i64
	workspace  string
	model      string
	messages   int
	bytes      int
	tokens_in  int
	tokens_out int
	file       string
}

pub struct Manifest {
pub mut:
	version  int = 1
	sessions []Meta
}

// set_dir overrides the default location (called once from cli.run() with
// cfg.sessions.dir, resolved against the workspace when relative).
pub fn set_dir(d string) {
	g_dir = d
}

// dir returns the sessions directory: set_dir() > USAGI_SESSIONS_DIR > default.
pub fn dir() string {
	if g_dir != '' {
		return g_dir
	}
	env := os.getenv('USAGI_SESSIONS_DIR')
	if env != '' {
		return env
	}
	return os.join_path(os.home_dir(), '.usagi', 'sessions')
}

fn index_path() string {
	return os.join_path(dir(), 'index.json')
}

fn session_path(id string) string {
	return os.join_path(dir(), '${id}.jsonl')
}

// new_id: sortable and unique enough for a single user (unix seconds + 4 hex
// chars from rand, which is auto-seeded with time).
pub fn new_id() string {
	return '${time.unix_now()}-${rand.hex(4)}'
}

// default_name derives a session name from the first user message.
pub fn default_name(text string) string {
	s := text.trim_space()
	nl := s.index('\n') or { s.len }
	mut first := s[..nl].trim_space()
	if first == '' {
		return 'session'
	}
	r := first.runes()
	if r.len > 40 {
		first = r[..40].string()
	}
	return first
}

// age_str formats "now / 5m ago / 2h ago / 3d ago" for listing.
pub fn age_str(updated i64) string {
	d := time.unix_now() - updated
	if d < 60 {
		return 'now'
	}
	if d < 3600 {
		return '${d / 60}m ago'
	}
	if d < 86400 {
		return '${d / 3600}h ago'
	}
	return '${d / 86400}d ago'
}

// encode_line serializes one message as a single JSON line (newlines inside
// content are escaped by the encoder, so it stays one physical line).
fn encode_line(m Message) string {
	return json2.encode(m, json2.EncoderOptions{})
}

fn read_manifest() Manifest {
	p := index_path()
	if !os.exists(p) {
		return Manifest{}
	}
	text := os.read_file(p) or { return Manifest{} }
	return json2.decode[Manifest](text) or { Manifest{} }
}

fn write_manifest(m Manifest) ! {
	os.mkdir_all(dir()) or { return err }
	tmp := os.join_path(dir(), 'index.json.tmp')
	os.write_file(tmp, json2.encode(m, json2.EncoderOptions{prettify: true}))!
	os.rename(tmp, index_path())!
}

// list returns the manifest sessions sorted by `updated` desc (newest first).
pub fn list() Manifest {
	m := read_manifest()
	mut s := m.sessions.clone()
	s.sort_with_compare(fn (a &Meta, b &Meta) int {
		return if a.updated > b.updated { -1 } else if a.updated < b.updated { 1 } else { 0 }
	})
	return Manifest{
		version:  m.version
		sessions: s
	}
}

// find resolves a query to one session: exact id, unique id prefix, exact
// name, or unique name substring. Errors when not found or ambiguous.
pub fn find(query string) !Meta {
	q := query.trim_space()
	if q == '' {
		return error('usage: /resume <id|name> (use /sessions to list)')
	}
	m := list()
	mut by_id := []Meta{}
	mut by_name := []Meta{}
	for meta in m.sessions {
		if meta.id == q || meta.id.starts_with(q) {
			by_id << meta
		}
		if meta.name == q || meta.name.contains(q) {
			by_name << meta
		}
	}
	if by_id.len == 1 {
		return by_id[0]
	}
	if by_id.len == 0 && by_name.len == 1 {
		return by_name[0]
	}
	if by_id.len == 0 && by_name.len == 0 {
		return error('no session matches "${q}"')
	}
	return error('"${q}" matches several sessions — use the id')
}

// load reads a session file line by line. A trailing incomplete line (crash
// mid-write) is ignored.
pub fn load(id string) ![]Message {
	text := os.read_file(session_path(id))!
	mut out := []Message{}
	for raw in text.split('\n') {
		line := raw.trim_right('\r')
		if line == '' {
			continue
		}
		msg := json2.decode[Message](line) or { continue }
		out << msg
	}
	if out.len == 0 {
		return error('session ${id} is empty')
	}
	return out
}

// create writes the system message as line 1 and registers the session.
pub fn create(name string, workspace string, model string, system_msg Message) !Meta {
	os.mkdir_all(dir()) or { return err }
	id := new_id()
	line := encode_line(system_msg) + '\n'
	os.write_file(session_path(id), line)!
	now := time.unix_now()
	name_ := if name.trim_space() != '' { name.trim_space() } else { 'session' }
	meta := Meta{
		id:        id
		name:      name_
		created:   now
		updated:   now
		workspace: workspace
		model:     model
		messages:  1
		bytes:     line.len
		file:      '${id}.jsonl'
	}
	mut m := read_manifest()
	m.sessions << meta
	write_manifest(m)!
	return meta
}

// append adds the new messages of one turn (plus their token usage) to the end
// of the session file and refreshes the manifest. O(new), no full rewrite.
pub fn append(id string, new_msgs []Message, tin int, tout int) ! {
	if new_msgs.len == 0 && tin <= 0 && tout <= 0 {
		return
	}
	mut chunk := ''
	for msg in new_msgs {
		chunk += encode_line(msg) + '\n'
	}
	if chunk.len > 0 {
		mut f := os.open_append(session_path(id))!
		f.write_string(chunk)!
		f.close()
	}
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].updated = time.unix_now()
			m.sessions[i].messages += new_msgs.len
			m.sessions[i].bytes += chunk.len
			m.sessions[i].tokens_in += tin
			m.sessions[i].tokens_out += tout
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not in index')
}

// add_tokens accumulates token counters without touching the file (used after
// save_full, which does not know the turn's usage).
pub fn add_tokens(id string, tin int, tout int) ! {
	if tin <= 0 && tout <= 0 {
		return
	}
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].tokens_in += tin
			m.sessions[i].tokens_out += tout
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not in index')
}

// save_full rewrites the whole session file (rare: the append_user merge case,
// and /session save). Atomic: tmp + rename. Leaves token counters untouched.
pub fn save_full(id string, messages []Message) ! {
	os.mkdir_all(dir()) or { return err }
	mut chunk := ''
	for msg in messages {
		chunk += encode_line(msg) + '\n'
	}
	tmp := session_path(id) + '.tmp'
	os.write_file(tmp, chunk)!
	os.rename(tmp, session_path(id))!
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].messages = messages.len
			m.sessions[i].bytes = chunk.len
			m.sessions[i].updated = time.unix_now()
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not in index')
}

// rename updates only the name in the manifest.
pub fn rename(id string, name string) ! {
	name_ := name.trim_space()
	if name_ == '' {
		return error('usage: /session rename <id> <name>')
	}
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].name = name_
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not found')
}

// remove deletes one session (file + manifest entry).
pub fn remove(id string) ! {
	mut m := read_manifest()
	mut kept := []Meta{}
	mut found := false
	for meta in m.sessions {
		if meta.id == id {
			found = true
		} else {
			kept << meta
		}
	}
	if !found {
		return error('session ${id} not found')
	}
	os.rm(session_path(id)) or {} // already-gone file is not fatal
	m.sessions = kept
	write_manifest(m)!
}

// prune enforces sessions.max (count) and sessions.max_age_days (age). <=0
// disables that rule. Deletes only inside dir(); never the user workspace.
pub fn prune(max int, max_age_days int) ! {
	mut m := read_manifest()
	if m.sessions.len == 0 {
		return
	}
	now := time.unix_now()
	mut kept := []Meta{}
	for meta in m.sessions {
		age_days := (now - meta.updated) / 86400
		if max_age_days > 0 && age_days >= max_age_days {
			os.rm(session_path(meta.id)) or {}
			continue
		}
		kept << meta
	}
	if max > 0 && kept.len > max {
		kept.sort_with_compare(fn (a &Meta, b &Meta) int {
			return if a.updated > b.updated { -1 } else if a.updated < b.updated { 1 } else { 0 }
		})
		for meta in kept[max..] {
			os.rm(session_path(meta.id)) or {}
		}
		kept = kept[..max]
	}
	m.sessions = kept
	write_manifest(m)!
}

// cleanup reconciles the manifest with disk: drops entries whose file is
// missing, and removes orphan .jsonl files with no manifest entry.
pub fn cleanup() ! {
	os.mkdir_all(dir()) or { return err }
	mut m := read_manifest()
	mut kept := []Meta{}
	for meta in m.sessions {
		if os.exists(session_path(meta.id)) {
			kept << meta
		}
	}
	m.sessions = kept
	write_manifest(m)!
	files := os.ls(dir()) or { return err }
	for f in files {
		if !f.ends_with('.jsonl') {
			continue
		}
		id := f[..f.len - 6] // strip ".jsonl"
		mut in_index := false
		for meta in m.sessions {
			if meta.id == id {
				in_index = true
				break
			}
		}
		if !in_index {
			os.rm(session_path(id)) or {}
		}
	}
}
