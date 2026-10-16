module ctx

import sync
import config { Config }
import proto { Message }

// Context budget: pure functions that decide what to actually send (aging old
// tool results, dropping whole old turns) plus the global holding the model's
// context window, probed in the background at startup.

__global g_window int // model context length; filled by a background probe
__global g_window_mu sync.Mutex

// window_size returns the probed model context length (0 while unknown).
// Guarded by a mutex because the background probe writes it from its own
// thread while the render/repl threads read it.
pub fn window_size() int {
	g_window_mu.lock()
	n := g_window
	g_window_mu.unlock()
	return n
}

pub fn set_window_size(n int) {
	g_window_mu.lock()
	g_window = n
	g_window_mu.unlock()
}

// estimate_tokens is a rough prompt-size estimate (~4 chars/token plus a
// small per-message overhead); it never has to be exact, it only drives when
// to age old tool output and drop old turns.
fn estimate_tokens(messages []Message) int {
	mut n := 0
	for m in messages {
		n += m.content.len / 4 + 4
		for tc in m.tool_calls {
			n += (tc.arguments.len + tc.name.len) / 4 + 4
		}
	}
	return n
}

// age_old_tool_results rewrites tool messages older than the *current* user
// turn to a one-line stub, so a few big read_file results cannot fill the
// window. The stored history is untouched: this runs on a copy in build_body.
pub fn age_old_tool_results(mut msgs []Message) {
	mut user_idxs := []int{}
	for i, m in msgs {
		if m.role == 'user' {
			user_idxs << i
		}
	}
	if user_idxs.len == 0 {
		return
	}
	cutoff := user_idxs[user_idxs.len - 1] // start of the current turn
	for i in 1 .. cutoff {
		if msgs[i].role == 'tool' && msgs[i].content.len > 300 {
			msgs[i].content = '[tool result omitted to save context — ${msgs[i].content.len} chars]'
		}
	}
}

// trim_old_turns drops whole oldest turns (a user message and everything up
// to the next user message, so tool_call/tool pairs stay intact) until the
// estimate fits `budget`. The current turn is never dropped.
pub fn trim_old_turns(mut msgs []Message, budget int) {
	for estimate_tokens(msgs) > budget {
		mut first_user := -1
		for i := 1; i < msgs.len; i++ {
			if msgs[i].role == 'user' {
				first_user = i
				break
			}
		}
		if first_user < 0 {
			break
		}
		mut next_user := -1
		for i := first_user + 1; i < msgs.len; i++ {
			if msgs[i].role == 'user' {
				next_user = i
				break
			}
		}
		if next_user < 0 {
			break // only the current turn remains
		}
		msgs.delete_many(first_user, next_user - first_user)
	}
}

// trim_for_request returns the message list to actually send: old tool
// results aged, then whole old turns dropped above ~75% of the context
// window. When the window is unknown, only the lightweight aging runs.
pub fn trim_for_request(messages []Message, cfg Config) []Message {
	mut msgs := messages.clone()
	age_old_tool_results(mut msgs)
	window := if cfg.context_length > 0 { cfg.context_length } else { window_size() }
	if window > 0 {
		trim_old_turns(mut msgs, window * 3 / 4)
	}
	return msgs
}
