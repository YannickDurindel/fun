#!/usr/bin/env bash
# Renders a scene (default main) with autodrive and saves a PNG after N frames.
# Usage: tools/screenshot.sh OUT.png [res://scene.tscn] [frames] [extra user args, e.g. --spawn_s=1300]
#
# Extra user args go to the game (scripts/bootstrap.gd). Useful ones for judging a track:
#   --track=ID --spawn_s=METRES --camera=1|2|3   where the car is and which chase camera
#   --cam-pos=x,y,z [--cam-look=x,y,z]           fixed free camera (looks at the car without --cam-look)
#   --overview                                   the whole lap from high above, fog pushed back
#   --time=day|dusk|night                        lighting override, to compare times of day
#   --quality=low|medium|high                    graphics preset (trees, facades, shadows ...)
#   --scenery-dir=PATH                           read the scenery files from another folder
#   --no-scenery                                 the track without any scenery file
#   --tour=S1,S2,... | --tour=every:400          MANY pictures in ONE run (one track load): the
#                                                car is put at each distance in turn and
#                                                OUT_<metres>.png is saved. Use this instead of
#                                                one run per picture; add --tour-frames=N to
#                                                settle longer at each stop (default 70).
# Example: tools/screenshot.sh "$PWD/shots/monaco_night.png" res://scenes/race.tscn 300 \
#              --track=monaco --spawn_s=1300 --camera=2 --time=night
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
# A tour saves OUT_<metres>.png files and runs longer than a single picture.
TOUR=0; LIMIT="${FUN_SHOT_TIMEOUT:-180}"
for a in "${@:4}"; do [[ "$a" == --tour=* ]] && { TOUR=1; LIMIT="${FUN_SHOT_TIMEOUT:-900}"; }; done
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
	WAYLAND_DISPLAY="$SOCK" DISPLAY= timeout "$LIMIT" "$GODOT" --display-driver wayland "${ARGS[@]}"
else
	timeout "$LIMIT" "$GODOT" "${ARGS[@]}"
fi
if [[ "$TOUR" == 1 ]]; then
	ls "${OUT%.*}"_[0-9]*."${OUT##*.}" >/dev/null 2>&1 && echo "OK: ${OUT%.*}_*.${OUT##*.}"
else
	test -f "$OUT" && echo "OK: $OUT"
fi
