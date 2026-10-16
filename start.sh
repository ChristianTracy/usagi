#!/usr/bin/env bash
# Build and run usagi.
#
# Native (needs the V compiler, https://vlang.io):
#   ./start.sh [--debug]
#
# Without installing V on the host, build and run in Docker:
#   ./start.sh --docker [--debug]
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--docker" ]; then
    shift
    exec docker run --rm -it -v "$PWD:/app" -w /app thevlang/vlang:latest \
        sh -c 'v -enable-globals -o usagi . && exec ./usagi "$@"' -- "$@"
fi

if ! command -v v >/dev/null 2>&1; then
    echo "error: the V compiler is not installed. Use ./start.sh --docker, or see https://vlang.io" >&2
    exit 1
fi

v -enable-globals -o usagi .
exec ./usagi "$@"
