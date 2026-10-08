extends RefCounted
## Trackmania-style race clock. Waits after spawn/respawn and starts on the first
## driver input. Advanced only from the physics step, so it is deterministic.

enum State { WAITING, RUNNING }

var state: State = State.WAITING
var elapsed: float = 0.0

## Call once per physics tick. `has_input` = any driver input this tick.
func step(delta: float, has_input: bool) -> void:
	if state == State.WAITING:
		if not has_input:
			return
		state = State.RUNNING
	elapsed += delta

func reset() -> void:
	state = State.WAITING
	elapsed = 0.0

func is_running() -> bool:
	return state == State.RUNNING

## Formats seconds as M:SS.mmm (truncated to the millisecond, like Trackmania).
static func format_time(seconds: float) -> String:
	var ms: int = to_ms(seconds)
	@warning_ignore("integer_division")
	var minutes: int = ms / 60000
	@warning_ignore("integer_division")
	var secs: int = (ms / 1000) % 60
	return "%d:%02d.%03d" % [minutes, secs, ms % 1000]

## Whole milliseconds (truncated, never negative) used for display.
static func to_ms(seconds: float) -> int:
	return maxi(0, floori(seconds * 1000.0 + 1e-4))
