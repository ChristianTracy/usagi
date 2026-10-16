module main
import text { display_width, pad }
import tui { is_printable }

// Unit tests for the P0 text helpers (rune/width handling). Run with:
//   v -enable-globals test tests/

fn test_display_width_ascii() {
	assert display_width('hello') == 5
	assert display_width('') == 0
	assert display_width('a b') == 3
}

fn test_display_width_wide() {
	// 世 and 界 are wide (2 cells each).
	assert display_width('世界') == 4
	// héllo 世界: h,é,l,l,o,space (1 each) + 世,界 (2 each) = 6 + 4 = 10.
	assert display_width('héllo 世界') == 10
	// 😀 (U+1F600) is wide.
	assert display_width('😀') == 2
}

fn test_pad_uses_display_cells() {
	// 'ab' is 2 cells; pad to 5 → 3 trailing spaces.
	assert pad('ab', 5) == 'ab   '
	// '世' is 2 cells; pad to 4 → 2 trailing spaces.
	assert pad('世', 4) == '世  '
	// Already wider than w → returned unchanged.
	assert pad('世界', 3) == '世界'
}

fn test_is_printable() {
	assert is_printable(rune(97))   // 'a'
	assert is_printable(rune(0x4e16)) // 世
	assert is_printable(rune(32))   // space
	// Control characters and DEL are rejected.
	assert !is_printable(rune(3))   // Ctrl-C
	assert !is_printable(rune(27))  // ESC
	assert !is_printable(rune(127)) // DEL
}
