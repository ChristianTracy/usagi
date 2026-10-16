module text

import strings

// Text helpers for the TUI renderer: display width estimation and line
// wrapping. The stdlib has no wcwidth, so width is best-effort — East Asian
// wide characters and emoji count as 2 terminal cells, everything else as 1.
// It never splits a multibyte sequence. A rare exotic combining sequence may
// be off by a cell, which only affects alignment, never byte correctness.

// wide_ranges lists the Unicode blocks whose characters render in 2 cells.
// See https://unicode.org/Public/UNIDATA/EastAsianProperty.txt (3.1).
pub const wide_ranges = [
	[0x1100, 0x115F], // Hangul Jamo
	[0x23F0, 0x23FF], // Some emoji
	[0x2E00, 0x303E], // Radicals + CJK symbols + Hangul Compatibility Jamo
	[0x3040, 0x33FF], // Japanese + Korean broadways
	[0x3400, 0x4DBF], // CJK Extension A
	[0x4E00, 0x9FFF], // CJK Unified Ideographs
	[0xA000, 0xA4CF], // Yi Syllables + Radicals
	[0xAC00, 0xD7A3], // Hangul Syllables
	[0xF900, 0xFAFF], // CJK Compatibility Ideographs
	[0xFE00, 0xFE30], // CJK Compatibility Forms
	[0xFE4E, 0xFE4F], // Halfwidth + Fullwidth forms
	[0xFE50, 0xFEFF], // CJK small forms
	[0xFF00, 0xFF60], // Fullwidth Forms
	[0xFFE0, 0xFFE6], // Fullwidth Signs
	[0x1F000, 0x1FADB], // Mahjong + Domino + playing cards emoji
	[0x1F900, 0x1F9FF], // Other emoji
	[0x20000, 0x2A6DF], // CJK Extension B
	[0x2A700, 0x2EBEF], // CJK Extension C..H
	[0x30000, 0x3AFEF], // CJK Extension I
]

// rune_width returns the display width (in terminal cells) of a single rune.
pub fn rune_width(r rune) int {
	v := u32(r)
	for pair in wide_ranges {
		if v >= pair[0] && v <= pair[1] {
			return 2
		}
	}
	return 1
}

// display_width returns the number of terminal cells `s` occupies.
pub fn display_width(s string) int {
	mut width := 0
	for r in s.runes() {
		width += rune_width(r)
	}
	return width
}

// prefix_width returns the display width of the first `n` runes of `s`.
pub fn prefix_width(s string, n int) int {
	mut w := 0
	for i, r in s.runes() {
		if i >= n {
			break
		}
		w += rune_width(r)
	}
	return w
}

// slice_by_cells returns the part of `s` starting at display cell `start`,
// at most `max_cells` cells wide. A wide rune that would only fit
// partially is left out — never split mid-cell.
pub fn slice_by_cells(s string, start int, max_cells int) string {
	if max_cells <= 0 {
		return ''
	}
	mut out := ''
	mut cell := 0
	end := start + max_cells
	for r in s.runes() {
		if cell >= end {
			break
		}
		w := rune_width(r)
		if cell >= start && cell + w <= end {
			out += r.str()
		}
		cell += w
	}
	return out
}

// pad right-pads `s` with spaces to exactly `w` display cells so every drawn
// row fully overwrites whatever was on it before. Used by the renderer to
// avoid leaving stale characters when a row shrinks.
pub fn pad(s string, w int) string {
	if display_width(s) >= w {
		return s
	}
	return s + ' '.repeat(w - display_width(s))
}

// --- small string helpers ------------------------------------------------

// compact_ws collapses runs of whitespace (including newlines) to single
// spaces and trims — used to squeeze tool arguments onto one header row.
pub fn compact_ws(s string) string {
	mut sb := strings.Builder{}
	mut pending_space := false
	for r in s.runes() {
		if r == ` ` || r == `\n` || r == `\t` || r == `\r` {
			if sb.len > 0 {
				pending_space = true
			}
		} else {
			if pending_space {
				sb.write_u8(` `)
				pending_space = false
			}
			sb.write_rune(r)
		}
	}
	return sb.str()
}

// truncate_cells cuts `s` to at most `max` display cells, appending an
// ellipsis when anything was removed.
pub fn truncate_cells(s string, max int) string {
	if max <= 1 {
		return slice_by_cells(s, 0, if max < 0 { 0 } else { max })
	}
	if display_width(s) <= max {
		return s
	}
	return slice_by_cells(s, 0, max - 1) + '…'
}

// fit_cells truncates `s` to `w` display cells and right-pads with spaces so
// a drawn row always overwrites exactly the row it lands on.
pub fn fit_cells(s string, w int) string {
	if w <= 0 {
		return ''
	}
	return pad(slice_by_cells(s, 0, w), w)
}

// --- time formatting ------------------------------------------------------

pub fn fmt_secs(ms i64) string {
	return '${ms / 1000}.${ms % 1000 / 100}s'
}

// fmt_ttft formats a time-to-first-token in ms: sub-second stays in ms (so
// 150ms does not round to 0.1s), the rest as seconds with two decimals.
pub fn fmt_ttft(ms int) string {
	if ms >= 1000 {
		return '${f64(ms) / 1000.0:.2f}s'
	}
	return '${ms}ms'
}
