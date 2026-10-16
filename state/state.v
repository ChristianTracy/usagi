module state

// Session-wide flags shared between the streaming client, the TUI and the
// line REPL. V globals are process-wide and need `-enable-globals` (the build
// already passes it). They live in their own leaf module so `client`, `tui`
// and `cli` can share them without an import cycle.

pub __global (
	g_tui       bool // TUI mode: term.ui owns the keyboard
	g_interrupt bool // set by the TUI Esc/Ctrl-C handler
	g_aborted   bool // set by on_body_chunk once a stream is interrupted
)
