module tools

import os

import x.json2

fn rejects(p string) bool {
	safe_path(p, true) or { return true }
	return false
}

fn test_safe_path() {
	inside := safe_path('some_new_file.txt', true) or { panic('inside rejected: ${err}') }
	assert inside.ends_with('some_new_file.txt')
	assert rejects('../outside.txt')
	assert rejects('config.json')
	assert rejects('etc/config.json')
	assert rejects('assets/logo.png')
	assert rejects('main.v')
	assert rejects('tui/tui.v')
	assert rejects('tools/util.v')
	assert rejects('/etc/passwd')
}

fn test_protected_only_applies_to_agent_root() {
	// An installed agent works on the user's project, where names like
	// main.v/config.json are ordinary files; only the agent's own tree is
	// protected.
	old := workspace_root()
	dir := os.join_path(os.temp_dir(), 'usagi_ws_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		set_workspace(old)
		os.rmdir_all(dir) or {}
	}
	set_workspace(dir)
	p1 := safe_path('main.v', true) or { panic('main.v rejected outside agent root: ${err}') }
	assert p1.ends_with('main.v')
	p2 := safe_path('config.json', true) or {
		panic('config.json rejected outside agent root: ${err}')
	}
	assert p2.ends_with('config.json')
}

fn test_parse_args() {
	m := parse_args('{"path":"a.txt"}') or { panic('parse failed') }
	assert jstr(m, 'path') == 'a.txt'
	assert parse_args('not json') == none
	if empty := parse_args('   ') {
		assert empty.len == 0
	} else {
		assert false
	}
}

fn test_single_string_param() {
	assert single_string_param('bash') or { '' } == 'command'
	assert single_string_param('read_file') or { '' } == 'path'
	assert single_string_param('write_file') == none
	assert single_string_param('edit_file') == none
	assert single_string_param('nope') == none
}

fn test_normalize_args_strips_over_quoted_values() {
	mut a := map[string]json2.Any{}
	a['path'] = '"index.html"'
	a['command'] = '"tail -n 5 x.txt"'
	a['old_text'] = '"keep me"'
	normalize_args(mut a)
	assert jstr(a, 'path') == 'index.html'
	assert jstr(a, 'command') == 'tail -n 5 x.txt'
	// content-like params are left untouched
	assert jstr(a, 'old_text') == '"keep me"'
}

fn test_execute_normalizes_over_quoted_path() {
	dir := os.join_path(project_root(), 'test_tmp_files')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'q.txt'), 'hi\n') or { panic(err) }
	// The model's value literally contains the quotes; encode() produces
	// {"path":"\"test_tmp_files/q.txt\""}.
	mut quoted := map[string]json2.Any{}
	quoted['path'] = '"test_tmp_files/q.txt"'
	res := execute(ToolCall{
		name:      'read_file'
		arguments: json2.encode(quoted)
	}, false)
	assert res == 'hi'
}

fn test_bash_guards() {
	assert bash_check('ls') == none
	assert bash_check('git status') == none
	assert bash_check('rm -rf /') != none
	assert bash_check('ls; rm -rf /') != none
	assert bash_check('cat a | grep b') != none
	assert bash_check('echo hi > out.txt') != none
	assert bash_check('git push origin main') != none
	assert bash_check('find . -delete') != none
	assert (bash_check('sudo ls') or { '' }).contains('not allowed')
	assert (bash_check('ls -la && sudo rm') or { '' }).contains('shell operators')
}

fn test_write_read_edit() {
	dir := os.join_path(project_root(), 'test_tmp_files')
	os.mkdir_all(dir) or { panic(err) }
	path := 'test_tmp_files/a.txt'
	mut wargs := map[string]json2.Any{}
	wargs['path'] = path
	wargs['content'] = 'one\ntwo\nthree\n'
	assert write_file_exec(wargs).starts_with('Wrote 14 chars to ${path}.')
	mut rargs := map[string]json2.Any{}
	rargs['path'] = path
	assert read_file_exec(rargs) == 'one\ntwo\nthree'
	mut eargs := map[string]json2.Any{}
	eargs['path'] = path
	eargs['old_text'] = 'two'
	eargs['new_text'] = 'TWO'
	assert edit_file_exec(eargs).starts_with('Edited')
	text := os.read_file(os.join_path(project_root(), path)) or { '' }
	assert text == 'one\nTWO\nthree\n'
	os.rmdir_all(dir) or {}
}

fn test_bash_exec() {
	mut args := map[string]json2.Any{}
	args['command'] = 'echo hi'
	assert bash_exec(args) == 'hi'
	args['command'] = 'rm -rf /'
	assert bash_exec(args).starts_with('ERROR')
}

fn test_split_args_quoting() {
	assert split_args('echo "hello world"') == ['echo', 'hello world']
	assert split_args("find . -name '*.v'") == ['find', '.', '-name', '*.v']
	assert split_args('a  b\tc') == ['a', 'b', 'c']
	assert split_args('') == []
	assert split_args(r'echo a\ b') == ['echo', 'a b']
}

fn test_bash_quoted_metachars_allowed() {
	// quoted operators are literal arguments, not shell syntax
	assert bash_check('echo "a | b"') == none
	assert bash_check("grep 'x; y' notes.txt") == none
	// but unquoted ones are still rejected
	assert bash_check('echo a | b') != none
	assert bash_check('echo a ; b') != none
}

fn test_bash_path_fence() {
	assert bash_check('cat /etc/passwd') != none
	assert bash_check('cat ../../etc/passwd') != none
	assert bash_check('cp x.txt tui/tui.v') != none
	assert bash_check('mkdir newdir') == none
	assert bash_check('ls -la .') == none
}

fn test_fuzzy_replace() {
	text := 'def f():\n    x = 1\n    return x\n'
	// model copied the body without the 4-space indent
	got := fuzzy_replace(text, 'x = 1\nreturn x', 'x = 2\nreturn x + 1') or {
		panic('fuzzy_replace returned none')
	}
	assert got == 'def f():\n    x = 2\n    return x + 1\n'
	// a non-match yields none
	assert fuzzy_replace(text, 'nope', 'x') == none
}

fn test_max_output_tunable() {
	old := max_output()
	set_max_output(1234)
	assert max_output() == 1234
	set_max_output(old)
}

fn test_bash_runs_in_workspace() {
	mut args := map[string]json2.Any{}
	args['command'] = 'pwd'
	assert bash_exec(args).trim_space() == workspace_root()
}

fn test_bash_timeout_kills_command() {
	old := command_timeout_secs()
	set_command_timeout(1)
	mut args := map[string]json2.Any{}
	// sleep reliably outlives the 1 s cap.
	args['command'] = 'sleep 5'
	res := bash_exec(args)
	set_command_timeout(old)
	assert res.starts_with('ERROR: command timed out')
}

fn test_read_file_rejects_binary() {
	dir := os.join_path(project_root(), 'test_tmp_files')
	os.mkdir_all(dir) or { panic(err) }
	path := 'test_tmp_files/bin.dat'
	os.write_file(os.join_path(project_root(), path), 'ab\x00cd') or { panic(err) }
	mut args := map[string]json2.Any{}
	args['path'] = path
	res := read_file_exec(args)
	os.rmdir_all(dir) or {}
	assert res.starts_with('ERROR: ${path} looks like a binary file')
}

fn test_bash_drains_large_output() {
	// Regression: the output pipe must be drained while waiting, or a command
	// writing more than a pipe buffer blocks until the timeout.
	dir := os.join_path(project_root(), 'test_tmp_files')
	os.mkdir_all(dir) or { panic(err) }
	path := 'test_tmp_files/big.txt'
	os.write_file(os.join_path(project_root(), path), 'x'.repeat(200000)) or { panic(err) }
	old_out := max_output()
	set_max_output(500000)
	mut args := map[string]json2.Any{}
	args['command'] = 'cat ${path}'
	res := bash_exec(args)
	set_max_output(old_out)
	os.rmdir_all(dir) or {}
	assert !res.starts_with('ERROR')
	assert res.len >= 200000
}
