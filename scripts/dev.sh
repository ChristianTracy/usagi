#!/usr/bin/env bash
# Developer install for usagi (pre-release).
#
#   scripts/dev.sh install     build + link `usagi` into PATH (default)
#   scripts/dev.sh build       build only, into $USAGI_HOME/usagi
#   scripts/dev.sh link        (re)create the `usagi` symlinks
#   scripts/dev.sh sync        (re)link config.json/system.md/pet.txt/.env
#   scripts/dev.sh unlink      remove the `usagi` symlinks
#   scripts/dev.sh uninstall   unlink + remove $USAGI_HOME
#   scripts/dev.sh status      show the current install
#   scripts/dev.sh help        this help
#
# In developer mode the runtime files (etc/config.json, etc/system.md,
# etc/pet.txt, etc/.env) are *symlinked* from the repo into $USAGI_HOME, so
# editing them in the repo takes effect immediately. Set USAGI_COPY=1 to copy
# them instead.
#
# Everything is self-contained under $USAGI_HOME, so "uninstall" is just
# removing it (symlinks are unlinked, never their repo targets). Overrides:
#
#   USAGI_HOME=...     install root        (default: ~/.usagi)
#   USAGI_BIN_DIR=...  where the link goes (default: ~/.local/bin)
#   USAGI_COPY=1       copy runtime files instead of linking them
#   V=...              V compiler          (default: v)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGI_HOME="${USAGI_HOME:-$HOME/.usagi}"
BIN_DIR="${USAGI_BIN_DIR:-$HOME/.local/bin}"
V="${V:-v}"

# RUNTIME_FILES are read by usagi from `etc/` under the app folder. In dev they
# point at the repo so there is a single source of truth.
RUNTIME_FILES="etc/config.json etc/system.md etc/pet.txt etc/.env"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

# sync_files points the runtime files at the repo (developer mode). An existing
# regular file is kept as `<name>.local.bak` and replaced by the link, so an
# edit made directly in $USAGI_HOME is never lost silently. With USAGI_COPY=1
# it copies instead of linking.
sync_files() {
  mkdir -p "$USAGI_HOME"
  for f in $RUNTIME_FILES; do
    src="$ROOT/$f"
    dst="$USAGI_HOME/$f"
    mkdir -p "$(dirname "$dst")"
    if [ ! -f "$src" ]; then
      continue
    fi
    if [ -L "$dst" ]; then
      ln -sfn "$src" "$dst"
      continue
    fi
    if [ -e "$dst" ]; then
      mv "$dst" "$dst.local.bak"
      say "kept previous $dst as $dst.local.bak"
    fi
    if [ "${USAGI_COPY:-0}" = "1" ]; then
      cp "$src" "$dst"
      say "copied $dst <- $src"
    else
      ln -s "$src" "$dst"
      say "linked $dst -> $src"
    fi
  done
  # No repo .env yet: seed the example once so usagi can start.
  if [ ! -e "$USAGI_HOME/etc/.env" ] && [ -f "$ROOT/etc/.env.example" ]; then
    cp "$ROOT/etc/.env.example" "$USAGI_HOME/etc/.env"
    chmod 600 "$USAGI_HOME/etc/.env"
    say "seeded $USAGI_HOME/etc/.env from etc/.env.example (edit it, or create $ROOT/etc/.env)"
  fi
}

build() {
  command -v "$V" >/dev/null 2>&1 || die "$V not found in PATH (set V=/path/to/v)"
  mkdir -p "$USAGI_HOME"
  # Build beside the target and move into place, so a binary in use is never
  # truncated by the compiler.
  tmp="$USAGI_HOME/.usagi.new.$$"
  trap 'rm -f "$tmp"' EXIT
  ( cd "$ROOT" && "$V" -enable-globals -prod -o "$tmp" . )
  mv -f "$tmp" "$USAGI_HOME/usagi"
  trap - EXIT
  sync_files
  say "built  $USAGI_HOME/usagi"
}

link() {
  [ -x "$USAGI_HOME/usagi" ] || die "no binary at $USAGI_HOME/usagi (run: $0 build)"
  mkdir -p "$USAGI_HOME/bin" "$BIN_DIR"
  ln -sfn "$USAGI_HOME/usagi" "$USAGI_HOME/bin/usagi"
  ln -sfn "$USAGI_HOME/usagi" "$BIN_DIR/usagi"
  say "linked $BIN_DIR/usagi -> $USAGI_HOME/usagi"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "note: add it to PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
  esac
}

unlink() {
  for l in "$BIN_DIR/usagi" "$USAGI_HOME/bin/usagi"; do
    if [ -L "$l" ]; then
      rm -f "$l"
      say "removed $l"
    fi
  done
}

uninstall() {
  unlink
  if [ -d "$USAGI_HOME" ]; then
    # rm does not follow symlinks here: the repo files are left untouched.
    rm -rf "$USAGI_HOME"
    say "removed $USAGI_HOME"
  fi
}

status() {
  say "repo:       $ROOT"
  say "USAGI_HOME: $USAGI_HOME"
  if [ -x "$USAGI_HOME/usagi" ]; then
    say "binary:     $USAGI_HOME/usagi"
  else
    say "binary:     (none)"
  fi
  for f in $RUNTIME_FILES; do
    p="$USAGI_HOME/$f"
    if [ -L "$p" ]; then
      say "file:       $f -> $(readlink "$p")"
    elif [ -e "$p" ]; then
      say "file:       $f (copy)"
    else
      say "file:       $f (none)"
    fi
  done
  for l in "$BIN_DIR/usagi" "$USAGI_HOME/bin/usagi"; do
    if [ -L "$l" ]; then
      say "link:       $l -> $(readlink "$l")"
    else
      say "link:       $l (none)"
    fi
  done
}

case "${1:-install}" in
  build) build ;;
  link) link ;;
  sync) sync_files ;;
  unlink) unlink ;;
  install) build; link ;;
  uninstall) uninstall ;;
  status) status ;;
  -h | --help | help) usage ;;
  *) die "unknown command: $1 (try: $0 help)" ;;
esac
