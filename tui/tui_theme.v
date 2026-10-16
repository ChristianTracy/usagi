module tui

import os
import term.ui as tui_std
import config { TuiConfig }

// Phase 3 theming: every TUI color lives here, with three built-in palettes
// and per-kind overrides from `tui.colors` in config.json. `NO_COLOR` and
// `TERM=dumb` switch the renderer to monochrome (the theme still resolves, but
// the renderer skips set_color).

// theme_names lists the selectable palettes for `tui.theme` / `/theme`.
pub const theme_names = ['dark', 'light', 'cyberpunk']

pub struct Theme {
pub mut:
	mono   bool
	colors map[string]tui_std.Color
}

pub fn dark_palette() map[string]tui_std.Color {
	return {
		'user':        tui_std.Color{r: 235, g: 235, b: 235}
		'content':     tui_std.Color{r: 120, g: 220, b: 120}
		'thinking':    tui_std.Color{r: 130, g: 130, b: 165}
		'tool':        tui_std.Color{r: 120, g: 200, b: 240}
		'tool_result': tui_std.Color{r: 150, g: 150, b: 175}
		'code':        tui_std.Color{r: 200, g: 200, b: 150}
		'fence':       tui_std.Color{r: 130, g: 130, b: 165}
		'note':        tui_std.Color{r: 130, g: 130, b: 165}
		'error':       tui_std.Color{r: 240, g: 110, b: 110}
		'rule':        tui_std.Color{r: 90, g: 90, b: 110}
		'line':        tui_std.Color{r: 190, g: 190, b: 190}
		'bold':        tui_std.Color{r: 255, g: 255, b: 255}
		'code_style':  tui_std.Color{r: 200, g: 200, b: 150}
		'gutter':      tui_std.Color{r: 90, g: 90, b: 110}
		'status':      tui_std.Color{r: 140, g: 140, b: 160}
		'accent':      tui_std.Color{r: 215, g: 135, b: 255}
		'hint':        tui_std.Color{r: 110, g: 110, b: 130}
		'session':     tui_std.Color{r: 130, g: 130, b: 165}
		'ok':          tui_std.Color{r: 120, g: 220, b: 120}
		'warn':        tui_std.Color{r: 240, g: 200, b: 100}
		'hot':         tui_std.Color{r: 240, g: 110, b: 110}
		'interrupt':   tui_std.Color{r: 240, g: 160, b: 80}
		// Mouse selection highlight (bg) and the text drawn on it (fg).
		'selection':    tui_std.Color{r: 62, g: 92, b: 148}
		'selection_fg': tui_std.Color{r: 245, g: 248, b: 255}
		'bubble_user':      tui_std.Color{r: 22, g: 40, b: 62}
		'bubble_assistant': tui_std.Color{r: 30, g: 34, b: 40}
		'bubble_thinking':  tui_std.Color{r: 30, g: 28, b: 38}
		'bubble_tool':      tui_std.Color{r: 24, g: 32, b: 42}
		'bubble_note':      tui_std.Color{r: 30, g: 34, b: 40}
		'bubble_error':     tui_std.Color{r: 52, g: 24, b: 28}
		// Pixel-pet palette (dark): warm tan rabbit, pink inner ears, dark eyes.
		'pet_body': tui_std.Color{r: 201, g: 160, b: 106}
		'pet_ear':  tui_std.Color{r: 242, g: 168, b: 184}
		'pet_eye':  tui_std.Color{r: 26, g: 20, b: 16}
	}
}

// light_palette uses darker foregrounds on a light background so the same
// kinds stay readable. `bg` makes the renderer paint that background across the
// whole UI (input, status, transcript), not just inside bubbles.
pub fn light_palette() map[string]tui_std.Color {
	return {
		'bg':          tui_std.Color{r: 255, g: 255, b: 255}
		'user':        tui_std.Color{r: 20, g: 20, b: 20}
		'content':     tui_std.Color{r: 20, g: 110, b: 20}
		'thinking':    tui_std.Color{r: 90, g: 90, b: 120}
		'tool':        tui_std.Color{r: 20, g: 90, b: 150}
		'tool_result': tui_std.Color{r: 80, g: 80, b: 100}
		'code':        tui_std.Color{r: 120, g: 90, b: 0}
		'fence':       tui_std.Color{r: 90, g: 90, b: 120}
		'note':        tui_std.Color{r: 90, g: 90, b: 120}
		'error':       tui_std.Color{r: 170, g: 20, b: 20}
		'rule':        tui_std.Color{r: 150, g: 150, b: 150}
		'line':        tui_std.Color{r: 40, g: 40, b: 40}
		'bold':        tui_std.Color{r: 0, g: 0, b: 0}
		'code_style':  tui_std.Color{r: 120, g: 90, b: 0}
		'gutter':      tui_std.Color{r: 150, g: 150, b: 150}
		'status':      tui_std.Color{r: 80, g: 80, b: 100}
		'accent':      tui_std.Color{r: 130, g: 40, b: 170}
		'hint':        tui_std.Color{r: 120, g: 120, b: 140}
		'session':     tui_std.Color{r: 90, g: 90, b: 120}
		'ok':          tui_std.Color{r: 20, g: 120, b: 20}
		'warn':        tui_std.Color{r: 150, g: 100, b: 0}
		'hot':         tui_std.Color{r: 180, g: 30, b: 30}
		'interrupt':   tui_std.Color{r: 170, g: 90, b: 0}
		'selection':    tui_std.Color{r: 180, g: 210, b: 250}
		'selection_fg': tui_std.Color{r: 10, g: 10, b: 20}
		'bubble_user':      tui_std.Color{r: 214, g: 232, b: 255}
		'bubble_assistant': tui_std.Color{r: 240, g: 240, b: 242}
		'bubble_thinking':  tui_std.Color{r: 235, g: 235, b: 242}
		'bubble_tool':      tui_std.Color{r: 230, g: 240, b: 248}
		'bubble_note':      tui_std.Color{r: 240, g: 240, b: 242}
		'bubble_error':     tui_std.Color{r: 255, g: 232, b: 232}
		// Pixel-pet palette (light): darker tan, deeper pink, near-black eyes.
		'pet_body': tui_std.Color{r: 169, g: 122, b: 74}
		'pet_ear':  tui_std.Color{r: 217, g: 111, b: 143}
		'pet_eye':  tui_std.Color{r: 28, g: 28, b: 28}
	}
}

// cyberpunk_palette is neon-on-dark: electric cyan and magenta, neon green
// prose, amber code. Best on a dark background.
pub fn cyberpunk_palette() map[string]tui_std.Color {
	return {
		'user':        tui_std.Color{r: 125, g: 249, b: 255}
		'content':     tui_std.Color{r: 0, g: 255, b: 159}
		'thinking':    tui_std.Color{r: 154, g: 123, b: 208}
		'tool':        tui_std.Color{r: 0, g: 217, b: 255}
		'tool_result': tui_std.Color{r: 143, g: 168, b: 189}
		'code':        tui_std.Color{r: 255, g: 204, b: 102}
		'fence':       tui_std.Color{r: 176, g: 106, b: 179}
		'note':        tui_std.Color{r: 154, g: 123, b: 208}
		'error':       tui_std.Color{r: 255, g: 42, b: 109}
		'rule':        tui_std.Color{r: 90, g: 61, b: 122}
		'line':        tui_std.Color{r: 201, g: 209, b: 224}
		'bold':        tui_std.Color{r: 255, g: 255, b: 255}
		'code_style':  tui_std.Color{r: 255, g: 204, b: 102}
		'gutter':      tui_std.Color{r: 90, g: 74, b: 122}
		'status':      tui_std.Color{r: 154, g: 160, b: 192}
		'accent':      tui_std.Color{r: 255, g: 47, b: 214}
		'hint':        tui_std.Color{r: 106, g: 106, b: 146}
		'session':     tui_std.Color{r: 138, g: 127, b: 191}
		'ok':          tui_std.Color{r: 0, g: 255, b: 159}
		'warn':        tui_std.Color{r: 255, g: 204, b: 0}
		'hot':         tui_std.Color{r: 255, g: 42, b: 109}
		'interrupt':   tui_std.Color{r: 255, g: 138, b: 0}
		'selection':    tui_std.Color{r: 58, g: 22, b: 92}
		'selection_fg': tui_std.Color{r: 255, g: 210, b: 255}
		'bubble_user':      tui_std.Color{r: 30, g: 8, b: 50}
		'bubble_assistant': tui_std.Color{r: 6, g: 26, b: 32}
		'bubble_thinking':  tui_std.Color{r: 26, g: 16, b: 40}
		'bubble_tool':      tui_std.Color{r: 6, g: 32, b: 44}
		'bubble_note':      tui_std.Color{r: 6, g: 26, b: 32}
		'bubble_error':     tui_std.Color{r: 48, g: 6, b: 26}
		// Pixel-pet palette (cyberpunk): hacker-green phosphor — bright green
		// body, deeper green ears, near-black green eyes.
		'pet_body': tui_std.Color{r: 57, g: 255, b: 20}
		'pet_ear':  tui_std.Color{r: 0, g: 179, b: 45}
		'pet_eye':  tui_std.Color{r: 0, g: 34, b: 0}
	}
}

// theme_for resolves the palette for the configured theme and applies the
// per-kind overrides, then decides whether color must be suppressed.
pub fn theme_for(cfg TuiConfig) Theme {
	mut colors := match cfg.theme {
		'light' { light_palette() }
		'cyberpunk' { cyberpunk_palette() }
		else { dark_palette() }
	}
	for k, v in cfg.colors {
		c := parse_hex(v) or { continue }
		colors[k] = c
	}
	mono := os.getenv('NO_COLOR') != '' || os.getenv('TERM') == 'dumb'
	return Theme{
		mono:   mono
		colors: colors
	}
}

pub fn hex_digit(c u8) ?int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return none
}

// parse_hex parses `#rrggbb` (or `rrggbb`) into a tui_std.Color.
pub fn parse_hex(s string) ?tui_std.Color {
	mut h := s.trim_space()
	if h.starts_with('#') {
		h = h[1..]
	}
	if h.len != 6 {
		return none
	}
	mut vals := []int{}
	for i := 0; i < 6; i += 2 {
		hi := hex_digit(h[i]) or { return none }
		lo := hex_digit(h[i + 1]) or { return none }
		vals << hi * 16 + lo
	}
	return tui_std.Color{r: u8(vals[0]), g: u8(vals[1]), b: u8(vals[2])}
}

pub fn (t Theme) color_for(kind string) tui_std.Color {
	if kind in t.colors {
		return t.colors[kind]
	}
	return t.colors['line']
}

pub fn (t Theme) row_color(row RenderRow) tui_std.Color {
	if row.style == 'bold' {
		return t.color_for('bold')
	}
	if row.style == 'code' {
		return t.color_for('code_style')
	}
	return t.color_for(row.kind)
}

// bubble_color resolves a bubble class to its background color.
pub fn (t Theme) bubble_color(cls string) tui_std.Color {
	key := 'bubble_${cls}'
	if key in t.colors {
		return t.colors[key]
	}
	return t.color_for('bubble_assistant')
}

// span_color resolves an inline span style against the row kind's base color.
pub fn (t Theme) span_color(kind string, style string) tui_std.Color {
	if style == 'bold' {
		return t.color_for('bold')
	}
	if style == 'code' {
		return t.color_for('code')
	}
	if style == 'dim' {
		return t.color_for('gutter')
	}
	return t.color_for(kind)
}

// c looks up a palette entry by name, falling back to the status color.
pub fn (t Theme) c(name string) tui_std.Color {
	if name in t.colors {
		return t.colors[name]
	}
	return t.color_for('status')
}

// bg returns the base background the theme wants painted across the whole UI,
// or none when it leaves the terminal background alone.
pub fn (t Theme) bg() ?tui_std.Color {
	if 'bg' in t.colors {
		return t.colors['bg']
	}
	return none
}

// pet_color resolves a pixel-pet palette character ('b' body, 'e' ear, 'k'
// eye) to its theme color. Any other char falls back to the body color.
pub fn (t Theme) pet_color(ch u8) tui_std.Color {
	return match ch {
		`e` { t.color_for('pet_ear') }
		`k` { t.color_for('pet_eye') }
		else { t.color_for('pet_body') }
	}
}

pub fn (t Theme) ctx_color(pct int) tui_std.Color {
	if pct >= 90 {
		return t.c('hot')
	}
	if pct >= 70 {
		return t.c('warn')
	}
	return t.c('ok')
}
