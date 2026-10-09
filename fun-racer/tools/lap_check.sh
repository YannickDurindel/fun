#!/usr/bin/env bash
# Autopilot lap check for any track, headless and faster than real time.
# Usage: tools/lap_check.sh <track_id> [--handling=arcade|simulation] [--lap-report]
#            [--lap-tracks-dir=res://tests/fixtures/tracks]   (a fixture or scratch track)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="${1:?track id required}"
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
timeout 900 "$GODOT" --headless --path "$ROOT" --fixed-fps 240 --disable-vsync \
	-s res://tools/lap_check.gd -- --lap-track="$ID" "${@:2}" > "$LOG" 2>&1 || true
grep -E "LAPCHECK|SCRIPT ERROR|turn |^T[0-9]|lap_time" "$LOG" || echo "LAPCHECK $ID NO RESULT"
# A script error means the result cannot be trusted, whatever the line above says.
if grep -q "SCRIPT ERROR" "$LOG"; then exit 2; fi
grep -q "LAPCHECK .* OK " "$LOG"
