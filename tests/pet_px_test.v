module main

import config { TuiConfig }
import pet { pack_pixel_pet, pet_grid_rows, pixel_frame_grid, pixel_interval, pixel_sequence }
import tui { theme_for }

// Tests for the half-block pixel pet: the 8x8 rabbit packs into 4 rows of
// `▀`/`▄` cells, and every mood maps to real frames.

fn test_pixel_pet_shape() {
	grid := pixel_frame_grid('idle')
	assert grid.len == 8
	assert grid[0].len == 8
	assert pet_grid_rows(grid) == 4
	cells := pack_pixel_pet(grid)
	assert cells.len == 4
	assert cells[0].len == 8
}

fn test_pack_half_blocks() {
	// top only -> `▀` with fg only
	cells := pack_pixel_pet(['b.', '..'])
	assert cells.len == 1
	assert cells[0][0].glyph == '▀'
	assert cells[0][0].fg == `b`
	assert cells[0][0].bg == u8(0)
	assert cells[0][1].glyph == ' '

	// bottom only -> `▄` with fg only
	cells2 := pack_pixel_pet(['.', 'e'])
	assert cells2[0][0].glyph == '▄'
	assert cells2[0][0].fg == `e`

	// both halves -> `▀` carrying two colors
	cells3 := pack_pixel_pet(['b', 'k'])
	assert cells3[0][0].glyph == '▀'
	assert cells3[0][0].fg == `b`
	assert cells3[0][0].bg == `k`

	// same colour on both halves -> full block
	cells4 := pack_pixel_pet(['b', 'b'])
	assert cells4[0][0].glyph == '█'
	assert cells4[0][0].fg == `b`
	assert cells4[0][0].bg == u8(0)
}

fn test_pixel_sequences_reference_real_frames() {
	assert pixel_sequence('error') == ['droop']
	assert 'blink' in pixel_sequence('done')
	assert 'squint' in pixel_sequence('reading')
	assert 'ear_l' in pixel_sequence('thinking') && 'ear_r' in pixel_sequence('thinking')
	assert pixel_sequence('idle').len >= 3
	for mood in ['idle', 'thinking', 'writing', 'tool', 'reading', 'done', 'error',
		'interrupt', 'asleep', 'blink'] {
		for name in pixel_sequence(mood) {
			grid := pixel_frame_grid(name)
			assert grid.len == 8
			assert grid[0].len == 8
		}
		assert pixel_interval(mood) > 0
	}
}

fn test_all_frames_keep_face_outline() {
	// No animation may change the face silhouette: every frame used by every
	// mood keeps the idle head sides (row 3) and chin/mouth (row 7). Emotions
	// are shown through the eyes and ears only.
	idle := pixel_frame_grid('idle')
	for mood in ['idle', 'thinking', 'writing', 'tool', 'reading', 'done', 'error',
		'interrupt', 'asleep', 'blink'] {
		for name in pixel_sequence(mood) {
			g := pixel_frame_grid(name)
			assert g[3] == idle[3]
			assert g[7] == idle[7]
		}
	}
}

fn test_pet_palette_differs_per_theme() {
	dark := theme_for(TuiConfig{
		theme: 'dark'
	})
	light := theme_for(TuiConfig{
		theme: 'light'
	})
	cyber := theme_for(TuiConfig{
		theme: 'cyberpunk'
	})
	// Each theme has its own body colour, and body/ear/eye differ within a theme.
	assert dark.pet_color(`b`) != light.pet_color(`b`)
	assert light.pet_color(`b`) != cyber.pet_color(`b`)
	assert dark.pet_color(`b`) != dark.pet_color(`e`)
	assert dark.pet_color(`e`) != dark.pet_color(`k`)
}
