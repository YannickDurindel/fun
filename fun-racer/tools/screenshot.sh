#!/usr/bin/env bash
# Renders a scene (default main) with autodrive and saves a PNG after N frames.
# Usage: tools/screenshot.sh OUT.png [res://scene.tscn] [frames] [extra user args, e.g. --spawn_s=1300]
#
# The render happens OFF-SCREEN: a private virtual Wayland compositor (kwin_wayland --virtual)
# is started for the run, so no window appears on the desktop. Only one screenshot renders at
# a time on the machine (a lock in ~/.cache/fun-racer), so parallel callers queue instead of
# starting many Godot instances at once. Set FUN_SCREENSHOT_VISIBLE=1 to use a normal window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(realpath -m "${1:?output png path required}")"
SCENE="${2:-res://scenes/main.tscn}"
FRAMES="${3:-120}"
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
ARGS=(--path "$ROOT" --resolution 1280x720 "$SCENE" -- --autodrive --screenshot="$OUT" --frames="$FRAMES" "${@:4}")

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/fun-racer"
mkdir -p "$CACHE"
exec 9>"$CACHE/screenshot.lock"
flock -w 1800 9 || { echo "screenshot: timed out waiting for the render lock" >&2; exit 1; }

if [[ "${FUN_SCREENSHOT_VISIBLE:-0}" != "1" ]] && command -v kwin_wayland >/dev/null; then
	SOCK="fun-racer-shot-$$"
	kwin_wayland --virtual --no-lockscreen --socket "$SOCK" --width 1280 --height 720 >/dev/null 2>&1 &
	KWIN=$!
	trap 'kill "$KWIN" 2>/dev/null || true' EXIT
	for _ in $(seq 50); do
		[[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$SOCK" ]] && break
		sleep 0.1
	done
	WAYLAND_DISPLAY="$SOCK" DISPLAY= timeout 180 "$GODOT" --display-driver wayland "${ARGS[@]}"
else
	timeout 180 "$GODOT" "${ARGS[@]}"
fi
test -f "$OUT" && echo "OK: $OUT"
