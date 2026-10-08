#!/usr/bin/env bash
# Renders a scene (default main) with autodrive and saves a PNG after N frames.
# Usage: tools/screenshot.sh OUT.png [res://scene.tscn] [frames] [extra user args, e.g. --spawn_s=1300]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(realpath -m "${1:?output png path required}")"
SCENE="${2:-res://scenes/main.tscn}"
FRAMES="${3:-120}"
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
timeout 120 "$GODOT" --path "$ROOT" --resolution 1280x720 "$SCENE" -- --autodrive --screenshot="$OUT" --frames="$FRAMES" "${@:4}"
test -f "$OUT" && echo "OK: $OUT"
