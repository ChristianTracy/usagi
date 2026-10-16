module main

import tui { RenderRow, Selection, TuiLine, build_rows, bubble_geometry, expand_bubbles, row_content_start, row_copy_text, selection_cells, selection_text }

// Unit tests for mouse text selection: the pure helpers that map the view
// rows to clean copyable text (bubble borders and padding excluded).

fn bubble_rows(lines []TuiLine, w int) []tui.RenderRow {
	return expand_bubbles(build_rows(lines, w, false), w)
}

fn test_selection_text_single_message() {
	rows := bubble_rows([TuiLine{ kind: 'content', text: 'hola mundo' }], 60)
	sel := Selection{
		active: true
		row0:   0
		col0:   0
		row1:   rows.len - 1
		col1:   10000
	}
	assert selection_text(rows, sel, 60) == 'hola mundo'
}

fn test_selection_text_strips_bubble_borders() {
	rows := bubble_rows([
		TuiLine{ kind: 'content', text: 'hola' },
		TuiLine{ kind: 'user', text: 'chau' },
	], 60)
	sel := Selection{
		active: true
		row0:   0
		col0:   0
		row1:   rows.len - 1
		col1:   10000
	}
	got := selection_text(rows, sel, 60)
	// No box characters the bubble uses (│ ╭ ╮ ╰ ╯ ─).
	assert !got.contains('│') && !got.contains('╭') && !got.contains('╯') && !got.contains('─')
	assert got == 'hola\n\nchau'
}

fn test_selection_text_partial_row() {
	rows := bubble_rows([TuiLine{ kind: 'content', text: 'hola mundo' }], 60)
	// The content row is after the top border and the vertical padding.
	mut content_row := -1
	for i, r in rows {
		if row_copy_text(r) == 'hola mundo' {
			content_row = i
			break
		}
	}
	assert content_row > 0
	sel := Selection{
		active: true
		row0:   content_row
		col0:   0
		row1:   content_row
		col1:   4
	}
	assert selection_text(rows, sel, 60) == 'hola'
}

fn test_selection_empty_is_blank() {
	rows := bubble_rows([TuiLine{ kind: 'content', text: 'hola' }], 60)
	empty := Selection{
		active: true
		row0:   0
		col0:   0
		row1:   0
		col1:   0
	}
	assert empty.empty()
	assert selection_text(rows, empty, 60) == ''
	assert selection_text(rows, Selection{}, 60) == ''
}

fn test_selection_cells_bounds() {
	sel := Selection{
		active: true
		row0:   1
		col0:   2
		row1:   3
		col1:   4
	}
	assert selection_cells(sel, 0, 10) == none
	assert selection_cells(sel, 4, 10) == none
	middle := selection_cells(sel, 2, 10) or { panic('expected a range') }
	assert middle.a == 0 && middle.b == 10
	first := selection_cells(sel, 1, 10) or { panic('expected a range') }
	assert first.a == 2 && first.b == 10
	last := selection_cells(sel, 3, 10) or { panic('expected a range') }
	assert last.a == 0 && last.b == 4
	// Reversed drag is normalized.
	rev := Selection{
		active: true
		row0:   3
		col0:   4
		row1:   1
		col1:   2
	}
	mid2 := selection_cells(rev, 2, 10) or { panic('expected a range') }
	assert mid2.a == 0 && mid2.b == 10
}

fn test_bubble_content_start() {
	assistant := RenderRow{
		kind:   'content'
		text:   'hello'
		bubble: 'assistant'
		align:  'left'
	}
	left, right, _ := bubble_geometry(assistant, 60)
	assert left == 1
	assert right > left
	assert row_content_start(assistant, 60) == left + 2
	// Right-aligned bubble pushes the text to the right edge of the interior.
	user := RenderRow{
		kind:   'user'
		text:   'hi'
		bubble: 'user'
		align:  'right'
	}
	assert row_content_start(user, 60) > left + 2
	// A non-bubble row starts at column 0.
	assert row_content_start(RenderRow{ kind: 'rule', text: 'x' }, 60) == 0
}
