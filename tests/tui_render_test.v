module main

import term.ui as termui
import config { TuiConfig }
import proto { Message }
import text as textlib { compact_ws, display_width, fit_cells, truncate_cells }
import tui { RenderRow, StatusView, Theme, TuiLine, box_bottom, box_bottom_label, box_top, bubble_align, bubble_class, bubble_content_width, bubble_width, build_rows, build_status, build_transcript_lines, compose_frame, default_spin_frames, default_spin_interval_ms, expand_bubbles, fit_status, flatten_spans, frame_view, kind_prefix, layout_for, parse_hex, parse_md_spans, parse_tool_header, render_line_rows, resolve_animation, rule_text, scroll_thumb, small_text, split_fence, status_join, theme_for, thinking_label, tool_header_rows, tool_result_rows, wrap_labeled, wrap_span_rows, wrap_text }

// Test-local theme resolver (the production path goes through theme_for).
fn theme_default() Theme {
	return theme_for(TuiConfig{})
}

// Unit tests for the Phase 2 rendering helpers: wrapping, prefixes,
// markdown-lite, tool blocks, and the status bar. All pure functions — no
// terminal, no term.ui context.

// ---------------------------------------------------------------------------
// wrap_text

fn test_wrap_text_basic() {
	assert wrap_text('', 10) == ['']
	assert wrap_text('hello', 10) == ['hello']
	assert wrap_text('abc def', 3) == ['abc', ' de', 'f']
}

fn test_wrap_text_preserves_whitespace() {
	// Wrapping is lossless: joining the rows reproduces the input exactly.
	for s in ['hello world', 'a  b   c', '  leading and trailing  ', 'one', 'x'.repeat(25)] {
		assert wrap_text(s, 7).join('') == s
	}
}

fn test_wrap_text_hard_breaks_long_tokens() {
	assert wrap_text('abcdefghij', 4) == ['abcd', 'efgh', 'ij']
	// a token longer than the width is cut, not dropped
	assert wrap_text('aaaaaaaaaaaa', 5).join('') == 'aaaaaaaaaaaa'
}

fn test_wrap_text_newlines_and_wide() {
	assert wrap_text('ab\ncd', 10) == ['ab', 'cd']
	assert wrap_text('你好世界', 4) == ['你好', '世界']
	// a wide rune that would only half-fit goes to the next row
	assert wrap_text('你好', 3) == ['你', '好']
	for row in wrap_text('héllo 世界 😀', 4) {
		assert display_width(row) <= 4
	}
}

// ---------------------------------------------------------------------------
// wrap_labeled

fn test_wrap_labeled_hanging_indent() {
	rows := wrap_labeled('▸ ', 'hello world', 8)
	assert rows[0] == '▸ hello '
	// continuation rows are indented by the prefix width (2 cells)
	assert rows[1] == '  world'
}

fn test_wrap_labeled_multiline() {
	rows := wrap_labeled('· ', 'one\ntwo', 20)
	assert rows == ['· one', '· two']
}

// ---------------------------------------------------------------------------
// prefixes / markdown-lite

fn test_kind_prefix() {
	assert kind_prefix('user').contains('you')
	assert kind_prefix('tool').contains('⚙')
	assert kind_prefix('tool_result').contains('│')
	assert kind_prefix('error').contains('✗')
	assert kind_prefix('rule') == ''
	for k in ['user', 'content', 'thinking', 'tool', 'note', 'error', 'line'] {
		assert kind_prefix(k) != ''
	}
}

fn test_parse_md_spans() {
	spans := parse_md_spans('a **bold** word')
	// join of the spans reproduces the text without markers
	assert flatten_spans(spans) == 'a bold word'
	mut has_bold := false
	for sp in spans {
		if sp.style == 'bold' {
			has_bold = true
		}
	}
	assert has_bold
	// inline code is a real span, not a whole-row tint
	spans2 := parse_md_spans('call `run_turn` now')
	assert flatten_spans(spans2) == 'call run_turn now'
	mut code := ''
	for sp in spans2 {
		if sp.style == 'code' {
			code = sp.text
		}
	}
	assert code == 'run_turn'
	// unmatched markers stay literal
	assert flatten_spans(parse_md_spans('2 * 3 = 6')) == '2 * 3 = 6'
}

fn test_parse_md_spans_styles_survive_wrap() {
	rows := wrap_span_rows('', '', parse_md_spans('aa `code` ' + 'bb '.repeat(20)), 12)
	assert rows.len > 1
	// every row's flattened text is at most 12 cells
	for r in rows {
		assert display_width(flatten_spans(r)) <= 12
	}
	// the code run keeps its style on whichever row it lands
	mut found := false
	for r in rows {
		for sp in r {
			if sp.style == 'code' && sp.text.contains('code') {
				found = true
			}
		}
	}
	assert found
}

fn test_split_fence_pure_delimiters() {
	segs, st := split_fence('```python', false)
	assert st == true
	assert segs.len == 1 && segs[0].kind == 'fence' && segs[0].text == '```python'
	// a lone ``` closes an open fence
	segs2, st2 := split_fence('```', true)
	assert st2 == false
	assert segs2.len == 1 && segs2[0].kind == 'fence'
	// plain prose stays content
	segs3, st3 := split_fence('hello world', false)
	assert st3 == false && segs3[0].kind == 'content'
	// a line inside a fence is code
	segs4, _ := split_fence('    return 1', true)
	assert segs4.len == 1 && segs4[0].kind == 'code'
}

fn test_split_fence_glued() {
	// opener glued to code: ```pythondef greet(name):
	segs, st := split_fence('```pythondef greet(name):', false)
	assert st == true
	assert segs[0].kind == 'fence' && segs[0].text == '```pythondef'
	assert segs.len == 2 && segs[1].kind == 'code'
	assert segs[1].text == 'greet(name):'
	// closer glued to code: print(x)```
	segs2, st2 := split_fence('print(x)```', true)
	assert st2 == false
	assert segs2[0].kind == 'code' && segs2[0].text == 'print(x)'
	assert segs2[1].kind == 'fence' && segs2[1].text == '```'
}

// ---------------------------------------------------------------------------
// small string helpers

fn test_compact_ws() {
	assert compact_ws('a\n  b\tc') == 'a b c'
	assert compact_ws('   ') == ''
	assert compact_ws(' one ') == 'one'
}

fn test_truncate_cells() {
	assert truncate_cells('hello', 10) == 'hello'
	assert truncate_cells('hello', 4) == 'hel…'
	assert display_width(truncate_cells('hello', 4)) == 4
	assert display_width(truncate_cells('你好世界', 5)) <= 5
}

fn test_fit_cells() {
	assert fit_cells('hello', 8) == 'hello   '
	assert fit_cells('hello', 3) == 'hel'
	assert display_width(fit_cells('世界!', 4)) == 4
}

// ---------------------------------------------------------------------------
// rules

fn test_rule_text() {
	r := rule_text('12:00:00', 20)
	assert r.contains('12:00:00')
	assert display_width(r) == 20
	plain := rule_text('', 10)
	assert plain == '──────────'
}

// ---------------------------------------------------------------------------
// tool blocks

fn test_tool_header_rows() {
	rows := tool_header_rows('bash', '{"cmd": "ls -la"}', 60)
	assert rows.len >= 1
	assert rows[0].kind == 'tool'
	assert rows[0].text.starts_with('⚙ bash(')
	assert !rows[0].text.contains('\n')
	// huge arguments are compacted and ellipsized before wrapping
	long := 'x'.repeat(500)
	big := tool_header_rows('write_file', long, 40)
	assert big.len > 1
	assert big[0].text.contains('…') || big[big.len - 1].text.contains('…')
}

fn test_tool_result_rows_truncated() {
	short := tool_result_rows('one\ntwo\nthree', 60, false)
	assert short.len == 3
	assert short[0].text.starts_with('  │ one')

	mut many := []string{}
	for i in 0 .. 20 {
		many << 'line ${i}'
	}
	text := many.join('\n')
	rows := tool_result_rows(text, 60, false)
	assert rows.len == tui.tool_result_lines + 1
	assert rows[rows.len - 1].text.contains('more line(s)')
	assert rows[rows.len - 1].kind == 'tool_result'
	// expanded shows everything
	expanded := tool_result_rows(text, 60, true)
	assert expanded.len == 20
}

fn test_tool_result_rows_empty() {
	rows := tool_result_rows('', 60, false)
	assert rows.len == 1
	assert rows[0].text.contains('(no output)')
}

// ---------------------------------------------------------------------------
// parse_tool_header

fn test_parse_tool_header() {
	name, args := parse_tool_header('❯❯❯❯ bash  {"cmd": "ls"}')
	assert name == 'bash'
	assert args == '{"cmd": "ls"}'
	n2, a2 := parse_tool_header('❯❯❯❯ read_file')
	assert n2 == 'read_file' && a2 == ''
	n3, _ := parse_tool_header('')
	assert n3 == ''
}

// ---------------------------------------------------------------------------
// status bar

fn sample_status() StatusView {
	return StatusView{
		model:    'qwen2.5-coder-7b'
		busy:     false
		spin:     '⠋'
		last_ms:  1200
		tok_s:    '42.0 tok/s'
		prompt:   8000
		window:   32000
		sess_in:  1234
		sess_out: 567
		thinking: true
	}
}

fn test_status_full() {
	segs := build_status(sample_status(), theme_default())
	joined := status_join(segs)
	assert joined.contains('qwen2.5-coder-7b')
	assert joined.contains('ready')
	assert joined.contains('ctx 8.0k/32.0k [')
	assert joined.contains('25%')
	// Compact session tokens: up = in, down = out.
	assert joined.contains('↑1.2k ↓567')
	assert joined.contains('42.0 tok/s')
	// The key-hint guide is gone (the `/help` command documents the keys).
	assert !joined.contains('enter: send')
}

fn test_status_priority_keeps_ctx() {
	segs := build_status(sample_status(), theme_default())
	// 40 columns: the least useful segments go, but the context bar stays.
	fitted := fit_status(segs, 40)
	joined := status_join(fitted)
	assert joined.contains('ctx 8.0k/32.0k')
	assert !joined.contains('↑')
	assert display_width(joined) <= 40
	// Even narrower: only one segment survives, truncated to fit.
	tiny := fit_status(build_status(sample_status(), theme_default()), 12)
	tiny_join := status_join(tiny)
	assert tiny.len == 1
	assert display_width(tiny_join) <= 12
}

fn test_status_interrupt_and_thinking() {
	mut sv := sample_status()
	sv.busy = true
	sv.interrupted = true
	joined := status_join(build_status(sv, theme_default()))
	assert joined.contains('■ stopping…')
	// The stop marker must be a single cell so the status row stays aligned
	// (a wide-marked glyph left a stale character behind).
	assert display_width('■') == 1
	assert display_width('■ stopping…') == 11
	mut sv2 := sample_status()
	sv2.think = 'low·hidden'
	assert status_join(build_status(sv2, theme_default())).contains('T:low·hidden')
}

fn test_ctx_color_thresholds() {
	th := theme_default()
	assert th.ctx_color(10) == th.c('ok')
	assert th.ctx_color(75) == th.c('warn')
	assert th.ctx_color(95) == th.c('hot')
}

fn test_theme_hex_parse_and_override() {
	th := theme_default()
	assert th.color_for('content') == termui.Color{r: 120, g: 220, b: 120}
	c := parse_hex('#0102ff') or { panic('parse failed') }
	assert c == termui.Color{r: 1, g: 2, b: 255}
	c2 := parse_hex('0102ff') or { panic('parse failed') }
	assert c2 == c
	bad := parse_hex('#zzzzzz') or { termui.Color{r: 9, g: 9, b: 9} }
	assert bad == termui.Color{r: 9, g: 9, b: 9}
	// config overrides win over the palette default
	cfg := TuiConfig{
		theme:  'dark'
		colors: {'content': '#000001', 'accent': '#abcdef'}
	}
	th2 := theme_for(cfg)
	assert th2.color_for('content') == termui.Color{r: 0, g: 0, b: 1}
	assert th2.c('accent') == termui.Color{r: 171, g: 205, b: 239}
}

fn test_theme_light_differs() {
	lt := theme_for(TuiConfig{
		theme: 'light'
	})
	dt := theme_default()
	assert lt.color_for('content') != dt.color_for('content')
}

fn test_theme_cyberpunk() {
	cp := theme_for(TuiConfig{
		theme: 'cyberpunk'
	})
	dt := theme_default()
	lt := theme_for(TuiConfig{
		theme: 'light'
	})
	assert cp.color_for('content') != dt.color_for('content')
	assert cp.color_for('content') != lt.color_for('content')
	assert cp.color_for('accent') == termui.Color{r: 255, g: 47, b: 214}
	// all three names are selectable
	assert 'dark' in tui.theme_names && 'light' in tui.theme_names && 'cyberpunk' in tui.theme_names
	// unknown names fall back to the dark palette
	unknown := theme_for(TuiConfig{
		theme: 'nope'
	})
	assert unknown.color_for('content') == dt.color_for('content')
	// per-kind overrides still win over a themed palette
	over := theme_for(TuiConfig{
		theme:  'cyberpunk'
		colors: {'content': '#abcdef'}
	})
	assert over.color_for('content') == termui.Color{r: 171, g: 205, b: 239}
}

fn test_build_transcript_lines_roundtrip() {
	msgs := [
		Message{role: 'system', content: 'sys'},
		Message{role: 'user', content: 'hi'},
		Message{role: 'assistant', content: 'hello\n```v\nfn main() {}\n```'},
		Message{role: 'tool', content: 'tool output'},
	]
	lines := build_transcript_lines(msgs, false)
	mut kinds := map[string]int{}
	for l in lines {
		kinds[l.kind] = kinds[l.kind] + 1
	}
	// no more full-width rules: the timestamp rides on the user line
	assert kinds['rule'] == 0
	assert kinds['user'] == 1
	assert kinds['content'] == 1
	assert kinds['fence'] == 2
	assert kinds['code'] == 1
	assert kinds['tool_result'] == 1
	// system messages are skipped; loaded history carries no clock stamp
	assert lines[0].kind == 'user'
	assert lines[0].stamp == ''
}

fn test_expand_bubbles_dynamic_width() {
	// a short user message gets a small (but not tiny) bubble
	short := expand_bubbles([RenderRow{
		kind: 'user'
		text: 'hi'
		bubble: 'user'
		align: 'right'
	}], 80)
	assert short[0].bubble_w >= 12
	assert short[0].bubble_w < bubble_width(80)
	// a long message grows to the terminal-derived maximum
	long := 'x'.repeat(400)
	expanded := expand_bubbles(render_line_rows('user', long, '', '', 80, false), 80)
	mut max_bw := 0
	for r in expanded {
		if r.bubble_w > max_bw {
			max_bw = r.bubble_w
		}
	}
	assert max_bw == bubble_width(80)
}

fn test_expand_bubbles_stamp_inside() {
	rows := [RenderRow{
		kind: 'user'
		text: 'hi'
		bubble: 'user'
		align: 'right'
		stamp: '10:00'
	}]
	out := expand_bubbles(rows, 80)
	// the stamp rides on the bottom border (no extra row for it)
	mut found := false
	mut mids := 0
	for r in out {
		if r.box == 'bottom' && r.text.contains('¹⁰·⁰⁰') {
			found = true
		}
		if r.box == 'mid' {
			mids += 1
		}
	}
	assert found
	// top + 2 vpad + 1 content + bottom = 4 mids? no: mid rows are vpad+content+vpad = 3
	assert mids == 3
}

fn test_box_bottom_label() {
	b := box_bottom_label(20, '10:00')
	assert b.starts_with('╰')
	assert b.ends_with('╯')
	assert b.contains('¹⁰·⁰⁰')
	assert display_width(b) == 20
	// too small for the label -> plain bottom
	assert box_bottom_label(4, '10:00') == box_bottom(4)
}

fn test_small_text() {
	assert small_text('10:22') == '¹⁰·²²'
	assert small_text('19:09') == '¹⁹·⁰⁹'
	assert small_text('abc') == 'abc'
}

fn test_scroll_thumb() {
	// Nothing to scroll: no thumb.
	t0, h0 := scroll_thumb(10, 10, 5)
	assert t0 == 0 && h0 == 0
	t1, h1 := scroll_thumb(100, 0, 0)
	assert t1 == 0 && h1 == 0
	// At the top the thumb starts at row 0; at the live bottom it ends at the
	// last row. Height is the visible fraction (min 1).
	top, h := scroll_thumb(100, 10, 90)
	assert top == 0
	assert h == 1
	btop, bh := scroll_thumb(100, 10, 0)
	assert bh == 1
	assert btop == 10 - bh
	// A larger viewport over the same transcript gives a taller thumb.
	_, h2 := scroll_thumb(30, 10, 0)
	assert h2 == 3
}

// ---------------------------------------------------------------------------
// render_line_rows / build_rows

fn test_render_line_rows_user_bubble() {
	rows := render_line_rows('user', 'hello there world this is a longer user message', '', '', 40, false)
	assert rows.len > 1
	for r in rows {
		assert r.bubble == 'user'
		assert r.align == 'right'
		// wrapped to the bubble content width, and no speaker label
		assert display_width(r.text) <= bubble_content_width(40)
		assert !r.text.starts_with('▸')
	}
}

fn test_render_line_rows_content_bubble() {
	rows := render_line_rows('content', 'hi there', '', '', 40, false)
	assert rows[0].bubble == 'assistant'
	assert rows[0].align == 'left'
	assert rows[0].text == 'hi there'
	// the turn rule is not bubbled
	rule := render_line_rows('rule', '', '09:30:00', '', 40, false)
	assert rule[0].bubble == ''
}

fn test_render_line_rows_content_spans() {
	rows := render_line_rows('content', 'use `x` here', '', '', 30, false)
	assert rows.len == 1
	assert !rows[0].text.contains('`')
	mut code := ''
	for sp in rows[0].spans {
		if sp.style == 'code' {
			code = sp.text
		}
	}
	assert code == 'x'
	// prose around the code keeps the default (kind) style
	assert rows[0].spans[0].style == ''
}

fn test_render_line_rows_thinking_markdown() {
	// Thinking is model text too: markers are stripped and inline code is
	// tinted instead of showing literal backticks.
	rows := render_line_rows('thinking', 'the `factorial` fn is **right**', '', '', 80, false)
	assert rows[0].text.starts_with('· ')
	mut all := ''
	mut code := ''
	mut bold := ''
	for r in rows {
		all += r.text
		for sp in r.spans {
			if sp.style == 'code' {
				code += sp.text
			}
			if sp.style == 'bold' {
				bold += sp.text
			}
		}
	}
	assert !all.contains('`')
	assert !all.contains('**')
	assert code == 'factorial'
	assert bold == 'right'
}

fn test_build_rows_kinds() {
	lines := [
		TuiLine{kind: 'rule', stamp: '09:30:00'},
		TuiLine{kind: 'user', text: 'hi'},
		TuiLine{kind: 'thinking', text: 'pondering'},
		TuiLine{kind: 'code', text: 'fn main() {}'},
		TuiLine{kind: 'tool', text: 'bash', arg: 'ls'},
	]
	rows := build_rows(lines, 40, false)
	mut kinds := map[string]bool{}
	for r in rows {
		kinds[r.kind] = true
	}
	for k in ['rule', 'user', 'thinking', 'code', 'tool'] {
		assert k in kinds
	}
}

// ---------------------------------------------------------------------------
// golden frame composition

fn test_box_helpers() {
	assert box_top(5) == '╭───╮'
	assert box_bottom(5) == '╰───╯'
	assert box_top(1) == '╭'
}

fn test_expand_bubbles_structure() {
	rows := [
		RenderRow{kind: 'user', text: 'hi', bubble: 'user', align: 'right'},
		RenderRow{kind: 'rule', text: '---'},
		RenderRow{kind: 'content', text: 'yo', bubble: 'assistant', align: 'left'},
	]
	out := expand_bubbles(rows, 60)
	mut boxes := []string{}
	mut has_rule := false
	for r in out {
		boxes << r.box
		if r.kind == 'rule' && r.bubble == '' {
			has_rule = true
		}
	}
	assert has_rule
	// the first bubble starts at the top (no leading margin)
	assert boxes[0] == 'top'
	assert boxes[boxes.len - 1] == 'bottom'
	// there is a margin gap before the second bubble
	mut gaps := 0
	for r in out {
		if r.box == 'gap' {
			gaps += 1
		}
	}
	assert gaps == 1
	// a bubble has top + 2 vpad + content + bottom = at least 5 rows
	mut tops := 0
	for r in out {
		if r.box == 'top' {
			tops += 1
		}
	}
	assert tops == 2
}

fn test_frame_view_scroll() {
	mut view := []RenderRow{}
	for i in 0 .. 10 {
		view << RenderRow{text: 'row ${i}'}
	}
	bottom := frame_view(view, 3, 0)
	assert bottom.len == 3
	assert bottom[2] == 'row 9'
	assert bottom[0] == 'row 7'
	top := frame_view(view, 3, 1 << 30)
	assert top[0] == 'row 0'
	short := frame_view([RenderRow{text: 'only'}], 8, 0)
	assert short.len == 8
	assert short[0] == 'only'
	assert short[7] == ''
}

fn test_compose_frame_chat_layout() {
	lines := [
		TuiLine{kind: 'rule', stamp: '#1'},
		TuiLine{kind: 'user', text: 'hello'},
		TuiLine{kind: 'rule', stamp: '#2'},
		TuiLine{kind: 'content', text: 'hi there'},
	]
	frame := compose_frame(lines, 60, 20, 0, false)
	text := frame.join('\n')
	assert text.contains('╭') && text.contains('╮')
	assert text.contains('╰') && text.contains('╯')
	assert text.contains('hello')
	assert text.contains('hi there')
}

// ---------------------------------------------------------------------------
// layout (compact vs. normal)

fn test_layout_normal_and_compact() {
	// Tall terminal: four-row status (two text rows + four-row pixel pet).
	n := layout_for(24, 1)
	assert n.compact == false
	assert n.status_h == 4
	assert n.status_gap == 2
	assert n.transcript_h == 24 - 4 - 2 - 3

	// Short terminal: one-row status + one-row gap gives the transcript room.
	c := layout_for(10, 1)
	assert c.compact == true
	assert c.status_h == 1
	assert c.status_gap == 1
	assert c.transcript_h == 10 - 1 - 1 - 3

	// Too small: empty layout.
	assert layout_for(8, 1).transcript_h == 0
}

// ---------------------------------------------------------------------------
// phase-aware status + animation modes

fn busy_status(phase string, detail string) StatusView {
	return StatusView{
		model:            'm'
		busy:             true
		spin:             '◦◦◦'
		phase:            phase
		phase_detail:     detail
		phase_elapsed_ms: 1200
	}
}

fn test_status_phase_labels() {
	th := theme_default()
	assert status_join(build_status(busy_status('connecting', ''), th)).contains('connecting…')
	// Phases follow the output: no tokens -> processing, reasoning -> thinking,
	// answer -> writing.
	assert status_join(build_status(busy_status('waiting', ''), th)).contains('processing…')
	assert status_join(build_status(busy_status('thinking', ''), th)).contains('thinking…')
	assert status_join(build_status(busy_status('writing', ''), th)).contains('writing…')
	assert status_join(build_status(busy_status('tool', 'bash'), th)).contains('running bash…')
	assert status_join(build_status(busy_status('retrying', '1/2'), th)).contains('retrying 1/2…')
	// unknown/empty phase falls back to the generic label
	assert status_join(build_status(busy_status('', ''), th)).contains('working…')
}

fn test_resolve_animation() {
	assert resolve_animation('full', false) == 'full'
	assert resolve_animation('calm', false) == 'calm'
	assert resolve_animation('off', false) == 'off'
	assert resolve_animation('bogus', false) == 'full'
	// NO_COLOR / TERM=dumb force motion off
	assert resolve_animation('full', true) == 'off'
}

fn test_ball_wave_shape() {
	frames := default_spin_frames()
	assert frames.len == 6
	assert default_spin_interval_ms() == 100
	for f in frames {
		assert display_width(f) == 3
	}
}

fn test_status_cache_segment() {
	// cached >= 0 means the server reported it; show cached/prompt even at 0
	// (a miss is exactly what we want to see).
	mut sv := sample_status()
	sv.cached = 3200
	assert status_join(build_status(sv, theme_default())).contains('CH:3.2k/8.0k')
	sv.cached = 0
	assert status_join(build_status(sv, theme_default())).contains('CH:0/8.0k')
	// -1 = not reported -> no cache text at all.
	sv.cached = -1
	assert !status_join(build_status(sv, theme_default())).contains('CH:')
}

fn test_status_ttft_segment() {
	mut sv := sample_status()
	sv.ttft = 150
	assert status_join(build_status(sv, theme_default())).contains('ttft 150ms')
	sv.ttft = 1450
	assert status_join(build_status(sv, theme_default())).contains('ttft 1.45s')
	// not reported -> no text
	sv.ttft = -1
	assert !status_join(build_status(sv, theme_default())).contains('ttft')
}

// ---------------------------------------------------------------------------
// thinking_label

fn test_thinking_label() {
	assert thinking_label(false, '', true) == 'off'
	assert thinking_label(true, '', true) == 'auto'
	assert thinking_label(true, 'low', true) == 'low'
	assert thinking_label(true, 'high', false) == 'high·hidden'
}

// ---------------------------------------------------------------------------
// light theme background

fn test_light_theme_paints_bg() {
	light := theme_for(TuiConfig{
		theme: 'light'
	})
	if bg := light.bg() {
		assert bg.r == 255 && bg.g == 255 && bg.b == 255
	} else {
		assert false
	}
	// Dark and cyberpunk leave the terminal background alone.
	assert theme_for(TuiConfig{}).bg() == none
	assert theme_for(TuiConfig{
		theme: 'cyberpunk'
	}).bg() == none
}
