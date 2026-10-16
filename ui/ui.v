module ui

import os
import config { Colors }

// Small terminal helper: colorized output and debug lines.
// In TUI mode `out` (a line sink) is set and every line is routed there
// instead of stdout, so the TUI can render it in its transcript.
pub type LineSink = fn (kind string, text string)

pub struct Ui {
	pub mut:
	debug  bool
	colors Colors
	out    LineSink = unsafe { nil }
}

// g_ui is the process-wide UI (set once at startup). It lives here so the
// client and the agent can reach it across module boundaries.
pub __global g_ui = Ui{}

// style wraps text in its configured ANSI color (plain when piped).
pub fn (u Ui) style(kind string, text string) string {
	code := match kind {
		'content' { u.colors.content }
		'thinking' { u.colors.thinking }
		'tool' { u.colors.tool }
		'debug' { u.colors.debug }
		else { '2' }
	}
	if os.is_atty(1) > 0 {
		return '\x1b[${code}m${text}\x1b[0m'
	}
	return text
}

// dbg prints a debug line (only in --debug mode), to stderr so stdout stays clean.
pub fn (u Ui) dbg(msg string) {
	if u.debug {
		eprintln(u.style('debug', '[debug] ${msg}'))
	}
}

// emit prints one line: through the TUI sink when set, else to stdout styled.
pub fn (u Ui) emit(kind string, text string) {
	if u.out != unsafe { nil } {
		u.out(kind, text)
	} else {
		println(u.style(kind, text))
	}
}

// print_raw mirrors print() in plain mode. The TUI renders its own layout
// (color-coded transcript, no prefixes), so this is a no-op there.
pub fn (u Ui) print_raw(text string) {
	if u.out != unsafe { nil } {
		return
	} else {
		print(text)
	}
}

// line prints a plain (unstyled) line in either mode.
pub fn (u Ui) line(text string) {
	if u.out != unsafe { nil } {
		u.out('line', text)
	} else {
		println(text)
	}
}

// note prints a dim status line.
pub fn (u Ui) note(text string) {
	u.emit('thinking', text)
}
