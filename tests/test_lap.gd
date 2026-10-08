extends TestCase
## Autopilot on the Red Bull Ring: the car must stay on the road, avoid drifting on straights and
## post sane speeds. The suite runs one representative sector (grid -> past Remus, ~25 s of
## physics). The full lap runs with `--full-lap` (tools/lap_demo.sh, fixed-fps, much faster).

const SCENE := "res://scenes/race_red_bull_ring.tscn"
const TICK := 1.0 / 240.0

var _scene: Node
var _car: Car
var _pilot: Autopilot
var _data: TrackData
## Per-run measurements (independent of the autopilot's own bookkeeping).
var _progress: float = 0.0
var _time: float = 0.0
var _max_abs_offset: float = 0.0
var _worst_edge: float = INF
var _worst_edge_s: float = 0.0
var _straight_drift: int = 0

func _start() -> bool:
	Bootstrap.autodrive = true
	_scene = spawn(SCENE)
	_car = _scene.get_node("Car") as Car
	_pilot = _scene.get_node("Autodrive") as Autopilot
	_data = (_scene.get_node("Track") as Track).data
	assert_true(_pilot != null, "Autodrive node must run the Autopilot")
	assert_true(Bootstrap.autodrive_provider == _pilot, "Autopilot registers as autodrive provider")
	if _pilot == null:
		return false
	# Robust to a race countdown freezing the car: wait for it to start rolling.
	var waited := 0
	while _car.linear_velocity.length() < 1.0 and waited < 240 * 12:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 12, "car never started moving")
	return waited < 240 * 12

func _finish() -> void:
	Bootstrap.autodrive = false

## Steps physics until `done` returns true or `timeout_s` of physics time elapses, checking the
## on-road and no-straight-drift invariants every tick.
func _drive(done: Callable, timeout_s: float) -> bool:
	var s := _data.closest_s(_car.global_position)
	while _time < timeout_s:
		await physics_frames(1)
		_time += TICK
		var pos := _car.global_position
		var ns := _data.closest_s(pos, s)
		_progress += _data.delta_s(s, ns)
		s = ns
		var off := absf(_data.lateral_offset(pos, s))
		_max_abs_offset = maxf(_max_abs_offset, off)
		var edge := _data.width_at(s) * 0.5 - off
		if edge < _worst_edge:
			_worst_edge = edge
			_worst_edge_s = s
		if _car.is_drifting and _centre_curvature(s) < 1.0 / 250.0:
			_straight_drift += 1
		if done.call():
			return true
	return false

func _centre_curvature(s: float) -> float:
	var a := _data.tangent_at(s - 8.0)
	var b := _data.tangent_at(s + 8.0)
	return a.angle_to(b) / 16.0

func _turn(id: String) -> Dictionary:
	var rows := _pilot.last_lap_turn_stats if not _pilot.last_lap_turn_stats.is_empty() else _pilot.per_turn_stats
	for st in rows:
		if st["id"] == id:
			return st
	return {}

func _common_asserts() -> void:
	assert_true(_worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f (max |offset| %.2f m)" % [
			_worst_edge, _worst_edge_s, _max_abs_offset])
	assert_true(_straight_drift == 0, "drifted on a straight for %d ticks" % _straight_drift)

func test_sector_grid_to_remus() -> void:
	if not await _start():
		_finish()
		return
	var target := _data.delta_s(_data.closest_s(_car.global_position), 1500.0)
	var ok := await _drive(func() -> bool: return _progress >= target, 45.0)
	assert_true(ok, "sector grid -> s=1500 not completed in 45 s (progress %.0f m)" % _progress)
	_common_asserts()
	var remus := _turn("T3")
	assert_true(not remus.is_empty() and float(remus["min_kmh"]) > 0.0, "Remus stats recorded")
	if not remus.is_empty():
		assert_between(float(remus["min_kmh"]), 30.0, 110.0, "Remus min speed (km/h)")
		assert_true(float(remus["max_before_kmh"]) > 280.0,
				"top speed on the run to Remus %.0f km/h, expected > 280" % float(remus["max_before_kmh"]))
	assert_between(_time, 15.0, 35.0, "sector time grid -> s=1500 (s)")
	print("       sector grid->1500 m: %.2f s, max |offset| %.2f m, min edge margin %.2f m" % [
			_time, _max_abs_offset, _worst_edge])
	_finish()

func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap, see tools/lap_demo.sh)")
		return
	if not await _start():
		_finish()
		return
	var ok := await _drive(func() -> bool: return _pilot.laps_completed >= 1, 150.0)
	assert_true(ok, "lap not completed in 150 s of physics (progress %.0f m)" % _progress)
	_common_asserts()
	assert_between(_pilot.lap_time, 65.0, 90.0, "lap time (s)")
	var remus := _turn("T3")
	if not remus.is_empty():
		assert_true(float(remus["min_kmh"]) < 110.0, "Remus min speed %.0f km/h" % float(remus["min_kmh"]))
		assert_true(float(remus["max_before_kmh"]) > 280.0, "top speed before Remus %.0f km/h" % float(remus["max_before_kmh"]))
	for st in _pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nLAP 1 (from the grid, timed start line to start line)\n" + _pilot.report())
	print("       test clock: %.0f m in %.2f s total, max |offset| %.2f m, min edge %.2f m at s=%.0f\n" % [
			_progress, _time, _max_abs_offset, _worst_edge, _worst_edge_s])
	var standing := _pilot.lap_time
	# Second (flying) lap: same invariants, should be quicker than the standing one.
	ok = await _drive(func() -> bool: return _pilot.laps_completed >= 2, _time + 120.0)
	assert_true(ok, "flying lap not completed")
	_common_asserts()
	assert_between(_pilot.lap_time, 65.0, standing + 0.5, "flying lap time (s)")
	print("\nLAP 2 (flying)\n" + _pilot.report() + "\n")
	_finish()
