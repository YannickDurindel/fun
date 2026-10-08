#!/usr/bin/env bash
# Autopilot lap check for any track, headless and faster than real time.
# Usage: tools/lap_check.sh <track_id> [--lap-report]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="${1:?track id required}"
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
timeout 900 "$GODOT" --headless --path "$ROOT" --fixed-fps 240 --disable-vsync \
	-s res://tools/lap_check.gd -- --lap-track="$ID" "${@:2}" 2>&1 | grep -E "LAPCHECK|SCRIPT ERROR|turn |^T[0-9]|lap_time" || true
