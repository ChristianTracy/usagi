module pet

import os
import text as textlib { display_width }

// The status-bar pet: ASCII art loaded from `pet.txt` (next to config.json).
// Each frame is three lines; the file separates frames with blank lines. Only
// the face is kept — the trailing label on the middle line names the mood.
pub struct PetFrame {
pub mut:
	top    string
	mid    string
	bottom string
	name   string
}

pub struct Pet {
pub mut:
	frames []PetFrame
}

// face_of keeps just the `(...)` face from a middle line.
fn face_of(line string) string {
	mut close := -1
	for i in 0 .. line.len {
		if line[i] == `)` {
			close = i
			break
		}
	}
	if close >= 0 {
		return line[..close + 1]
	}
	return line
}

// name_of is the last whitespace-separated token of the middle line.
fn name_of(line string) string {
	parts := line.fields()
	if parts.len == 0 {
		return ''
	}
	return parts[parts.len - 1]
}

// load_pet reads pet.txt from the project root. A missing or malformed file
// simply yields an empty pet (nothing is drawn).
pub fn load_pet(root string) Pet {
	text := os.read_file(os.join_path(root, 'pet.txt')) or { return Pet{} }
	mut frames := []PetFrame{}
	mut block := []string{}
	for raw in text.split('\n') {
		line := raw.trim_right('\r')
		if line.trim_space() == '' {
			if block.len >= 3 {
				frames << PetFrame{
					top:    block[0]
					mid:    face_of(block[1])
					bottom: block[2]
					name:   name_of(block[1])
				}
			}
			block = []
		} else {
			block << line
		}
	}
	if block.len >= 3 {
		frames << PetFrame{
			top:    block[0]
			mid:    face_of(block[1])
			bottom: block[2]
			name:   name_of(block[1])
		}
	}
	return Pet{
		frames: frames
	}
}

// width is the widest line, used to reserve space on the right of the status
// bar.
pub fn (p Pet) width() int {
	mut m := 0
	for f in p.frames {
		for line in [f.top, f.mid, f.bottom] {
			w := display_width(line)
			if w > m {
				m = w
			}
		}
	}
	return m
}

// by_name returns the frame for a mood name, falling back to the first frame.
pub fn (p Pet) by_name(name string) PetFrame {
	for f in p.frames {
		if f.name == name {
			return f
		}
	}
	if p.frames.len > 0 {
		return p.frames[0]
	}
	return PetFrame{}
}

// mood_name maps an agent state to the pet label used in pet.txt.
pub fn mood_name(mood string) string {
	return match mood {
		'thinking' { 'focus' }
		'writing' { 'parsing' }
		'tool' { 'deploy' }
		'reading' { 'squint' }
		'error' { 'crashed' }
		'interrupt' { 'alarm' }
		'done' { 'green' }
		'asleep' { 'asleep' }
		'blink' { 'blink' }
		else { 'idle' }
	}
}

// pet_frame_for resolves a mood + animation tick to a frame. Active moods
// alternate between two faces so the pet visibly reacts while it works.
pub fn pet_frame_for(p Pet, mood string, tick int) PetFrame {
	match mood {
		'idle' {
			if (tick / 45) % 2 == 1 {
				return p.by_name('blink')
			}
			return p.by_name('idle')
		}
		'thinking' {
			if (tick / 20) % 2 == 1 {
				return p.by_name('squint')
			}
			return p.by_name('focus')
		}
		'writing' {
			if (tick / 20) % 2 == 1 {
				return p.by_name('focus')
			}
			return p.by_name('parsing')
		}
		'tool' {
			if (tick / 20) % 2 == 1 {
				return p.by_name('focus')
			}
			return p.by_name('deploy')
		}
		else {
			return p.by_name(mood_name(mood))
		}
	}
}
