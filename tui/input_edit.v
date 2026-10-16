module tui

import os
import strings
import text as textlib { display_width, prefix_width }

// InputLine: the TUI's editable input buffer. All edit operations are
// plain functions over a rune array (no rendering, no globals), so every
// edit and history op is unit-testable in tui_test.v.
//
//   text    the line buffer (may contain '\n' — multi-line input)
//   cursor  rune index, 0..text.len
//   scroll_x horizontal scroll offset in display cells
//   history session history ring (newest last)
//   hist_pos -1 = editing the live line, else index into `history`
//   scratch  the live line, saved when a history walk starts

pub const history_limit = 200

pub const history_file_name = '.usagi_history'

pub struct InputLine {
pub mut:
	text     []rune
	cursor   int
	scroll_x int
	history  []string
	hist_pos  int = -1
	scratch   string
}

pub fn (mut il InputLine) clear() {
	il.text = []
	il.cursor = 0
	il.scroll_x = 0
	il.hist_pos = -1
	il.scratch = ''
}

pub fn (il InputLine) text_str() string {
	mut s := ''
	for r in il.text {
		s += r.str()
	}
	return s
}

// set_text replaces the buffer and puts the cursor at the end.
pub fn (mut il InputLine) set_text(s string) {
	il.text = s.runes()
	il.cursor = il.text.len
	il.scroll_x = 0
	il.hist_pos = -1
}

// show replaces the buffer without touching `hist_pos` — used by the
// history walk to swap in an entry.
pub fn (mut il InputLine) show(s string) {
	il.text = s.runes()
	il.cursor = il.text.len
	il.scroll_x = 0
}

pub fn (mut il InputLine) insert(r rune) {
	il.text.insert(il.cursor, r)
	il.cursor += 1
}

pub fn (mut il InputLine) insert_str(s string) {
	for r in s.runes() {
		il.insert(r)
	}
}

pub fn (mut il InputLine) insert_newline() {
	il.insert(rune(10))
}
// strip_terminal_noise removes key/escape reports that can leak into the input
// when term.ui's reader splits an escape sequence across reads: the leading ESC
// is consumed as its own event, leaving the rest (`[<64;5;41M`, `[127;1:3u`, …)
// to arrive as plain text. Common leaked forms are dropped; ordinary bracketed
// text (`a[0] = b`, `[A]`, `[2024M`) is kept.
pub fn strip_terminal_noise(s string) string {
	if s == '' {
		return s
	}
	if is_bare_key_report(s) {
		return ''
	}
	mut out := strings.Builder{}
	mut i := 0
	for i < s.len {
		n := leaked_report_len(s, i)
		if n > 0 {
			i += n
			continue
		}
		out.write_u8(s[i])
		i += 1
	}
	return out.str()
}

// is_bare_key_report matches a whole leaked report with no leading `[`/`<`
// (e.g. the tail of `[127;1:3u` if the `[` was consumed too).
fn is_bare_key_report(s string) bool {
	if s.len < 2 {
		return false
	}
	mut i := 0
	mut has_sep := false
	for i < s.len {
		c := s[i]
		if c == `;` || c == `:` {
			has_sep = true
		} else if !c.is_digit() {
			break
		}
		i += 1
	}
	if i != s.len - 1 {
		return false
	}
	return match s[i] {
		`u`, `M`, `m` { has_sep }
		`~` { has_sep }
		else { false }
	}
}

// leaked_report_len returns the length of a leaked escape report starting at
// `i` (which must be `[` or `<`), or 0 when the text is not one.
fn leaked_report_len(s string, i int) int {
	if i >= s.len || (s[i] != `[` && s[i] != `<`) {
		return 0
	}
	mut j := i
	if s[j] == `[` {
		j += 1
	}
	mut had_lt := false
	if j < s.len && s[j] == `<` {
		had_lt = true
		j += 1
	}
	mut k := j
	mut has_sep := false
	for k < s.len {
		c := s[k]
		if c == `;` || c == `:` {
			has_sep = true
			k += 1
			continue
		}
		if c.is_digit() || c == `<` || c == `?` || c == `>` {
			k += 1
			continue
		}
		break
	}
	if k >= s.len {
		return 0
	}
	body := k - j
	ok := match s[k] {
		`M`, `m` { body > 0 && (had_lt || has_sep) }
		`u` { body > 0 && has_sep }
		`~` { body > 0 }
		`A`, `B`, `C`, `D`, `F`, `H`, `P`, `Q`, `R`, `S`, `Z` { body > 0 && has_sep }
		else { false }
	}
	if ok {
		return k + 1 - i
	}
	return 0
}

// insert_text inserts a chunk of text (a paste, or a single typed rune).
// Embedded CR / CRLF / LF become input line breaks; control characters other
// than newline are dropped so a paste can never inject raw escapes into the
// buffer. Returns the number of visible runes inserted.
pub fn (mut il InputLine) insert_text(s string) int {
	mut n := 0
	runes := strip_terminal_noise(s).runes()
	mut i := 0
	for i < runes.len {
		r := runes[i]
		if r == `\r` {
			if i + 1 < runes.len && runes[i + 1] == `\n` {
				i += 1 // treat CRLF as one newline
			}
			il.insert_newline()
			n += 1
		} else if r == `\n` {
			il.insert_newline()
			n += 1
		} else if is_printable(r) {
			il.insert(r)
			n += 1
		}
		i += 1
	}
	return n
}

pub fn (mut il InputLine) backspace() {
	if il.cursor > 0 {
		il.text.delete(il.cursor - 1)
		il.cursor -= 1
	}
}

pub fn (mut il InputLine) forward_delete() {
	if il.cursor < il.text.len {
		il.text.delete(il.cursor)
	}
}

pub fn (mut il InputLine) move_left() {
	if il.cursor > 0 {
		il.cursor -= 1
	}
}

pub fn (mut il InputLine) move_right() {
	if il.cursor < il.text.len {
		il.cursor += 1
	}
}

// line_bounds returns the rune offsets of the start and end (exclusive)
// of the line the cursor is on.
pub fn (il InputLine) line_bounds() (int, int) {
	mut start := 0
	for i in 0 .. il.cursor {
		if il.text[i] == `\n` {
			start = i + 1
		}
	}
	mut end := il.text.len
	for i in il.cursor .. il.text.len {
		if il.text[i] == `\n` {
			end = i
			break
		}
	}
	return start, end
}

// current_line returns the line containing the cursor as a string, plus
// the cursor's rune index within that line.
pub fn (il InputLine) current_line() (string, int) {
	start, end := il.line_bounds()
	mut s := ''
	for i in start .. end {
		s += il.text[i].str()
	}
	return s, il.cursor - start
}

// logical_lines splits the buffer on '\n' (always at least one line).
pub fn (il InputLine) logical_lines() []string {
	mut out := []string{}
	mut sb := strings.Builder{}
	for r in il.text {
		if r == `\n` {
			out << sb.str()
			sb = strings.Builder{}
		} else {
			sb.write_rune(r)
		}
	}
	out << sb.str()
	return out
}

// cursor_line is the 0-based index of the line the cursor is on.
pub fn (il InputLine) cursor_line() int {
	mut n := 0
	for i in 0 .. il.cursor {
		if il.text[i] == `\n` {
			n += 1
		}
	}
	return n
}

// move_home / move_end jump to the start / end of the current line.
pub fn (mut il InputLine) move_home() {
	start, _ := il.line_bounds()
	il.cursor = start
}

pub fn (mut il InputLine) move_end() {
	_, end := il.line_bounds()
	il.cursor = end
}

// line_starts returns the rune index where each logical line begins.
pub fn (il InputLine) line_starts() []int {
	mut out := [0]
	for i, r in il.text {
		if r == `\n` {
			out << i + 1
		}
	}
	return out
}

// move_up / move_down move the cursor between input lines, keeping the column
// where possible (like a text box). No-op on the first / last line.
pub fn (mut il InputLine) move_up() {
	starts := il.line_starts()
	cl := il.cursor_line()
	if cl <= 0 {
		return
	}
	col := il.cursor - starts[cl]
	prev_start := starts[cl - 1]
	prev_len := (starts[cl] - 1) - prev_start
	il.cursor = prev_start + (if col > prev_len { prev_len } else { col })
}

pub fn (mut il InputLine) move_down() {
	starts := il.line_starts()
	cl := il.cursor_line()
	if cl >= starts.len - 1 {
		return
	}
	col := il.cursor - starts[cl]
	next_start := starts[cl + 1]
	next_end := if cl + 2 < starts.len { starts[cl + 2] - 1 } else { il.text.len }
	next_len := next_end - next_start
	il.cursor = next_start + (if col > next_len { next_len } else { col })
}

pub fn (mut il InputLine) kill_to_start() { // ctrl-u
	if il.cursor == 0 {
		return
	}
	il.text = il.text[il.cursor..]
	il.cursor = 0
}

pub fn (mut il InputLine) kill_to_end() { // ctrl-k
	if il.cursor >= il.text.len {
		return
	}
	il.text = il.text[..il.cursor]
}

// delete_word removes the word before the cursor (trailing spaces, then
// word characters) — the Emacs ctrl-w behaviour.
pub fn (mut il InputLine) delete_word() {
	if il.cursor == 0 {
		return
	}
	mut i := il.cursor
	for i > 0 && il.text[i - 1] == ` ` {
		i -= 1
	}
	for i > 0 && is_word_char(il.text[i - 1]) {
		i -= 1
	}
	if i < il.cursor {
		il.text.delete_many(i, il.cursor - i)
		il.cursor = i
	}
}

pub fn is_word_char(r rune) bool {
	u := u32(r)
	return (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5a)
		|| (u >= 0x61 && u <= 0x7a) || u == 0x5f
}

// adjust_scroll keeps the cursor inside the horizontally visible window
// of `view_w` cells, scrolling right to reveal it and snapping back left.
pub fn (mut il InputLine) adjust_scroll(view_w int) {
	line, cur := il.current_line()
	if view_w <= 0 {
		il.scroll_x = 0
		return
	}
	cur_w := prefix_width(line, cur)
	line_w := display_width(line)
	if cur_w > il.scroll_x + view_w {
		il.scroll_x = cur_w - view_w
	} else if cur_w < il.scroll_x {
		il.scroll_x = cur_w
	}
	mut max_x := line_w - view_w
	if max_x < 0 {
		max_x = 0
	}
	if il.scroll_x > max_x {
		il.scroll_x = max_x
	}
	if il.scroll_x < 0 {
		il.scroll_x = 0
	}
}

// --- history --------------------------------------------------------------

// push_history appends to the ring: blanks are ignored, consecutive
// repeats are de-duped, and the ring is capped at history_limit.
pub fn (mut il InputLine) push_history(raw string) {
	s := raw.trim_space()
	if s == '' {
		return
	}
	if il.history.len > 0 && il.history.last() == s {
		return
	}
	il.history << s
	if il.history.len > history_limit {
		il.history = il.history[1..]
	}
}

// hist_prev walks back through the history; the first call saves the live
// line in `scratch`. Returns false at the newest entry.
pub fn (mut il InputLine) hist_prev() bool {
	if il.history.len == 0 {
		return false
	}
	if il.hist_pos == -1 {
		il.scratch = il.text_str()
		il.hist_pos = il.history.len - 1
	} else if il.hist_pos > 0 {
		il.hist_pos -= 1
	} else {
		return false
	}
	il.show(il.history[il.hist_pos])
	return true
}

// hist_next walks back towards the live line and restores it at the top.
pub fn (mut il InputLine) hist_next() bool {
	if il.hist_pos < 0 {
		return false
	}
	il.hist_pos += 1
	if il.hist_pos >= il.history.len {
		il.hist_pos = -1
		il.show(il.scratch)
		il.scratch = ''
	} else {
		il.show(il.history[il.hist_pos])
	}
	return true
}

pub fn history_file_path() string {
	return os.join_path(os.home_dir(), history_file_name)
}

// load_input_history reads the per-user history file (best effort).
pub fn load_input_history() []string {
	text := os.read_file(history_file_path()) or {
		return []
	}
	mut out := []string{}
	for raw in text.split('\n') {
		l := raw.trim_space()
		if l != '' {
			out << l
		}
	}
	if out.len > history_limit {
		out = out[out.len - history_limit ..]
	}
	return out
}

// save_input_history persists the history (best effort — a file we cannot
// write is not fatal).
pub fn save_input_history(h []string) {
	if h.len == 0 {
		return
	}
	os.write_file(history_file_path(), '${h.join('\n')}\n') or {
	}
}

// --- `:` commands ----------------------------------------------------------

pub const tui_commands = [
	'/budget'
	'/clear'
	'/copy'
	'/effort'
	'/help'
	'/history'
	'/load'
	'/model'
	'/pet'
	'/quit'
	'/resume'
	'/save'
	'/session'
	'/sessions'
	'/theme'
	'/think'
	'/tokens'
	'/tools'
]

// find_byte returns the index of the first occurrence of single-byte `b`
// in `s`, or -1 (this V release's `string.index` returns an optional).
pub fn find_byte(s string, b string) int {
	if b.len == 0 {
		return -1
	}
	mut i := 0
	for i < s.len {
		if s[i] == b[0] {
			return i
		}
		i += 1
	}
	return -1
}

// parse_command splits `/cmd rest` into the command name and the full rest
// — everything after the first space, spaces preserved — so `/save my
// file.json` and `/model my model` keep their arguments intact.
pub fn parse_command(cmd string) (string, string) {
	i := find_byte(cmd, " ")
	if i < 0 {
		return cmd, ''
	}
	return cmd[0..i], cmd[i + 1 ..]
}

pub fn common_prefix(ss []string) string {
	if ss.len == 0 {
		return ''
	}
	mut p := ss[0]
	for s in ss[1..] {
		mut i := 0
		for i < p.len && i < s.len && p[i] == s[i] {
			i += 1
		}
		p = p[0..i]
	}
	return p
}

// split_path splits a path into (dir, base); a trailing '/' means "list
// this directory" (base is '').
pub fn split_path(p string) (string, string) {
	if p.ends_with('/') {
		return p, ''
	}
	mut i := p.len - 1
	for i >= 0 && p[i] != `/` {
		i -= 1
	}
	if i < 0 {
		return '', p
	}
	return p[0..i], p[i + 1 ..]
}

// complete_input completes `/` command names and, for `/save`, filesystem
// paths. Returns the (possibly updated) whole input, unchanged when there
// is no unique or unambiguous completion.
pub fn complete_input(text string) string {
	name, rest := parse_command(text)
	if !name.starts_with('/') {
		return text
	}
	if find_byte(text, " ") < 0 {
		cands := tui_commands.filter(it.starts_with(name))
		if cands.len == 1 && cands[0].len > name.len {
			return cands[0] + ' '
		}
		if cands.len > 1 {
			cp := common_prefix(cands)
			if cp.len > name.len {
				return cp
			}
		}
		return text
	}
	if name != '/save' && name != '/load' {
		return text
	}
	return '${name} ${complete_path(rest)}'
}

// complete_path completes a partial path against the disk: a unique match
// (or an unambiguous common prefix) is completed, and directories get a
// trailing '/'. Returns `partial` unchanged when nothing matches.
pub fn complete_path(partial string) string {
	mut dir, base := split_path(partial)
	if dir == '' {
		dir = '.'
	}
	entries := os.ls(dir) or {
		return partial
	}
	cands := entries.filter(it.starts_with(base))
	if cands.len == 0 {
		return partial
	}
	mut done := false
	mut result := ''
	if cands.len == 1 {
		e := cands[0]
		if os.is_dir(os.join_path(dir, e)) {
			result = os.join_path(dir, e) + '/'
		} else {
			result = os.join_path(dir, e)
		}
		done = true
	} else {
		cp := common_prefix(cands)
		if cp.len > base.len {
			result = os.join_path(dir, cp)
			done = true
		}
	}
	return if done { result } else { partial }
}
