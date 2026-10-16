module main

import os
import tools
import pet { load_pet, mood_name, pet_frame_for }

// The status-bar pet is parsed from pet.txt: three lines per frame, frames
// separated by blank lines. Only the face is kept; the trailing label on the
// middle line names the mood.

fn test_load_pet() {
	d := os.join_path(tools.project_root(), 'test_tmp_files', 'pet')
	os.rmdir_all(d) or {}
	os.mkdir_all(d) or {}
	os.write_file(os.join_path(d, 'pet.txt'), ' (\\_/)\n (o,o)  $ _   idle\n (" )(")\n\n (\\_/)\n (-,-)  blink\n (" )(")\n') or {}
	p := load_pet(d)
	assert p.frames.len == 2
	// only the face is kept
	assert p.frames[0].mid == ' (o,o)'
	assert p.frames[1].mid == ' (-,-)'
	// the label names the frame
	assert p.frames[0].name == 'idle'
	assert p.frames[1].name == 'blink'
	assert p.width() > 0
	// lookup by mood name, with a fallback
	assert p.by_name('blink').mid == ' (-,-)'
	assert p.by_name('nope').mid == ' (o,o)'
	os.rmdir_all(d) or {}
}

fn test_load_pet_missing() {
	p := load_pet(os.join_path(tools.project_root(), 'test_tmp_files', 'nope_pet'))
	assert p.frames.len == 0
	assert p.width() == 0
	assert p.by_name('idle').mid == ''
}

fn test_mood_name() {
	assert mood_name('thinking') == 'focus'
	assert mood_name('writing') == 'parsing'
	assert mood_name('tool') == 'deploy'
	assert mood_name('reading') == 'squint'
	assert mood_name('error') == 'crashed'
	assert mood_name('interrupt') == 'alarm'
	assert mood_name('done') == 'green'
	assert mood_name('asleep') == 'asleep'
	assert mood_name('idle') == 'idle'
	assert mood_name('whatever') == 'idle'
}

fn test_pet_frame_for() {
	d := os.join_path(tools.project_root(), 'test_tmp_files', 'pet_moods')
	os.rmdir_all(d) or {}
	os.mkdir_all(d) or {}
	mut body := ''
	for name in ['idle', 'blink', 'focus', 'squint', 'parsing', 'deploy', 'alarm', 'crashed', 'green', 'asleep'] {
		body += ' (\\_/)\n (o,o)  ${name}\n (" )(")\n\n'
	}
	os.write_file(os.join_path(d, 'pet.txt'), body) or {}
	p := load_pet(d)
	// active moods alternate, but always start on their primary face
	assert pet_frame_for(p, 'idle', 0).name == 'idle'
	assert pet_frame_for(p, 'idle', 45).name == 'blink'
	assert pet_frame_for(p, 'thinking', 0).name == 'focus'
	assert pet_frame_for(p, 'thinking', 20).name == 'squint'
	assert pet_frame_for(p, 'writing', 0).name == 'parsing'
	assert pet_frame_for(p, 'tool', 0).name == 'deploy'
	// reactive moods stay put
	assert pet_frame_for(p, 'interrupt', 0).name == 'alarm'
	assert pet_frame_for(p, 'interrupt', 99).name == 'alarm'
	assert pet_frame_for(p, 'error', 0).name == 'crashed'
	assert pet_frame_for(p, 'done', 0).name == 'green'
	assert pet_frame_for(p, 'asleep', 0).name == 'asleep'
	os.rmdir_all(d) or {}
}
