<p align="center">
  <img src="assets/logo.png" width="200" alt="usagi logo">
</p>

<h1 align="center">usagi</h1>

<p align="center"><b>a coding agent for small local LLMs</b></p>

<p align="center">
  <a href="https://vlang.io"><img src="https://img.shields.io/badge/V-0.5.x-3d5a80" alt="V"></a>
  <img src="https://img.shields.io/badge/version-0.1.0-blue" alt="version 0.1.0">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license MIT">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen" alt="dependencies: none">
  <img src="https://img.shields.io/badge/binary-single%20static-brightgreen" alt="single static binary">
  <img src="https://img.shields.io/badge/endpoint-OpenAI--compatible-purple" alt="OpenAI-compatible endpoint">
  <img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey" alt="platforms">
</p>

A coding agent for small local LLMs: a `for` loop, an interactive chat REPL, a
`.env` for secrets and a `config.json` for tuning — written in **V**, using
only the standard library (vlib). No dependencies, no venv: it builds to a
single static binary.

`usagi` is designed around the constraints of small models running on your own
machine. Fenced tools, truncated tool-call salvage, repetition breaking,
context aging and retries are what make a 2B–8B model usable as a coding
assistant on real files, instead of a chat toy that falls over on the first
malformed tool call.

Works with any OpenAI-compatible endpoint: llama.cpp `server`, Ollama,
LM Studio, vLLM, MLX, etc.

## Quick start

```bash
scripts/dev.sh install   # build + link `usagi` into PATH (dev install)
usagi .                  # run the TUI on the current folder
```

There is no packaged installer before the first release: see
[Build & run](#build--run) for the dev install and [Configure](#configure) for
the endpoint and the workspace rules.

## Files

```
usagi/
├── v.mod         # module metadata
├── main.v        # entry point: imports cli and calls cli.run()
├── etc/          # runtime files
│   ├── config.json   # non-secret behaviour/tuning (colors, tui, limits)
│   ├── system.md     # system prompt
│   ├── pet.txt       # ASCII pet frames (fallback for `tui.pet = ascii`)
│   └── .env.example  # template for secrets/machine settings (copy to .env)
├── assets/
│   └── logo.png  # project logo
├── config/       # Config struct + loaders
│   └── config.v      # config.json / .env decoding + system prompt
├── text/         # pure text helpers
│   └── tui_text.v    # display width, wrapping, truncate/fit, time formatting
├── proto/        # wire-shaped types shared by every module
│   └── proto.v       # Message, ToolCall, Usage, ChatReply, TokenFn
├── ctx/          # context budget
│   └── ctx.v         # window global + trim/aging of old turns
├── server/       # server compatibility layer
│   └── server.v      # profile + capability probe, request dialect, context length
├── ui/           # output sink
│   └── ui.v          # colors, debug lines, line routing
├── state/        # session-wide flags
│   └── state.v       # g_tui, g_interrupt, g_aborted
├── sessions/     # saved sessions: JSONL store + index.json manifest
│   └── sessions.v    # create/append/load/list/find/prune (stdlib only)
├── app/          # runtime context
│   └── app.v         # App (cfg, ui, url, per-turn tool_choice)
├── client/       # streaming SSE client
│   ├── client.v      # build_body, SSE, chat()
│   └── salvage.v     # truncated tool-call JSON salvage
├── agent/        # agent loop
│   └── agent.v       # run_agent, run_repl, usage tracking, probes
├── pet/          # status-bar companion
│   ├── pet.v         # pet.txt loader + animation frames
│   └── pet_px.v      # half-block pixel rabbit: frames + half-block packer
├── tui/          # terminal UI (term.ui)
│   ├── tui.v         # transcript view, events, commands, turn loop
│   ├── tui_render.v  # render helpers: wrap, prefixes, tool blocks, status
│   ├── tui_theme.v   # theming: palettes, config overrides, NO_COLOR
│   └── input_edit.v  # editable input line: cursor, kill ops, history
├── cli/          # orchestrator
│   └── cli.v         # run(), workspace resolution, tool config
├── tests/        # unit + integration tests (import the modules above)
│   ├── tui_test.v        # input editing, history, command parsing, completion
│   ├── tui_render_test.v # wrapping, markdown, tool blocks, status, golden frames
│   ├── tui_text_test.v   # display width / wrapping
│   ├── config_test.v     # config decoding + theme overrides
│   ├── pet_test.v        # pet.txt parsing + frame wrap
│   ├── pet_px_test.v     # pixel-pet frames + half-block packer
│   ├── client_test.v     # salvage + JSON helpers
│   ├── agent_test.v      # build_body, context trimming, repetition counting
│   ├── server_test.v     # profile selection + 400/422 fallback
│   ├── chat_sse_test.v   # mock SSE server: streaming + truncation salvage
│   ├── run_agent_test.v  # mock SSE server: tool dispatch + loop end-to-end
│   └── sessions_test.v   # saved-session store: roundtrip, find, prune, cleanup
├── tools/
│   ├── tools.v       # tool registry + schemas + dispatch
│   ├── util.v        # path fence, workspace, max_output, shared JSON accessors
│   ├── bash.v        # allowlisted single-command shell: quoting, fence, timeout
│   ├── read_file.v   # streaming chunked line reader (binary-safe)
│   ├── write_file.v  # create / replace / append, with a size guard
│   ├── edit_file.v   # unique exact-match replace, whitespace fallback
│   └── tools_test.v  # tests for guards, fence, file tools
├── scripts/
│   └── dev.sh    # local install: build into ~/.usagi + link `usagi` into PATH
└── start.sh      # build + run (native or Docker)
```

## Build & run

Native, with the V compiler installed:

```bash
./start.sh            # v -enable-globals -o usagi . && ./usagi
./start.sh --debug
```

Without installing V on the host, using Docker:

```bash
./start.sh --docker           # builds and runs in thevlang/vlang
./start.sh --docker --debug
```

`-enable-globals` is required: the streaming callback carries no user-data
argument, so the state it fills lives in a module global.

### Requirements

`usagi` is pure V and imports **only `vlib`** (no third-party modules), so
building it needs nothing beyond the V compiler and a C toolchain:

| Requirement | Notes |
| --- | --- |
| **V 0.5.x** | tested with V 0.5.2 (`v --version`). |
| **A C compiler / linker** | `gcc` or `clang` on Linux/macOS (V's bundled `tcc` also works for dev builds); MSVC, MinGW-w64 or `tcc` on Windows. |
| **`git`** | only to install/update V. |
| **`make`** | only to build V on Linux/macOS (`build-essential` on Debian/Ubuntu). |

There is **no `v install` step**: nothing is downloaded from the V package
registry at build time. Network access is only needed at runtime to reach the
OpenAI-compatible endpoint.

Install V from source (`make` on Linux/macOS, `makev.bat` on Windows):

```bash
git clone --depth=1 https://github.com/vlang/v
cd v && make            # Windows: makev.bat
sudo ./v symlink        # optional: put `v` on PATH
```

See the [official install guide](https://github.com/vlang/v#installing-v-from-source)
for distro-specific packages and troubleshooting. `-enable-globals` (above)
is required on every build, not just releases.

### Build for your platform

Run these from the repository root. Add `-prod` for an optimized release
binary (recommended: smaller and faster); without it the build is a debug
build.

**Linux**

```bash
v -enable-globals -prod -o usagi .
```

A fully static binary, copyable to another Linux machine with no libc
dependency:

```bash
v -enable-globals -prod -cc gcc -cflags -static -o usagi .
```

**macOS** — uses `clang` from the Xcode Command Line Tools
(`xcode-select --install` if missing):

```bash
v -enable-globals -prod -o usagi .
```

**Windows** (PowerShell or `cmd`) — the `.exe` suffix is added
automatically. V prefers an active Visual Studio Developer environment (MSVC),
then a MinGW-w64 `clang`/`gcc`, then the bundled `tcc`; force one with
`-cc msvc` or `-cc gcc`:

```bat
v -enable-globals -prod -o usagi.exe .
```

On Linux/macOS, `./start.sh [--debug]` wraps the native `v -enable-globals`
build and then runs the binary; `scripts/dev.sh` (next section) does an
optimized `-prod` build and installs it.

### Cross-compilation

V cross-compiles to Windows, Linux and FreeBSD from any supported host, and
the build is pure V, so no target libraries are needed beyond a C
cross-compiler. Two caveats:

- **A macOS binary must be built on macOS** — cross-compiling *to* macOS is
  not supported.
- **Windows binaries need MinGW-w64** when built on a Linux/macOS host.

```bash
v -enable-globals -prod -os linux   -o usagi-linux .
v -enable-globals -prod -os windows -o usagi.exe .    # Linux host: needs MinGW-w64
v -enable-globals -prod -os freebsd -o usagi-freebsd .
```

On Debian/Ubuntu install the Windows cross-compiler first, then build:

```bash
sudo apt install gcc-mingw-w64-x86-64
v -enable-globals -prod -os windows -o usagi.exe .
```

On Arch use `sudo pacman -S mingw-w64-gcc`. To use a different toolchain, pass
`-cc <compiler>` for one build or set `VCROSS_COMPILER_NAME` in the
environment. From Windows you can build a Linux binary with
`v -os linux .` (a cross `gcc`/`clang` targeting Linux must be on `PATH`).

### Local install (development)

Before the first release there is no installer to distribute. `scripts/dev.sh`
builds the binary into `~/.usagi/usagi` and links `usagi` into `~/.local/bin`.
In developer mode the runtime files are **symlinked** from the repo into
`~/.usagi`, so editing `system.md` / `config.json` / `.env` in the repo takes
effect immediately (no copy step):

```bash
scripts/dev.sh install     # build + link (default)
scripts/dev.sh sync        # (re)link the runtime files only
scripts/dev.sh status      # what is installed where
scripts/dev.sh uninstall   # remove the links and ~/.usagi
```

An existing regular file is kept as `<name>.local.bak` before being replaced
by a link, so an edit made directly in `~/.usagi` is never lost silently. Set
`USAGI_COPY=1` to copy the files instead of linking them. Everything lives
under `~/.usagi`, so uninstalling is just removing it; `rm` never follows the
symlinks, so the repo files are left untouched. Use `USAGI_HOME` /
`USAGI_BIN_DIR` to test a throwaway install without touching your real one:

```bash
USAGI_HOME=$PWD/.usagi-dev USAGI_BIN_DIR=/tmp/bin scripts/dev.sh install
```

### Workspace

The agent works on a single folder, fenced: file tools may not escape it and
`bash` runs with it as cwd. By default that folder is **where you started the
agent** (the current directory); pass another one as an argument (resolved from
the current directory, so `usagi .` is the folder you are in):

```bash
usagi                    # the current directory (default)
usagi .                  # the current directory, explicit
usagi /path/to/project   # an explicit folder
usagi --workspace .      # same, named flag (also -w and --workspace=DIR)
```

The workspace is resolved in this order: command-line argument → `WORKSPACE`
in `.env` → `workspace` in `config.json` → the current directory. The agent's
own config and install live in `~/.usagi`, *outside* the workspace.

### Interface: TUI and line REPL

On a terminal (TTY) the agent starts in a **terminal UI**: a scrolling
transcript (user / thinking / content / tool lines, color-coded), an input
line at the bottom, and a status bar (model, context, session tokens, keys).
The input line is a real editable buffer with rune-accurate UTF-8, history,
multi-line entry and tab completion, shown between two **horizontal rules**
(top and bottom, no side borders; a `» ` marker is drawn on the first line —
visual only, never part of the message) whose height **grows with
the number of lines up to 10**, then scrolls. The transcript is laid out like a
chat app: each message is a **bordered block** (rounded `╭─╮` … `╰─╯`
outline, horizontal + vertical padding, a one-row margin between messages, and
a **width that hugs the message** up to `min(2/3·terminal, 100)`), with the turn
timestamp rendered **inside the bottom border** of the user bubble in
superscript digits (`¹³·²²`) so it costs no extra row. **User input is
right-aligned**, assistant replies left-aligned, with separate blocks for
thinking and tool calls. When the input has several lines, `up`/`down` and the
mouse wheel scroll it (the caret moves between lines); otherwise they scroll
the transcript. A **four-line status bar** on tall terminals (a single row in compact mode) is
closed by a grey rule and a blank margin; its first row carries the model,
state and `ctx used/window [bar] %` (kept even on narrow terminals), and the
second row `T:<level>` thinking, `CH:<cached>/<prompt>` prefix-cache hit and
compact session tokens (`↑in ↓out`). Key hints live in `/help`, not in the bar.
The top-right holds the **pixel rabbit**, an 8×8 half-block sprite drawn as four
rows, with three theme colours (`pet_body` / `pet_ear` /
`pet_eye`) that differ per palette (cyberpunk uses a hacker-green phosphor
set), and it **reacts to the agent state**: it looks around while idle,
flicks its ears while thinking, stays calm with an occasional blink while
streaming, winks while reading a result, gives a happy blink when a turn
finishes, drops its ears on error, darts its eyes on interrupt, and lies flat
after a long idle. No animation changes the face outline; moods are shown
through the eyes and ears only. `tui.pet` selects `pixel` (default), `ascii` (the
old
`pet.txt` frames), or `off`; under `NO_COLOR`/`TERM=dumb` the shape stays but
the colours are dropped and the eyes remain as holes. While a turn runs, the
state text is **phase-aware**: `connecting…`, `processing…` (no output yet),
`thinking…` (reasoning tokens), `writing…` (answer tokens),
`running <tool>…`, and `↻ retrying n/2…`, each with its own timer, next to the
ball-wave spinner (`.env`/`config`: `tui.animation` = `full`, `calm` — 4×
slower spinner and a static pet — or `off`; `NO_COLOR`/`TERM=dumb` force
`off`). Blocks carry a `⚙ tool(args)` header and
truncated results, and content
gets a markdown-lite tint for `**bold**` / `` `code` `` (fenced blocks get a `│`
gutter). Colors come from a `dark` / `light` / `cyberpunk` palette plus per-kind
overrides in `tui.colors`; the `light` palette also paints a white background
across the whole UI (input, status, transcript) instead of relying on the
terminal one, so the input box is white and the rest stays light. Setting
`NO_COLOR` or `TERM=dumb` drops the filled
backgrounds (borders, padding and margins stay). `tok/s` is measured over the
streaming window (first → last token), matching what the server logs, rather
than whole-turn wall time. A `CH:N/prompt` segment shows the prefix-cache hit
(including `CH:0/…` for a miss) from omlx/OpenAI
(`prompt_tokens_details.cached_tokens`), DeepSeek (`prompt_cache_hit_tokens`)
or llama.cpp (`timings.cache_n`). When the server reports a time-to-first-token
(omlx `usage.time_to_first_token`, llama.cpp `timings.prompt_ms`) the ready
state shows `ttft 150ms` / `ttft 2.28s`, so a cache hit (fast) and a re-prefill
(slow) are obvious at a glance. That fraction and TTFT are the numbers to watch
when tuning how much history is sent. Local
`/` commands include
`/clear /tokens /sessions /resume /session /model /samplings /save /load /history /theme /think /effort /budget /copy /tools /pet /quit /help`.
`/model` with no argument opens a **selector** built from `GET /v1/models`:
`↑/↓` (or wheel) moves, typing filters by id/owner, `enter` picks (and adopts
that model's context length), `ctrl-r` refetches, `esc` cancels. The list is
cached for `models_cache_ttl` seconds (default 300), so the picker does not hit
the endpoint on every keypress; it works for both omlx and llama.cpp.
`/samplings` opens an editor for the **decoding knobs** (temperature, top_p,
max_tokens, top_k, min_p, repeat/frequency/presence penalty, seed). It shows
only what the active server supports (e.g. `top_k`/`min_p`/`repeat_penalty`
only on llama.cpp), `enter` edits, `r` resets a field to *server default* and
`esc` closes. Changes are **session-only** (nothing is written to
`config.json`); an empty value means "omit and let the server/preset decide".

- `enter` — send the message
- `shift+enter` / `ctrl-j` — insert a newline (multi-line message)
- `esc` — interrupt the in-flight request, or clear the idle input
- `ctrl-c` — interrupt while busy, quit when idle
- `left/right` — move the input cursor; `home/end` do the same, or jump the
  transcript to top/bottom when the input is empty
- `ctrl-a` / `ctrl-e` — start / end of the input line
- `ctrl-u` / `ctrl-k` / `ctrl-w` — kill to start / to end / delete word
- `backspace` / `delete` — delete the rune before / under the cursor
- `tab` — complete a `/` command or a `/save` path
- `up/down`, `page up/down` — scroll the transcript (bottom = live)
- `ctrl-p` / `ctrl-n`, `alt-up/down` — walk the input history
- `ctrl-t` — cycle the thinking level (off → low → medium → high → off)
- `ctrl-h` — show/hide the thinking block (view only)
- `ctrl-o` / `/tools` — expand or collapse tool output blocks
- `ctrl-home` / `ctrl-end` — jump the transcript to the top / bottom
- `mouse wheel` — scroll the transcript (enable with `tui.mouse`)
- `mouse drag` — select transcript text; on release it copies the **clean**
  text (bubble borders, padding and turn rules excluded) via OSC 52, and the
  wheel keeps scrolling while you drag (enable with `tui.mouse`); hold `shift`
  to defer to the terminal's own selection

Piped/redirected stdin, or `NO_TUI=1`, falls back to the classic
**line-based REPL** (the `▰▰▰▱` prompt, `exit` to quit):

```
$ NO_TUI=1 ./usagi
model: Sharp-MiniCPM5-2B-MLX-oQ6e @ http://192.168.1.109:9000/v1  (exit to quit)
▰▰▰▱ hello
↴ usagi> ...
```

The TUI is built on V's standard `term.ui` module (no external packages).

Tests (also runnable without a host install):

```bash
docker run --rm -v "$PWD:/app" -w /app thevlang/vlang:latest \
    sh -c 'v -enable-globals test tests/ && v -enable-globals test tools/'
```

## Configure

Secrets and machine-specific values (endpoint, model, api key) live in a
`.env` file next to `config.json`. `.env` is **gitignored**, so they never end
up in the repo; `.env.example` is the committed template:

```bash
cp etc/.env.example etc/.env   # then edit BASE_URL (and API_KEY)
```

```ini
# .env
BASE_URL=http://localhost:8080/v1
# MODEL is optional: leave it empty and usagi picks one from
# GET {BASE_URL}/models (the loaded model on a llama.cpp router, else the
# first advertised) and shows a note. `/model` changes it at runtime.
MODEL=
API_KEY=none
```

Precedence is **real environment variables → `.env` → `config.json`**, so you
can also just `export BASE_URL=... MODEL=... API_KEY=...` (or any of the
optional overrides listed in `.env.example`) with no file at all. `config.json`
holds the non-secret behaviour and tuning (and is optional — with only a
`.env`, the built-in defaults apply):

```json
{
  "reasoning": true,
  "reasoning_effort": "",
  "thinking_budget": 0,
  "stream_options": true,
  "single_tool_call": true,
  "max_tool_output": 6000,
  "tool_timeout": 120,
  "workspace": "",
  "server": "auto",
  "tool_choice": "",
  "parallel_tool_calls": false,
  "tui": {
    "bell": false,
    "timestamps": true,
    "thinking_default": true,
    "input_history": true,
    "theme": "dark",
    "mouse": false,
    "animation": "full",
    "pet": "pixel"
  },
  "sessions": {
    "dir": "",
    "autosave": true,
    "restore_workspace": true,
    "max": 50,
    "max_age_days": 0
  },
  "colors": {
    "content": "1;96",
    "thinking": "3;35",
    "tool": "48;5;205;30",
    "debug": "2;36"
  }
}
```

| Key              | Meaning                                                    |
| ---------------- | ---------------------------------------------------------- |
| `base_url`       | Base URL of the OpenAI-compatible server (`.env`: `BASE_URL`) |
| `model`          | Model name as served by the endpoint (`.env`: `MODEL`). Optional: when empty, the loaded/first model from `GET /v1/models` is used |
| `api_key`        | Bearer token, any string for llama.cpp/Ollama (`.env`: `API_KEY`) |
| `system`         | System prompt (overridden by `system.md` when present; `.env`: `SYSTEM`) |
| `reasoning`      | `true` requests and streams thinking; `false` disables it (`reasoning_effort: none` + `enable_thinking: false` on omlx/llama.cpp) |
| `temperature`    | Sampling temperature. **Omitted by default** (server/preset decides); set e.g. `0` for deterministic tool calls, or a negative value to omit again |
| `top_p`          | Nucleus sampling; only sent when `0 < top_p < 1` (default `1` = omit) |
| `max_tokens`     | Output cap; `0` (default) = server default                   |
| `top_k`, `min_p`, `repeat_penalty` | llama.cpp-only extensions; empty/0/-1 = server default. Editable with `/samplings` |
| `frequency_penalty`, `presence_penalty` | OpenAI standard; `0`/empty = server default  |
| `seed`           | `>= 0` fixes the RNG; `-1`/empty = random                    |
| `stream_options` | Send `stream_options.include_usage` (turn off for servers that reject it) |
| `reasoning_effort` | Thinking depth when `reasoning` is on: `low`/`medium`/`high`/`none`, or a model-specific value. Empty (default) = let the server/template decide |
| `thinking_budget` | Cap the thinking tokens (omlx only; `0` = server default)  |
| `read_timeout`   | Seconds allowed for one streaming request (default 300)      |
| `single_tool_call` | Reject more than one tool call in an assistant message (default true, matches `system.md`) |
| `max_tool_output` | Max chars returned by one tool result (default 6000)        |
| `tool_timeout`   | Seconds before a `bash` command is killed (default 120)      |
| `workspace`      | Folder the file tools are fenced to and `bash` runs in; `""` (default) = the current directory. A command-line workspace (`usagi .`, `usagi DIR`, `--workspace DIR`) overrides it |
| `server`         | Request dialect: `auto` (probe), `omlx`, `llamacpp` or `openai` |
| `tool_choice`    | Sent with the tool list when non-empty: `auto`, `required`, `none` (or a JSON object for one tool) |
| `parallel_tool_calls` | Ask for multiple tool calls per message; only sent on servers that support it (llama.cpp) |
| `context_length` | Manual context size override (else probed from `/models`)   |
| `models_cache_ttl` | Seconds the `/v1/models` list is cached for the model selector; `0` = refetch every time |
| `colors`         | ANSI SGR codes per output kind (line REPL)                  |
| `tui.bell`       | Ring the terminal bell when a turn ends while scrolled away |
| `tui.timestamps` | Show a timestamped rule before each user turn          |
| `tui.thinking_default` | Show thinking lines until `ctrl-h` hides them      |
| `tui.input_history` | Persist and recall input history (`~/.usagi_history`) |
| `tui.theme`      | `dark`, `light`, or `cyberpunk` palette                      |
| `tui.mouse`      | Enable mouse wheel scrolling and drag-to-select/copy (off by default) |
| `tui.animation`  | Status-bar motion: `full` (default), `calm` (4× slower spinner, static pet), or `off`; `NO_COLOR`/`TERM=dumb` force `off` |
| `tui.pet`        | Status-bar companion: `pixel` (half-block rabbit, default), `ascii` (`pet.txt`), or `off`. `/pet show` / `/pet hide` / `/pet toggle` overrides it at runtime |
| `tui.colors`     | Per-kind overrides, e.g. `{"content": "#ff00aa"}`; these win over the selected theme (also `selection`/`selection_fg` for the drag highlight) |
| `sessions.dir`   | Where saved sessions live; `""` (default) = `~/.usagi/sessions` (`.env`: `USAGI_SESSIONS_DIR`). A relative path is resolved against the workspace |
| `sessions.autosave` | Append each finished turn to the active session file (default true; `.env`: `USAGI_AUTOSAVE`) |
| `sessions.restore_workspace` | `/resume` switches back to the session's stored workspace (default true; `.env`: `USAGI_RESTORE_WORKSPACE`) |
| `sessions.max`   | Keep at most this many sessions, pruning the oldest at startup (default 50; `.env`: `USAGI_SESSIONS_MAX`) |
| `sessions.max_age_days` | At startup, prune sessions with no activity for N days; `0` (default) = off (`.env`: `USAGI_SESSIONS_MAX_AGE_DAYS`) |

Note the two color grammars: the top-level `colors` block is raw ANSI SGR codes
(used by the piped line REPL), while `tui.colors` is `#rrggbb` hex (used by the
TUI).

### Server compatibility

"OpenAI-compatible" is a spectrum, so the client shapes the request to the
endpoint it is talking to. At startup it resolves a profile (`server: auto`):
`GET /v1/models` identifies omlx (`owned_by: "omlx"`) and `GET /props`
identifies llama.cpp; anything else uses the generic OpenAI profile. Set
`server` explicitly if probing is not desirable. The context size is taken
from `/v1/models` when present (omlx `max_model_len`), from the llama.cpp
router's per-model `status.args` (`--ctx-size` ÷ `--parallel`), or from
`/props` otherwise (single-model llama.cpp `default_generation_settings.n_ctx`),
so the ctx bar and the model picker work on both.

What differs in practice:

| Field | omlx | llama.cpp |
| --- | --- | --- |
| `tools` / `tool_choice` | yes | yes (needs `--jinja`) |
| `parallel_tool_calls` | not in its schema (omitted) | yes |
| `strict` inside a tool | ignored | ignored |
| constrained JSON | `structured_outputs` / `guided_grammar` | `grammar` / `json_schema` |
| `chat_template_kwargs` | yes | yes |

`tool_choice` is only sent when `tool_choice` is non-empty and the profile
supports it. `required` is forced for the single retry after a malformed tool
call. `parallel_tool_calls` is sent only when enabled *and* the server supports
it. `chat_template_kwargs: {"enable_thinking": false}` is added for omlx/
llama.cpp when `reasoning` is off.

Safety net: if the server answers `400`/`422`, the profile is marked **degraded**
for the session and the request is retried once without those optional fields,
so an unknown field can never kill a turn.

### Thinking controls

Three layers, often conflated:

- **`reasoning`** (request): whether the model should think at all.
- **`reasoning_effort`** (request): depth when it does; **`thinking_budget`**
  caps the thinking tokens (omlx only).
- **`show_thinking`** (view): whether the thinking block is drawn.

Runtime commands: `/think on|off|toggle`, `/effort <level>`, `/budget <n>`.
**`ctrl-t`** cycles every level the model offers (off → low → medium → high →
off) and changes the request; **`ctrl-h`** only hides/shows the block. The
status bar shows `T:<level>` (e.g. `T:low`) and `T:low·hidden` when the block
is hidden while still requested; the level still applies and `ctrl-t` keeps
working. Use `/think` to see whether the server advertised support.

**Per-model detection.** At startup the client reads model metadata:
`GET /v1/models` (omlx can advertise profile variants like `<model>:thinking`)
and llama.cpp's `/props` chat template, plus a name heuristic (`qwen3`,
`deepseek-r1`, …). When support cannot be confirmed it still fills the
`/effort` list with the default levels, so `ctrl-t` keeps working even on
servers that do not advertise thinking. `.env`: `REASONING_EFFORT`,
`THINKING_BUDGET`.

Examples: llama.cpp `http://localhost:8080`, Ollama
`http://localhost:11434/v1`, LM Studio `http://localhost:1234/v1`.

## What is an agent? The concept

An LLM is **stateless**: it knows nothing between calls, and it can only
produce text. An *agent* wraps the model in a loop that feeds it context,
executes its requests, and feeds the results back.

- **The message history is the memory.** The agent keeps a `messages` list
  and re-sends it on every call (`client.v`).
- **The loop is the "thinking".** Each iteration the model decides the next
  step; if it asks for a tool, the agent executes it, appends the result as a
  `tool` message, and loops. A plain text reply with no tool calls ends the
  turn (`agent.v`, `run_agent`).
- **Streaming** comes from `net.http`'s `on_progress_body` callback: chunks
  of the SSE stream are parsed as `data: {...}` lines, tokens are printed
  live, and fragmented tool-call arguments are reassembled by index.
- **Escape cancels** generation: the callback polls the keyboard
  (`term.key_pressed`) and aborts the request when Escape or Ctrl-C is seen.
- **Small-model hardening**: truncated tool-call JSON is repaired
  (`salvage_args`) both on the HTTP-500 path and when a stream simply ends
  mid-call; a 500 whose body echoes the truncated arguments is salvaged and
  routed to the matching tool; a one-argument tool whose arguments arrive as a
  bare string (`echo hi`) is wrapped into its sole parameter when the server
  aborts the stream with `invalid_tool_call`; a `path`/`command` value that
  still carries its own quotes (`"\"index.html\""`) is unquoted before the
  tool runs; exact repeated tool calls are rejected with a nudge to change
  approach (within a turn and across turns); 503/504 and connection failures
  are retried twice with backoff before a turn is lost; `single_tool_call`
  keeps the model to one tool per message.

## Implementation notes

- **Single binary**: `v -prod -o usagi .` ships everything (keep
  `config.json`/`system.md` next to it, or edit them there).
- **Tool timeout enforced**: `bash` runs through `os.Process` and is killed
  after `tool_timeout` seconds (default 120), with stdin from `/dev/null` so a
  bare `cat`/`tail` cannot hang the agent.
- **Bash is fenced like the file tools**: absolute paths, `..`, `~` and
  protected agent files are rejected, and the command runs in the workspace
  folder. It also uses a quote-aware tokenizer, so `echo "a b"` and
  `find . -name "*.v"` work.
- **Escape is polled per stream chunk**, so Escape is only noticed when data
  arrives.
- **Chunked transfer framing**: V 0.5's `net.http` de-chunks only after the
  response completes, so the raw callback sees chunk-size lines; they are
  skipped as non-`data:` lines. Per-event server writes keep boundaries
  aligned, which is the normal streaming case.

## Improvements

The reliability levers below were the main gaps for small local models. The
ones marked ✅ are implemented; the rest are still open.

### Request knobs

- ✅ **Sampling defaults to the server** — `temperature`, `top_p`,
  `max_tokens`, the penalties, `seed` and the llama.cpp extras are **omitted
  unless overridden** (config, env or `/samplings`), so the endpoint/preset
  decides. Set `temperature: 0` (or `min_p`, `repeat_penalty`) for more
  deterministic small-model tool calls.
- ✅ **`max_tokens` cap** — bounded output makes truncation predictable
  (truncated → the salvage path) instead of catastrophic.
- ✅ **Reasoning toggle** — `reasoning: false` sends `reasoning_effort`
  (default `none`); `true` streams the monologue.
- ⬜ **Reasoning off by default** — the shipped `config.json` still says
  `"reasoning": true`; flip it to `false` for the lowest per-turn latency.

### Context management

- ✅ **Age old tool results** — before sending, tool messages older than the
  current turn are rewritten to a one-line stub.
- ✅ **Trim old turns** — when the estimate (`chars/4`) exceeds ~75% of the
  window, whole oldest turns are dropped (tool-call pairs stay intact); the
  current turn is never dropped. `context_length`, the `/models` probe (omlx)
  or `/props` (llama.cpp `n_ctx`) supplies the window.
- ✅ **Lower `max_output`** — now `max_tool_output`, config-driven, default
  6000 (was a hard-coded 12000).

### Robustness

- ✅ **Retry on 503/504** — twice with 1–2 s backoff, only when nothing has
  streamed yet.
- ✅ **Salvage truncated streams** — `salvage_args` is applied to the
  accumulated tool-call arguments at final assembly, not just on 500.
- ✅ **Salvage bare-string arguments** — when a one-argument tool (`bash`,
  `read_file`) arrives with its argument as a raw string and the server aborts
  the stream with `invalid_tool_call`, the string is wrapped into the tool's
  sole parameter and the call runs instead of failing the turn.
- ✅ **Unquote path/command arguments** — a value like `"\"index.html\""` (the
  model quotes the JSON string inside itself) is normalized to `index.html`
  before the tool runs; `content`/`old_text`/`new_text` are left untouched.
- ✅ **Repetition breaker across turns** — a call that already errored twice
  in the stored history is refused and the model is told to change approach.

### Server-side (omlx / MLX)

- ⬜ **Prompt/KV-cache reuse** — if the server exposes it, enable it: agent
  loops re-send the same prefix every turn, so cache hits cut per-turn time
  dramatically. Nothing to change client-side.

### Possible next steps

- ⬜ Tool-call streaming for multi-call replies (currently extra calls are
  rejected, not executed).
- ⬜ Prompt-cache-aware trimming (keep the system prefix byte-identical).
- ⬜ Session compaction (`/compact` + auto): once a session grows near the
  context window, replace the oldest turns with a summary so nothing is lost
  silently when the request is trimmed.
- ⬜ A CI workflow running the Docker test command in the README.
- ⬜ Release packaging: an `install.sh` that installs prebuilt binaries from a
  local `dist/` (then GitHub Releases), with `~/.usagi/versions/<v>`, checksums
  and an atomic `current` switch; `scripts/dev.sh` stays the developer path.

## Notes

- The whole conversation is kept in memory for the session; every request
  re-sends the history, but `build_body` now ages old tool output and drops
  whole oldest turns above ~75% of the context window.
- `/save`/`/load` persist a conversation as JSON, relative to the workspace
  folder. Separately, every finished turn is **autosaved** to
  `~/.usagi/sessions/<id>.jsonl` (one JSON line per message) with a small
  `index.json` manifest; `/sessions` with no argument opens a **filterable
  picker** (like `/model`; type to filter, `↑/↓` + `enter` resumes, `esc`
  cancels), while `/sessions <filter>` prints a text list and
  `/resume <id|name>` restores one directly (history, stats and, unless
  disabled, its stored workspace). `/session new|save|title|rename|rm|clean`
  manages them. `~/.usagi/sessions/`
  is overridable via `sessions.dir` / `USAGI_SESSIONS_DIR`; `autosave`,
  `restore_workspace`, `max` and `max_age_days` are configurable too.
- Before the first release there is no packaged installer: `scripts/dev.sh`
  builds into `~/.usagi`, symlinks the repo runtime files (`system.md`,
  `config.json`, `.env`, `pet.txt`) there and links `usagi` into PATH. `config.json`/`system.md`/`pet.txt`/`.env` are looked up next to the
  binary (that is, in `~/.usagi`), so the agent runs from any directory.
- The agent works on the current directory by default, or on the folder given
  on the command line (`usagi .`, `usagi /path`); `workspace` in the config or
  `WORKSPACE` in `.env` pins a fixed folder instead.
