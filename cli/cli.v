module cli

import os
import tools
import app { App }
import agent { probe_context, run_repl }
import config { Config, SessionsConfig, load_config }
import sessions
import server { probe_backend, resolve_default_model }
import tui { run_tui }
import ui { Ui }

// apply_tool_config pushes the config tunables into the tools package
// (which cannot import us, so the values are set here instead).
fn apply_tool_config(root string, cfg Config) {
	if cfg.max_tool_output > 0 {
		tools.set_max_output(cfg.max_tool_output)
	}
	if cfg.tool_timeout > 0 {
		tools.set_command_timeout(cfg.tool_timeout)
	}
	if cfg.workspace != '' {
		ws := if os.is_abs_path(cfg.workspace) { cfg.workspace } else { os.join_path(root, cfg.workspace) }
		tools.set_workspace(ws)
	}
}

// cli_workspace returns the workspace requested on the command line: a
// positional directory (`usagi .`, `usagi /folder`) or `--workspace DIR`
// (`-w DIR`, `--workspace=DIR`). '' means "no override".
fn cli_workspace() string {
	args := os.args[1..]
	mut i := 0
	for i < args.len {
		a := args[i]
		if a == '--workspace' || a == '-w' {
			if i + 1 >= args.len {
				eprintln('error: ${a} needs a directory')
				exit(2)
			}
			return args[i + 1]
		}
		if a.starts_with('--workspace=') {
			return a.all_after('--workspace=')
		}
		if !a.starts_with('-') {
			return a
		}
		i += 1
	}
	return ''
}

// resolve_workspace_arg expands a leading `~` and makes the path absolute
// relative to the process cwd, so `usagi .` means "the folder I am in".
fn resolve_workspace_arg(raw string) string {
	p := raw.trim_space()
	if p == '' {
		return ''
	}
	mut path := p
	if path.starts_with('~') {
		path = os.join_path(os.home_dir(), path[1..].trim_left('/\\'))
	}
	return os.abs_path(path)
}

// sessions_housekeeping reconciles orphans and prunes old sessions in the
// background so startup is never delayed by disk work.
fn sessions_housekeeping(s SessionsConfig) {
	sessions.cleanup() or {}
	sessions.prune(s.max, s.max_age_days) or {}
}

pub fn run() {
	root := tools.project_root()
	mut cfg := load_config(tools.config_dir(root))
	// A workspace given on the command line wins over config.json and $WORKSPACE.
	ws := cli_workspace()
	if ws != '' {
		path := resolve_workspace_arg(ws)
		if path == '' || !os.is_dir(path) {
			eprintln('error: not a directory: ${ws}')
			exit(2)
		}
		cfg.workspace = path
	}
	// No explicit workspace (CLI, $WORKSPACE or config.json): work on the folder
	// the agent was started from, like pi/opencode — never on the config/install
	// directory.
	if cfg.workspace == '' {
		cfg.workspace = os.getwd()
	}
	apply_tool_config(root, cfg)
	// Sessions: resolve the dir (relative -> workspace) and set it once, then
	// run housekeeping (orphan cleanup + prune) in the background.
	if cfg.sessions.dir != '' {
		mut d := cfg.sessions.dir
		if !os.is_abs_path(d) {
			d = os.join_path(cfg.workspace, d)
		}
		sessions.set_dir(d)
	}
	spawn sessions_housekeeping(cfg.sessions)
	// MODEL is optional: when it is not set, pick one from `/v1/models` (the
	// loaded model on a llama.cpp router, else the first advertised).
	mut startup_note := ''
	if cfg.model == '' {
		model := resolve_default_model(cfg)
		if model == '' {
			eprintln('error: MODEL is not set and no models were reported by ${cfg.base_url.trim_right('/')}/models')
			eprintln('       set MODEL in .env or config.json (or check BASE_URL)')
			exit(2)
		}
		cfg.model = model
		startup_note = 'MODEL not set; using "${model}" (use /model to pick another)'
	}
	// Identify the endpoint (omlx / llama.cpp / generic) in the background so a
	// slow or unreachable server never delays startup.
	spawn probe_backend(cfg)
	my_app := App{
		cfg: cfg
		ui: Ui{
			debug:  '--debug' in os.args
			colors: cfg.colors
		}
		url: cfg.base_url.trim_right('/') + '/chat/completions'
		startup_note: startup_note
	}
	ui.g_ui = my_app.ui
	// Probe the context length in the background; the window stays 0 until it
	// arrives, and the UI simply omits the ctx bar until then.
	spawn probe_context(cfg)
	// TUI on a TTY; classic line-based REPL when piped or NO_TUI=1.
	if os.is_atty(0) > 0 && os.getenv('NO_TUI') == '' {
		run_tui(my_app) or {
			eprintln('TUI failed (${err.msg()}); falling back to line REPL')
			run_repl(my_app)
		}
	} else {
		run_repl(my_app)
	}
}
