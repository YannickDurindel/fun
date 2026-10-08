#!/usr/bin/env bash
# Full autopilot lap of the Red Bull Ring, headless and as fast as the CPU allows
# (--fixed-fps 240: one 240 Hz physics tick per frame, no real-time sync).
# Prints the per-turn table (entry / apex / exit speed) and the lap time; exits non-zero if the
# lap checks in tests/test_lap.gd fail.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --fixed-fps 240 --disable-vsync \
	-s res://tests/runner.gd -- --filter=test_lap --full-lap "$@"
