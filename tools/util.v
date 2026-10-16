module tools

import os
import x.json2

// Tunables shared by every tool. They are globals (the build already runs
// with -enable-globals) so config.json can override them at startup without a
// rebuild: max_output caps one tool result, tool_timeout caps one bash command,
// and workspace_root is the folder the file tools are fenced to (and the cwd
// bash runs in).
__global (
	tools_max_output       int = 6000 // never flood the model's context
	tools_timeout_secs     int = 120  // one bash command's wall-clock cap
	tools_workspace        string
)

// set_max_output overrides the per-result character cap.
pub fn set_max_output(n int) {
	if n > 0 {
		tools_max_output = n
	}
}

// max_output is the current per-result character cap.
pub fn max_output() int {
	return tools_max_output
}

// set_command_timeout overrides the bash command timeout, in seconds.
pub fn set_command_timeout(secs int) {
	if secs > 0 {
		tools_timeout_secs = secs
	}
}

// command_timeout_secs is the current bash command timeout.
pub fn command_timeout_secs() int {
	return tools_timeout_secs
}

// set_workspace points the file fence (and bash's working folder) at a folder
// other than the one config.json lives in. '' restores the default.
pub fn set_workspace(path string) {
	tools_workspace = path
}

// workspace_root is the folder the agent may read/write: the configured
// workspace when set, else the folder next to config.json. It is always
// canonicalized (symlinks resolved) so fence comparisons are consistent.
pub fn workspace_root() string {
	p := if tools_workspace != '' { tools_workspace } else { project_root() }
	real := os.real_path(p)
	if real != '' {
		return real
	}
	return os.abs_path(p)
}

// Key-based accessors over `map[string]json2.Any`, shared by the tools and
// the main module. Indexing an Any-valued map directly triggers V's "or {}
// block required" warning, so every read goes through these. A missing key
// behaves like null.
pub fn jget(m map[string]json2.Any, key string) json2.Any {
	return m[key] or { json2.Any(json2.Null{}) }
}

// jstr returns the string value, or '' when the key is missing or not a string.
pub fn jstr(m map[string]json2.Any, key string) string {
	v := jget(m, key)
	if v is string {
		return v
	}
	return ''
}

pub fn jint(m map[string]json2.Any, key string) int {
	return jget(m, key).int()
}

pub fn jbool(m map[string]json2.Any, key string) bool {
	return jget(m, key).bool()
}

pub fn jmap(m map[string]json2.Any, key string) ?map[string]json2.Any {
	v := jget(m, key)
	if v is map[string]json2.Any {
		return v
	}
	return none
}

pub fn jarr(m map[string]json2.Any, key string) []json2.Any {
	v := jget(m, key)
	if v is []json2.Any {
		return v
	}
	return []
}

// File tools are fenced to the folder the agent runs in, and the agent's own
// files are protected from it. The first path component is what matters:
// `tui` and `tools` cover their whole trees. The runtime files live under
// `etc/`, so that folder is protected as a whole.
const protected = ['app', 'agent', 'assets', 'cli', 'client', 'config', 'ctx', 'etc', 'pet', 'proto',
	'server', 'state', 'text', 'tui', 'ui', 'tools', 'tests', 'main.v', 'config.json', 'system.md',
	'start.sh', 'v.mod']

// project_root is the app folder: next to the binary, or next to the sources
// when running with `v run` (tools/util.v -> tools/ -> project root).
pub fn project_root() string {
	exe_dir := os.dir(os.executable())
	// The app's folder is the one holding the runtime `etc/` (or, for a legacy
	// layout, config.json/.env directly next to the binary).
	if os.exists(os.join_path(exe_dir, 'etc', 'config.json'))
		|| os.exists(os.join_path(exe_dir, 'etc', '.env'))
		|| os.exists(os.join_path(exe_dir, 'config.json')) || os.exists(os.join_path(exe_dir, '.env')) {
		return exe_dir
	}
	return os.dir(os.dir(@FILE))
}

// config_dir is where the runtime files live (`config.json`, `.env`,
// `system.md`, `pet.txt`): `<root>/etc` in the standard layout, or `<root>`
// itself for a legacy/standalone one.
pub fn config_dir(root string) string {
	etc := os.join_path(root, 'etc')
	if os.exists(os.join_path(etc, 'config.json')) || os.exists(os.join_path(etc, '.env'))
		|| os.exists(os.join_path(etc, 'system.md')) || os.exists(os.join_path(etc, 'pet.txt'))
		|| os.exists(os.join_path(etc, '.env.example')) {
		return etc
	}
	return root
}

// config_root is config_dir(project_root()), for callers that just need to
// load a runtime file without the two-step dance.
pub fn config_root() string {
	return config_dir(project_root())
}

// canonical_agent_root is project_root() resolved the same way
// workspace_root() resolves its path, so the two can be compared directly.
fn canonical_agent_root() string {
	p := project_root()
	real := os.real_path(p)
	if real != '' {
		return real
	}
	return os.abs_path(p)
}

// safe_path resolves p to an absolute path inside the fence.
//
// Returns an error if the path escapes the working folder or touches a
// protected agent file (when protect=true). real_path() also collapses ".."
// and follows symlinks, so both "../.." and a symlink pointing outside are
// caught. Relative paths are anchored to workspace_root(), not the process cwd.
pub fn safe_path(p string, protect bool) !string {
	root := workspace_root()
	mut path := p
	if path.starts_with('~') {
		path = os.join_path(os.home_dir(), path[1..])
	}
	// Relative paths are anchored to the project root, so the agent behaves
	// the same no matter which cwd it was started from.
	if !os.is_abs_path(path) {
		path = os.join_path(root, path)
	}
	abs := os.abs_path(path)
	// real_path resolves symlinks; on failure it returns the input path.
	real := os.real_path(abs)
	resolved := if real != '' { real } else { abs }
	if !inside_fence(resolved, root) {
		return error("'${p}' is outside the working folder. Resend the tool call.")
	}
	// A new file inside a symlinked folder would not be resolved above: check
	// the parent too — but only for paths that do not exist yet. For an
	// existing path real_path() has already resolved it, and for the workspace
	// root itself the parent is (correctly) outside the fence.
	if !os.exists(resolved) {
		parent := os.dir(resolved)
		preal := os.real_path(parent)
		presolved := if preal != '' { preal } else { parent }
		if !inside_fence(presolved, root) {
			return error("'${p}' is outside the working folder. Resend the tool call.")
		}
	}
	// The `protected` list names the agent's own source/config files. It only
	// makes sense when the workspace *is* the agent root (running from the
	// sources). An installed agent works on the user's project while its config
	// lives outside the fence (in ~/.usagi), so those names are ordinary files.
	if protect && root == canonical_agent_root() {
		prefix_len := root.len + 1
		rel := if resolved.len > prefix_len { resolved[prefix_len..] } else { '' }
		parts := rel.split(os.path_separator)
		if parts.len > 0 && parts[0] in protected {
			return error("'${p}' is a protected agent file. Resend the tool call.")
		}
	}
	return resolved
}

// inside_fence reports whether p is root itself or somewhere under it.
fn inside_fence(p string, root string) bool {
	return p == root || p.starts_with(root + os.path_separator)
}
