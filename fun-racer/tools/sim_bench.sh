#!/usr/bin/env bash
# Calibration bench for the simulation car: standard manoeuvres on a flat pad, headless and
# faster than real time, as one table against real F1 numbers (docs/sim_targets.md).
#
# Usage: tools/sim_bench.sh [--csv FILE] [--only NAME[,NAME]] [--handling=simulation|arcade] [--lap TRACK]
#   --only NAME   run some groups only: launch, top_speed, braking, cornering, step_steer,
#                 lift_off, ride (comma separated); "lap" with --lap runs the lap alone
#   --csv FILE    record the whole run (60 Hz) to FILE; the `marker` column is the manoeuvre
#   --lap TRACK   also drive tools/lap_check.sh TRACK and compare the flying lap with the pole
#
# Exit code: 0 when the bench ran, whatever the PASS / WARN / FAIL column says (the table is
# the result); non-zero only for a script error, a crash, a timeout or a bad argument.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
ARGS=()
HANDLING="simulation"
LAP=""
ONLY=""
while (($#)); do
	case "$1" in
		--csv) ARGS+=("--csv=$(realpath -m "${2:?--csv needs a file}")"); shift 2 ;;
		--csv=*) ARGS+=("--csv=$(realpath -m "${1#--csv=}")"); shift ;;
		--only) ONLY="${2:?--only needs a name}"; shift 2 ;;
		--only=*) ONLY="${1#--only=}"; shift ;;
		--handling) HANDLING="${2:?--handling needs a model}"; shift 2 ;;
		--handling=*) HANDLING="${1#--handling=}"; shift ;;
		--lap) LAP="${2:?--lap needs a track id}"; shift 2 ;;
		--lap=*) LAP="${1#--lap=}"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "sim_bench: unknown argument '$1'" >&2; usage >&2; exit 64 ;;
	esac
done
if [[ "$HANDLING" != "simulation" && "$HANDLING" != "arcade" ]]; then
	echo "sim_bench: unknown handling '$HANDLING' (simulation or arcade)" >&2
	exit 64
fi
[[ -n "$ONLY" ]] && ARGS+=("--only=$ONLY")
ARGS+=("--handling=$HANDLING")
"$ROOT/tools/get_godot.sh"
GODOT="$ROOT/tools/bin/godot"
[[ -d "$ROOT/.godot" ]] || "$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

if [[ -n "$LAP" ]]; then
	# The lap check prints e.g.  LAPCHECK id [simulation] OK laps=["1:12.345", "1:08.901"] top=...
	# The second lap is the flying one. Its exit code only says whether the laps were clean.
	echo "  .. lap check on $LAP ($HANDLING), this takes a while"
	LAPOUT="$("$ROOT/tools/lap_check.sh" "$LAP" --handling="$HANDLING" 2>&1 || true)"
	echo "$LAPOUT" | grep -E "LAPCHECK|SCRIPT ERROR" || true
	if echo "$LAPOUT" | grep -q "SCRIPT ERROR"; then
		echo "sim_bench: the lap check reported script errors" >&2
		exit 2
	fi
	LINE="$(echo "$LAPOUT" | grep -E "^LAPCHECK " | tail -n 1 || true)"
	STATUS="NONE"
	[[ "$LINE" == *" OK "* ]] && STATUS="OK"
	[[ "$LINE" == *" FAIL "* ]] && STATUS="NOT-CLEAN"
	LAPS="$(echo "$LINE" | sed -n 's/.*laps=\[\(.*\)\] top=.*/\1/p' | tr -d '" ')"
	LAST="$(echo "$LAPS" | awk -F, '{print $NF}')"
	LAP_S="-1"
	if [[ "$LAST" =~ ^([0-9]+):([0-9.]+)$ ]]; then
		LAP_S="$(awk -v m="${BASH_REMATCH[1]}" -v s="${BASH_REMATCH[2]}" 'BEGIN { printf "%.3f", m * 60 + s }')"
		# One lap only: there was no flying lap; do not pass the standing lap off as one.
		if [[ "$(echo "$LAPS" | awk -F, '{print NF}')" -lt 2 ]]; then
			LAP_S="-1"
			STATUS="NO-FLYING-LAP"
		fi
	fi
	ARGS+=("--bench-lap=$LAP:$LAP_S:$STATUS")
fi

set +e
timeout 600 "$GODOT" --headless --path "$ROOT" --fixed-fps 240 --disable-vsync \
	-s res://tools/sim_bench.gd -- "${ARGS[@]}" 2>&1 | tee "$LOG" | grep --line-buffered -vE "^Godot Engine v"
status=${PIPESTATUS[0]}
set -e
if grep -qE "SCRIPT ERROR|Parse Error" "$LOG"; then
	echo "sim_bench: script errors were reported; the table cannot be trusted." >&2
	exit 2
fi
if [[ "$status" -ne 0 ]]; then
	echo "sim_bench: the run failed or timed out (exit $status)." >&2
	exit "$status"
fi
if ! grep -q "^BENCH DONE" "$LOG"; then
	echo "sim_bench: the run ended without finishing." >&2
	exit 3
fi
