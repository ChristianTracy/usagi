# sessions.md — SPEC de implementación (v1)

Sistema de sesiones guardadas (`/sessions`, `/resume`, `/session …`) para usagi.
Este documento es una **spec completa y autocontenida**: un agente de código
puede implementar v1 sin tomar decisiones de diseño. Cada decisión está
resuelta y se referencia la API exacta de V 0.5.2 (verificada contra vlib).

> Reglas para el implementador:
> 1. Leer este documento entero antes de tocar código.
> 2. Seguir el orden del §16. Cada paso compila y los tests pasan.
> 3. Construir con `v -enable-globals -o usagi .` (igual que `start.sh`).
> 4. Correr tests con `v -enable-globals test .`.

---

## 1. Objetivo y alcance (v1)

Persistir conversaciones de forma **liviana y rápida**, manteniendo el espíritu
del proyecto: V + stdlib, binario estático, **cero dependencias nuevas**.

En v1:

- Autosave de la sesión activa tras cada turno (append, sin reescribir).
- `/sessions [filtro]` — lista sesiones guardadas.
- `/resume <id|nombre>` — retoma una sesión (historial + transcript + stats + workspace).
- `/session new|save|title|rename|rm|clean` — gestión.
- `/save [file]` y `/load <file>` se conservan (export/import manual portable).

Fuera de v1 (documentado en §15): compactación, picker para `/resume` sin arg,
paridad de comandos en el REPL por líneas.

---

## 2. Decisiones ya tomadas (decision log)

| # | Decisión | Elección | Razón |
|---|---|---|---|
| D1 | Formato del payload | JSONL: 1 línea = 1 `Message` | Append O(1) por turno; legible; reutiliza `json2` |
| D2 | Índice | `index.json` (manifiesto chico) | Listar O(1), sin escanear archivos |
| D3 | Ubicación | `~/.usagi/sessions/` por defecto | Un solo lugar global, no ensucia el repo |
| D4 | Override de ubicación | env `USAGI_SESSIONS_DIR` > `cfg.sessions.dir` | `dir` relativo se resuelve contra el workspace |
| D5 | Qué se guarda | Solo `[]Message` + metadatos | El transcript se reconstruye; es lo mínimo |
| D6 | Workspace en `/resume` | Se **restaura** el guardado (por defecto) | Evita editar el proyecto equivocado |
| D7 | Autosave | Append de los mensajes nuevos del turno | O(nuevas), no O(n) |
| D8 | Merge de `append_user` | Caso raro → `save_full` (reescribe) | El log sigue fiel a `t.messages` |
| D9 | Escritura del índice | `tmp` + `os.rename` (atómico) | No deja `index.json` a medias |
| D10 | IDs | `${unix}-${rand.hex(4)}` | Únicos, ordenables, cortos |
| D11 | Borrado/limpieza | `/session rm`, `rm --all`, `max`, `max_age_days`, `cleanup` | Ver §6 |
| D12 | `/clear` | Equivale a "nueva sesión" (desvincula) | Ver §14 |
| D13 | Concurrencia | Last-write-wins del índice | Ver §14 |
| D14 | System.md cambiado | Se conserva el `system` guardado | Fidelidad; opción futura `reload_system` |
| D15 | Compactación | Fuera de v1 | Ver §7 y §15 |

---

## 3. Estado actual del código (lo que ya existe)

- `proto/proto.v` — `Message { role, content, tool_calls []ToolCall, tool_call_id }` y `ToolCall { id, name, arguments }`.
- `tui/tui.v`
  - `handle_command(cmd)` (~línea 1352): match de comandos `/`. Ya están `/clear`, `/save`, `/load`, etc.
  - `load_conversation(path)` (~1875): lee un array JSON y reconstruye `lines` con `build_transcript_lines`.
  - `run_turn()` (~1956): clona `t.messages`, `append_user`, `run_agent`, y al final `t.messages = res.messages`.
  - `TuiApp` tiene `messages []Message`, `lines []TuiLine`, `sess_in/sess_out int`, `turn_no int`, etc.
  - `tui_frame` guarda el historial de input con `save_input_history` al salir.
- `tui/input_edit.v` — `tui_commands` (const) para tab-completion; `parse_command(cmd)`.
- `config/config.v` — `Config` (con `tui TuiConfig`), `apply_env_overrides`, helpers `env_str/env_bool/env_int`.
- `cli/cli.v` — `run()`: resuelve workspace, `apply_tool_config`, `spawn probe_backend`, `spawn probe_context`, elige TUI/REPL.
- `tools/util.v` — `workspace_root()`, `config_root()`, `project_root()`, `config_dir()`, `set_workspace()`.
- `ctx/ctx.v` — `trim_for_request` recorta el contexto **al enviar** (copia; no toca lo guardado).

---

## 4. Formato de almacenamiento (spec exacta)

```
~/.usagi/sessions/
├── index.json          # manifiesto
└── <id>.jsonl          # una sesión por archivo (payload)
```

### 4.1 `index.json` (manifiesto)

```json
{
  "version": 1,
  "sessions": [
    {
      "id": "1730000123-a1b2",
      "name": "fix login bug",
      "created": 1730000000,
      "updated": 1730000120,
      "workspace": "/home/me/proj",
      "model": "qwen2.5-coder-7b",
      "messages": 42,
      "bytes": 23180,
      "tokens_in": 120000,
      "tokens_out": 9000,
      "file": "1730000123-a1b2.jsonl"
    }
  ]
}
```

- `id` = `${time.unix_now()}-${rand.hex(4)}` (único y ordenable para un usuario).
- `file` = `${id}.jsonl`.
- `updated`, `messages`, `bytes`, `tokens_in/out` se refrescan en cada append.
- Escritura **atómica**: escribir `index.json.tmp` y luego `os.rename`.

### 4.2 `<id>.jsonl` (payload)

**Una línea física = un `Message`** serializado con `json2.encode(m, json2.EncoderOptions{})`
(sin `prettify`). Los `\n` internos del content quedan escapados como `\n`, así
que cada mensaje ocupa exactamente una línea física.

```
{"role":"system","content":"You are a coding assistant.","tool_calls":[],"tool_call_id":""}
{"role":"user","content":"arregla el login","tool_calls":[],"tool_call_id":""}
{"role":"assistant","content":"","tool_calls":[{"id":"call_1","name":"read_file","arguments":"{\"path\":\"auth.go\"}"}],"tool_call_id":""}
{"role":"tool","content":"...","tool_calls":[],"tool_call_id":"call_1"}
{"role":"assistant","content":"listo","tool_calls":[],"tool_call_id":""}
```

Notas:
- `json2.encode` emite `tool_calls: []` y `tool_call_id: ""` aunque estén vacíos
  (verificado). Es aceptable: `json2.decode[Message]` rellena los campos
  ausentes con zero-values, así que el roundtrip es fiel. (Optimización
  opcional futura: serializar vía `proto.message_to_any` para omitir vacíos.)
- La primera línea es el `system` (se escribe en `create`).
- Autosave normal = `os.open_append` + `write_string(chunk)` + `close`.
- Decodificar = leer, `split('\n')`, `json2.decode[Message](line)` por línea,
  ignorar líneas vacías o inválidas (la última línea a medio escribir se ignora).

### 4.3 Atomicidad / crash-safety

- Append JSONL: una línea = un `write_string` (si se corta, se pierde solo el último mensaje).
- `save_full` y `write_manifest`: `tmp` + `os.rename` (atómico en POSIX).

---

## 5. Workspace y `/resume` (semántica exacta)

**Todas las sesiones van al mismo lugar** (`~/.usagi/sessions/`) sin importar
desde qué carpeta se lance `usagi`. Cada `Meta` guarda el `workspace` con el
que se creó la sesión.

Escenario: `usagi /folder1` → charlas → sales → `cd folder2` → `usagi` →
`/resume <sesión de folder1>`.

Por defecto `/resume` **restaura el workspace guardado** (vuelve a fencear las
herramientas a `/folder1`) y muestra:

```
note: resumed "fix login bug" (1730000123-a1b2, 42 msgs, workspace /folder1)
```

Reglas (implementadas en `resume_session`, §11.5):

- Si el workspace guardado ya no existe → aviso y se mantiene el workspace actual.
- `sessions.restore_workspace=false` (o `USAGI_RESTORE_WORKSPACE=0`) desactiva el cambio.
- Implementación: `tools.set_workspace(meta.workspace)` + `t.app.cfg.workspace = meta.workspace`.

`/sessions` lista **todas** las sesiones de todos los workspaces y acepta filtro.

---

## 6. Limpieza y borrado

1. **Manual**: `rm ~/.usagi/sessions/<id>.jsonl` (el índice se regenera; no rompe nada).
2. `/session rm <id>` — borra `.jsonl` + entrada del índice.
3. `/session rm --all` — borra todas (el flag `--all` es la confirmación explícita).
4. **Poda por cantidad**: `sessions.max` (default 50). En el arranque se borran las más viejas si se supera el cap.
5. **Poda por antigüedad**: `sessions.max_age_days` (0 = off). En el arranque se borran sesiones sin actividad en N días.
6. **Huérfanos**: `sessions.cleanup()` (+ `/session clean`) reconcilia índice vs archivos.

El borrado y la poda **solo tocan `~/.usagi/sessions/`**, nunca el workspace del usuario.

---

## 7. Sesiones grandes y compactación (futuro, NO en v1)

**Qué pasa hoy con una sesión muy grande** (dos planos separados):

1. **En disco**: el `.jsonl` crece sin límite por-sesión (append). No hay tope de
   bytes por sesión; `sessions.max`/`max_age_days` podan sesiones *enteras*.
   `/resume` parsea todo el archivo (O(n), milisegundos incluso a varios MB).
2. **Al enviar**: `ctx.trim_for_request()` (ya existe) recorta el contexto **al
   enviar**, sin tocar lo guardado: `age_old_tool_results` → stubs de tool
   results viejos; `trim_old_turns` → descarta turnos hasta ~75% de la ventana.

El problema real es el **contexto**: los turnos viejos se pierden en silencio.
La solución futura es **compactar** (sustituir turnos viejos por un resumen), ver §15.

---

## 8. Módulo nuevo: `sessions/sessions.v` (código completo)

Crear el archivo `sessions/sessions.v` con **exactamente** este contenido:

```v
module sessions

// Saved sessions: a lightweight JSONL store (one file per session, one JSON
// line per message) plus a small index.json manifest for O(1) listing.
// Stdlib only — no new dependencies.

import os
import rand
import time
import x.json2
import proto { Message }

__global g_dir string

pub struct Meta {
pub mut:
	id         string
	name       string
	created    i64
	updated    i64
	workspace  string
	model      string
	messages   int
	bytes      int
	tokens_in  int
	tokens_out int
	file       string
}

pub struct Manifest {
pub mut:
	version  int = 1
	sessions []Meta
}

// set_dir overrides the default location (called once from cli.run() with
// cfg.sessions.dir, resolved against the workspace when relative).
pub fn set_dir(d string) {
	g_dir = d
}

// dir returns the sessions directory: set_dir() > USAGI_SESSIONS_DIR > default.
pub fn dir() string {
	if g_dir != '' {
		return g_dir
	}
	env := os.getenv('USAGI_SESSIONS_DIR')
	if env != '' {
		return env
	}
	return os.join_path(os.home_dir(), '.usagi', 'sessions')
}

fn index_path() string {
	return os.join_path(dir(), 'index.json')
}

fn session_path(id string) string {
	return os.join_path(dir(), '${id}.jsonl')
}

// new_id: sortable and unique enough for a single user (unix seconds + 4 hex
// chars from rand, which is auto-seeded with time).
pub fn new_id() string {
	return '${time.unix_now()}-${rand.hex(4)}'
}

// default_name derives a session name from the first user message.
pub fn default_name(text string) string {
	s := text.trim_space()
	nl := s.index('\n') or { s.len }
	mut first := s[..nl].trim_space()
	if first == '' {
		return 'session'
	}
	r := first.runes()
	if r.len > 40 {
		first = r[..40].string()
	}
	return first
}

// age_str formats "hace Xm/h/d" for listing.
pub fn age_str(updated i64) string {
	d := time.unix_now() - updated
	if d < 60 {
		return 'ahora'
	}
	if d < 3600 {
		return 'hace ${d / 60}m'
	}
	if d < 86400 {
		return 'hace ${d / 3600}h'
	}
	return 'hace ${d / 86400}d'
}

// encode_line serializes one message as a single JSON line (newlines inside
// content are escaped by the encoder, so it stays one physical line).
fn encode_line(m Message) string {
	return json2.encode(m, json2.EncoderOptions{})
}

fn read_manifest() Manifest {
	p := index_path()
	if !os.exists(p) {
		return Manifest{}
	}
	text := os.read_file(p) or { return Manifest{} }
	return json2.decode[Manifest](text) or { Manifest{} }
}

fn write_manifest(m Manifest) ! {
	os.mkdir_all(dir()) or { return err }
	tmp := os.join_path(dir(), 'index.json.tmp')
	os.write_file(tmp, json2.encode(m, json2.EncoderOptions{prettify: true}))!
	os.rename(tmp, index_path())!
}

// list returns the manifest sessions sorted by `updated` desc (newest first).
pub fn list() Manifest {
	m := read_manifest()
	mut s := m.sessions.clone()
	s.sort_with_compare(fn (a &Meta, b &Meta) int {
		return if a.updated > b.updated { -1 } else if a.updated < b.updated { 1 } else { 0 }
	})
	return Manifest{
		version:  m.version
		sessions: s
	}
}

// find resolves a query to one session: exact id, unique id prefix, exact
// name, or unique name substring. Errors when not found or ambiguous.
pub fn find(query string) !Meta {
	q := query.trim_space()
	if q == '' {
		return error('usage: /resume <id|nombre> (use /sessions to list)')
	}
	m := list()
	mut by_id := []Meta{}
	mut by_name := []Meta{}
	for meta in m.sessions {
		if meta.id == q || meta.id.starts_with(q) {
			by_id << meta
		}
		if meta.name == q || meta.name.contains(q) {
			by_name << meta
		}
	}
	if by_id.len == 1 {
		return by_id[0]
	}
	if by_id.len == 0 && by_name.len == 1 {
		return by_name[0]
	}
	if by_id.len == 0 && by_name.len == 0 {
		return error('no session matches "${q}"')
	}
	return error('"${q}" matches several sessions — use the id')
}

// load reads a session file line by line. A trailing incomplete line (crash
// mid-write) is ignored.
pub fn load(id string) ![]Message {
	text := os.read_file(session_path(id))!
	mut out := []Message{}
	for raw in text.split('\n') {
		line := raw.trim_right('\r')
		if line == '' {
			continue
		}
		msg := json2.decode[Message](line) or { continue }
		out << msg
	}
	if out.len == 0 {
		return error('session ${id} is empty')
	}
	return out
}

// create writes the system message as line 1 and registers the session.
pub fn create(name string, workspace string, model string, system_msg Message) !Meta {
	os.mkdir_all(dir()) or { return err }
	id := new_id()
	line := encode_line(system_msg) + '\n'
	os.write_file(session_path(id), line)!
	now := time.unix_now()
	name_ := if name.trim_space() != '' { name.trim_space() } else { 'session' }
	meta := Meta{
		id:        id
		name:      name_
		created:   now
		updated:   now
		workspace: workspace
		model:     model
		messages:  1
		bytes:     line.len
		file:      '${id}.jsonl'
	}
	mut m := read_manifest()
	m.sessions << meta
	write_manifest(m)!
	return meta
}

// append adds the new messages of one turn (plus their token usage) to the end
// of the session file and refreshes the manifest. O(new), no full rewrite.
pub fn append(id string, new_msgs []Message, tin int, tout int) ! {
	if new_msgs.len == 0 && tin <= 0 && tout <= 0 {
		return
	}
	mut chunk := ''
	for msg in new_msgs {
		chunk += encode_line(msg) + '\n'
	}
	if chunk.len > 0 {
		mut f := os.open_append(session_path(id))!
		f.write_string(chunk)!
		f.close()
	}
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].updated = time.unix_now()
			m.sessions[i].messages += new_msgs.len
			m.sessions[i].bytes += chunk.len
			m.sessions[i].tokens_in += tin
			m.sessions[i].tokens_out += tout
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not in index')
}

// add_tokens accumulates token counters without touching the file (used after
// save_full, which does not know the turn's usage).
pub fn add_tokens(id string, tin int, tout int) ! {
	if tin <= 0 && tout <= 0 {
		return
	}
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].tokens_in += tin
			m.sessions[i].tokens_out += tout
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not in index')
}

// save_full rewrites the whole session file (rare: the append_user merge case,
// and /session save). Atomic: tmp + rename. Leaves token counters untouched.
pub fn save_full(id string, messages []Message) ! {
	os.mkdir_all(dir()) or { return err }
	mut chunk := ''
	for msg in messages {
		chunk += encode_line(msg) + '\n'
	}
	tmp := session_path(id) + '.tmp'
	os.write_file(tmp, chunk)!
	os.rename(tmp, session_path(id))!
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].messages = messages.len
			m.sessions[i].bytes = chunk.len
			m.sessions[i].updated = time.unix_now()
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not in index')
}

// rename updates only the name in the manifest.
pub fn rename(id string, name string) ! {
	name_ := name.trim_space()
	if name_ == '' {
		return error('usage: /session rename <id> <nombre>')
	}
	mut m := read_manifest()
	for i in 0 .. m.sessions.len {
		if m.sessions[i].id == id {
			m.sessions[i].name = name_
			write_manifest(m)!
			return
		}
	}
	return error('session ${id} not found')
}

// remove deletes one session (file + manifest entry).
pub fn remove(id string) ! {
	mut m := read_manifest()
	mut kept := []Meta{}
	mut found := false
	for meta in m.sessions {
		if meta.id == id {
			found = true
		} else {
			kept << meta
		}
	}
	if !found {
		return error('session ${id} not found')
	}
	os.rm(session_path(id)) or {} // already-gone file is not fatal
	m.sessions = kept
	write_manifest(m)!
}

// prune enforces sessions.max (count) and sessions.max_age_days (age). <=0
// disables that rule. Deletes only inside dir(); never the user workspace.
pub fn prune(max int, max_age_days int) ! {
	mut m := read_manifest()
	if m.sessions.len == 0 {
		return
	}
	now := time.unix_now()
	mut kept := []Meta{}
	for meta in m.sessions {
		age_days := (now - meta.updated) / 86400
		if max_age_days > 0 && age_days >= max_age_days {
			os.rm(session_path(meta.id)) or {}
			continue
		}
		kept << meta
	}
	if max > 0 && kept.len > max {
		kept.sort_with_compare(fn (a &Meta, b &Meta) int {
			return if a.updated > b.updated { -1 } else if a.updated < b.updated { 1 } else { 0 }
		})
		for meta in kept[max..] {
			os.rm(session_path(meta.id)) or {}
		}
		kept = kept[..max]
	}
	m.sessions = kept
	write_manifest(m)!
}

// cleanup reconciles the manifest with disk: drops entries whose file is
// missing, and removes orphan .jsonl files with no manifest entry.
pub fn cleanup() ! {
	os.mkdir_all(dir()) or { return err }
	mut m := read_manifest()
	mut kept := []Meta{}
	for meta in m.sessions {
		if os.exists(session_path(meta.id)) {
			kept << meta
		}
	}
	m.sessions = kept
	write_manifest(m)!
	files := os.ls(dir()) or { return err }
	for f in files {
		if !f.ends_with('.jsonl') {
			continue
		}
		id := f[..f.len - 6] // strip ".jsonl"
		mut in_index := false
		for meta in m.sessions {
			if meta.id == id {
				in_index = true
				break
			}
		}
		if !in_index {
			os.rm(session_path(id)) or {}
		}
	}
}
```

---

## 9. Cambios en `config/config.v`

### 9.1 Nuevo struct (añadir junto a `TuiConfig`)

```v
// SessionsConfig holds the saved-sessions tunables.
pub struct SessionsConfig {
pub mut:
	dir               string // '' = ~/.usagi/sessions (o USAGI_SESSIONS_DIR)
	autosave          bool   = true
	restore_workspace bool   = true // /resume restaura el workspace guardado
	max               int    = 50 // cap de sesiones guardadas (poda las más viejas)
	max_age_days      int    = 0 // 0 = off; poda sesiones sin actividad en N días
}
```

### 9.2 Campo en `Config` (añadir tras `tui TuiConfig = TuiConfig{}`)

```v
	sessions SessionsConfig = SessionsConfig{}
```

### 9.3 Overrides de entorno (añadir al final de `apply_env_overrides`)

```v
	cfg.sessions.dir = env_str('USAGI_SESSIONS_DIR', cfg.sessions.dir)
	cfg.sessions.autosave = env_bool('USAGI_AUTOSAVE', cfg.sessions.autosave)
	cfg.sessions.restore_workspace = env_bool('USAGI_RESTORE_WORKSPACE', cfg.sessions.restore_workspace)
	cfg.sessions.max = env_int('USAGI_SESSIONS_MAX', cfg.sessions.max)
	cfg.sessions.max_age_days = env_int('USAGI_SESSIONS_MAX_AGE_DAYS', cfg.sessions.max_age_days)
```

---

## 10. Cambios en `cli/cli.v`

### 10.1 Imports

Cambiar la línea de import de config por:

```v
import config { Config, SessionsConfig, load_config }
```

Y añadir el import de sessions (junto a los demás):

```v
import sessions
```

### 10.2 Housekeeping (función a nivel de módulo, fuera de `run`)

```v
// sessions_housekeeping reconciles orphans and prunes old sessions in the
// background so startup is never delayed by disk work.
fn sessions_housekeeping(s SessionsConfig) {
	sessions.cleanup() or {}
	sessions.prune(s.max, s.max_age_days) or {}
}
```

### 10.3 Dentro de `run()` — justo después de `apply_tool_config(root, cfg)`

```v
	apply_tool_config(root, cfg)
	// Sessions: resolve the dir (relative -> workspace) and set it once, then
	// run housekeeping (orphan cleanup + prune) in the background.
	if cfg.sessions.dir != '' {
		d := cfg.sessions.dir
		if !os.is_abs_path(d) {
			d = os.join_path(cfg.workspace, d)
		}
		sessions.set_dir(d)
	}
	spawn sessions_housekeeping(cfg.sessions)
```

> `cfg.workspace` ya está resuelto antes de este punto (el bloque de
> `cli_workspace`/config/cwd corre arriba en `run()`).

---

## 11. Cambios en `tui/tui.v`

### 11.1 Import

Añadir `import sessions` junto a los demás imports (por ejemplo, después de
`import server { ... }`).

### 11.2 Campos en `TuiApp` (añadir justo después de `sess_out int`)

> `sess_in` y `sess_out` **ya existen** en `TuiApp`; NO los repitas. Añade
> solo estas dos líneas:

```v
	session_id   string // '' = sin sesión guardada todavía
	session_name string
```

### 11.3 Autosave en `run_turn()`

Reemplazar el cuerpo actual de `run_turn` por este (los comentarios indican lo
que cambia; el resto es idéntico al original):

```v
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
	t.messages = res.messages
	stats := res.stats
	// --- sessions autosave ---
	t.autosave_turn(n0, merge_case, stats.has_usage, stats.prompt_tokens, stats.completion_tokens)
	// The status bar already shows ctx + session tokens, so no note line.
	t.push('turn_end', '${stats.prompt_tokens}|${stats.completion_tokens}|${stats.has_usage}|${time.ticks() - start_ms}|${stats.gen_ms}|${if stats.has_cached { stats.cached_tokens } else { -1 }}|${if stats.has_ttft { stats.ttft_ms } else { -1 }}')
}
```

Y añadir el helper (método de `TuiApp`, en cualquier lugar del archivo):

```v
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
```

### 11.4 Comandos en `handle_command`

Añadir estos tres brazos al `match name { ... }` (por ejemplo, después del brazo
`'/load'`):

```v
		'/sessions' {
			t.list_sessions(arg)
		}
		'/resume' {
			t.resume_session(arg)
		}
		'/session' {
			t.session_command(arg)
		}
```

Y **reemplazar el brazo `/clear`** por:

```v
		'/clear' {
			t.reset_to_new_session('')
			t.push('note', 'transcript cleared (new session)')
		}
```

### 11.5 Métodos de sesión (añadir después de `handle_command`)

```v
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
				t.push('error', 'usage: /session rename <id> <nombre>')
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
```

### 11.6 Actualizar `/help` (opcional pero recomendado)

Reemplazar el bloque de líneas de comandos en el brazo `'/help'` por:

```v
				for l in [
					'commands: /sessions · /resume <id|nombre> · /session new|save|title|rename|rm|clean · /clear · /tokens'
					'          /model [name] (no arg: pick from /v1/models) · /save [file] · /load <file> · /history'
					'          /theme <dark|light|cyberpunk> · /think <on|off> · /effort <level> · /budget <n>'
					'          /copy [n] · /tools · /pet <show|hide> · /quit · /help [keys|commands]'
					'          (sessions live in ~/.usagi/sessions/; /save /load paths are workspace-relative)'
				] {
					t.push('note', l)
				}
```

---

## 12. Cambios en `tui/input_edit.v`

Añadir a `tui_commands` (mantener orden alfabético): `/resume`, `/session`,
`/sessions`.

```v
pub const tui_commands = [
	'/budget'
	'/clear'
	'/copy'
	'/effort'
	'/help'
	'/history'
	'/load'
	'/model'
	'/pet'
	'/quit'
	'/resume'
	'/save'
	'/session'
	'/sessions'
	'/theme'
	'/think'
	'/tokens'
	'/tools'
]
```

---

## 13. Tests: `tests/sessions_test.v` (código completo)

```v
module main

import os
import proto { Message }
import sessions

fn sys_msg() Message {
	return Message{
		role:    'system'
		content: 'You are a coding assistant.'
	}
}

fn user_msg(s string) Message {
	return Message{
		role:    'user'
		content: s
	}
}

// roundtrip: create -> append -> load keeps every message and meta counters.
fn test_sessions_roundtrip() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	assert meta.id != ''
	assert os.exists(os.join_path(d, '${meta.id}.jsonl'))
	sessions.append(meta.id, [user_msg('hola'), Message{
		role:    'assistant'
		content: 'hola!'
	}], 10, 5) or { panic(err) }
	msgs := sessions.load(meta.id) or { panic(err) }
	assert msgs.len == 3
	assert msgs[0].role == 'system'
	assert msgs[1].content == 'hola'
	assert msgs[2].content == 'hola!'
	m := sessions.list()
	assert m.sessions.len == 1
	assert m.sessions[0].messages == 3
	assert m.sessions[0].tokens_in == 10
	assert m.sessions[0].tokens_out == 5
}

// multiline content stays on one physical line (JSON escapes the newline).
fn test_sessions_multiline_content() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	sessions.append(meta.id, [user_msg('linea1\nlinea2')], 0, 0) or { panic(err) }
	text := os.read_file(os.join_path(d, '${meta.id}.jsonl')) or { panic(err) }
	assert text.split('\n').len == 3 // system + user (one line) + trailing ''
	msgs := sessions.load(meta.id) or { panic(err) }
	assert msgs[1].content == 'linea1\nlinea2'
}

// find resolves by unique id prefix and unique name; fails when not found.
fn test_sessions_find() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	m1 := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	m2 := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	sessions.rename(m1.id, 'alpha') or { panic(err) }
	sessions.rename(m2.id, 'beta') or { panic(err) }
	f := sessions.find(m1.id) or { panic(err) }
	assert f.id == m1.id
	f2 := sessions.find('alpha') or { panic(err) }
	assert f2.id == m1.id
	mut err_ok := false
	sessions.find('no-existe') or { err_ok = true }
	assert err_ok
	// ambiguous: two sessions with the same name -> find errors.
	sessions.rename(m1.id, 'dup') or { panic(err) }
	sessions.rename(m2.id, 'dup') or { panic(err) }
	mut amb := false
	sessions.find('dup') or { amb = true }
	assert amb
}

// remove deletes the file and the manifest entry; cleanup removes orphans.
fn test_sessions_remove_and_cleanup() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	sessions.remove(meta.id) or { panic(err) }
	assert sessions.list().sessions.len == 0
	assert !os.exists(os.join_path(d, '${meta.id}.jsonl'))
	// orphan: a .jsonl file with no manifest entry must be removed by cleanup().
	os.write_file(os.join_path(d, '1730000000-aaaa.jsonl'), '{}') or { panic(err) }
	sessions.cleanup() or { panic(err) }
	assert !os.exists(os.join_path(d, '1730000000-aaaa.jsonl'))
}

// prune keeps at most `max` sessions, oldest first out.
fn test_sessions_prune() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	for _ in 0 .. 3 {
		sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	}
	sessions.prune(1, 0) or { panic(err) }
	assert sessions.list().sessions.len == 1
}

// a trailing incomplete line (crash mid-write) is ignored by load().
fn test_sessions_trailing_line_ignored() {
	d := os.join_path(os.temp_dir(), 'usagi_sessions_${sessions.new_id()}')
	sessions.set_dir(d)
	defer {
		os.rmdir_all(d) or {}
	}
	meta := sessions.create('', '/w', 'm', sys_msg()) or { panic(err) }
	p := os.join_path(d, '${meta.id}.jsonl')
	os.write_file(p, os.read_file(p) or { panic(err) } + '{"role":"user","content":"par') or {
		panic(err)
	}
	msgs := sessions.load(meta.id) or { panic(err) }
	assert msgs.len == 1 // only the valid system line
}
```

> Nota: `sessions.set_dir(tmp)` en cada test redirige el store a un directorio
> temporal, para no tocar `~/.usagi/sessions` real. `g_dir` es un global del
> proceso; al ser tests de `module main` en un solo binario, setearlo por test
> es correcto.

---

## 14. Edge cases y cómo se resuelven

| Caso | Comportamiento / resolución |
|---|---|
| Sesión activa sin guardar al salir | Con `autosave=true` ya está persistida. Si `autosave=false`, el usuario usa `/session save`. |
| `append_user` hace merge (turno anterior terminó en `user`) | `merge_case` detectado en `run_turn` → `save_full` (reescribe). Ver §11.3. |
| Índice corrupto | La escritura atómica lo evita; si aun así falta, `cleanup()` lo reconstruye desde los `.jsonl`. |
| Dos usagi a la vez | Cada proceso usa su propio id → los appends no colisionan. El índice es last-write-wins (aceptado en v1). |
| `/resume` con `system.md` cambiado | Se conserva el `system` guardado (fidelidad). Futuro: `sessions.reload_system`. |
| Workspace guardado ya no existe | Aviso + se mantiene el workspace actual (§5). |
| Sesión muy grande | Disco crece; envío ya recortado por `ctx.trim_for_request`. Compact futuro (§7, §15). |
| `/clear` | Equivale a nueva sesión: desvincula (`session_id=''`), la sesión anterior queda guardada. |
| `/load` de un archivo suelto | Carga mensajes pero no crea sesión; el siguiente autosave le asigna id nuevo. |
| `.jsonl` truncado a mitad de línea | `load()` ignora la última línea incompleta. |

---

## 15. Fuera de v1 (documentado, NO implementar ahora)

1. **Compactación** (`/compact` + auto): sustituir turnos viejos por un resumen.
   - Conservar `system` + últimos K turnos; reemplazar lo anterior por un
     mensaje `user` con prefijo `[resumen de la conversación anterior]`.
   - Resumen generado por el modelo (llamada extra barata) con fallback
     heurístico sin modelo (conservar `user` + respuestas finales truncadas).
   - Disparo: manual o cuando `bytes`/tokens estimados superen
     `sessions.compact_tokens` (~80% de la ventana).
   - Es la única operación que reescribe el `.jsonl` de forma pesada: `.tmp` +
     `rename`, con backup `<id>.bak.jsonl`.
   - Config futura: `compact_tokens`, `compact_keep_turns`, `compact_auto`.
2. **Picker para `/resume` sin arg**: overlay tipo `ModelPicker` (reutilizar el
   patrón de `model_picker`). En v1, `/resume` sin arg devuelve el error de uso.
3. **Paridad en el REPL por líneas** (`agent/run_repl`): interceptar `/sessions`,
   `/resume`, `/session save`, `/save`, `/load`. En v1 los comandos son TUI-only.
4. **Confirmación interactiva** en `/session rm --all` (el flag es la confirmación en v1).
5. **Serialización compacta** vía `proto.message_to_any` para omitir campos vacíos (ahorra bytes).
6. **`sessions.reload_system=true`** para regenerar el `system` desde `system.md` al retomar.

---

## 16. Orden de implementación (cada paso compila y testeable)

1. Crear `sessions/sessions.v` (§8) — compila solo: `v -enable-globals -c sessions/sessions.v`.
2. Crear `tests/sessions_test.v` (§13) y correr solo el módulo:
   `v -enable-globals test sessions` (ajustar comando si el runner lo requiere).
3. Añadir `SessionsConfig` + campo + env overrides en `config/config.v` (§9).
4. Añadir imports + `sessions_housekeeping` + `set_dir` + `spawn` en `cli/cli.v` (§10).
5. Añadir import + campos en `TuiApp` (§11.1, §11.2).
6. Modificar `run_turn` + añadir `autosave_turn` (§11.3).
7. Añadir brazos de comandos + reemplazar `/clear` (§11.4).
8. Añadir métodos `list_sessions`, `resume_session`, `session_command`,
   `save_current`, `reset_to_new_session`, `session_remove_all`,
   `first_user_text` (§11.5).
9. Actualizar `/help` (§11.6) y `tui_commands` (§12).
10. Build completo + tests: `v -enable-globals -o usagi . && v -enable-globals test .`.
11. Smoke manual:
    - `usagi .` → chatear un turno → `cat ~/.usagi/sessions/index.json` (existe sesión).
    - `/sessions` la lista; `/resume <id>` la retoma; `/session title x` renombra;
      `/session rm <id>` borra; `/session new` empieza limpia.
    - `USAGI_AUTOSAVE=0 usagi .` → chatear → `/session save` guarda manualmente.
    - `usagi /folder1` → charlar → `cd folder2` → `usagi` → `/resume <id>` →
      verificar nota "workspace restored to /folder1" y que `read_file` ve folder1.

---

## 17. Verificación final (definición de "terminado")

- [ ] `sessions/sessions.v` compila y todos los tests de `sessions_test.v` pasan.
- [ ] `v -enable-globals -o usagi .` produce binario sin warnings nuevos relevantes.
- [ ] `v -enable-globals test .` pasa la suite completa (sin romper tests existentes).
- [ ] Autosave: un turno genera/appendea una sesión en `~/.usagi/sessions/`.
- [ ] `/sessions`, `/resume`, `/session new|save|title|rename|rm|clean` funcionan.
- [ ] `/resume` restaura el workspace guardado (y avisa si la carpeta no existe).
- [ ] `/clear` desvincula y la sesión anterior permanece guardada.
- [ ] `USAGI_SESSIONS_DIR`, `USAGI_AUTOSAVE`, `USAGI_RESTORE_WORKSPACE`,
      `USAGI_SESSIONS_MAX`, `USAGI_SESSIONS_MAX_AGE_DAYS` se leen desde el entorno.
- [ ] El borrado/poda nunca toca archivos fuera de `~/.usagi/sessions/`.
