#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT"

if command -v python3 >/dev/null 2>&1; then
  exec python3 "$ROOT/start.py" "$@"
fi

if command -v python >/dev/null 2>&1; then
  exec python "$ROOT/start.py" "$@"
fi

echo "Python was not found. Please install Python 3 or add it to PATH." >&2
exit 1
