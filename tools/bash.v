module tools

import os
import time

import x.json2

// --- Guards: the model is the "user" of this shell, so fence it in. ----------
// All rejections are ERROR strings that go back to the model, which can read
// them and try again.

// 1. Allowlist: only these programs may run (checked on the first token).
const allowed_commands = ['cat', 'cp', 'diff', 'echo', 'find', 'git', 'grep', 'head',
	'ls', 'mkdir', 'mv', 'pwd', 'sed', 'sleep', 'sort', 'tail', 'touch', 'uniq', 'wc',
	'which']

// 2. Tokens that are always rejected, whatever the command (checked after the
//    quote-aware split, so they cannot be smuggled in as a quoted argument).
const blocked_tokens = ['sudo', 'mkfs', 'shutdown', 'reboot', 'dd', 'chmod', 'chown',
	'kill', 'pkill', 'curl', 'wget', 'nc', 'ncat', 'ssh', 'scp', 'rsync']

// 3. Destructive find/grep action flags.
const blocked_flags = ['-exec', '-execdir', '-ok', '-delete', '-fprintf', '-fls']

// git can execute programs (pager, editor, hooks) via flags, so only read-only
// subcommands are allowed.
const git_readonly = ['status', 'log', 'diff', 'show', 'blame', 'rev-parse', 'ls-files',
	'grep']

fn bash_schema() json2.Any {
	desc := 'Run one allowed shell command (no pipes or redirects). Allowed: ${allowed_commands.join(', ')}. Example: {"command":"ls"}'
	schema := '{"type":"function","function":{"name":"bash","description":${json2.encode(desc)},"parameters":{"type":"object","properties":{"command":{"type":"string","description":"Command to run"}},"required":["command"]}}}'
	return json2.decode[json2.Any](schema) or { json2.Any(map[string]json2.Any{}) }
}

// split_args tokenizes a command POSIX-style: whitespace separates tokens,
// 'single' and "double" quotes group them, and a backslash escapes the next
// character. This is what cmd.fields() cannot do — it turned
// `echo "hello world"` into ['echo', '"hello', 'world"'].
pub fn split_args(cmd string) []string {
	mut out := []string{}
	mut cur := []u8{}
	mut have := false
	mut in_single := false
	mut in_double := false
	rs := cmd.bytes()
	mut i := 0
	for i < rs.len {
		c := rs[i]
		if in_single {
			if c == `'` {
				in_single = false
			} else {
				cur << c
				have = true
			}
		} else if in_double {
			if c == `"` {
				in_double = false
			} else if c == `\\` && i + 1 < rs.len {
				i++
				cur << rs[i]
				have = true
			} else {
				cur << c
				have = true
			}
		} else {
			if c == `'` {
				in_single = true
				have = true
			} else if c == `"` {
				in_double = true
				have = true
			} else if c == `\\` && i + 1 < rs.len {
				i++
				cur << rs[i]
				have = true
			} else if c == ` ` || c == `\t` {
				if have {
					out << cur.bytestr()
					cur = []u8{}
					have = false
				}
			} else {
				cur << c
				have = true
			}
		}
		i++
	}
	if have {
		out << cur.bytestr()
	}
	return out
}

// first_unquoted_metachar scans the raw command for a shell operator outside
// quotes. Quoted operators are literal (arguments), so they are allowed.
fn first_unquoted_metachar(cmd string) string {
	mut in_single := false
	mut in_double := false
	mut esc := false
	for c in cmd.bytes() {
		if esc {
			esc = false
			continue
		}
		if in_single {
			if c == `'` {
				in_single = false
			}
			continue
		}
		if in_double {
			if c == `\\` {
				esc = true
			} else if c == `"` {
				in_double = false
			}
			continue
		}
		match c {
			`'` { in_single = true }
			`"` { in_double = true }
			`\\` { esc = true }
			`;` { return ';' }
			`|` { return '|' }
			`&` { return '&' }
			`>` { return '>' }
			`<` { return '<' }
			`$` { return '$' }
			`\`` { return '`' }
			`\n` { return 'newline' }
			else {}
		}
	}
	return ''
}

// looks_like_path reports whether a token is a filesystem path that should be
// checked against the workspace fence. Flags are skipped by the caller.
fn looks_like_path(tok string) bool {
	return tok == '.' || tok == '..' || tok.starts_with('/') || tok.starts_with('~')
		|| tok.contains('/') || tok.starts_with('./') || tok.starts_with('../')
}

fn bash_check(cmd string) ?string {
	parts := split_args(cmd)
	first := if parts.len > 0 { parts[0] } else { '' }
	if first !in allowed_commands {
		return "ERROR: '${first}' is not allowed. Allowed: ${allowed_commands.join(', ')}. Resend the tool call."
	}
	if first == 'git' && (parts.len < 2 || parts[1] !in git_readonly) {
		return 'ERROR: only read-only git commands are allowed: ${git_readonly.join(', ')}. Resend the tool call.'
	}
	meta := first_unquoted_metachar(cmd)
	if meta != '' {
		return 'ERROR: shell operators (; && | $ ` > <) are not allowed. Send one simple command at a time.'
	}
	for tok in parts {
		if tok in blocked_tokens {
			return "ERROR: command contains blocked token '${tok}'. Resend the tool call."
		}
		if tok in blocked_flags {
			return "ERROR: command contains blocked flag '${tok}'. Resend the tool call."
		}
		if tok.starts_with('-') {
			continue // a flag, not a path
		}
		if looks_like_path(tok) {
			// The bash tool is fenced like the file tools: absolute paths,
			// '..', '~' and protected agent files are rejected.
			safe_path(tok, true) or { return 'ERROR: ${err.msg()}' }
		}
	}
	return none
}

struct CmdOut {
	output    string
	code      int
	timed_out bool
}

// run_command runs one already-validated argv without a shell, in `cwd`, with
// stdin from /dev/null (so `cat`/`tail` cannot hang waiting for the terminal)
// and stdout+stderr merged. It drains the output pipe while polling, so a
// command that writes more than a pipe buffer cannot deadlock, and it enforces
// a hard wall-clock cap by killing the process after command_timeout_secs.
fn run_command(parts []string, cwd string) !CmdOut {
	mut p := os.new_process(parts[0])
	p.set_args(parts[1..])
	if cwd != '' {
		p.set_work_folder(cwd)
	}
	p.set_stdin_path(os.path_devnull)
	p.set_redirect_stdio_merged()
	p.run()
	timeout_ms := i64(command_timeout_secs()) * 1000
	// Keep draining forever, but only remember up to a little more than the
	// result cap, so a huge output cannot exhaust memory.
	cap := max_output() + 8192
	start := time.ticks()
	mut out := ''
	mut timed_out := false
	for p.is_alive() {
		if p.is_pending(.stdout) {
			chunk := p.stdout_read()
			if out.len < cap {
				out += chunk
			}
		} else {
			time.sleep(20 * time.millisecond)
		}
		if time.ticks() - start >= timeout_ms {
			timed_out = true
			p.signal_kill()
			break
		}
	}
	p.wait()
	out += p.stdout_slurp()
	code := p.code
	p.close()
	return CmdOut{
		output:    out
		code:      code
		timed_out: timed_out
	}
}

fn bash_exec(args map[string]json2.Any) string {
	cmd := jstr(args, 'command').trim_space()
	if cmd == '' {
		return 'ERROR: empty command. Resend the tool call.'
	}
	rejected := bash_check(cmd) or { '' }
	if rejected != '' {
		return rejected
	}
	parts := split_args(cmd)
	// os.new_process (argument array) replaces the deprecated os.execute (which
	// parsed a command string and allowed shell injection).
	res := run_command(parts, workspace_root()) or {
		return 'ERROR: failed to run ${parts[0]}: ${err.msg()}'
	}
	if res.timed_out {
		return 'ERROR: command timed out after ${command_timeout_secs()}s and was killed. Try a narrower command.'
	}
	out := res.output.trim_space()
	if out.len > max_output() {
		return out[..max_output()] + '\n...[truncated]'
	}
	if out == '' {
		return '(exit code ${res.code}, no output)'
	}
	return out
}
