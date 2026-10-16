module main

import os
import tools
import text { prefix_width, slice_by_cells }
import tui { InputLine, complete_input, complete_path, help_head, help_row, parse_command, strip_terminal_noise }

// Unit tests for the editable input line (InputLine), input history,
// command parsing, and completion (P1). Pure functions only — no
// rendering, no term.ui.

// ---------------------------------------------------------------------------
// InputLine editing

fn test_insert_and_cursor() {
	mut il := InputLine{}
	il.insert_str('hello')
	assert il.text_str() == 'hello'
	assert il.cursor == 5
	// insert in the middle
	il.move_left()
	il.insert_str('X')
	assert il.text_str() == 'hellXo'
	assert il.cursor == 5
}

fn test_backspace_and_forward_delete() {
	mut il := InputLine{}
	il.insert_str('abcde')
	il.backspace()
	assert il.text_str() == 'abcd'
	il.backspace()
	il.backspace()
	il.backspace()
	il.backspace()
	il.backspace() // no-op at start
	assert il.text_str() == ''
	assert il.cursor == 0
	il.insert_str('ab')
	il.move_left()
	il.forward_delete()
	assert il.text_str() == 'a'
	il.forward_delete()
	il.forward_delete() // no-op at end
	assert il.text_str() == 'a'
}

fn test_kill_ops() {
	mut il := InputLine{}
	il.insert_str('hello world')
	il.move_home()
	il.kill_to_end()
	assert il.text_str() == ''
	il.insert_str('hello world')
	il.move_end()
	il.kill_to_start()
	assert il.text_str() == ''
	il.insert_str('hello world')
	il.move_left() // cursor before 'd'
	il.kill_to_end()
	assert il.text_str() == 'hello worl'
	assert il.cursor == 10
}

fn test_delete_word() {
	mut il := InputLine{}
	il.insert_str('hello world foo')
	il.delete_word()
	assert il.text_str() == 'hello world '
	il.delete_word()
	assert il.text_str() == 'hello '
	il.delete_word()
	assert il.text_str() == ''
	// word chars include underscore; punctuation is not a word char
	mut il2 := InputLine{}
	il2.insert_str('a_b_c. d')
	il2.delete_word()
	assert il2.text_str() == 'a_b_c. '
	il2.delete_word()
	assert il2.text_str() == 'a_b_c.'
}

fn test_cjk_editing() {
	mut il := InputLine{}
	il.insert_str('世界你好')
	assert il.text_str() == '世界你好'
	assert il.cursor == 4
	il.backspace()
	assert il.text_str() == '世界你' // one rune gone, not one byte
	il.move_home()
	il.insert(`前`)
	assert il.text_str() == '前世界你'
	assert il.cursor == 1
}

fn test_multi_line_home_end() {
	mut il := InputLine{}
	il.insert_str('first line')
	il.insert_newline()
	il.insert_str('second line')
	assert il.text_str() == 'first line\nsecond line'
	il.move_home()
	assert il.cursor == 11 // start of the current (second) line
	il.move_end()
	assert il.cursor == 22
	// move_left crosses the newline, move_right stops at line ends
	il.move_left()
	il.move_left()
	assert il.cursor == 20
	il.move_home()
	assert il.cursor == 11
	il.move_end()
	il.move_right() // no-op at end of last line
	assert il.cursor == 22
	il.move_left()
	il.move_left()
	il.move_left()
	assert il.cursor == 19
	il.move_left()
	assert il.cursor == 18
	il.move_home()
	assert il.cursor == 11
	il.move_left() // crosses the newline to the end of the first line
	assert il.cursor == 10
}

fn test_input_text_normalizes_paste() {
	// A paste arrives as one chunk: CR / CRLF / LF become line breaks and
	// other control characters (tab) are dropped — raw control runes must
	// never reach the buffer (P1.11).
	mut il := InputLine{}
	n := il.insert_text('a\r\nb\nc\td')
	assert n == 6
	assert il.text_str() == 'a\nb\ncd'
	assert il.cursor == 6
	// single printable rune still works
	mut il2 := InputLine{}
	assert il2.insert_text('é') == 1
	assert il2.text_str() == 'é'
}

fn test_input_line_helpers() {
	mut il := InputLine{}
	il.insert_str('one\ntwo\nthree')
	assert il.logical_lines() == ['one', 'two', 'three']
	assert il.cursor_line() == 2
	il.move_home()
	assert il.cursor_line() == 2
	cl, off := il.current_line()
	assert cl == 'three' && off == 0
}

fn test_input_vertical_moves() {
	mut il := InputLine{}
	il.insert_str('aaa\nbbbbb\ncc')
	assert il.cursor_line() == 2
	// up keeps the column
	il.move_up()
	assert il.cursor_line() == 1
	l1, c1 := il.current_line()
	assert l1 == 'bbbbb' && c1 == 2
	il.move_up()
	l0, c0 := il.current_line()
	assert l0 == 'aaa' && c0 == 2
	// no-op at the first line
	il.move_up()
	assert il.cursor_line() == 0
	// down again keeps the column
	il.move_down()
	l1b, c1b := il.current_line()
	assert l1b == 'bbbbb' && c1b == 2
}

// ---------------------------------------------------------------------------
// History

fn test_history_push_dedupe_cap() {
	mut il := InputLine{}
	il.push_history('one')
	il.push_history('two')
	il.push_history('two') // duplicate of previous — not pushed
	assert il.history == ['one', 'two']
	for i in 0 .. 300 {
		il.push_history('msg ${i}')
	}
	assert il.history.len == 200
	assert il.history[0] == 'msg 100'
	assert il.history[199] == 'msg 299'
}

fn test_history_prev_next() {
	mut il := InputLine{}
	il.history = ['first', 'second']
	il.insert_str('live line')
	assert il.hist_prev()
	assert il.text_str() == 'second'
	assert il.hist_prev()
	assert il.text_str() == 'first'
	assert !il.hist_prev() // at the top entry
	assert il.hist_next()
	assert il.text_str() == 'second'
	assert il.hist_next() // restores the live line
	assert il.text_str() == 'live line'
	assert il.hist_pos == -1
	assert !il.hist_next()
	// no history → no-op
	mut empty := InputLine{}
	assert !empty.hist_prev()
}

// ---------------------------------------------------------------------------
// Command parsing

fn test_parse_command() {
	mut name, arg := parse_command('/clear')
	assert name == '/clear' && arg == ''
	name, arg = parse_command('/model')
	assert name == '/model' && arg == ''
	name, arg = parse_command('/model gpt-5.x')
	assert name == '/model' && arg == 'gpt-5.x'
	name, arg = parse_command('/save my file.json')
	assert name == '/save' && arg == 'my file.json' // spaces preserved
}

// ---------------------------------------------------------------------------
// Completion

fn test_complete_command() {
	assert complete_input('') == ''
	assert complete_input('/cl') == '/clear '
	assert complete_input('/he') == '/help '
	assert complete_input('/z') == '/z' // no match — unchanged
	assert complete_input('plain') == 'plain' // not a command
	// already unique match
	assert complete_input('/tok') == '/tokens '
}

fn test_complete_path() {
	mut d := os.join_path(tools.project_root(), 'test_tmp_files', 'completion')
	os.rmdir_all(d) or {}
	os.mkdir_all(d) or {}
	os.write_file(os.join_path(d, 'alpha.txt'), 'a')!
	os.write_file(os.join_path(d, 'albeta.txt'), 'b')!
	os.mkdir_all(os.join_path(d, 'subdir')) or {}
	// unique prefix
	assert complete_path('${d}/alph') == '${d}/alpha.txt'
	// no match — unchanged
	assert complete_path('${d}/zzz') == '${d}/zzz'
	// directory match gets a trailing slash
	assert complete_path('${d}/sub') == '${d}/subdir/'
	// common prefix of alpha/albeta is 'al' — unchanged
	assert complete_path('${d}/al') == '${d}/al'
	os.rmdir_all(d) or {}
}

// ---------------------------------------------------------------------------
// Display-cell helpers

fn test_prefix_width_and_slice_by_cells() {
	assert prefix_width('hello', 5) == 5
	assert prefix_width('你好', 1) == 2 // CJK = 2 cells per rune
	assert prefix_width('hi你', 3) == 4
	assert slice_by_cells('hello', 0, 5) == 'hello'
	assert slice_by_cells('hello', 2, 3) == 'llo'
	assert slice_by_cells('hello', 2, 10) == 'llo' // clamped to end
	assert slice_by_cells('你好啊', 0, 5) == '你好' // 啊 needs 6 cells
	assert slice_by_cells('你好啊', 2, 10) == '好啊'
	assert slice_by_cells('', 0, 10) == ''
}

fn test_adjust_scroll() {
	mut il := InputLine{}
	il.insert_str('short')
	il.adjust_scroll(80)
	assert il.scroll_x == 0
	// long line: cursor at the end scrolls right
	il.insert_str('abcdefghijklmnopqrstuvwxyz')
	il.move_end()
	il.adjust_scroll(10)
	assert il.scroll_x == 21 // 26 cells - 10 visible
	il.move_home()
	il.adjust_scroll(10)
	assert il.scroll_x == 0
	// mid-line cursor: minimal scroll to reveal it
	il.insert_str('012345678901234567890123456789')
	il.move_home()
	for i in 0 .. 15 {
		il.move_right()
	}
	il.adjust_scroll(10)
	assert il.scroll_x == 5 // cursor at cell 15, 10 visible
}

fn test_strip_terminal_noise() {
	// SGR mouse reports (and their ESC-less fragments) are dropped.
	assert strip_terminal_noise('[<64;5;41M') == ''
	assert strip_terminal_noise('[<64;5;41M[64;5241M') == ''
	assert strip_terminal_noise('<64;5;41M') == ''
	assert strip_terminal_noise('abc[<64;5;41Mdef') == 'abcdef'
	// Kitty CSI-u key reports (e.g. a key release) are dropped too.
	assert strip_terminal_noise('[127;1:3u') == ''
	assert strip_terminal_noise('[57444;9u') == ''
	assert strip_terminal_noise('127;1:3u') == ''
	assert strip_terminal_noise('abc[127;1:3udef') == 'abcdef'
	// Function keys / modified arrows.
	assert strip_terminal_noise('[1;5C') == ''
	assert strip_terminal_noise('[3~') == ''
	// Ordinary bracketed text is kept.
	assert strip_terminal_noise('a[0] = b') == 'a[0] = b'
	assert strip_terminal_noise('[A]') == '[A]'
	assert strip_terminal_noise('[2024M') == '[2024M'
	assert strip_terminal_noise('x < y') == 'x < y'
	assert strip_terminal_noise('x = 123') == 'x = 123'
	assert strip_terminal_noise('123~') == '123~'
	assert strip_terminal_noise('') == ''
}

fn test_insert_text_drops_mouse_noise() {
	mut il := InputLine{}
	n := il.insert_text('[<64;5;41Mhola')
	assert n == 4
	assert il.text_str() == 'hola'
	mut il2 := InputLine{}
	assert il2.insert_text('theme[127;1:3u') == 5
	assert il2.text_str() == 'theme'
}

// ---------------------------------------------------------------------------
// /help formatting

fn test_help_rows_align() {
	assert help_head('keys') == '── keys ──'
	// 2-space indent + a 24-column command field, then the description.
	for c in ['/quit', '/clear', '/help [keys|commands]', '/resume [id|name]'] {
		row := help_row(c, 'DESC')
		assert row.ends_with('DESC')
		assert row[26..] == 'DESC'
	}
	assert help_row('/quit', 'exit') == '  /quit' + ' '.repeat(19) + 'exit'
}
