#!/bin/bash
# Frame-time benchmark of a track at 1280x720 with bots (the W1-D perf budget: >= 50 fps on the
# Intel HD 520, Mobile renderer). Prints Bootstrap's "FRAMETIME avg=... ms" line.
#   tools/render_bench.sh [track_id] [bots] [frames]      default: wec_le_mans 9 900
# The car starts on the grid (pit straight); 300 warm-up frames, then `frames` are timed.
# MESA_VK_WSI_PRESENT_MODE=immediate: on Wayland --disable-vsync alone still caps at the
# display rate (60 fps), which hides everything below 16.7 ms.
cd "$(dirname "$0")/.." || exit 1
TRACK=${1:-wec_le_mans}
BOTS=${2:-9}
FRAMES=${3:-900}
MESA_VK_WSI_PRESENT_MODE=immediate tools/bin/godot --path . --resolution 1280x720 --disable-vsync -- \
	--track="$TRACK" --bots="$BOTS" --ghost=0 --no-countdown --frames=300 --bench="$FRAMES" 2>&1 \
	| grep -E "FRAMETIME|SCRIPT ERROR|SHADER ERROR"
