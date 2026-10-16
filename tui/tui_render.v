module tui

import strings
import term.ui as tui_std
import proto { Message }
import server { ModelEntry }
import text as textlib { compact_ws, display_width, fit_cells, fmt_secs, fmt_ttft, pad, rune_width, slice_by_cells, truncate_cells }

// Phase 2 rendering: the pure, testable half of the TUI. Everything here
// turns transcript data into wrapped, prefixed, color-tagged rows and status
// segments. None of it touches term.ui except for the Color type, so the
// whole pipeline can be unit-tested without a terminal.

// Span is one inline-styled run of text: style is '' | 'bold' | 'code'.
pub struct Span {
	pub mut:
	text  string
	style string
}

// RenderRow is one physical terminal row. `kind` picks the base color. Plain
// rows use `text`/`style`; markdown-lite rows carry `spans` (
// `text` is their flattened form) so inline `code`/`**bold**` can be tinted
// per segment rather than repainting the whole row. `text` already includes
// the speaker prefix / hanging indent.
pub struct RenderRow {
	pub mut:
	kind  string
	style string
	text  string
	spans []Span
	// Chat-bubble layout: `bubble` is the bubble class ('' = not bubbled, e.g.
	// a turn rule) and `align` is 'left' (assistant side) or 'right' (user).
	bubble string
	align  string
	// box is the row's role inside a bubble: '' (plain), 'top', 'mid',
	// 'bottom', or 'gap' (margin between bubbles).
	box string
	// bubble_w is the (dynamic) block width chosen for this message.
	bubble_w int
	// stamp is a per-turn label, rendered inside the user bubble.
	stamp string
}

// --- chat bubbles ----------------------------------------------------------

// bubble_max_width caps how wide a message block can grow on huge terminals.
pub const bubble_max_width = 100

// bubble_width is the full block width (including the two padding cells).
pub fn bubble_width(w int) int {
	if w < 32 {
		return if w > 4 { w - 2 } else { 1 }
	}
	mut bw := w * 2 / 3
	if bw > bubble_max_width {
		bw = bubble_max_width
	}
	return bw
}

// bubble_content_width is the text area inside a bubble: 1 cell border,
// 1 cell padding, on each side.
pub fn bubble_content_width(w int) int {
	cw := bubble_width(w) - 4
	return if cw < 1 { 1 } else { cw }
}

// bubble_class groups kinds into one visual block.
pub fn bubble_class(kind string) string {
	return match kind {
		'user' { 'user' }
		'content', 'code', 'fence' { 'assistant' }
		'thinking' { 'thinking' }
		'tool', 'tool_result' { 'tool' }
		'note' { 'note' }
		'error' { 'error' }
		else { '' }
	}
}

pub fn bubble_align(kind string) string {
	return if kind == 'user' { 'right' } else { 'left' }
}

// class_kind maps a bubble class back to the transcript kind whose color the
// border should use.
pub fn class_kind(cls string) string {
	return match cls {
		'assistant' { 'content' }
		else { cls }
	}
}

// box_top / box_bottom draw the rounded border caps for a bubble of width n.
pub fn box_top(n int) string {
	if n < 2 {
		return '╭'
	}
	return '╭' + '─'.repeat(n - 2) + '╮'
}

pub fn box_bottom(n int) string {
	if n < 2 {
		return '╰'
	}
	return '╰' + '─'.repeat(n - 2) + '╯'
}

// box_bottom_label draws the bottom cap with a small label (the turn
// timestamp) sitting inside the border line, so it costs no extra row. The
// label is rendered in superscript digits to look like a smaller font.
pub fn box_bottom_label(n int, label string) string {
	if label == '' {
		return box_bottom(n)
	}
	small := small_text(label)
	lw := display_width(small)
	fill := n - lw - 4
	if fill < 1 {
		return box_bottom(n)
	}
	return '╰' + '─'.repeat(fill) + ' ' + small + ' ╯'
}

const superscript_digits = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹']

// small_text maps ASCII digits to superscript digits and ':' to a small middle
// dot (the closest a terminal gets to a smaller font). Other characters are
// left untouched.
pub fn small_text(s string) string {
	mut out := ''
	for r in s.runes() {
		if r >= `0` && r <= `9` {
			out += superscript_digits[int(r - `0`)]
		} else if r == `:` {
			out += '·'
		} else {
			out += r.str()
		}
	}
	return out
}

// expand_bubbles turns the flat content rows into bordered blocks: a margin
// row, a top border, vertical padding, the content, padding, and a bottom
// border. Pure, so the layout is unit-testable.
pub fn expand_bubbles(rows []RenderRow, w int) []RenderRow {
	max_bw := bubble_width(w)
	mut out := []RenderRow{}
	mut i := 0
	for i < rows.len {
		row := rows[i]
		if row.bubble == '' {
			out << row
			i += 1
			continue
		}
		cls := row.bubble
		al := row.align
		mut j := i
		for j < rows.len && rows[j].bubble == cls && rows[j].align == al {
			j += 1
		}
		// Dynamic width: hug the longest row (plus stamp), clamped to a
		// comfortable minimum and the terminal-derived maximum.
		mut maxw := 0
		mut stamp := ''
		for k in i .. j {
			if stamp == '' && rows[k].stamp != '' {
				stamp = rows[k].stamp
			}
			cw := display_width(rows[k].text)
			if cw > maxw {
				maxw = cw
			}
		}
		if stamp != '' {
			sw := display_width(stamp)
			if sw + 1 > maxw {
				maxw = sw + 1 // leave room for at least one dash in the cap
			}
		}
		mut bw := maxw + 4
		if bw < 12 {
			bw = 12
		}
		if bw > max_bw {
			bw = max_bw
		}
		if out.len > 0 {
			out << RenderRow{box: 'gap'} // margin between messages
		}
		out << RenderRow{
			kind:     cls
			box:      'top'
			bubble:   cls
			align:    al
			bubble_w: bw
			text:     box_top(bw)
		}
		out << RenderRow{kind: cls, box: 'mid', bubble: cls, align: al, bubble_w: bw} // vpad
		for k in i .. j {
			mut m := rows[k]
			m.box = 'mid'
			m.bubble_w = bw
			out << m
		}
		out << RenderRow{kind: cls, box: 'mid', bubble: cls, align: al, bubble_w: bw} // vpad
		out << RenderRow{
			kind:     cls
			box:      'bottom'
			bubble:   cls
			align:    al
			bubble_w: bw
			text:     box_bottom_label(bw, stamp)
			stamp:    stamp
		}
		i = j
	}
	return out
}

// bubble_prefix drops the speaker label for the two chat sides (alignment and
// bubble color already say who is talking); other kinds keep their label.
fn bubble_prefix(kind string) string {
	if kind == 'user' || kind == 'content' {
		return ''
	}
	return kind_prefix(kind)
}

// --- wrapping --------------------------------------------------------------

pub const wrap_min_width = 2

// runes_to_string joins a rune slice with a strings.Builder (linear, unlike
// repeated `line += r.str()`).
pub fn runes_to_string(r []rune) string {
	mut sb := strings.Builder{}
	sb.write_runes(r)
	return sb.str()
}

// wrap_text wraps `s` to `width` display cells. It preserves whitespace
// exactly, prefers to break after a space, hard-breaks tokens longer than the
// width, never splits a wide rune across rows, and treats embedded newlines
// as hard line breaks.
pub fn wrap_text(s string, width int) []string {
	w := if width < wrap_min_width { wrap_min_width } else { width }
	mut out := []string{}
	for raw in s.split('\n') {
		wrap_one(raw, w, mut out)
	}
	if out.len == 0 {
		out << ''
	}
	return out
}

pub fn wrap_one(line string, w int, mut out []string) {
	r := line.runes()
	mut i := 0
	for i < r.len {
		mut j := i
		mut cells := 0
		mut last_space := -1
		for j < r.len {
			rw := rune_width(r[j])
			if cells + rw > w {
				break
			}
			cells += rw
			if r[j] == ` ` {
				last_space = j
			}
			j += 1
		}
		if j >= r.len {
			out << runes_to_string(r[i..])
			break
		}
		mut end := j
		if last_space > i {
			end = last_space + 1 // keep the space on the row (whitespace preserved)
		}
		if end <= i {
			end = i + 1 // hard-break a token wider than the row
		}
		out << runes_to_string(r[i..end])
		i = end
	}
}

// wrap_labeled wraps `text` and puts `prefix` on the first row plus a
// hanging indent (spaces the width of `prefix`) on continuation rows.
pub fn wrap_labeled(prefix string, text string, width int) []string {
	pw := display_width(prefix)
	indent := ' '.repeat(pw)
	inner := if width - pw < wrap_min_width { wrap_min_width } else { width - pw }
	mut out := []string{}
	for raw in text.split('\n') {
		parts := wrap_text(raw, inner)
		for i, part in parts {
			if i == 0 {
				out << prefix + part
			} else {
				out << indent + part
			}
		}
	}
	if out.len == 0 {
		out << prefix
	}
	return out
}

// --- prefixes & markdown-lite ---------------------------------------------

// kind_prefix is the speaker label for a transcript kind. The label width is
// also the hanging indent used by continuation rows.
pub fn kind_prefix(kind string) string {
	return match kind {
		'user' { '▸ you ' }
		'content' { '› ' }
		'thinking' { '· ' }
		'code' { '│ ' }
		'fence' { '│ ' }
		'tool' { '⚙ ' }
		'tool_result' { '  │ ' }
		'note' { '· ' }
		'error' { '✗ ' }
		'rule' { '' }
		else { '  ' }
	}
}

// parse_md_spans tokenizes markdown-lite inline markup into styled spans.
// `**bold**` and `` `code` `` are recognized; an unmatched marker is kept as
// literal text. Because term.ui can draw several segments per row, this is a
// real per-span tint (not a whole-row tint).
pub fn parse_md_spans(s string) []Span {
	mut out := []Span{}
	mut cur := strings.Builder{}
	mut style := ''
	r := s.runes()
	mut i := 0
	for i < r.len {
		if r[i] == `*` && i + 1 < r.len && r[i + 1] == `*` {
			if style == 'bold' {
				out << Span{text: cur.str(), style: 'bold'}
				cur = strings.Builder{}
				style = ''
			} else if style == '' {
				if cur.len > 0 {
					out << Span{text: cur.str(), style: ''}
					cur = strings.Builder{}
				}
				style = 'bold'
			} else {
				cur.write_rune(r[i])
				cur.write_rune(r[i + 1])
			}
			i += 2
			continue
		}
		if r[i] == `\`` {
			if style == 'code' {
				out << Span{text: cur.str(), style: 'code'}
				cur = strings.Builder{}
				style = ''
			} else if style == '' {
				if cur.len > 0 {
					out << Span{text: cur.str(), style: ''}
					cur = strings.Builder{}
				}
				style = 'code'
			} else {
				cur.write_rune(r[i])
			}
			i += 1
			continue
		}
		cur.write_rune(r[i])
		i += 1
	}
	if cur.len > 0 {
		out << Span{text: cur.str(), style: style}
	}
	if out.len == 0 {
		out << Span{text: '', style: ''}
	}
	return out
}

pub fn flatten_spans(spans []Span) string {
	mut s := ''
	for sp in spans {
		s += sp.text
	}
	return s
}

// StyleRune is one rune plus its inline style, used to wrap styled text while
// keeping the styling attached across row breaks.
pub struct StyleRune {
	pub mut:
	r     rune
	style string
}

pub fn spans_to_styled(spans []Span) []StyleRune {
	mut out := []StyleRune{}
	for sp in spans {
		for r in sp.text.runes() {
			out << StyleRune{r: r, style: sp.style}
		}
	}
	return out
}

pub fn styled_to_spans(rs []StyleRune) []Span {
	mut out := []Span{}
	mut cur := strings.Builder{}
	mut style := ''
	for sr in rs {
		if sr.style != style {
			if cur.len > 0 {
				out << Span{text: cur.str(), style: style}
				cur = strings.Builder{}
			}
			style = sr.style
		}
		cur.write_rune(sr.r)
	}
	if cur.len > 0 {
		out << Span{text: cur.str(), style: style}
	}
	if out.len == 0 {
		out << Span{text: '', style: ''}
	}
	return out
}

// wrap_styled_line greedily wraps styled runes to `w` cells with the same
// whitespace-preserving / hard-break rules as wrap_one.
pub fn wrap_styled_line(rs []StyleRune, w int) [][]StyleRune {
	if rs.len == 0 {
		return [[]]
	}
	mut out := [][]StyleRune{}
	mut i := 0
	for i < rs.len {
		mut j := i
		mut cells := 0
		mut last_space := -1
		for j < rs.len {
			rw := rune_width(rs[j].r)
			if cells + rw > w {
				break
			}
			cells += rw
			if rs[j].r == ` ` {
				last_space = j
			}
			j += 1
		}
		if j >= rs.len {
			out << rs[i..]
			break
		}
		mut end := j
		if last_space > i {
			end = last_space + 1
		}
		if end <= i {
			end = i + 1
		}
		out << rs[i..end]
		i = end
	}
	return out
}

// wrap_span_rows wraps styled spans with `prefix` on the first row and a
// hanging indent on continuation rows, returning each row as spans.
pub fn wrap_span_rows(prefix string, prefix_style string, spans []Span, width int) [][]Span {
	pw := display_width(prefix)
	indent := ' '.repeat(pw)
	inner := if width - pw < wrap_min_width { wrap_min_width } else { width - pw }
	styled := spans_to_styled(spans)
	mut logical := [][]StyleRune{}
	mut start := 0
	for i, sr in styled {
		if sr.r == `\n` {
			logical << styled[start..i]
			start = i + 1
		}
	}
	logical << styled[start..]
	mut out := [][]Span{}
	for line in logical {
		for idx, part in wrap_styled_line(line, inner) {
			mut rowspans := []Span{}
			if idx == 0 {
				rowspans << Span{text: prefix, style: prefix_style}
			} else {
				rowspans << Span{text: indent, style: prefix_style}
			}
			rowspans << styled_to_spans(part)
			out << rowspans
		}
	}
	if out.len == 0 {
		out << [Span{text: prefix, style: prefix_style}]
	}
	return out
}

// --- fenced code -----------------------------------------------------------

pub struct FenceSeg {
	pub mut:
	kind string
	text string
}

pub fn find_sub(s string, sub string) int {
	if sub.len == 0 || s.len < sub.len {
		return -1
	}
	mut i := 0
	for i + sub.len <= s.len {
		mut j := 0
		for j < sub.len && s[i + j] == sub[j] {
			j += 1
		}
		if j == sub.len {
			return i
		}
		i += 1
	}
	return -1
}

// leading_backticks returns the byte offset of a ``` run at the start of the
// (space-trimmed) line, or -1.
pub fn leading_backticks(s string) int {
	mut i := 0
	for i < s.len && (s[i] == ` ` || s[i] == `\t`) {
		i += 1
	}
	if i + 2 < s.len && s[i] == `\`` && s[i + 1] == `\`` && s[i + 2] == `\`` {
		return i
	}
	return -1
}

pub fn is_lang_char(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
		|| c == `_` || c == `+` || c == `-` || c == `.` || c == `#`
}

// split_fence classifies one logical content line given the current fence
// state, returning the rows to emit and the next state. It tolerates fences
// glued to code (```` ```pythondef f() ```` and ```` return x``` ````), which
// small models emit routinely — that is what used to latch `in_fence` open
// and paint the rest of the reply as code.
pub fn split_fence(line string, in_fence bool) ([]FenceSeg, bool) {
	mut out := []FenceSeg{}
	mut state := in_fence
	lead := leading_backticks(line)
	if lead >= 0 {
		// Opening (or lone) delimiter: swallow an optional language token
		// only when it is a whole word, so ```python is a language but
		// ```pythondef greet( is marker + code.
		mut m := lead
		for m < line.len && line[m] == `\`` {
			m += 1
		}
		mut lang_end := m
		for lang_end < line.len && is_lang_char(line[lang_end]) {
			lang_end += 1
		}
		mut marker_end := m
		if lang_end > m && (lang_end == line.len || line[lang_end] == ` ` || line[lang_end] == `\t`) {
			marker_end = lang_end
		}
		mut rest := line[marker_end..]
		if marker_end > m && rest.starts_with(' ') {
			rest = rest[1..]
		}
		state = !state
		out << FenceSeg{kind: 'fence', text: line[0..marker_end]}
		if rest != '' {
			out << FenceSeg{kind: 'code', text: rest}
		}
		return out, state
	}
	if in_fence {
		// Closing delimiter glued to the end of a code line.
		p := find_sub(line, '```')
		if p >= 0 {
			mut e := p
			for e < line.len && line[e] == `\`` {
				e += 1
			}
			before := line[0..p]
			after := line[e..]
			if before.trim_space() != '' {
				out << FenceSeg{kind: 'code', text: before}
			}
			state = false
			out << FenceSeg{kind: 'fence', text: line[p..e]}
			if after != '' {
				out << FenceSeg{kind: 'content', text: after}
			}
			return out, state
		}
		out << FenceSeg{kind: 'code', text: line}
		return out, state
	}
	out << FenceSeg{kind: 'content', text: line}
	return out, state
}

// --- turn rules ------------------------------------------------------------

// rule_text renders a centered dim rule with the turn timestamp.
pub fn rule_text(stamp string, w int) string {
	label := if stamp != '' { ' ${stamp} ' } else { '' }
	fill := w - display_width(label)
	mut f := fill
	if f < 0 {
		f = 0
	}
	left := f / 2
	return '─'.repeat(left) + label + '─'.repeat(f - left)
}

// --- tool blocks -----------------------------------------------------------

pub const tool_arg_cells = 160

pub const tool_result_lines = 8

// tool_header_rows renders `⚙ name(compact args)`.
pub fn tool_header_rows(name string, args string, w int) []RenderRow {
	mut a := compact_ws(args)
	a = truncate_cells(a, tool_arg_cells)
	text := if a != '' { '${name}(${a})' } else { name }
	mut out := []RenderRow{}
	for part in wrap_labeled(kind_prefix('tool'), text, w) {
		out << RenderRow{kind: 'tool', text: part}
	}
	return out
}

// span_render_rows wraps one preformatted string with a (possibly dim)
// prefix, returning span-carrying rows.
pub fn span_render_rows(kind string, prefix string, prefix_style string, body string, w int) []RenderRow {
	mut out := []RenderRow{}
	for rowspans in wrap_span_rows(prefix, prefix_style, [Span{text: body, style: ''}], w) {
		out << RenderRow{
			kind:  kind
			text:  flatten_spans(rowspans)
			spans: rowspans
		}
	}
	return out
}

// tool_result_rows renders a tool result, indented. When collapsed it shows
// only the first `tool_result_lines` lines plus a "more lines" summary;
// `expanded` (ctrl-o / :expand) shows everything.
pub fn tool_result_rows(text string, w int, expanded bool) []RenderRow {
	all := text.trim_right('\r\n').split('\n')
	if all.len == 1 && all[0] == '' {
		return span_render_rows('tool_result', kind_prefix('tool_result'), 'dim', '(no output)', w)
	}
	mut limit := all.len
	if !expanded && limit > tool_result_lines {
		limit = tool_result_lines
	}
	mut out := []RenderRow{}
	for i in 0 .. limit {
		out << span_render_rows('tool_result', kind_prefix('tool_result'), 'dim', all[i].trim_right('\r'), w)
	}
	if all.len > limit {
		out << span_render_rows('tool_result', kind_prefix('tool_result'), 'dim',
			'… ${all.len - limit} more line(s) (ctrl-o to expand)', w)
	}
	return out
}

// render_line_rows turns one committed transcript line into physical rows.
// Chat kinds wrap to the bubble content width and carry their bubble class /
// alignment; the turn rule stays full width.
pub fn render_line_rows(kind string, text string, stamp string, arg string, w int, expanded bool) []RenderRow {
	cls := bubble_class(kind)
	cw := if cls == '' { w } else { bubble_content_width(w) }
	mut out := []RenderRow{}
	match kind {
		'rule' {
			out << RenderRow{kind: 'rule', text: rule_text(stamp, w)}
		}
		'tool' {
			out = tool_header_rows(text, arg, cw)
		}
		'tool_result' {
			out = tool_result_rows(text, cw, expanded)
		}
		'content', 'thinking' {
			// Markdown-lite: parse inline styles, then wrap while keeping them.
			for rowspans in wrap_span_rows(bubble_prefix(kind), '', parse_md_spans(text), cw) {
				out << RenderRow{
					kind:  kind
					text:  flatten_spans(rowspans)
					spans: rowspans
				}
			}
		}
		'code', 'fence' {
			// Fenced code is preformatted: a dim gutter, code-colored body.
			out = span_render_rows(kind, bubble_prefix(kind), 'dim', text, cw)
		}
		else {
			for part in wrap_labeled(bubble_prefix(kind), text, cw) {
				out << RenderRow{kind: kind, text: part}
			}
		}
	}
	for i in 0 .. out.len {
		out[i].bubble = cls
		out[i].align = bubble_align(kind)
		out[i].stamp = stamp
	}
	return out
}

// frame_view selects the visible window of `view` for a transcript pane of
// `transcript_h` rows at the given scroll offset, padding with blanks so the
// result is always exactly transcript_h strings. Pure, so the layout can be
// golden-tested without a terminal.
pub fn frame_view(view []RenderRow, transcript_h int, scroll int) []string {
	if transcript_h <= 0 {
		return []
	}
	area := transcript_h
	max_scroll := if view.len > area { view.len - area } else { 0 }
	mut s := scroll
	if s < 0 {
		s = 0
	}
	if s > max_scroll {
		s = max_scroll
	}
	mut start := view.len - area - s
	if start < 0 {
		start = 0
	}
	mut out := []string{}
	for i in start .. view.len {
		out << view[i].text
	}
	for out.len < area {
		out << ''
	}
	return out
}

// compose_frame is the pure layout pipeline: transcript lines -> wrapped rows
// -> the visible frame as strings. Mirrors the renderer's selection math and
// backs the golden layout tests.
pub fn compose_frame(lines []TuiLine, w int, h int, scroll int, expanded bool) []string {
	lay := layout_for(h, 1)
	return frame_view(expand_bubbles(build_rows(lines, w, expanded), w), lay.transcript_h, scroll)
}

// build_rows maps a whole transcript to render rows (no cross-line state, so
// the caller can append incrementally).
pub fn build_rows(lines []TuiLine, w int, expanded bool) []RenderRow {
	mut out := []RenderRow{}
	for line in lines {
		for r in render_line_rows(line.kind, line.text, line.stamp, line.arg, w, expanded) {
			out << r
		}
	}
	return out
}

// --- status bar ------------------------------------------------------------

pub struct StatusSeg {
pub mut:
	text  string
	pri   int
	color tui_std.Color
}

pub struct StatusView {
pub mut:
	model            string
	busy             bool
	spin             string
	elapsed_ms       i64
	last_ms          i64
	tok_s            string
	prompt           int
	window           int
	cached           int = -1 // prefix-cache tokens; -1 = server did not report
	ttft             int = -1 // time to first token (ms); -1 = not reported
	sess_in          int
	sess_out         int
	thinking         bool
	interrupted      bool
	// think is the request-level thinking level (off/auto/low/medium/high),
	// with '·hidden' when the block is hidden. effort is kept for the label.
	think            string
	effort           string
	// phase is the current request lifecycle: connecting | waiting (first
	// token) | streaming | tool | retrying | stopping. phase_detail carries an
	// argument (the tool name, or the retry count). phase_elapsed_ms is time
	// spent in the current phase.
	phase            string
	phase_detail     string
	phase_elapsed_ms i64
}

pub fn ctx_bar(prompt int, window int) string {
	pct := if window > 0 { 100 * prompt / window } else { 0 }
	mut filled := if window > 0 { 10 * prompt / window } else { 0 }
	if filled > 10 {
		filled = 10
	}
	if filled < 0 {
		filled = 0
	}
	return 'ctx ${fmt_tokens(prompt)}/${fmt_tokens(window)} [${'▓'.repeat(filled)}${'░'.repeat(10 - filled)}] ${pct}%'
}

// fmt_tokens shortens a token count for the status bar (32768 -> 32.7k).
fn fmt_tokens(n int) string {
	if n >= 1000 {
		return '${n / 1000}.${n % 1000 / 100}k'
	}
	return '${n}'
}

// status_sep is the divider drawn between status segments.
pub fn status_sep() string {
	return '  ·  '
}

// thinking_label renders the status-bar T: value: the request level
// (off/auto/low/medium/high), with '·hidden' when the block is hidden while
// still requested.
pub fn thinking_label(reasoning bool, effort string, show_thinking bool) string {
	level := if !reasoning { 'off' } else if effort == '' { 'auto' } else { effort }
	if reasoning && !show_thinking {
		return level + '·hidden'
	}
	return level
}

// build_status produces the status segments in display order. Priorities:
// hints(0) < session(1) < ctx(2) < state(3) < model(4), so a narrow terminal
// drops the least important first and keeps the model name last.
pub fn build_status(v StatusView, th Theme) []StatusSeg {
	mut segs := []StatusSeg{}
	segs << StatusSeg{text: v.model, pri: 4, color: th.c('status')}
	mut st := ''
	mut stc := th.c('status')
	if v.interrupted {
		st = '■ stopping…'
		stc = th.c('interrupt')
	} else if v.busy {
		secs := fmt_secs(v.phase_elapsed_ms)
		match v.phase {
			'connecting' { st = '${v.spin} connecting… ${secs}' }
			'waiting' { st = '${v.spin} processing… ${secs}' } // no output yet (TTFT)
			'thinking' { st = '${v.spin} thinking… ${secs}' } // reasoning tokens
			'writing' { st = '${v.spin} writing… ${secs}' } // answer tokens
			'streaming' { st = '${v.spin} writing… ${secs}' }
			'tool' {
				st = if v.phase_detail != '' {
					'${v.spin} running ${v.phase_detail}… ${secs}'
				} else {
					'${v.spin} running tool… ${secs}'
				}
			}
			'retrying' {
				d := if v.phase_detail != '' { ' ${v.phase_detail}' } else { '' }
				st = '↻ retrying${d}… ${secs}'
			}
			else { st = '${v.spin} working… ${secs}' }
		}
		stc = th.c('accent')
	} else {
		st = 'ready'
		if v.last_ms > 0 {
			st += ' (${fmt_secs(v.last_ms)})'
		}
		if v.ttft >= 0 {
			st += '  ttft ${fmt_ttft(v.ttft)}'
		}
		if v.tok_s != '' {
			st += '  ${v.tok_s}'
		}
	}
	segs << StatusSeg{text: st, pri: 3, color: stc}
	// Context is always visible: the highest priority so fit_status drops
	// everything else before it. Without a window (probe failed) show the
	// prompt count alone rather than hiding the line.
	if v.window > 0 {
		segs << StatusSeg{
			text:  ctx_bar(v.prompt, v.window)
			pri:   5
			color: th.ctx_color(100 * v.prompt / v.window)
		}
	} else if v.prompt > 0 {
		segs << StatusSeg{text: 'ctx ${fmt_tokens(v.prompt)}', pri: 5, color: th.c('status')}
	}
	// CH: prefix-cache hit / prompt — the number to watch when tuning how much
	// history is sent. Shown even at 0, so a miss is visible.
	if v.cached >= 0 {
		segs << StatusSeg{
			text:  'CH:${fmt_tokens(v.cached)}/${fmt_tokens(v.prompt)}'
			pri:   2
			color: th.c('session')
		}
	}
	// T: thinking level (off/auto/low/medium/high), always shown so ctrl-t is
	// visible.
	if v.think != '' {
		segs << StatusSeg{text: 'T:${v.think}', pri: 2, color: th.c('status')}
	}
	// Session tokens, compact: up arrow = in (tokens sent), down arrow = out
	// (tokens generated).
	segs << StatusSeg{
		text:  '↑${fmt_tokens(v.sess_in)} ↓${fmt_tokens(v.sess_out)}'
		pri:   2
		color: th.c('session')
	}
	return segs
}

pub fn status_join(segs []StatusSeg) string {
	mut parts := []string{}
	for s in segs {
		parts << s.text
	}
	return parts.join(status_sep())
}

// fit_status drops the lowest-priority segments until the row fits `w`, then
// truncates the survivor if even that is too wide.
pub fn fit_status(segs []StatusSeg, w int) []StatusSeg {
	if w <= 0 {
		return []
	}
	mut ss := segs.clone()
	for ss.len > 1 && display_width(status_join(ss)) > w {
		mut mi := 0
		for i in 1 .. ss.len {
			if ss[i].pri < ss[mi].pri {
				mi = i
			}
		}
		ss.delete(mi)
	}
	if ss.len == 1 && display_width(ss[0].text) > w {
		ss[0].text = slice_by_cells(ss[0].text, 0, w)
	}
	return ss
}

// scroll_thumb returns the first row (0-based, within the transcript pane) and
// the height in rows of the vertical scroll thumb for a transcript of
// `view_len` rows shown in `area` rows at offset `scroll` (0 = pinned to the
// live bottom). Returns (0, 0) when there is nothing to scroll. The thumb sits
// at the top when the view is at the top and at the bottom when it is live.
pub fn scroll_thumb(view_len int, area int, scroll int) (int, int) {
	if area <= 0 || view_len <= area {
		return 0, 0
	}
	max_scroll := view_len - area
	// Thumb height = visible fraction of the transcript, at least one row.
	mut size := area * area / view_len
	if size < 1 {
		size = 1
	}
	if size > area {
		size = area
	}
	mut s := scroll
	if s < 0 {
		s = 0
	}
	if s > max_scroll {
		s = max_scroll
	}
	// progress from the top: 0 at the very top, 1 at the live bottom.
	frac := f64(max_scroll - s) / f64(max_scroll)
	travel := area - size
	top := int(frac * f64(travel) + 0.5)
	return top, size
}

// --- tool header parsing ---------------------------------------------------

// parse_tool_header splits the streamed `❯❯❯❯ name  args` tool line into
// name and (possibly empty) inline arguments.
pub fn parse_tool_header(text string) (string, string) {
	mut s := text.trim_space()
	marker := '❯❯❯❯ '
	if s.starts_with(marker) {
		s = s[marker.len..].trim_space()
	}
	if s == '' {
		return '', ''
	}
	i := find_byte(s, ' ')
	if i < 0 {
		return s, ''
	}
	return s[0..i], s[i + 1 ..].trim_space()
}

// --- transcript reconstruction ---------------------------------------------

// build_transcript_lines rebuilds the render transcript from a message list,
// used by `/load` to restore a saved conversation. Fences are re-classified,
// and tool calls are shown as `⚙ name(args)` rows. Timestamps are omitted for
// loaded history (the original turn time is not stored).
pub fn build_transcript_lines(messages []Message, with_time bool) []TuiLine {
	mut out := []TuiLine{}
	mut in_fence := false
	for m in messages {
		match m.role {
			'user' {
				stamp := if with_time { now_stamp() } else { '' }
				for part in m.content.split('\n') {
					out << TuiLine{kind: 'user', text: part, stamp: stamp}
				}
			}
			'assistant' {
				for tc in m.tool_calls {
					out << TuiLine{kind: 'tool', text: tc.name, arg: tc.arguments}
				}
				if m.content.trim_space() != '' {
					for part in m.content.split('\n') {
						segs, st := split_fence(part, in_fence)
						in_fence = st
						for s in segs {
							out << TuiLine{kind: s.kind, text: s.text}
						}
					}
				}
			}
			'tool' {
				if m.content.trim_space() != '' {
					out << TuiLine{kind: 'tool_result', text: m.content}
				}
			}
			else {}
		}
	}
	return out
}

// --- mouse text selection -------------------------------------------------
//
// Mouse drag selection works over the flattened view rows in view
// coordinates: `row0/row1` are indices into `view` (so the selection stays
// anchored to the text while it scrolls) and the columns are display-cell
// offsets into a row's *clean* content — the bubble border and padding are
// excluded, which is what makes the copy free of box characters.

pub struct Selection {
pub mut:
	active bool
	row0   int
	col0   int
	row1   int
	col1   int
}

// CellRange is a half-open [a, b) span of display cells.
pub struct CellRange {
pub mut:
	a int
	b int
}

// ordered returns the selection endpoints in reading order.
pub fn (s Selection) ordered() (int, int, int, int) {
	if s.row0 < s.row1 || (s.row0 == s.row1 && s.col0 <= s.col1) {
		return s.row0, s.col0, s.row1, s.col1
	}
	return s.row1, s.col1, s.row0, s.col0
}

// empty reports whether the selection covers no cell at all.
pub fn (s Selection) empty() bool {
	if !s.active {
		return true
	}
	r0, c0, r1, c1 := s.ordered()
	return r0 == r1 && c0 == c1
}

// bubble_geometry recomputes the left/right/inside cell bounds of a bubble row
// exactly the way render() lays it out (cw is the transcript width).
pub fn bubble_geometry(row RenderRow, cw int) (int, int, int) {
	row_bw := if row.bubble_w > 0 { row.bubble_w } else { bubble_width(cw) }
	mut left := if row.align == 'right' { cw - row_bw - 1 } else { 1 }
	if left < 0 {
		left = 0
	}
	mut right := left + row_bw
	if right > cw {
		right = cw
	}
	inner := if right - left - 4 > 0 { right - left - 4 } else { 0 }
	return left, right, inner
}

// row_copy_text is the clean text a row contributes to a copy: the border and
// padding rows contribute nothing.
pub fn row_copy_text(row RenderRow) string {
	if row.box in ['top', 'bottom', 'gap'] || row.kind == 'rule' {
		return ''
	}
	return row.text
}

// row_content_start is the screen cell where row_copy_text begins on screen.
pub fn row_content_start(row RenderRow, cw int) int {
	if row.bubble == '' {
		return 0
	}
	left, _, inner := bubble_geometry(row, cw)
	mut sx := left + 2
	if row.align == 'right' {
		total := display_width(row.text)
		if total < inner {
			sx = left + 2 + (inner - total)
		}
	}
	if sx < 0 {
		sx = 0
	}
	return sx
}

// selection_cells returns the cell span selected on row `i`, or none when the
// row is outside the selection or the span is empty.
pub fn selection_cells(s Selection, i int, content_len int) ?CellRange {
	r0, c0, r1, c1 := s.ordered()
	if i < r0 || i > r1 {
		return none
	}
	mut a := 0
	mut b := content_len
	if i == r0 {
		a = c0
	}
	if i == r1 {
		b = c1
	}
	if a < 0 {
		a = 0
	}
	if a > content_len {
		a = content_len
	}
	if b > content_len {
		b = content_len
	}
	if b < 0 {
		b = 0
	}
	if b <= a {
		return none
	}
	return CellRange{
		a: a
		b: b
	}
}

// selection_text extracts the selected text from the view. Bubble borders,
// padding and turn rules are dropped, so the copy is plain text.
pub fn selection_text(view []RenderRow, s Selection, cw int) string {
	if s.empty() {
		return ''
	}
	r0, _, r1, _ := s.ordered()
	mut lines := []string{}
	for i in r0 .. r1 + 1 {
		if i < 0 || i >= view.len {
			continue
		}
		row := view[i]
		if row.box in ['top', 'bottom', 'gap'] || row.kind == 'rule' {
			continue
		}
		content := row_copy_text(row)
		clen := display_width(content)
		cr := selection_cells(s, i, clen) or {
			// A blank content row inside the selection: keep the line.
			lines << ''
			continue
		}
		piece := slice_by_cells(content, cr.a, cr.b - cr.a)
		lines << piece.trim_right(' \t')
	}
	// Collapse runs of blank lines (bubble vertical padding) into one, then
	// drop the leading/trailing blanks.
	mut collapsed := []string{}
	for line in lines {
		if line.trim_space() == '' && collapsed.len > 0
			&& collapsed[collapsed.len - 1].trim_space() == '' {
			continue
		}
		collapsed << line
	}
	mut start := 0
	for start < collapsed.len && collapsed[start].trim_space() == '' {
		start += 1
	}
	mut end := collapsed.len
	for end > start && collapsed[end - 1].trim_space() == '' {
		end -= 1
	}
	if start >= end {
		return ''
	}
	return collapsed[start..end].join('\n')
}

// --- model picker ---------------------------------------------------------

// filter_models returns the entries matching `q` (case-insensitive substring on
// the model id or owner). An empty query returns the list unchanged.
pub fn filter_models(items []ModelEntry, q string) []ModelEntry {
	query := q.trim_space().to_lower()
	if query == '' {
		return items
	}
	mut out := []ModelEntry{}
	for it in items {
		if it.id.to_lower().contains(query) || it.owned_by.to_lower().contains(query) {
			out << it
		}
	}
	return out
}

// picker_clamp keeps a list cursor inside [0, len-1].
pub fn picker_clamp(sel int, len int) int {
	if len <= 0 || sel < 0 {
		return 0
	}
	if sel >= len {
		return len - 1
	}
	return sel
}

// model_meta is the right-hand column of a picker row: context, owner and a
// thinking hint, from the cached /v1/models data.
pub fn model_meta(e ModelEntry) string {
	mut parts := []string{}
	if e.context_len > 0 {
		parts << 'ctx ${fmt_tokens(e.context_len)}'
	}
	if e.owned_by != '' {
		parts << e.owned_by
	}
	if e.loaded {
		parts << 'loaded'
	}
	if e.thinking {
		parts << 'think'
	}
	return parts.join(' · ')
}
