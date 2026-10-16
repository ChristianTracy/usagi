module pet

// The pixel pet: an 8x8 rabbit drawn as Unicode half-blocks, so it occupies
// 8 columns x 4 terminal rows. Each frame is a grid of 8 strings of 8 chars:
//
//   '.' transparent   'b' body   'e' ear   'k' eye / dark (mouth)
//
// pack_pixel_pet() folds two pixel rows into one terminal cell:
//   same colour -> '█'
//   both, different -> '▀' with fg = top pixel, bg = bottom pixel
//   top only -> '▀' with fg = top pixel
//   bot only -> '▄' with fg = bottom pixel
//   neither  -> ' '
// Colours come from the theme (pet_body / pet_ear / pet_eye), which differ per
// palette.

pub const pet_px_width = 8
pub const pet_px_rows = 4

// pet_px_idle: ears up, eyes forward.
pub const pet_px_idle = [
	'.b....b.'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bkbbbbkb'
	'bbbbbbbb'
	'.bbbbbb.'
]

// pet_px_blink: eyes closed.
pub const pet_px_blink = [
	'.b....b.'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bbbbbbbb'
	'bbbbbbbb'
	'.bbbbbb.'
]

// pet_px_look_l / pet_px_look_r: eyes glance sideways (idle "waiting").
pub const pet_px_look_l = [
	'.b....b.'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bkbbbkbb'
	'bbbbbbbb'
	'.bbbbbb.'
]

pub const pet_px_look_r = [
	'.b....b.'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bbkbbbkb'
	'bbbbbbbb'
	'.bbbbbb.'
]

// pet_px_ear_l / pet_px_ear_r: one ear flicked down, the other up. Alternating
// them keeps the ears moving while the model is thinking.
pub const pet_px_ear_l = [
	'.b......'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bkbbbbkb'
	'bbbbbbbb'
	'.bbbbbb.'
]

pub const pet_px_ear_r = [
	'......b.'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bkbbbbkb'
	'bbbbbbbb'
	'.bbbbbb.'
]

// pet_px_squint: one eye winking while reading a result.
pub const pet_px_squint = [
	'.b....b.'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bbbbbbkb'
	'bbbbbbbb'
	'.bbbbbb.'
]

// pet_px_droop: ears folded down, eyes closed (error).
pub const pet_px_droop = [
	'........'
	'.be..eb.'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bbbbbbbb'
	'bbbbbbbb'
	'.bbbbbb.'
]

// pet_px_sleep: ears flat, eyes closed (long idle).
pub const pet_px_sleep = [
	'........'
	'........'
	'.be..eb.'
	'.bbbbbb.'
	'bbbbbbbb'
	'bbbbbbbb'
	'bbbbbbbb'
	'.bbbbbb.'
]

// pixel_frame_grid returns the pixel grid for a named frame.
pub fn pixel_frame_grid(name string) []string {
	return match name {
		'blink' { pet_px_blink }
		'look_l' { pet_px_look_l }
		'look_r' { pet_px_look_r }
		'ear_l' { pet_px_ear_l }
		'ear_r' { pet_px_ear_r }
		'squint' { pet_px_squint }
		'droop' { pet_px_droop }
		'sleep' { pet_px_sleep }
		else { pet_px_idle }
	}
}

// pixel_sequence maps an agent mood to the frames to cycle through. No frame
// changes the face outline (rows 3 and 7 of the grid): emotions show through
// the eyes and ears only.
//   idle      -> looks around and blinks (waiting)
//   thinking  -> ears always moving
//   writing   -> calm and focused, only an occasional blink
//   done      -> happy blink
//   interrupt -> eyes darting around
pub fn pixel_sequence(mood string) []string {
	return match mood {
		'blink' { ['blink'] }
		'thinking' { ['ear_l', 'ear_r'] }
		'writing' { ['idle', 'idle', 'idle', 'blink'] }
		'tool' { ['ear_l', 'idle', 'ear_r', 'idle'] }
		'reading' { ['squint', 'idle', 'idle', 'squint'] }
		'done' { ['blink', 'idle'] }
		'error' { ['droop'] }
		'interrupt' { ['look_l', 'look_r'] }
		'asleep' { ['sleep'] }
		else { ['idle', 'idle', 'look_l', 'idle', 'look_r', 'idle', 'idle', 'blink'] }
	}
}

// pixel_interval is the per-frame duration (ms) in full-motion mode.
pub fn pixel_interval(mood string) int {
	return match mood {
		'thinking' { 260 }
		'writing' { 480 }
		'tool' { 300 }
		'reading' { 400 }
		'done' { 450 }
		'error' { 700 }
		'interrupt' { 220 }
		'asleep' { 1200 }
		'blink' { 300 }
		else { 420 }
	}
}

// PetCell is one terminal cell of a packed pixel-pet frame. `fg`/`bg` are
// palette chars ('b'/'e'/'k') or 0 when that half is transparent.
pub struct PetCell {
pub mut:
	glyph string
	fg    u8
	bg    u8
}

// pack_pixel_pet folds a pixel grid into half-block cells (see the module
// comment). Pure, so the packing is unit-testable.
pub fn pack_pixel_pet(grid []string) [][]PetCell {
	if grid.len == 0 {
		return [][]PetCell{}
	}
	w := grid[0].len
	mut rows := [][]PetCell{}
	mut r := 0
	for r * 2 < grid.len {
		top_line := grid[r * 2]
		bot_line := if r * 2 + 1 < grid.len { grid[r * 2 + 1] } else { '' }
		mut row := []PetCell{}
		for c in 0 .. w {
			top := if c < top_line.len { top_line[c] } else { `.` }
			bot := if c < bot_line.len { bot_line[c] } else { `.` }
			t_on := top != `.`
			b_on := bot != `.`
			if t_on && b_on {
				if top == bot {
					// Same colour on both halves: a full block (and the
					// classic silhouette when rendered in monochrome).
					row << PetCell{glyph: '█', fg: top, bg: u8(0)}
				} else {
					row << PetCell{glyph: '▀', fg: top, bg: bot}
				}
			} else if t_on {
				row << PetCell{glyph: '▀', fg: top, bg: u8(0)}
			} else if b_on {
				row << PetCell{glyph: '▄', fg: bot, bg: u8(0)}
			} else {
				row << PetCell{glyph: ' ', fg: u8(0), bg: u8(0)}
			}
		}
		rows << row
		r++
	}
	return rows
}

// pet_grid_rows is how many terminal rows a packed grid occupies.
pub fn pet_grid_rows(grid []string) int {
	return (grid.len + 1) / 2
}
