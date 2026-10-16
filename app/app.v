module app

import config { Config }
import ui { Ui }

// App is the runtime context threaded through the agent loop and the client:
// the resolved config, the output sink, the chat-completions URL and the
// per-turn tool_choice override. It lives in its own module so both `client`
// (which needs it to build a request) and `agent` (which owns the loop) can
// use it without a cycle.

pub struct App {
pub mut:
	cfg Config
	ui  Ui
	url string
	// tool_choice is a per-turn override applied by run_agent (empty = use
	// cfg.tool_choice). Used to force a tool call after a malformed one.
	tool_choice string
	// startup_note is a one-off message shown when the session starts (e.g. the
	// model picked automatically because MODEL was not set).
	startup_note string
}
