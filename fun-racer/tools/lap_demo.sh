#!/usr/bin/env bash
# Full autopilot lap, headless and as fast as the CPU allows
# (--fixed-fps 240: one 240 Hz physics tick per frame, no real-time sync).
# Prints the per-turn table (entry / apex / exit speed) and the lap time; exits non-zero if the
# lap checks fail.
# Usage: tools/lap_demo.sh [track_id] [runner args]
#   no track id: the Red Bull Ring (tests/test_lap.gd)
#   a track id:  that track's own lap test, tests/test_track_<id>.gd (e.g. spa)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILTER=test_lap
if [[ $# -gt 0 && "$1" != -* ]]; then
	FILTER="test_track_$1"
	[[ -f "$ROOT/tests/$FILTER.gd" ]] || { echo "no lap test for track '$1' (tests/$FILTER.gd)" >&2; exit 2; }
	shift
fi
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --fixed-fps 240 --disable-vsync \
	-s res://tests/runner.gd -- --filter="$FILTER" --full-lap "$@"
