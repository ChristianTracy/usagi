module tui

import sync
import term.ui as tui_std
import tools
import json2
import os
import time
import encoding.base64
import app as appmod { App }
import agent { append_user, run_agent }
import config { SamplingField, load_system_prompt, sampling_apply, sampling_fields, sampling_value }
import ctx { set_window_size, window_size }
import pet { Pet, PetFrame, load_pet, mood_name, pack_pixel_pet, pet_frame_for, pixel_frame_grid, pixel_interval, pixel_sequence }
import proto { Message, TokenFn }
import server { ModelEntry, cached_models, capabilities_for_entry, model_capabilities, next_thinking_level, server_profile, set_model_capabilities, thinking_effort_levels, thinking_levels }
import sessions
import state
import text as textlib { display_width, fit_cells, fmt_ttft, prefix_width, slice_by_cells, truncate_cells }

// TUI mode: transcript pane + input line + status bar, built on the V
// stdlib `term.ui`. The agent turn runs in a goroutine; everything it
// produces is pushed into a lock-guarded queue, and the frame loop (main
// thread) drains that queue into the transcript. All transcript state is
// therefore only mutated on the main thread.

pub struct TuiMsg {
	pub mut:
	kind string // 'content' 'thinking' 'line' 'tool' 'tool_result' 'debug' 'note' 'error'
	text string
}

pub struct TuiLine {
	pub mut:
	kind  string
	text  string
	stamp string // turn timestamp shown by a 'rule' row
	arg   string // tool-call arguments for a 'tool' row
}

// ModelPicker is the overlay state for `/model`: a filterable list of the
// models the endpoint advertises, read from the session cache.
pub struct ModelPicker {
pub mut:
	active bool
	items  []ModelEntry
	filter string
	sel    int
	scroll int
}

// SessionPicker is the overlay state for `/sessions` (and bare `/resume`): a
// filterable list of the saved sessions; enter resumes the selected one.
pub struct SessionPicker {
pub mut:
	active bool
	items  []sessions.Meta
	filter string
	sel    int
	scroll int
}

// SamplingEditor is the overlay state for `/samplings`: numeric decoding knobs
// editable per session (nothing is written back to config.json).
pub struct SamplingEditor {
pub mut:
	active  bool
	fields  []SamplingField
	values  []string
	sel     int
	scroll  int
	editing bool
	buffer  string
	profile string
}

@[heap]
pub struct TuiApp {
pub mut:
	handle        &tui_std.Context = unsafe { nil }
	app           App
	theme         Theme
	pet           Pet
	pet_mood      string = 'idle' // pet reaction to the current activity
	pet_mood_ms   i64 // when the mood was set (for done/idle timeouts)
	pet_hidden    bool // set by `/pet hide`, cleared by `/pet show`
	messages      []Message
	lines         []TuiLine   // committed transcript
	stream        string      // the in-flight streaming line
	stream_kind   string
	cur_tool_name string      // in-flight tool call (args stream in below)
	cur_tool_args string
	in_fence      bool        // inside a ``` fenced code block
	rows          []RenderRow // wrapped cache of `lines`
	rows_n        int         // how many `lines` are already in `rows`
	rows_w        int         // width `rows` was wrapped at
	view          []RenderRow // rows + stream, filtered by show_thinking
	view_dirty    bool = true
	input         InputLine   // editable input buffer (text + cursor + history)
	paste_chars   int         // printable chars typed in the current paste burst
	paste_last_ms i64         // when the last paste character arrived
	busy          bool
	dirty         bool = true
	scroll        int  // 0 = pinned to bottom
	quit          bool // set by the event handler; the frame fn exits via this
	need_clear    bool = true // clear the screen on the next render (resize/shrink)
	prev_w        int  // previous window width (to detect viewport shrink)
	prev_h        int  // previous window height
	sess_in       int
	sess_out      int
	session_id    string // '' = no saved session yet
	session_name  string
	last_prompt   int
	last_cached   int = -1 // prompt tokens from prefix cache; -1 = not reported
	last_ttft     int = -1 // time to first token (ms); -1 = not reported
	last_tok_s    string // completion tokens / second for the last turn
	last_turn_ms  i64
	pending_user  string // set in start_turn, read by the turn goroutine
	pending_osc   string // OSC 52 clipboard sequence flushed with the next frame
	// Mouse drag selection over the transcript (in view coordinates).
	sel          Selection
	sel_dragging bool
	sel_moved    bool
	// `/model` overlay.
	model_picker ModelPicker
	// `/sessions` overlay.
	session_picker SessionPicker
	// `/samplings` overlay.
	sampling SamplingEditor
	lock          sync.Mutex
	pending       []TuiMsg
	show_thinking bool = true // ctrl-t toggles thinking visibility
	tools_expanded bool // ctrl-o toggles full tool results
	interrupted   bool // esc/ctrl-c pressed while busy (status feedback)
	turn_no       int  // number of the current turn (shown on the rule)
	frame_n       int  // frame counter (drives the spinner)
	turn_start_ms i64  // set in start_turn (ms, from time.ticks)
	// Request lifecycle shown in the status bar. phase is one of
	// connecting | waiting | streaming | tool | retrying | stopping.
	phase            string = 'idle'
	phase_detail     string // tool name, or retry count (e.g. '1/2')
	phase_ms         i64    // when phase last changed
	attempt_mark     int = -1 // committed lines at the start of the current attempt
	spin_frames      []string
	spin_interval_ms int
	animation        string // full | calm | off (resolved at startup)
	anim_epoch_ms    i64    // spinner clock origin
}

// ball_wave is the busy animation: six frames of a three-cell ball travelling
// across the status bar. Frames advance every ball_wave_interval_ms (0.1 s).
pub const ball_wave_frames = ['𓃉𓃉𓃉', '𓃉𓃉∘', '𓃉∘°', '∘°∘', '°∘𓃉', '∘𓃉𓃉']

pub const ball_wave_interval_ms = 100

// default_spin_frames / default_spin_interval_ms expose the built-in ball-wave
// animation (constants cannot be selectively imported by tests).
pub fn default_spin_frames() []string {
	return ball_wave_frames
}

pub fn default_spin_interval_ms() int {
	return ball_wave_interval_ms
}

// Layout: the explicit row allocation for the three panes, defined in one
// place so the transcript/input boundary never drifts.
pub struct Layout {
	pub mut:
	status_h     int
	status_gap   int // grey rule + blank margin under the status bar
	transcript_h int
	input_h      int
	compact      bool // short terminal: one status row, no pet
}

// max_input_lines caps how tall the input box may grow before it scrolls.
pub const max_input_lines = 10

// layout_for allocates the rows: a two-line status bar, a grey rule and a
// blank margin, the transcript, and a bordered input box whose height follows
// the number of input lines (1..max_input_lines, plus top/bottom rules).
pub fn layout_for(h int, input_lines int) Layout {
	if h < 9 {
		return Layout{}
	}
	// On a short terminal drop to a single status row and a one-row margin.
	// Otherwise reserve four rows: two status text rows plus the four-row
	// pixel-pet sprite (which overlaps the text rows on the right).
	compact := h < 14
	status_h := if compact { 1 } else { 4 }
	gap := if compact { 1 } else { 2 }
	mut content := input_lines
	if content < 1 {
		content = 1
	}
	if content > max_input_lines {
		content = max_input_lines
	}
	mut input_h := content + 2
	mut transcript_h := h - status_h - gap - input_h
	if transcript_h < 1 {
		// Shrink the input so the transcript keeps at least one row.
		transcript_h = 1
		input_h = h - status_h - gap - transcript_h
		if input_h < 3 {
			input_h = 3
		}
	}
	return Layout{
		status_h:     status_h
		status_gap:   gap
		transcript_h: transcript_h
		input_h:      input_h
		compact:      compact
	}
}

// input_content_lines is how many input lines the box should show, clamped to
// [1, max_input_lines].
pub fn (t &TuiApp) input_content_lines() int {
	n := t.input.logical_lines().len
	if n < 1 {
		return 1
	}
	if n > max_input_lines {
		return max_input_lines
	}
	return n
}

// is_printable reports whether a rune may be typed into the input line.
// Control characters (0x00–0x1F and 0x7F) are rejected so a stray escape
// sequence from a paste can't corrupt the display; space and all printable
// ASCII/Unicode (including the first rune of a multibyte char) are allowed.
pub fn is_printable(r rune) bool {
	return r >= 0x20 && r != 0x7f
}

pub fn now_stamp() string {
	n := time.now()
	return '${n.hour:02d}:${n.minute:02d}'
}

// push queues output events from the turn goroutine. Text is split on
// newlines (an empty part is a line break) so the renderer never sees a
// raw '\n' — drawing one would move the cursor and break the layout.
pub fn (mut t TuiApp) push(kind string, text string) {
	for part in text.split('\n') {
		mut p := part.trim_right('\r')
		t.lock.lock()
		t.pending << TuiMsg{kind: kind, text: p}
		t.lock.unlock()
	}
}

// push_raw queues a message whole, newlines included (tool results are
// rendered as their own block, not line by line).
pub fn (mut t TuiApp) push_raw(kind string, text string) {
	t.lock.lock()
	t.pending << TuiMsg{kind: kind, text: text}
	t.lock.unlock()
}

// pump drains the pending queue into the transcript (main thread only).
pub fn (mut t TuiApp) pump() {
	t.lock.lock()
	mut msgs := t.pending.clone()
	t.pending = []
	t.lock.unlock()
	if msgs.len == 0 {
		return
	}
	for m in msgs {
		// The pet reacts to what the agent is doing right now. While an interrupt
		// is pending, streaming tokens must not steal the face back.
		match m.kind {
			'debug', 'tool' {
				if !t.interrupted {
					t.set_mood('tool')
				}
			}
			'tool_result' {
				if !t.interrupted {
					t.set_mood('reading')
				}
			}
			'content' {
				if !t.interrupted {
					t.set_mood('writing')
				}
			}
			'thinking' {
				if !t.interrupted {
					t.set_mood('thinking')
				}
			}
			'error' {
				if m.text.contains('interrupted') {
					t.set_mood('interrupt')
				} else {
					t.set_mood('error')
				}
			}
			'turn_end' {
				// Keep an error / interrupt face until the next turn starts.
				if t.pet_mood != 'error' && t.pet_mood != 'interrupt' {
					t.set_mood('done')
				}
			}
			else {}
		}
		match m.kind {
			'debug' {
				// Tool-argument fragments belong to the in-flight tool header.
				t.cur_tool_args += m.text
			}
			'tool' {
				t.commit_tool_block()
				name, inline := parse_tool_header(m.text)
				if name != '' {
					t.cur_tool_name = name
					t.cur_tool_args = inline
					t.set_phase('tool', name)
				}
			}
			'tool_result' {
				t.commit_tool_block()
				t.lines << TuiLine{kind: 'tool_result', text: m.text}
			}
			'phase' {
				// '<phase>[ <detail>]' from the streaming client.
				parts := m.text.split(' ')
				detail := if parts.len > 1 { parts[1..].join(' ') } else { '' }
				if parts.len > 0 {
					if parts[0] == 'connecting' {
						// Mark where this attempt's output starts, so a failed
						// attempt can be rewound before the nudge retry.
						t.attempt_mark = t.lines.len
						t.stream = ''
						t.stream_kind = ''
						t.cur_tool_name = ''
						t.cur_tool_args = ''
					}
					t.set_phase(parts[0], detail)
				}
				t.dirty = true
				continue
			}
			'rewind' {
				// Drop the failed attempt's streamed output: truncate the
				// transcript back to the attempt mark and clear in-flight state.
				t.stream = ''
				t.stream_kind = ''
				t.cur_tool_name = ''
				t.cur_tool_args = ''
				if t.attempt_mark >= 0 && t.attempt_mark <= t.lines.len {
					t.lines = t.lines[..t.attempt_mark]
					t.rows = []
					t.rows_n = 0
					t.rows_w = -1
				}
				t.view_dirty = true
				t.dirty = true
				continue
			}
			'content', 'thinking' {
				t.commit_tool_block()
				// Phase follows the actual output: thinking tokens -> THINKING,
				// answer tokens -> WRITING (nothing yet -> PROCESSING).
				t.set_phase(if m.kind == 'content' { 'writing' } else { 'thinking' }, '')
				if m.text == '' {
					// a line break inside the stream: commit the line so far
					t.flush_stream()
					t.view_dirty = true
					t.dirty = true
					continue
				}
				if t.stream_kind != '' && t.stream_kind != m.kind {
					t.flush_stream()
				}
				t.stream_kind = m.kind
				t.stream += m.text
			}
			'turn_end' { // 'prompt|out|has_usage|ms' from the turn goroutine
				t.commit_tool_block()
				p := m.text.split('|')
				ms := p[3].int()
				gen_ms := if p.len > 4 { p[4].int() } else { 0 }
				t.last_cached = if p.len > 5 { p[5].int() } else { -1 }
				t.last_ttft = if p.len > 6 { p[6].int() } else { -1 }
				if p[2] == 'true' {
					t.last_prompt = p[0].int()
					t.sess_in += p[0].int()
					t.sess_out += p[1].int()
					comp := p[1].int()
					// Prefer the streaming window (what the server logs) over the
					// whole-turn wall time, which includes tool runs and latency.
					base_ms := if gen_ms > 0 { gen_ms } else { ms }
					if base_ms > 0 && comp > 0 {
						tps := f64(comp) * 1000.0 / f64(base_ms)
						t.last_tok_s = '${tps:.1f} tok/s'
					}
				}
				t.last_turn_ms = ms
				t.busy = false
				t.interrupted = false
				t.set_phase('idle', '')
				// Terminal bell: only ring when the user has scrolled up away
				// from the fresh output, and only if the bell is enabled in
				// config. Otherwise stay silent.
				if t.app.cfg.tui.bell && t.scroll > 0 {
					t.handle.write('\a')
				}
			}
			else {
				t.commit_tool_block()
				t.flush_stream()
				t.lines << TuiLine{kind: m.kind, text: m.text}
			}
		}
		t.view_dirty = true
		t.dirty = true
	}
}

// commit_tool_block finalizes an in-flight tool call into one transcript
// line (name + collected arguments).
pub fn (mut t TuiApp) commit_tool_block() {
	if t.cur_tool_name == '' {
		return
	}
	t.lines << TuiLine{
		kind: 'tool'
		text: t.cur_tool_name
		arg:  t.cur_tool_args.trim_space()
	}
	t.cur_tool_name = ''
	t.cur_tool_args = ''
}

// flush_stream commits the in-flight streaming line, classifying fenced code
// (with a glued-fence-tolerant splitter) so prose never gets painted as code.
pub fn (mut t TuiApp) flush_stream() {
	if t.stream != '' {
		if t.stream_kind == 'content' {
			segs, state := split_fence(t.stream, t.in_fence)
			t.in_fence = state
			for s in segs {
				t.lines << TuiLine{kind: s.kind, text: s.text}
			}
		} else {
			t.lines << TuiLine{kind: t.stream_kind, text: t.stream}
		}
	}
	t.stream = ''
	t.stream_kind = ''
}

// build_view lays out the committed rows plus the in-flight stream/tool state
// into the scrollable view. Pure read of TuiApp, so callers can cache it.
pub fn (t &TuiApp) build_view(w int) []RenderRow {
	mut v := []RenderRow{}
	for r in t.rows {
		if r.kind == 'thinking' && !t.show_thinking {
			continue
		}
		v << r
	}
	if t.cur_tool_name != '' {
		for r in render_line_rows('tool', t.cur_tool_name, '', t.cur_tool_args, w, t.tools_expanded) {
			v << r
		}
	}
	if t.stream != '' {
		for r in render_line_rows(t.stream_kind, t.stream, '', '', w, t.tools_expanded) {
			v << r
		}
	}
	return expand_bubbles(v, w)
}

// spinner returns the current animation frame. It is time-based (not
// frame-count based), so changing frame_rate does not change its speed.
// 'calm' advances four times slower; 'off' stays on the first frame.
pub fn (t &TuiApp) spinner() string {
	if t.spin_frames.len == 0 {
		return ''
	}
	if t.animation == 'off' {
		return t.spin_frames[0]
	}
	interval := if t.animation == 'calm' {
		t.spin_interval_ms * 4
	} else {
		t.spin_interval_ms
	}
	if interval <= 0 {
		return t.spin_frames[0]
	}
	elapsed := time.ticks() - t.anim_epoch_ms
	idx := int(elapsed / interval) % t.spin_frames.len
	return t.spin_frames[idx]
}

pub fn (t &TuiApp) status_view() StatusView {
	// The indicator shows the *level* itself (off/auto/low/medium/high), so
	// ctrl-t's cycle is visible at a glance; '·hidden' means the block is
	// hidden (ctrl-h) while thinking is still requested. The level is always
	// shown, because ctrl-t changes the request even when the probe cannot
	// confirm the model thinks (see `/think` for that detail).
	think := thinking_label(t.app.cfg.reasoning, t.app.cfg.reasoning_effort, t.show_thinking)
	return StatusView{
		model:            t.app.cfg.model
		busy:             t.busy
		spin:             t.spinner()
		elapsed_ms:       time.ticks() - t.turn_start_ms
		last_ms:          t.last_turn_ms
		cached:           t.last_cached
		ttft:             t.last_ttft
		tok_s:            t.last_tok_s
		prompt:           t.last_prompt
		window:           window_size()
		sess_in:          t.sess_in
		sess_out:         t.sess_out
		thinking:         t.show_thinking
		interrupted:      t.interrupted
		think:            think
		effort:           ''
		phase:            t.phase
		phase_detail:     t.phase_detail
		phase_elapsed_ms: time.ticks() - t.phase_ms
	}
}

// cycle_thinking advances ctrl-t through every thinking configuration the
// model offers: off/none first, then the effort levels (low/medium/high, or
// whatever the server advertises). It changes the *request*; the view toggle
// stays on ctrl-h.
pub fn (mut t TuiApp) cycle_thinking() {
	caps := model_capabilities()
	caps_levels := if caps.effort_levels.len > 0 { caps.effort_levels } else { thinking_effort_levels() }
	levels := thinking_levels(caps_levels)
	cur := if !t.app.cfg.reasoning {
		'none'
	} else if t.app.cfg.reasoning_effort == '' {
		'auto'
	} else {
		t.app.cfg.reasoning_effort
	}
	next := next_thinking_level(levels, cur)
	if next == 'none' {
		t.app.cfg.reasoning = false
		t.app.cfg.reasoning_effort = ''
	} else {
		t.app.cfg.reasoning = true
		t.app.cfg.reasoning_effort = next
	}
	// Show the block when thinking is on, so the change is visible.
	t.show_thinking = t.app.cfg.reasoning
	t.view_dirty = true
	t.dirty = true
}

// set_phase records the request lifecycle for the status bar. The phase timer
// only resets when the phase (or its detail) actually changes, so a stream of
// tokens keeps one "streaming… 3.2s" timer. Once interrupted, only the
// stopping phase may take over.
pub fn (mut t TuiApp) set_phase(phase string, detail string) {
	if t.interrupted && phase != 'stopping' {
		return
	}
	if t.phase != phase || t.phase_detail != detail {
		t.phase_ms = time.ticks()
	}
	t.phase = phase
	t.phase_detail = detail
}

// set_mood records the pet's reaction and when it started.
pub fn (mut t TuiApp) set_mood(mood string) {
	t.pet_mood = mood
	t.pet_mood_ms = time.ticks()
}

// age_pet_mood fades 'done' back to idle after a few seconds and turns a long
// idle into 'asleep'.
pub fn (mut t TuiApp) age_pet_mood() {
	now := time.ticks()
	if t.pet_mood == 'done' && now - t.pet_mood_ms > 3000 {
		t.set_mood('idle')
	} else if t.pet_mood == 'idle' && now - t.pet_mood_ms > 120000 {
		t.pet_mood = 'asleep'
	}
}

// pixel_pet_grid resolves the current mood + animation mode to a pixel frame.
// full cycles ~4 fps so blink/twitch read as motion; calm is much slower; off
// holds the first frame. Pure data, ready for pack_pixel_pet().
pub fn (mut t TuiApp) pixel_pet_grid() []string {
	t.age_pet_mood()
	seq := pixel_sequence(t.pet_mood)
	mut grid := pixel_frame_grid('idle')
	if seq.len > 0 {
		if t.animation == 'off' {
			grid = pixel_frame_grid(seq[0])
		} else {
			base := pixel_interval(t.pet_mood)
			ms := if t.animation == 'calm' { base * 3 } else { base }
			epoch := if t.pet_mood_ms > 0 { t.pet_mood_ms } else { t.anim_epoch_ms }
			elapsed := time.ticks() - epoch
			idx := if elapsed > 0 && ms > 0 { int(elapsed / ms) % seq.len } else { 0 }
			grid = pixel_frame_grid(seq[idx])
		}
	}
	if t.theme.mono {
		// Monochrome: collapse ear/eye colours into the silhouette, leaving
		// the eyes as holes so the rabbit still reads without colour.
		mut out := []string{}
		for line in grid {
			out << line.replace('k', '.').replace('e', 'b')
		}
		return out
	}
	return grid
}

// pet_frame resolves the current mood to a frame. 'done' fades back to idle
// after a few seconds, a long idle becomes 'asleep', and idle itself blinks
// occasionally so the pet feels alive.
pub fn (mut t TuiApp) pet_frame() PetFrame {
	t.age_pet_mood()
	// Reduced motion: keep the mood face but do not flap between frames.
	if t.animation != 'full' {
		return t.pet.by_name(mood_name(t.pet_mood))
	}
	if t.pet_mood == 'idle' {
		if (t.frame_n / 45) % 2 == 1 {
			return t.pet.by_name('blink')
		}
		return t.pet.by_name('idle')
	}
	return pet_frame_for(t.pet, t.pet_mood, t.frame_n)
}

// set_base_bg paints the theme's base background (or resets to the terminal
// default when the theme does not define one, or colours are off).
fn (t &TuiApp) set_base_bg(c &tui_std.Context) {
	if !t.theme.mono {
		if bg := t.theme.bg() {
			c.set_bg_color(bg)
			return
		}
	}
	c.reset_bg_color()
}

pub fn (mut t TuiApp) render() {
	w := t.handle.window_width
	h := t.handle.window_height
	mut c := t.handle
	// OSC 52 replies / clipboard writes queued by `/copy` go out with the frame.
	if t.pending_osc != '' {
		c.write(t.pending_osc)
		t.pending_osc = ''
	}
	if w < 30 || h < 9 {
		t.set_base_bg(c)
		c.clear()
		if !t.theme.mono {
			c.set_color(t.theme.color_for('rule'))
		}
		c.draw_text(0, 1, fit_cells('terminal too small (need 30×9)', w))
		c.flush()
		return
	}
	// The transcript reserves its last column for the vertical scroll bar.
	cw := w - 1
	// Re-wrap committed lines when the transcript grew or the window resized.
	mut grew := false
	if t.rows_w != cw {
		t.rows = build_rows(t.lines, cw, t.tools_expanded)
		t.rows_n = t.lines.len
		t.rows_w = cw
		t.view_dirty = true
		grew = true
	} else {
		for i in t.rows_n .. t.lines.len {
			for r in render_line_rows(t.lines[i].kind, t.lines[i].text, t.lines[i].stamp, t.lines[i].arg, cw, t.tools_expanded) {
				t.rows << r
			}
			grew = true
		}
		t.rows_n = t.lines.len
	}
	if grew {
		t.view_dirty = true
	}
	if t.view_dirty {
		t.view = t.build_view(cw)
		t.view_dirty = false
	}
	lay := layout_for(h, t.input_content_lines())
	area := lay.transcript_h
	mut max_scroll := if t.view.len > area { t.view.len - area } else { 0 }
	if t.scroll > max_scroll {
		t.scroll = max_scroll
	}
	mut start := t.view.len - area - t.scroll
	if start < 0 {
		start = 0
	}

	// Clear only on the first frame, on resize, or when the viewport shrank.
	// Otherwise the padded rows overwrite in place, so no per-frame clear is
	// needed — this removes flicker and preserves scrollback (clear() wipes it).
	t.set_base_bg(c)
	if t.need_clear || t.prev_w == 0 || t.prev_h == 0 || w < t.prev_w || h < t.prev_h {
		c.clear()
		t.need_clear = false
	}
	t.prev_w = w
	t.prev_h = h

	// NO_COLOR / TERM=dumb: keep the terminal's default foreground and skip
	// every set_color below.
	if t.theme.mono {
		c.reset_color()
	}

	// Status bar: in normal mode rows 1-2 are model/state/ctx and
	// session/hints, row 3 shares space with the animated pet. In compact
	// mode everything collapses onto a single row.
	// Status-bar companion: pixel half-block rabbit (default), the ASCII pet
	// from pet.txt, or nothing. In compact mode the pet is hidden, and
	// `/pet hide` hides it at runtime too.
	pet_mode := if t.pet_hidden { 'off' } else { t.app.cfg.tui.pet }
	pet_w := match pet_mode {
		'pixel' { pet.pet_px_width }
		'ascii' { if t.pet.frames.len > 0 { t.pet.width() } else { 0 } }
		else { 0 }
	}
	show_pet := pet_w > 0 && w >= pet_w + 24 && !lay.compact
	mut avail := if show_pet { w - pet_w - 3 } else { w }
	if avail < 10 {
		avail = 10
	}
	all_segs := build_status(t.status_view(), t.theme)
	mut srow1 := []StatusSeg{}
	mut srow2 := []StatusSeg{}
	for s in all_segs {
		if s.pri >= 3 {
			srow1 << s
		} else {
			srow2 << s
		}
	}
	status_rows := if lay.compact { [all_segs] } else { [srow1, srow2] }
	for si, segs_in in status_rows {
		sy := 1 + si
		// Blank the whole row first: segment widths are best-effort, so a
		// mis-measured glyph must never leave a stale character behind.
		c.reset_color()
		t.set_base_bg(c)
		c.draw_text(0, sy, ' '.repeat(w))
		fitted := fit_status(segs_in, avail)
		mut x := 0
		for i, seg in fitted {
			// Draw the segment and its trailing separator in one call. If the
			// terminal renders a glyph wider than display_width estimates, a
			// separate separator draw could land on the segment's last cell and
			// erase it (that is what ate the `k` in `CH:…k` and the `t` in the
			// model name). Drawing them contiguously makes that impossible.
			if !t.theme.mono {
				c.set_color(seg.color)
			}
			chunk := if i < fitted.len - 1 { seg.text + status_sep() } else { seg.text }
			c.draw_text(x, sy, chunk)
			x += display_width(chunk)
		}
		if x < w {
			c.draw_text(x, sy, ' '.repeat(w - x))
		}
	}
	// Blank the pet-only status rows (3..status_h) so a hidden or shrunken
	// pet never leaves stale glyphs behind.
	for sy in status_rows.len + 1 .. lay.status_h + 1 {
		c.reset_color()
		t.set_base_bg(c)
		c.draw_text(0, sy, ' '.repeat(w))
	}
	if show_pet {
		pet_x := if w - pet_w > 0 { w - pet_w } else { 0 }
		if pet_mode == 'pixel' {
			// Half-block cells: fg is the top pixel, bg the bottom one.
			for r, row in pack_pixel_pet(t.pixel_pet_grid()) {
				for col, cell in row {
					if t.theme.mono {
						c.reset_color()
						t.set_base_bg(c)
					} else if cell.fg != 0 && cell.bg != 0 {
						c.set_color(t.theme.pet_color(cell.fg))
						c.set_bg_color(t.theme.pet_color(cell.bg))
					} else if cell.fg != 0 {
						c.set_color(t.theme.pet_color(cell.fg))
						t.set_base_bg(c)
					} else if cell.bg != 0 {
						c.set_color(t.theme.pet_color(cell.bg))
						t.set_base_bg(c)
					} else {
						c.reset_color()
						t.set_base_bg(c)
					}
					c.draw_text(pet_x + col, 1 + r, cell.glyph)
				}
			}
			c.reset_color()
			t.set_base_bg(c)
		} else {
			fr := t.pet_frame()
			if !t.theme.mono {
				c.set_color(t.theme.c('accent'))
			}
			c.draw_text(pet_x, 1, fr.top)
			c.draw_text(pet_x, 2, fr.mid)
			c.draw_text(pet_x, 3, fr.bottom)
		}
	}
	// Grey rule closing the status bar, then a blank margin row before the
	// transcript.
	bar_border_y := 1 + lay.status_h
	if !t.theme.mono {
		c.set_color(t.theme.c('gutter'))
	}
	c.draw_text(0, bar_border_y, '─'.repeat(w))
	c.reset_color()
	c.draw_text(0, bar_border_y + 1, ' '.repeat(w))

	// NOTE: V's set_cursor_position writes the 0-based y straight into the
	// 1-based CSI CUP sequence, so y=0 and y=1 both land on the top row.
	// We offset every y by 1: status rows 1..status_h, then the rule + margin,
	// the transcript, then the input area at the bottom.
	mut y := 1 + lay.status_h + lay.status_gap
	for i in start .. t.view.len {
		row := t.view[i]
		if row.bubble == '' {
			// Full-width rows (turn rules) and empty margin gaps.
			if !t.theme.mono {
				c.set_color(t.theme.row_color(row))
			}
			c.draw_text(0, y, fit_cells(row.text, cw))
			y += 1
			continue
		}
		// Chat bubble: a bordered, padded block. User blocks are right
		// aligned, assistant-side blocks left aligned. Width is dynamic per
		// message (chosen in expand_bubbles).
		row_bw := if row.bubble_w > 0 { row.bubble_w } else { bubble_width(cw) }
		x0 := if row.align == 'right' { cw - row_bw - 1 } else { 1 }
		mut left := x0
		if left < 0 {
			left = 0
		}
		mut right := left + row_bw
		if right > cw {
			right = cw
		}
		inner := if right - left - 4 > 0 { right - left - 4 } else { 0 }
		// Clear the whole row first so nothing stale survives.
		t.set_base_bg(c)
		c.reset_color()
		c.draw_text(0, y, ' '.repeat(cw))
		if !t.theme.mono {
			c.set_bg_color(t.theme.bubble_color(row.bubble))
			c.draw_text(left, y, ' '.repeat(right - left))
			c.set_color(t.theme.color_for(class_kind(row.bubble)))
		}
		match row.box {
			'top', 'bottom' {
				c.draw_text(left, y, row.text)
			}
			else {
				c.draw_text(left, y, '│')
				c.draw_text(right - 1, y, '│')
				if row.text != '' || row.spans.len > 0 {
					mut sx := left + 2
					if row.align == 'right' {
						total := display_width(row.text)
						if total < inner {
							sx = left + 2 + (inner - total)
						}
					}
					if row.spans.len > 0 {
						for sp in row.spans {
							if sx >= right - 2 {
								break
							}
							visible := slice_by_cells(sp.text, 0, right - 2 - sx)
							if !t.theme.mono {
								c.set_color(t.theme.span_color(row.kind, sp.style))
							}
							c.draw_text(sx, y, visible)
							sx += display_width(visible)
						}
					} else {
						if !t.theme.mono {
							c.set_color(t.theme.row_color(row))
						}
						c.draw_text(sx, y, slice_by_cells(row.text, 0, right - 2 - sx))
					}
				}
			}
		}
		if !t.theme.mono {
			t.set_base_bg(c)
		}
		c.reset_color()
		y += 1
	}
	// Mouse selection highlight: repaint the selected cells on top of the rows
	// just drawn. The copy itself reads the clean row text, not this pass.
	if t.sel.active && !t.sel.empty() {
		for i in start .. t.view.len {
			row := t.view[i]
			if row.box in ['top', 'bottom', 'gap'] || row.kind == 'rule' {
				continue
			}
			content := row_copy_text(row)
			clen := display_width(content)
			cr := selection_cells(t.sel, i, clen) or { continue }
			row_start := row_content_start(row, cw)
			maxw := cw - row_start
			mut bend := cr.b
			if bend > maxw {
				bend = maxw
			}
			if bend <= cr.a {
				continue
			}
			piece := slice_by_cells(content, cr.a, bend - cr.a)
			if piece == '' {
				continue
			}
			yy := 1 + lay.status_h + lay.status_gap + (i - start)
			sx := row_start + prefix_width(content, cr.a)
			if t.theme.mono {
				c.write('\x1b[7m') // reverse video when colors are off
			} else {
				c.set_bg_color(t.theme.c('selection'))
				c.set_color(t.theme.c('selection_fg'))
			}
			c.draw_text(sx, yy, piece)
			if t.theme.mono {
				c.write('\x1b[0m')
			}
		}
		t.set_base_bg(c)
		c.reset_color()
	}
	// Blank any rows the shrunken view no longer covers.
	for y < 1 + lay.status_h + lay.status_gap + lay.transcript_h {
		t.set_base_bg(c)
		c.draw_text(0, y, ' '.repeat(cw))
		y += 1
	}
	c.reset_color()
	t.set_base_bg(c)

	// Vertical scroll bar in the reserved last column of the transcript: the
	// thumb's height is the visible fraction and its position tracks the
	// viewport (top = top of the transcript, bottom = live).
	thumb_top, thumb_h := scroll_thumb(t.view.len, area, t.scroll)
	if thumb_h > 0 {
		top_y := 1 + lay.status_h + lay.status_gap
		for r in 0 .. area {
			is_thumb := r >= thumb_top && r < thumb_top + thumb_h
			if !t.theme.mono {
				c.set_color(if is_thumb { t.theme.c('accent') } else { t.theme.c('gutter') })
			}
			c.draw_text(w - 1, top_y + r, if is_thumb { '█' } else { '│' })
		}
		if !t.theme.mono {
			c.reset_color()
		}
	}

	// Input area: just a horizontal rule above and below (no side borders),
	// with two content rows. The cursor line stays visible and scrolls
	// horizontally.
	input_y0 := 1 + lay.status_h + lay.status_gap + lay.transcript_h
	if !t.theme.mono {
		c.set_color(t.theme.c('accent'))
	}
	c.draw_text(0, input_y0, '─'.repeat(w))
	c.draw_text(0, input_y0 + lay.input_h - 1, '─'.repeat(w))
	lines_in := t.input.logical_lines()
	cl := t.input.cursor_line()
	row_h := if lay.input_h - 2 > 0 { lay.input_h - 2 } else { 1 }
	content_w := w
	mut first := 0
	if cl >= row_h {
		first = cl - row_h + 1
	}
	if first + row_h > lines_in.len && lines_in.len >= row_h {
		first = lines_in.len - row_h
	}
	if first < 0 {
		first = 0
	}
	cur_line, cur_off := t.input.current_line()
	// `» ` is a visual prompt on the first input line only. It lives in no
	// buffer, so it is never sent in the prompt.
	marker := '» '
	marker_w := display_width(marker)
	cur_pad := if cl == 0 { marker_w } else { 0 }
	t.input.adjust_scroll(content_w - cur_pad)
	mut cur_x := 0
	mut cur_y := input_y0 + 1
	for r in 0 .. row_h {
		iy := input_y0 + 1 + r
		idx := first + r
		mut txt := ''
		if idx < lines_in.len {
			txt = lines_in[idx]
		}
		start_cell := if idx == cl { t.input.scroll_x } else { 0 }
		pad := if idx == 0 { marker_w } else { 0 }
		shown := slice_by_cells(txt, start_cell, content_w - pad)
		if idx == 0 {
			if !t.theme.mono {
				c.set_color(t.theme.c('accent'))
			}
			c.draw_text(0, iy, marker)
		}
		if !t.theme.mono {
			c.set_color(t.theme.c('line'))
		}
		c.draw_text(pad, iy, fit_cells(shown, content_w - pad))
		if idx == cl {
			mut cell := prefix_width(cur_line, cur_off) - t.input.scroll_x
			if cell < 0 {
				cell = 0
			}
			// draw_text starts at column max(pad, 1) (CUP 0 is clamped to 1); the
			// caret must use that same 1-based column, so the old unconditional
			// `+1` is applied only when the text starts at x=0.
			cur_x = cell + (if pad == 0 { 1 } else { pad })
			cur_y = iy
		}
	}
	if t.busy || t.model_picker.active || t.sampling.active || t.session_picker.active {
		c.hide_cursor()
	} else {
		if cur_x < 1 {
			cur_x = 1
		}
		if cur_x > w {
			cur_x = w
		}
		c.set_cursor_position(cur_x, cur_y)
		c.show_cursor()
	}
	if t.model_picker.active {
		t.render_model_picker(c, w, h)
	}
	if t.sampling.active {
		t.render_sampling_editor(c, w, h)
	}
	if t.session_picker.active {
		t.render_session_picker(c, w, h)
	}
	c.flush()
}

pub fn tui_frame(x voidptr) {
	mut t := unsafe { &TuiApp(x) }
	t.frame_n += 1
	t.pump()
	// Quit is handled here, in the frame loop, so term.ui's at_exit cleanup
	// (restore_terminal_state) runs: raw mode off, alternate buffer restored,
	// cursor shown. Exiting straight from the event handler would bypass this.
	if t.quit {
		if t.app.cfg.tui.input_history {
			save_input_history(t.input.history)
		}
		exit(0)
	}
	// Paste-burst counter decays by time, not per frame: a paste that spans
	// several frames still reads as one burst when the newline arrives.
	if t.paste_chars > 0 && time.ticks() - t.paste_last_ms > 300 {
		t.paste_chars = 0
	}
	// Animate the pet even while idle (about once a second at 30 fps), but
	// only in full-motion mode; calm/off keep a static face.
	if t.animation == 'full' && t.pet.frames.len > 0 && t.frame_n % 30 == 0 {
		t.dirty = true
	}
	// Render every frame while busy so the spinner and elapsed time animate.
	if !t.dirty && !t.busy {
		return
	}
	t.dirty = false
	t.render()
}

pub fn tui_event(e &tui_std.Event, x voidptr) {
	mut t := unsafe { &TuiApp(x) }
	if e.typ == .resized {
		t.rows_w = -1 // force re-wrap at the new width
		t.need_clear = true
		t.view_dirty = true
		t.dirty = true
		return
	}
	if t.model_picker.active {
		t.model_picker_event(e)
		return
	}
	if t.sampling.active {
		t.sampling_event(e)
		return
	}
	if t.session_picker.active {
		t.session_picker_event(e)
		return
	}
	if e.typ == .mouse_down {
		// Left press inside the transcript starts a drag selection. Shift is
		// left alone so the terminal's native selection can take over.
		lay := layout_for(t.handle.window_height, t.input_content_lines())
		top := t.transcript_rows_top(lay)
		if e.button == .left && !e.modifiers.has(.shift) && e.y >= top
			&& e.y < top + lay.transcript_h {
			t.selection_begin(e.x, e.y, lay)
		}
		return
	}
	if e.typ == .mouse_drag {
		if t.sel_dragging {
			lay := layout_for(t.handle.window_height, t.input_content_lines())
			t.selection_extend(e.x, e.y, lay)
		}
		return
	}
	if e.typ == .mouse_up {
		if t.sel_dragging {
			t.selection_finish()
		}
		return
	}
	if e.typ == .mouse_move {
		return
	}
	if e.typ == .mouse_scroll {
		// Wheel over the input scrolls the input lines; elsewhere it scrolls
		// the transcript (enabled with `tui.mouse`).
		lay := layout_for(t.handle.window_height, t.input_content_lines())
		over_input := e.y >= t.handle.window_height - lay.input_h
		if over_input && t.input.logical_lines().len > 1 {
			if e.direction == .up {
				t.input.move_up()
			} else if e.direction == .down {
				t.input.move_down()
			}
		} else if e.direction == .up {
			t.scroll += 3
		} else if e.direction == .down {
			t.scroll -= 3
			if t.scroll < 0 {
				t.scroll = 0
			}
		}
		t.dirty = true
		return
	}
	if e.typ != .key_down {
		return
	}
	// Unrecognized functional keys (e.g. a terminal's Kitty CSI-u report for
	// Ctrl+Shift+C) arrive as a key_down with no KeyCode and the raw escape
	// sequence in `utf8`. Never treat that as typed text — it used to leak
	// "[57444;9u" into the input line.
	if e.code == .null {
		return
	}
	if e.code == .c && e.modifiers.has(.ctrl) {
		if t.busy {
			state.g_interrupt = true
			t.interrupted = true
			t.set_mood('interrupt')
			t.set_phase('stopping', '')
		} else if !t.quit {
			// Route the quit through the frame loop so terminal cleanup runs.
			t.quit = true
		}
		t.dirty = true
		return
	}
	if e.code == .t && e.modifiers.has(.ctrl) {
		// ctrl-t cycles the available thinking levels (off/low/medium/high for
		// most models) instead of only hiding the block.
		t.cycle_thinking()
		return
	}
	if e.code == .h && e.modifiers.has(.ctrl) {
		// ctrl-h is the view-only toggle: show/hide the thinking block without
		// changing what we ask the server for.
		t.show_thinking = !t.show_thinking
		t.view_dirty = true
		t.dirty = true
		return
	}
	has_ctrl := e.modifiers.has(.ctrl)
	has_alt := e.modifiers.has(.alt)
	// History: ctrl-p / ctrl-n, and alt-up / alt-down when the terminal
	// reports the alt modifier (terminals with modified-key reporting).
	if t.app.cfg.tui.input_history {
		if has_ctrl && (e.code == .p || e.code == .n) {
			mut ok := if e.code == .p { t.input.hist_prev() } else { t.input.hist_next() }
			if ok {
				t.dirty = true
			}
			return
		}
		if has_alt && (e.code == .up || e.code == .down) {
			mut ok := if e.code == .up { t.input.hist_prev() } else { t.input.hist_next() }
			if ok {
				t.dirty = true
			}
			return
		}
	}
	// ctrl-j inserts a newline (the reliable alias for shift+enter).
	if has_ctrl && e.code == .j {
		t.input.insert_newline()
		t.dirty = true
		return
	}
	// Editing keys: cursor movement, emacs kill/word ops.
	if has_ctrl {
		match e.code {
			.a { t.input.move_home() }
			.e { t.input.move_end() }
			.u { t.input.kill_to_start() }
			.k { t.input.kill_to_end() }
			.w { t.input.delete_word() }
			.o {
				t.tools_expanded = !t.tools_expanded
				t.rows_w = -1 // re-wrap so tool blocks collapse/expand
				t.view_dirty = true
			}
			.home { t.scroll = 1 << 30 } // ctrl-home: transcript top
			.end { t.scroll = 0 } // ctrl-end: transcript bottom
			.left { t.input.move_left() }
			.right { t.input.move_right() }
			else { return } // any other ctrl combo: ignore, don't type it
		}
		t.dirty = true
		return
	}
	mut lay := layout_for(t.handle.window_height, t.input_content_lines())
	match e.code {
		.escape {
			if t.busy {
				state.g_interrupt = true
				t.interrupted = true
				t.set_mood('interrupt')
				t.set_phase('stopping', '')
			} else {
				t.input.clear()
			}
			t.dirty = true
		}
		.enter {
			if t.busy {
				return
			}
			// shift+enter inserts a newline when the terminal reports the
			// shift modifier (ctrl-j is the always-available alias).
			if e.modifiers.has(.shift) {
				t.input.insert_newline()
				t.dirty = true
				return
			}
			sent := t.input.text_str().trim_space()
			if sent == '' {
				return
			}
			// A newline arriving right after a burst of pasted characters is
			// treated as a line break inside the input, not a submit.
			if t.paste_chars >= paste_submit_threshold
				&& time.ticks() - t.paste_last_ms < paste_window_ms {
				t.input.insert_newline()
				t.dirty = true
				return
			}
			t.paste_chars = 0
			t.input.push_history(sent)
			if sent.starts_with('/') {
				t.handle_command(sent)
			} else {
				t.start_turn()
			}
		}
		.backspace { // rune-safe: deletes one codepoint, not one byte
			t.input.backspace()
			t.dirty = true
		}
		.delete { // forward delete
			t.input.forward_delete()
			t.dirty = true
		}
		.left { t.input.move_left(); t.dirty = true }
		.right { t.input.move_right(); t.dirty = true }
		.home {
			// home = "start of the input line"; when the input is empty it
			// jumps the transcript to the top instead.
			if t.input.text.len == 0 {
				t.scroll = 1 << 30 // clamped to max_scroll by render()
			} else {
				t.input.move_home()
			}
			t.dirty = true
		}
		.end {
			if t.input.text.len == 0 {
				t.scroll = 0
			} else {
				t.input.move_end()
			}
			t.dirty = true
		}
		.tab {
			t.input.set_text(complete_input(t.input.text_str()))
			t.dirty = true
		}
		.up {
			// Multi-line input: up/down move the caret between input lines.
			// Otherwise they scroll the transcript.
			if t.input.logical_lines().len > 1 {
				t.input.move_up()
			} else {
				t.scroll += 1
			}
			t.dirty = true
		}
		.down {
			if t.input.logical_lines().len > 1 {
				t.input.move_down()
			} else if t.scroll > 0 {
				t.scroll -= 1
			}
			t.dirty = true
		}
		.page_up {
			t.scroll += lay.transcript_h
			t.dirty = true
		}
		.page_down {
			t.scroll -= lay.transcript_h
			if t.scroll < 0 {
				t.scroll = 0
			}
			t.dirty = true
		}
		else {
			// Accept a printable rune — or a whole pasted chunk, which term.ui
			// delivers as one `.utf8` event (read_all_bytes). insert_text
			// normalizes embedded newlines and drops other control chars, so a
			// paste can never inject raw \r/\t into the buffer. `e.utf8`
			// carries the full codepoint, so é / 世界 / emoji work too.
			if has_alt || e.utf8 == '' {
				return
			}
			// Never insert a raw escape sequence (a terminal key report that
			// term.ui could not map to a KeyCode has utf8 = the CSI bytes).
			if e.utf8.starts_with('\x1b') {
				return
			}
			n := t.input.insert_text(e.utf8)
			if n > 0 {
				t.paste_chars += n
				t.paste_last_ms = time.ticks()
				t.dirty = true
			}
		}
	}
}

// A newline within this many ms of a paste burst is treated as "insert
// newline", not "send".
pub const paste_window_ms = 60
pub const paste_submit_threshold = 8

// help_row formats one `/help` command line: a two-space indent, the command
// left-padded to a fixed column, then its one-line description. help_head is
// the label of a section.
pub fn help_row(cmd string, desc string) string {
	mut c := cmd
	if c.len < 24 {
		c += ' '.repeat(24 - c.len)
	}
	return '  ' + c + desc
}

pub fn help_head(title string) string {
	return '── ${title} ──'
}

// handle_command processes local `/` commands typed at the input line.
// The argument is everything after the first space, so `/save my file.json`
// keeps its spaces.
pub fn (mut t TuiApp) handle_command(cmd string) {
	t.input.clear()
	name, arg := parse_command(cmd)
	match name {
		'/clear' {
			t.reset_to_new_session('')
			t.push('note', 'transcript cleared (new session)')
		}
		'/tokens' {
			cache := if t.last_cached >= 0 { ' · cache ${t.last_cached}/${t.last_prompt}' } else { '' }
			ttft := if t.last_ttft >= 0 { ' · ttft ${fmt_ttft(t.last_ttft)}' } else { '' }
			t.push('note', 'ctx ${t.last_prompt} · window ${window_size()}${cache}${ttft} · session ${t.sess_in} in / ${t.sess_out} out')
		}
		'/model' {
			if arg == '' {
				t.open_model_picker()
			} else {
				t.app.cfg.model = arg
				t.push('note', 'model set to ${arg}')
			}
		}
		'/samplings' {
			t.open_sampling_editor()
		}
		'/save' {
			mut path := if arg != '' { arg } else { 'chat.json' }
			// `/save file.json` is relative to the workspace, like the tools.
			if !os.is_abs_path(path) {
				path = os.join_path(tools.workspace_root(), path)
			}
			mut ok := true
			os.write_file(path, json2.encode(t.messages, json2.EncoderOptions{prettify: true})) or {
				ok = false
				t.push('error', 'save failed: ${err.msg()}')
			}
			if ok {
				t.push('note', 'conversation saved to ${path}')
			}
		}
		'/history' {
			if t.input.history.len == 0 {
				t.push('note', 'history is empty')
			} else {
				mut start := t.input.history.len - 10
				if start < 0 {
					start = 0
				}
				for e in t.input.history[start..] {
					t.push('note', e)
				}
			}
		}
		'/load' {
			if arg == '' {
				t.push('error', 'usage: /load <file.json>')
			} else {
				t.load_conversation(arg)
			}
		}
		'/sessions' {
			if arg == '' {
				t.open_session_picker('')
			} else {
				t.list_sessions(arg)
			}
		}
		'/resume' {
			if arg == '' {
				t.open_session_picker('')
			} else {
				t.resume_session(arg)
			}
		}
		'/session' {
			t.session_command(arg)
		}
		'/tools' {
			t.tools_expanded = !t.tools_expanded
			t.rows_w = -1
			t.view_dirty = true
			t.push('note', if t.tools_expanded { 'tool output expanded' } else { 'tool output collapsed' })
		}
		'/copy' {
			t.copy_assistant(if arg == '' { 1 } else { arg.int() })
		}
		'/theme' {
			if arg == '' {
				t.push('note', 'theme: ${t.app.cfg.tui.theme} (${theme_names.join('|')})')
			} else if arg in theme_names {
				t.app.cfg.tui.theme = arg
				t.theme = theme_for(t.app.cfg.tui)
				t.need_clear = true
				t.push('note', 'theme set to ${arg}')
			} else {
				t.push('error', 'theme must be one of: ${theme_names.join(', ')}')
			}
		}
		'/think' {
			// Request-level thinking (cfg.reasoning); ctrl-t only hides the block.
			if arg == '' {
				caps := model_capabilities()
				t.push('note', 'thinking: ${if t.app.cfg.reasoning { 'on' } else { 'off' }} · model supports: ${if caps.thinking { 'yes' } else { 'no/unknown' }} (${caps.source})')
			} else if arg in ['on', 'off', 'toggle'] {
				if arg == 'on' {
					t.app.cfg.reasoning = true
					t.show_thinking = true
				} else if arg == 'off' {
					t.app.cfg.reasoning = false
					t.show_thinking = false
				} else {
					t.app.cfg.reasoning = !t.app.cfg.reasoning
					t.show_thinking = t.app.cfg.reasoning
				}
				mut msg := 'thinking ${if t.app.cfg.reasoning { 'on' } else { 'off' }}'
				if t.app.cfg.reasoning && !model_capabilities().thinking {
					msg += ' (server did not report thinking support; it may be ignored)'
				}
				t.push('note', msg)
				t.view_dirty = true
			} else {
				t.push('error', 'usage: /think [on|off|toggle]')
			}
		}
		'/effort' {
			caps := model_capabilities()
			levels := if caps.effort_levels.len > 0 { caps.effort_levels } else { thinking_effort_levels() }
			if arg == '' {
				cur := if t.app.cfg.reasoning_effort == '' { '(default)' } else { t.app.cfg.reasoning_effort }
				t.push('note', 'effort: ${cur} · levels: ${levels.join('|')}')
			} else if arg in levels || caps.source == 'unknown' {
				t.app.cfg.reasoning_effort = arg
				t.push('note', 'reasoning_effort = ${arg}')
			} else {
				t.push('error', 'effort must be one of: ${levels.join(', ')}')
			}
		}
		'/budget' {
			if arg == '' {
				supported := server_profile().thinking_budget
				t.push('note', 'thinking_budget: ${t.app.cfg.thinking_budget} (0 = server default) · server supports: ${supported}')
			} else if !server_profile().thinking_budget {
				t.push('error', 'this server does not support thinking_budget (omlx only)')
			} else {
				n := arg.int()
				t.app.cfg.thinking_budget = if n > 0 { n } else { 0 }
				t.push('note', 'thinking_budget = ${t.app.cfg.thinking_budget}')
			}
		}
		'/pet' {
			match arg {
				'hide' {
					t.pet_hidden = true
					t.push('note', 'pet hidden (`/pet show` to bring it back)')
				}
				'show' {
					t.pet_hidden = false
					if t.app.cfg.tui.pet !in ['pixel', 'ascii'] {
						t.app.cfg.tui.pet = 'pixel'
					}
					t.push('note', 'pet shown (${t.app.cfg.tui.pet})')
				}
				'toggle' {
					t.pet_hidden = !t.pet_hidden
					if !t.pet_hidden && t.app.cfg.tui.pet !in ['pixel', 'ascii'] {
						t.app.cfg.tui.pet = 'pixel'
					}
					t.push('note', if t.pet_hidden { 'pet hidden' } else { 'pet shown' })
				}
				'' {
					pet_state := if t.pet_hidden { 'hidden' } else { t.app.cfg.tui.pet }
					t.push('note', 'pet: ${pet_state} (use /pet show · /pet hide · /pet toggle)')
				}
				else {
					t.push('error', 'usage: /pet show | /pet hide | /pet toggle')
				}
			}
			t.need_clear = true
		}
		'/quit' {
			t.quit = true
		}
		'/help' {
			show_keys := arg == '' || arg == 'keys'
			show_cmds := arg == '' || arg == 'commands'
			if show_cmds {
				for l in [
					help_head('sessions'),
					help_row('/sessions [filter]', 'list or pick a saved session'),
					help_row('/resume [id|name]', 'resume a session (no arg: picker)'),
					help_row('/session <cmd>', 'new · save · title · rename · rm · clean'),
					help_row('/clear', 'start a fresh session (previous stays saved)'),
					help_head('model & generation'),
					help_row('/model [name]', 'switch model (no arg: pick from /v1/models)'),
					help_row('/think <on|off>', 'turn reasoning on/off'),
					help_row('/effort <level>', 'reasoning effort level'),
					help_row('/budget <n>', 'thinking-token budget (omlx)'),
					help_row('/samplings', 'edit temperature, top_p, ... (this session)'),
					help_head('conversation & view'),
					help_row('/save [file]', 'export the conversation to JSON (workspace)'),
					help_row('/load <file>', 'import a conversation from JSON'),
					help_row('/copy [n]', 'copy the n-th answer to the clipboard'),
					help_row('/history', 'show recent input history'),
					help_row('/tokens', 'context + token stats'),
					help_row('/tools', 'expand or collapse tool output'),
					help_row('/theme <name>', 'dark · light · cyberpunk'),
					help_row('/pet <show|hide>', 'show or hide the pet'),
					help_row('/help [keys|commands]', 'this help'),
					help_row('/quit', 'exit'),
				] {
					t.push('note', l)
				}
			}
			if show_keys {
				for l in [
					help_head('keys'),
					help_row('enter', 'send · shift+enter / ctrl-j newline'),
					help_row('esc', 'interrupt, or clear the input when idle'),
					help_row('left/right, home/end', 'move the cursor (empty: top/bottom)'),
					help_row('ctrl-a / ctrl-e', 'start / end of the input line'),
					help_row('ctrl-u / k / w', 'kill to start / end / delete word'),
					help_row('backspace/delete', 'delete the char before / under the cursor'),
					help_row('tab', 'complete a /command or /save path'),
					help_row('up/down, pgup/pgdn', 'scroll the transcript'),
					help_row('ctrl-p/n, alt-up/down', 'input history'),
					help_row('ctrl-t / ctrl-h', 'thinking level / hide thinking'),
					help_row('ctrl-o', 'expand or collapse tool output'),
					help_row('ctrl-c', 'interrupt while busy, quit when idle'),
					help_row('mouse (tui.mouse)', 'wheel scroll · drag to copy · shift+drag terminal'),
				] {
					t.push('note', l)
				}
			}
		}
		else {
			t.push('error', 'unknown command ${name} — try /help')
		}
	}
	t.dirty = true
}

// --- session picker -------------------------------------------------------

// open_session_picker opens `/sessions` (bare) and `/resume` (no arg): a
// filterable list of saved sessions; enter resumes the selected one.
fn (mut t TuiApp) open_session_picker(filter string) {
	m := sessions.list()
	t.session_picker = SessionPicker{
		active: true
		items:  m.sessions
		filter: filter
	}
	if m.sessions.len == 0 {
		t.push('note', 'no sessions yet — /session save keeps the current one')
	}
	t.dirty = true
}

// filter_sessions returns the entries matching `q` (case-insensitive substring
// on name, id, model or workspace). An empty query returns the list unchanged.
pub fn filter_sessions(items []sessions.Meta, q string) []sessions.Meta {
	query := q.trim_space().to_lower()
	if query == '' {
		return items
	}
	mut out := []sessions.Meta{}
	for it in items {
		if it.name.to_lower().contains(query) || it.id.to_lower().contains(query)
			|| it.model.to_lower().contains(query) || it.workspace.to_lower().contains(query) {
			out << it
		}
	}
	return out
}

// session_meta is the right-hand column of a session picker row.
pub fn session_meta(m sessions.Meta) string {
	return '${m.id} · ${sessions.age_str(m.updated)} · ${m.messages} msgs'
}

fn (mut t TuiApp) session_picker_move(delta int) {
	items := filter_sessions(t.session_picker.items, t.session_picker.filter)
	t.session_picker.sel = picker_clamp(t.session_picker.sel + delta, items.len)
	t.dirty = true
}

// session_picker_choose resumes the selected session and closes the overlay.
fn (mut t TuiApp) session_picker_choose() {
	items := filter_sessions(t.session_picker.items, t.session_picker.filter)
	if items.len == 0 {
		return
	}
	meta := items[picker_clamp(t.session_picker.sel, items.len)]
	t.session_picker = SessionPicker{}
	t.resume_session(meta.id)
	t.dirty = true
}

// session_picker_event handles keys while the overlay is open. It never falls
// through to the input line, so typing filters the list.
fn (mut t TuiApp) session_picker_event(e &tui_std.Event) {
	if e.typ == .mouse_scroll {
		if e.direction == .up {
			t.session_picker_move(-1)
		} else {
			t.session_picker_move(1)
		}
		return
	}
	if e.typ != .key_down {
		return
	}
	if e.code == .r && e.modifiers.has(.ctrl) { // ctrl-r refetches
		t.open_session_picker(t.session_picker.filter)
		t.dirty = true
		return
	}
	match e.code {
		.escape { t.session_picker = SessionPicker{} }
		.enter { t.session_picker_choose() }
		.up { t.session_picker_move(-1) }
		.down { t.session_picker_move(1) }
		.page_up { t.session_picker_move(-10) }
		.page_down { t.session_picker_move(10) }
		.backspace {
			if t.session_picker.filter.len > 0 {
				t.session_picker.filter = t.session_picker.filter[..t.session_picker.filter.len - 1]
				t.session_picker.sel = 0
				t.session_picker.scroll = 0
			}
		}
		else {
			if e.code != .null && !e.modifiers.has(.ctrl) && !e.modifiers.has(.alt)
				&& e.utf8 != '' && !e.utf8.starts_with('\x1b') {
				t.session_picker.filter += e.utf8
				t.session_picker.sel = 0
				t.session_picker.scroll = 0
			}
		}
	}
	t.dirty = true
}

// render_session_picker draws the `/sessions` overlay on top of the frame.
fn (mut t TuiApp) render_session_picker(c &tui_std.Context, w int, h int) {
	items := filter_sessions(t.session_picker.items, t.session_picker.filter)
	bw := if w - 6 > 72 { 72 } else if w - 6 > 30 { w - 6 } else { 30 }
	mut bh := items.len + 4
	if bh > h - 2 {
		bh = h - 2
	}
	if bh < 5 {
		bh = 5
	}
	mut x0 := (w - bw) / 2
	if x0 < 0 {
		x0 = 0
	}
	mut y0 := (h - bh) / 2
	if y0 < 1 {
		y0 = 1
	}
	// Background + border.
	t.set_base_bg(c)
	c.reset_color()
	if !t.theme.mono {
		c.set_bg_color(t.theme.bubble_color('assistant'))
	}
	for r in 0 .. bh {
		c.draw_text(x0, y0 + r, ' '.repeat(bw))
	}
	if !t.theme.mono {
		c.set_color(t.theme.c('accent'))
	}
	c.draw_text(x0, y0, box_top(bw))
	c.draw_text(x0, y0 + bh - 1, box_bottom(bw))
	filter_note := if t.session_picker.filter != '' { '  filter:${t.session_picker.filter}' } else { '' }
	c.draw_text(x0 + 2, y0, truncate_cells(' sessions${filter_note} ', bw - 4))
	// Rows.
	vis := bh - 2
	mut sel := picker_clamp(t.session_picker.sel, items.len)
	mut scroll := picker_clamp(t.session_picker.scroll, items.len)
	if sel < scroll {
		scroll = sel
	}
	if sel >= scroll + vis {
		scroll = sel - vis + 1
	}
	t.session_picker.scroll = scroll
	for r in 0 .. vis {
		i := scroll + r
		if i >= items.len {
			break
		}
		meta := items[i]
		marker := if i == sel { '▸ ' } else { '  ' }
		cur := if meta.id == t.session_id { '● ' } else { '  ' }
		right := session_meta(meta)
		right_w := display_width(right)
		mut left_w := bw - 4 - right_w - 1
		if left_w < 6 {
			left_w = 6
		}
		left := truncate_cells(marker + cur + meta.name, left_w)
		line := fit_cells(left, left_w) + ' ' + right
		if !t.theme.mono {
			c.set_color(if i == sel { t.theme.c('content') } else { t.theme.c('line') })
		}
		c.draw_text(x0 + 2, y0 + 1 + r, truncate_cells(line, bw - 4))
	}
	// Footer help on the bottom border.
	if !t.theme.mono {
		c.set_color(t.theme.c('hint'))
	}
	footer := if items.len == 0 {
		' no sessions · ctrl-r refresh · esc '
	} else {
		' ${sel + 1}/${items.len} · ↑/↓ enter resume · ctrl-r refresh · esc '
	}
	c.draw_text(x0 + 2, y0 + bh - 1, truncate_cells(footer, bw - 4))
	t.set_base_bg(c)
	c.reset_color()
}

// list_sessions prints the manifest as note lines (newest first).
fn (mut t TuiApp) list_sessions(filter string) {
	m := sessions.list()
	mut shown := 0
	for meta in m.sessions {
		if filter != '' && !(meta.name.contains(filter) || meta.id.starts_with(filter)
			|| meta.model.contains(filter) || meta.workspace.contains(filter)) {
			continue
		}
		t.push('note', '${meta.id} · ${meta.name} · ${sessions.age_str(meta.updated)} · ${meta.messages} msgs · ${meta.model} · ${meta.workspace}')
		shown++
	}
	if shown == 0 {
		msg := if filter != '' { 'no sessions match "${filter}"' } else { 'no sessions yet' }
		t.push('note', msg + ' — /session save keeps the current one')
	}
}

// resume_session restores a saved session: history, transcript, stats and
// (unless disabled) the stored workspace.
fn (mut t TuiApp) resume_session(arg string) {
	meta := sessions.find(arg) or {
		t.push('error', err.msg())
		return
	}
	msgs := sessions.load(meta.id) or {
		t.push('error', 'resume failed: ${err.msg()}')
		return
	}
	if t.app.cfg.sessions.restore_workspace && meta.workspace != '' {
		if os.is_dir(meta.workspace) {
			tools.set_workspace(meta.workspace)
			t.app.cfg.workspace = meta.workspace
		} else {
			t.push('note', 'stored workspace is gone: ${meta.workspace} (using current)')
		}
	}
	t.messages = msgs
	t.lines = build_transcript_lines(msgs, false)
	t.rows = []
	t.rows_n = 0
	t.view = []
	t.view_dirty = true
	t.in_fence = false
	t.stream = ''
	t.stream_kind = ''
	t.cur_tool_name = ''
	t.cur_tool_args = ''
	t.scroll = 0
	t.need_clear = true
	t.last_prompt = 0
	t.last_cached = -1
	t.last_ttft = -1
	t.last_turn_ms = 0
	t.last_tok_s = ''
	mut turns := 0
	for m in msgs {
		if m.role == 'user' {
			turns += 1
		}
	}
	t.turn_no = turns
	t.session_id = meta.id
	t.session_name = meta.name
	t.sess_in = meta.tokens_in
	t.sess_out = meta.tokens_out
	t.push('note', 'resumed "${meta.name}" (${meta.id}, ${meta.messages} msgs, workspace ${meta.workspace})')
}

// session_command dispatches the /session subcommands.
fn (mut t TuiApp) session_command(arg string) {
	parts := arg.split(' ')
	sub := if parts.len > 0 && parts[0] != '' { parts[0] } else { '' }
	rest := if parts.len > 1 { parts[1..].join(' ') } else { '' }
	match sub {
		'' {
			cur := if t.session_id != '' { '${t.session_name} (${t.session_id})' } else { 'none' }
			t.push('note', 'session: ${cur} · /session new|save|title|rename|rm|clean')
		}
		'new' {
			t.reset_to_new_session(rest)
		}
		'save' {
			t.save_current(rest)
		}
		'title' {
			if t.session_id == '' {
				t.push('error', 'no active session — /session save first')
				return
			}
			sessions.rename(t.session_id, rest) or {
				t.push('error', err.msg())
				return
			}
			t.session_name = rest.trim_space()
			t.push('note', 'session renamed to "${t.session_name}"')
		}
		'rename' {
			p := rest.split(' ')
			if p.len < 2 {
				t.push('error', 'usage: /session rename <id> <name>')
				return
			}
			id := p[0]
			name := p[1..].join(' ')
			sessions.rename(id, name) or {
				t.push('error', err.msg())
				return
			}
			t.push('note', 'renamed ${id} to "${name}"')
		}
		'rm' {
			if rest == '--all' {
				t.session_remove_all()
				return
			}
			if rest == '' {
				t.push('error', 'usage: /session rm <id> · /session rm --all')
				return
			}
			meta := sessions.find(rest) or {
				t.push('error', err.msg())
				return
			}
			sessions.remove(meta.id) or {
				t.push('error', err.msg())
				return
			}
			if t.session_id == meta.id {
				t.session_id = ''
				t.session_name = ''
			}
			t.push('note', 'deleted session ${meta.id} ("${meta.name}")')
		}
		'clean' {
			sessions.cleanup() or {
				t.push('error', err.msg())
				return
			}
			t.push('note', 'sessions cleaned (orphans removed)')
		}
		else {
			t.push('error', 'usage: /session new|save|title|rename|rm|clean')
		}
	}
}

// save_current flushes the current conversation to its session file.
fn (mut t TuiApp) save_current(new_name string) {
	if t.messages.len == 0 {
		t.push('error', 'nothing to save')
		return
	}
	mut created := false
	if t.session_id == '' {
		name := if new_name != '' { new_name } else { sessions.default_name(first_user_text(t.messages)) }
		meta := sessions.create(name, tools.workspace_root(), t.app.cfg.model, t.messages[0]) or {
			t.push('error', 'save failed: ${err.msg()}')
			return
		}
		t.session_id = meta.id
		t.session_name = meta.name
		created = true
	} else if new_name != '' {
		sessions.rename(t.session_id, new_name) or {
			t.push('error', err.msg())
			return
		}
		t.session_name = new_name.trim_space()
	}
	sessions.save_full(t.session_id, t.messages) or {
		t.push('error', 'save failed: ${err.msg()}')
		return
	}
	t.push('note', 'session ${if created { 'created' } else { 'saved' }}: "${t.session_name}" (${t.session_id})')
}

// reset_to_new_session clears the transcript and unlinks the current session
// (the previously saved session stays on disk untouched).
fn (mut t TuiApp) reset_to_new_session(name string) {
	t.lines = []
	t.rows = []
	t.rows_n = 0
	t.view = []
	t.view_dirty = true
	t.stream = ''
	t.stream_kind = ''
	t.cur_tool_name = ''
	t.cur_tool_args = ''
	t.in_fence = false
	t.scroll = 0
	t.need_clear = true
	t.sess_in = 0
	t.sess_out = 0
	t.last_prompt = 0
	t.last_cached = -1
	t.last_ttft = -1
	t.last_turn_ms = 0
	t.last_tok_s = ''
	t.turn_no = 0
	t.session_id = ''
	t.session_name = name.trim_space()
	t.messages = [Message{
		role:    'system'
		content: load_system_prompt(tools.config_root(), t.app.cfg)
	}]
	t.push('note', 'new session${if name != '' { ' "${name}"' } else { '' }} started')
}

// session_remove_all deletes every saved session (explicit --all flag).
fn (mut t TuiApp) session_remove_all() {
	m := sessions.list()
	if m.sessions.len == 0 {
		t.push('note', 'no sessions to delete')
		return
	}
	for meta in m.sessions {
		sessions.remove(meta.id) or {}
	}
	t.session_id = ''
	t.session_name = ''
	t.push('note', 'deleted ${m.sessions.len} session(s)')
}

// first_user_text returns the first user message content (for auto-naming).
fn first_user_text(messages []Message) string {
	for m in messages {
		if m.role == 'user' {
			return m.content
		}
	}
	return ''
}

// copy_assistant puts the n-th newest non-empty assistant message on the
// system clipboard via OSC 52, which also works over SSH.
pub fn (mut t TuiApp) copy_assistant(n int) {
	if n < 1 {
		t.push('error', '/copy expects a positive message number')
		return
	}
	mut seen := 0
	mut text := ''
	mut i := t.messages.len - 1
	for i >= 0 {
		m := t.messages[i]
		if m.role == 'assistant' && m.content.trim_space() != '' {
			seen += 1
			if seen == n {
				text = m.content
				break
			}
		}
		i -= 1
	}
	if text == '' {
		t.push('error', 'no assistant message #${n} to copy')
		return
	}
	t.pending_osc = '\x1b]52;c;${base64.encode_str(text)}\x07'
	t.push('note', 'copied assistant message #${n} to the clipboard (OSC 52)')
}

// transcript_rows_top is the first 1-based screen row of the transcript pane,
// matching the y offsets used by render().
fn (t &TuiApp) transcript_rows_top(lay Layout) int {
	return 1 + lay.status_h + lay.status_gap
}

// view_start is the index of the first visible view row, matching render().
fn (t &TuiApp) view_start(area int) int {
	max_scroll := if t.view.len > area { t.view.len - area } else { 0 }
	mut s := t.scroll
	if s < 0 {
		s = 0
	}
	if s > max_scroll {
		s = max_scroll
	}
	mut start := t.view.len - area - s
	if start < 0 {
		start = 0
	}
	return start
}

// screen_to_view maps a 1-based mouse (x, y) to a (view row, content cell)
// position, clamped to the visible transcript.
fn (t &TuiApp) screen_to_view(px int, py int, lay Layout) (int, int) {
	cw := if t.handle.window_width - 1 > 0 { t.handle.window_width - 1 } else { 1 }
	start := t.view_start(lay.transcript_h)
	mut row := start + (py - t.transcript_rows_top(lay))
	if row < 0 {
		row = 0
	}
	if row > t.view.len - 1 {
		row = t.view.len - 1
	}
	mut col := 0
	if row >= 0 && row < t.view.len {
		r := t.view[row]
		col = px - row_content_start(r, cw)
		if col < 0 {
			col = 0
		}
		clen := display_width(row_copy_text(r))
		if col > clen {
			col = clen
		}
	}
	return row, col
}

// selection_begin starts a drag selection at the mouse position.
fn (mut t TuiApp) selection_begin(px int, py int, lay Layout) {
	row, col := t.screen_to_view(px, py, lay)
	t.sel = Selection{
		active: true
		row0:   row
		col0:   col
		row1:   row
		col1:   col
	}
	t.sel_dragging = true
	t.sel_moved = false
	t.dirty = true
}

// selection_extend moves the focus end of the selection.
fn (mut t TuiApp) selection_extend(px int, py int, lay Layout) {
	if !t.sel.active {
		return
	}
	row, col := t.screen_to_view(px, py, lay)
	if row != t.sel.row1 || col != t.sel.col1 {
		t.sel_moved = true
	}
	t.sel.row1 = row
	t.sel.col1 = col
	t.dirty = true
}

// selection_finish copies the selected clean text (bubble borders and padding
// excluded) to the clipboard via OSC 52 and clears the highlight.
fn (mut t TuiApp) selection_finish() {
	if t.sel_moved {
		cw := if t.handle.window_width - 1 > 0 { t.handle.window_width - 1 } else { 1 }
		text := selection_text(t.view, t.sel, cw)
		if text != '' {
			t.pending_osc = '\x1b]52;c;${base64.encode_str(text)}\x07'
			n := text.split('\n').len
			t.push('note', 'copied ${n} line(s) to the clipboard (OSC 52)')
		}
	}
	t.sel = Selection{}
	t.sel_moved = false
	t.sel_dragging = false
	t.dirty = true
}

// --- model picker ---------------------------------------------------------

// open_model_picker opens `/model`: it reads the cached /v1/models list (one
// request only when the cache is empty or stale).
fn (mut t TuiApp) open_model_picker() {
	entries := cached_models(t.app.cfg, false)
	mut sel := 0
	for i, e in entries {
		if e.id == t.app.cfg.model {
			sel = i
			break
		}
	}
	t.model_picker = ModelPicker{
		active: true
		items:  entries
		sel:    sel
	}
	if entries.len == 0 {
		t.push('note', 'no models reported by ${t.app.cfg.base_url}; ctrl-r to retry')
	}
	t.dirty = true
}

// picker_move moves the selection by `delta` rows.
fn (mut t TuiApp) picker_move(delta int) {
	items := filter_models(t.model_picker.items, t.model_picker.filter)
	t.model_picker.sel = picker_clamp(t.model_picker.sel + delta, items.len)
	t.dirty = true
}

// picker_choose applies the selected model and closes the overlay.
fn (mut t TuiApp) picker_choose() {
	items := filter_models(t.model_picker.items, t.model_picker.filter)
	if items.len == 0 {
		return
	}
	e := items[picker_clamp(t.model_picker.sel, items.len)]
	t.app.cfg.model = e.id
	if e.context_len > 0 {
		set_window_size(e.context_len)
	}
	set_model_capabilities(capabilities_for_entry(e))
	t.model_picker = ModelPicker{}
	ctx_note := if e.context_len > 0 { ' (ctx ${e.context_len})' } else { '' }
	think_note := if e.thinking { ' · thinking' } else { '' }
	t.push('note', 'model set to ${e.id}${ctx_note}${think_note}')
	t.dirty = true
}

// model_picker_event handles keys while the overlay is open. It never falls
// through to the input line, so typing filters the list.
fn (mut t TuiApp) model_picker_event(e &tui_std.Event) {
	if e.typ == .mouse_scroll {
		if e.direction == .up {
			t.picker_move(-1)
		} else {
			t.picker_move(1)
		}
		return
	}
	if e.typ != .key_down {
		return
	}
	if e.code == .r && e.modifiers.has(.ctrl) { // ctrl-r refetches
		t.model_picker.items = cached_models(t.app.cfg, true)
		t.model_picker.sel = 0
		t.model_picker.scroll = 0
		t.dirty = true
		return
	}
	match e.code {
		.escape { t.model_picker = ModelPicker{} }
		.enter { t.picker_choose() }
		.up { t.picker_move(-1) }
		.down { t.picker_move(1) }
		.page_up { t.picker_move(-10) }
		.page_down { t.picker_move(10) }
		.backspace {
			if t.model_picker.filter.len > 0 {
				t.model_picker.filter = t.model_picker.filter[..t.model_picker.filter.len - 1]
				t.model_picker.sel = 0
				t.model_picker.scroll = 0
			}
		}
		else {
			if e.code != .null && !e.modifiers.has(.ctrl) && !e.modifiers.has(.alt)
				&& e.utf8 != '' && !e.utf8.starts_with('\x1b') {
				t.model_picker.filter += e.utf8
				t.model_picker.sel = 0
				t.model_picker.scroll = 0
			}
		}
	}
	t.dirty = true
}

// render_model_picker draws the `/model` overlay on top of the frame.
fn (mut t TuiApp) render_model_picker(c &tui_std.Context, w int, h int) {
	items := filter_models(t.model_picker.items, t.model_picker.filter)
	bw := if w - 6 > 72 { 72 } else if w - 6 > 30 { w - 6 } else { 30 }
	mut bh := items.len + 4
	if bh > h - 2 {
		bh = h - 2
	}
	if bh < 5 {
		bh = 5
	}
	mut x0 := (w - bw) / 2
	if x0 < 0 {
		x0 = 0
	}
	mut y0 := (h - bh) / 2
	if y0 < 1 {
		y0 = 1
	}
	// Background + border.
	t.set_base_bg(c)
	c.reset_color()
	if !t.theme.mono {
		c.set_bg_color(t.theme.bubble_color('assistant'))
	}
	for r in 0 .. bh {
		c.draw_text(x0, y0 + r, ' '.repeat(bw))
	}
	if !t.theme.mono {
		c.set_color(t.theme.c('accent'))
	}
	c.draw_text(x0, y0, box_top(bw))
	c.draw_text(x0, y0 + bh - 1, box_bottom(bw))
	filter_note := if t.model_picker.filter != '' { '  filter:${t.model_picker.filter}' } else { '' }
	c.draw_text(x0 + 2, y0, truncate_cells(' models${filter_note} ', bw - 4))
	// Rows.
	vis := bh - 2
	mut sel := picker_clamp(t.model_picker.sel, items.len)
	mut scroll := picker_clamp(t.model_picker.scroll, items.len)
	if sel < scroll {
		scroll = sel
	}
	if sel >= scroll + vis {
		scroll = sel - vis + 1
	}
	t.model_picker.scroll = scroll
	for r in 0 .. vis {
		i := scroll + r
		if i >= items.len {
			break
		}
		e := items[i]
		marker := if i == sel { '▸ ' } else { '  ' }
		cur := if e.id == t.app.cfg.model { '● ' } else { '  ' }
		meta := model_meta(e)
		meta_w := display_width(meta)
		mut left_w := bw - 4 - meta_w - 1
		if left_w < 6 {
			left_w = 6
		}
		left := truncate_cells(marker + cur + e.id, left_w)
		line := fit_cells(left, left_w) + ' ' + meta
		if !t.theme.mono {
			c.set_color(if i == sel { t.theme.c('content') } else { t.theme.c('line') })
		}
		c.draw_text(x0 + 2, y0 + 1 + r, truncate_cells(line, bw - 4))
	}
	// Footer help on the bottom border.
	if !t.theme.mono {
		c.set_color(t.theme.c('hint'))
	}
	footer := if items.len == 0 {
		' no models · ctrl-r refresh · esc '
	} else {
		' ${sel + 1}/${items.len} · ↑/↓ enter · ctrl-r refresh · esc '
	}
	c.draw_text(x0 + 2, y0 + bh - 1, truncate_cells(footer, bw - 4))
	t.set_base_bg(c)
	c.reset_color()
}

// --- sampling editor ------------------------------------------------------

// open_sampling_editor opens `/samplings`: numeric decoding knobs for the
// active server, edited in-session.
fn (mut t TuiApp) open_sampling_editor() {
	kind := server_profile().kind
	fields := sampling_fields(kind)
	mut values := []string{cap: fields.len}
	for f in fields {
		values << sampling_value(t.app.cfg, f.key)
	}
	t.sampling = SamplingEditor{
		active:  true
		fields:  fields
		values:  values
		profile: kind
	}
	t.dirty = true
}

fn (mut t TuiApp) sampling_move(delta int) {
	n := t.sampling.fields.len
	if n == 0 {
		return
	}
	t.sampling.sel = picker_clamp(t.sampling.sel + delta, n)
	t.dirty = true
}

fn (mut t TuiApp) sampling_start_edit() {
	if t.sampling.fields.len == 0 {
		return
	}
	t.sampling.editing = true
	t.sampling.buffer = t.sampling.values[t.sampling.sel]
	t.dirty = true
}

// sampling_commit applies the edited value; invalid input keeps the editor open
// with an error in the transcript.
fn (mut t TuiApp) sampling_commit() {
	if t.sampling.fields.len == 0 {
		return
	}
	f := t.sampling.fields[t.sampling.sel]
	mut cfg := t.app.cfg
	err := sampling_apply(mut cfg, f.key, t.sampling.buffer)
	if err != '' {
		t.push('error', err)
		return
	}
	t.app.cfg = cfg
	t.sampling.values[t.sampling.sel] = sampling_value(t.app.cfg, f.key)
	t.sampling.editing = false
	t.sampling.buffer = ''
	t.dirty = true
}

// sampling_reset clears the selected knob ('' = server default).
fn (mut t TuiApp) sampling_reset() {
	if t.sampling.fields.len == 0 {
		return
	}
	f := t.sampling.fields[t.sampling.sel]
	mut cfg := t.app.cfg
	sampling_apply(mut cfg, f.key, '')
	t.app.cfg = cfg
	t.sampling.values[t.sampling.sel] = ''
	t.dirty = true
}

// sampling_event handles keys while the `/samplings` overlay is open.
fn (mut t TuiApp) sampling_event(e &tui_std.Event) {
	if e.typ == .mouse_scroll {
		if e.direction == .up {
			t.sampling_move(-1)
		} else {
			t.sampling_move(1)
		}
		return
	}
	if e.typ != .key_down {
		return
	}
	if t.sampling.editing {
		match e.code {
			.escape {
				t.sampling.editing = false
				t.sampling.buffer = ''
			}
			.enter { t.sampling_commit() }
			.backspace {
				if t.sampling.buffer.len > 0 {
					t.sampling.buffer = t.sampling.buffer[..t.sampling.buffer.len - 1]
				}
			}
			else {
				if e.utf8 != '' && !e.utf8.starts_with('\x1b') {
					c := e.utf8[0]
					if c.is_digit() || c == `-` || c == `+` || c == `.` || c == `e` || c == `E` {
						t.sampling.buffer += e.utf8
					}
				}
			}
		}
		t.dirty = true
		return
	}
	match e.code {
		.escape { t.sampling = SamplingEditor{} }
		.enter { t.sampling_start_edit() }
		.up { t.sampling_move(-1) }
		.down { t.sampling_move(1) }
		.page_up { t.sampling_move(-10) }
		.page_down { t.sampling_move(10) }
		.r { t.sampling_reset() }
		else {}
	}
	t.dirty = true
}

// render_sampling_editor draws the `/samplings` overlay on top of the frame.
fn (mut t TuiApp) render_sampling_editor(c &tui_std.Context, w int, h int) {
	n := t.sampling.fields.len
	bw := if w - 6 > 64 { 64 } else if w - 6 > 30 { w - 6 } else { 30 }
	mut bh := n + 4
	if bh > h - 2 {
		bh = h - 2
	}
	if bh < 5 {
		bh = 5
	}
	mut x0 := (w - bw) / 2
	if x0 < 0 {
		x0 = 0
	}
	mut y0 := (h - bh) / 2
	if y0 < 1 {
		y0 = 1
	}
	c.reset_color()
	c.reset_bg_color()
	if !t.theme.mono {
		c.set_bg_color(t.theme.bubble_color('assistant'))
	}
	for r in 0 .. bh {
		c.draw_text(x0, y0 + r, ' '.repeat(bw))
	}
	if !t.theme.mono {
		c.set_color(t.theme.c('accent'))
	}
	c.draw_text(x0, y0, box_top(bw))
	c.draw_text(x0, y0 + bh - 1, box_bottom(bw))
	title := ' samplings \u00b7 ${t.sampling.profile} \u00b7 empty = server default '
	c.draw_text(x0 + 2, y0, truncate_cells(title, bw - 4))
	vis := bh - 3
	sel := picker_clamp(t.sampling.sel, n)
	mut scroll := t.sampling.scroll
	if scroll < 0 {
		scroll = 0
	}
	if scroll > n - vis {
		scroll = n - vis
	}
	if scroll < 0 {
		scroll = 0
	}
	if sel < scroll {
		scroll = sel
	}
	if sel >= scroll + vis {
		scroll = sel - vis + 1
	}
	t.sampling.scroll = scroll
	for r in 0 .. vis {
		i := scroll + r
		if i >= n {
			break
		}
		f := t.sampling.fields[i]
		marker := if i == sel { '\u25b8 ' } else { '  ' }
		mut val := t.sampling.values[i]
		if t.sampling.editing && i == sel {
			val = t.sampling.buffer + '\u258f'
		} else if val == '' {
			val = '(default)'
		}
		line := marker + fit_cells(f.key, 20) + ' ' + val
		if !t.theme.mono {
			c.set_color(if i == sel { t.theme.c('content') } else { t.theme.c('line') })
		}
		c.draw_text(x0 + 2, y0 + 1 + r, truncate_cells(line, bw - 4))
	}
	if sel >= 0 && sel < n {
		if !t.theme.mono {
			c.set_color(t.theme.c('hint'))
		}
		c.draw_text(x0 + 2, y0 + bh - 2, truncate_cells(t.sampling.fields[sel].help, bw - 4))
	}
	if !t.theme.mono {
		c.set_color(t.theme.c('hint'))
	}
	footer := if t.sampling.editing {
		' enter save \u00b7 esc cancel '
	} else {
		' \u2191/\u2193 \u00b7 enter edit \u00b7 r reset \u00b7 esc close '
	}
	c.draw_text(x0 + 2, y0 + bh - 1, truncate_cells(footer, bw - 4))
	t.set_base_bg(c)
	c.reset_color()
}

// load_conversation restores a `/save` file: it replaces the message history
// and rebuilds the transcript from it.
pub fn (mut t TuiApp) load_conversation(path string) {
	full := if os.is_abs_path(path) { path } else { os.join_path(tools.workspace_root(), path) }
	text := os.read_file(full) or {
		t.push('error', 'load failed: ${err.msg()}')
		return
	}
	msgs := json2.decode[[]Message](text) or {
		t.push('error', 'invalid conversation file: ${err.msg()}')
		return
	}
	if msgs.len == 0 {
		t.push('error', 'conversation file is empty')
		return
	}
	t.messages = msgs
	t.lines = build_transcript_lines(msgs, false)
	t.rows = []
	t.rows_n = 0
	t.view = []
	t.view_dirty = true
	t.in_fence = false
	t.stream = ''
	t.stream_kind = ''
	t.cur_tool_name = ''
	t.cur_tool_args = ''
	t.scroll = 0
	t.need_clear = true
	t.last_prompt = 0
	t.last_cached = -1
	t.last_ttft = -1
	t.last_turn_ms = 0
	t.last_tok_s = ''
	mut turns := 0
	for m in msgs {
		if m.role == 'user' {
			turns += 1
		}
	}
	t.turn_no = turns
	t.push('note', 'loaded ${msgs.len} messages from ${full}')
}

// token_fn adapts the streaming callback to the TUI queue.
pub fn (t &TuiApp) token_fn() TokenFn {
	return fn [t] (kind string, text string) {
		t.push(kind, text)
	}
}

// line_sink adapts Ui line routing to the TUI queue. Tool results are queued
// whole (they render as a block); everything else is split on newlines.
pub fn (t &TuiApp) line_sink(kind string, text string) {
	if kind == 'tool_result' {
		t.push_raw(kind, text)
	} else {
		t.push(kind, text)
	}
}

pub fn (mut t TuiApp) start_turn() {
	t.flush_stream()
	t.turn_start_ms = time.ticks()
	t.pending_user = t.input.text_str().trim_space()
	t.turn_no += 1
	stamp := if t.app.cfg.tui.timestamps { now_stamp() } else { '' }
	t.lines << TuiLine{kind: 'user', text: t.pending_user, stamp: stamp}
	t.input.clear()
	t.busy = true
	t.interrupted = false
	t.set_mood('thinking')
	t.set_phase('connecting', '')
	t.scroll = 0
	state.g_interrupt = false
	t.view_dirty = true
	t.dirty = true
	go t.run_turn()
}

// run_turn runs the agent in a goroutine. It never touches render state
// (busy/dirty/scroll/lines) directly — everything is queued via push, so
// the main thread's frame loop stays the single mutator of the display.
pub fn (mut t TuiApp) run_turn() {
	start_ms := time.ticks()
	n0 := t.messages.len
	merge_case := n0 > 0 && t.messages[n0 - 1].role == 'user'
	mut msgs := t.messages.clone()
	append_user(mut msgs, t.pending_user)
	res := run_agent(t.app, mut msgs, t.token_fn()) or {
		t.push('error', if err.msg() == 'interrupted' { '⏸ interrupted' } else { '[error] ${err.msg()}' })
		t.push('turn_end', '0|0|false|${time.ticks() - start_ms}')
		return
	}
	t.messages = res.messages // only this goroutine ever touches `messages`
	stats := res.stats
	// --- sessions autosave ---
	t.autosave_turn(n0, merge_case, stats.has_usage, stats.prompt_tokens, stats.completion_tokens)
	// The status bar already shows ctx + session tokens, so no note line.
	t.push('turn_end', '${stats.prompt_tokens}|${stats.completion_tokens}|${stats.has_usage}|${time.ticks() - start_ms}|${stats.gen_ms}|${if stats.has_cached { stats.cached_tokens } else { -1 }}|${if stats.has_ttft { stats.ttft_ms } else { -1 }}')
}

// autosave_turn persists the messages produced by the turn that just finished.
// n0 = t.messages.len before the turn. Normal turns append the new messages;
// the rare append_user-merge case rewrites the whole file to stay faithful.
fn (mut t TuiApp) autosave_turn(n0 int, merge_case bool, has_usage bool, pin int, pout int) {
	if !t.app.cfg.sessions.autosave {
		return
	}
	tin := if has_usage { pin } else { 0 }
	tout := if has_usage { pout } else { 0 }
	if t.session_id == '' {
		name := if t.session_name != '' { t.session_name } else { sessions.default_name(t.pending_user) }
		meta := sessions.create(name, tools.workspace_root(), t.app.cfg.model, t.messages[0]) or {
			t.push('error', 'autosave: ${err.msg()}')
			return
		}
		t.session_id = meta.id
		t.session_name = meta.name
	}
	if merge_case {
		sessions.save_full(t.session_id, t.messages) or {
			t.push('error', 'autosave: ${err.msg()}')
			return
		}
		if tin != 0 || tout != 0 {
			sessions.add_tokens(t.session_id, tin, tout) or {}
		}
	} else {
		sessions.append(t.session_id, t.messages[n0..], tin, tout) or {
			t.push('error', 'autosave: ${err.msg()}')
		}
	}
}

// resolve_animation picks the effective motion mode. NO_COLOR / TERM=dumb
// (theme.mono) forces motion off, so reduced-motion and dumb terminals never
// get an animated status bar.
pub fn resolve_animation(mode string, mono bool) string {
	m := if mode in ['full', 'calm', 'off'] { mode } else { 'full' }
	if mono {
		return 'off'
	}
	return m
}

pub fn run_tui(app App) ! {
	th := theme_for(app.cfg.tui)
	mut t := TuiApp{
		app:              app
		theme:            th
		pet:              load_pet(tools.config_root())
		pet_mood_ms:      time.ticks()
		show_thinking:    app.cfg.tui.thinking_default
		spin_frames:      default_spin_frames()
		spin_interval_ms: default_spin_interval_ms()
		animation:        resolve_animation(app.cfg.tui.animation, th.mono)
		anim_epoch_ms:    time.ticks()
		messages:         [Message{
			role:    'system'
			content: load_system_prompt(tools.config_root(), app.cfg)
		}]
	}
	if app.cfg.tui.input_history {
		t.input.history = load_input_history()
	}
	t.app.ui.out = t.line_sink
	if app.startup_note != '' {
		t.push('note', app.startup_note)
	}
	state.g_tui = true
	mut ui_ctx := tui_std.init(
		user_data:      &t
		frame_fn:       tui_frame
		event_fn:       tui_event
		frame_rate:     30
		capture_events: true
		mouse_enabled:  app.cfg.tui.mouse
	)
	t.handle = ui_ctx
	ui_ctx.run()!
}
