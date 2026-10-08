#!/usr/bin/env bash
# Runs all headless tests. Extra args are passed to the runner (e.g. --filter=car).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
# A test that hits a script error aborts its coroutine but can still be reported as PASS, so
# any SCRIPT ERROR / Parse Error in the output fails the run.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
set +e
"$GODOT" --headless --path "$ROOT" -s res://tests/runner.gd -- "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e
if grep -qE "SCRIPT ERROR|Parse Error" "$LOG"; then
	echo "FAILED: script errors were reported during the run (see above)."
	exit 1
fi
exit "$status"
