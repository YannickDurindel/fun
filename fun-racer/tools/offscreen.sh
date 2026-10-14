#!/usr/bin/env bash
# Runs a command (usually tools/bin/godot ...) on a hidden Wayland display, so screenshots,
# renders and benchmarks use the GPU without opening a window on the desktop.
# Needs weston (dnf install weston). Starts a headless weston on socket "wayland-offscreen"
# the first time and leaves it running for the next calls.
#   tools/offscreen.sh tools/bin/godot --path . -- --track=wec_le_mans --screenshot=out.png
set -euo pipefail
SOCK=wayland-offscreen
RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ ! -S "$RUN/$SOCK" ]] || ! pgrep -f "weston.*--socket=$SOCK" >/dev/null; then
	rm -f "$RUN/$SOCK" "$RUN/$SOCK.lock"
	# weston outlives this call: it must not keep the caller's other file descriptors open (a
	# `flock LOCK tools/offscreen.sh ...` caller would otherwise stay locked as long as weston runs).
	(
		for fd in /proc/$BASHPID/fd/*; do
			fd=${fd##*/}
			if ((fd > 2)); then eval "exec $fd>&-" 2>/dev/null || true; fi
		done
		exec nohup weston --backend=headless --renderer=gl --socket="$SOCK" --width=1920 --height=1080 \
			--idle-time=0 >/dev/null 2>&1
	) &
	for _ in $(seq 50); do [[ -S "$RUN/$SOCK" ]] && break; sleep 0.1; done
fi
# Godot picks the display server from the environment: no X11, only the hidden Wayland socket.
cmd=("$@")
if [[ "${cmd[0]}" == *godot* && " ${cmd[*]} " != *" --display-driver "* && " ${cmd[*]} " != *" --headless "* ]]; then
	cmd=("${cmd[0]}" --display-driver wayland "${cmd[@]:1}")
fi
exec env -u DISPLAY WAYLAND_DISPLAY="$SOCK" "${cmd[@]}"
