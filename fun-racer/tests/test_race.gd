extends TestCase
## Race flow: countdown, checkpoints in order, lap timing, splits, respawn-to-checkpoint, wrong way.

const SCENE := "res://scenes/race_red_bull_ring.tscn"

var _scene: Node
var race: RaceManager
var car: Car
var data: TrackData

func _setup(skip_countdown: bool = true) -> void:
	Bootstrap.autodrive = false
	Bootstrap.skip_countdown = false
	_scene = spawn(SCENE)
	race = _scene.get_node("Track/Race") as RaceManager
	car = _scene.get_node("Car") as Car
	data = race.data
	race.persist_best = false
	race.clear_best()
	if skip_countdown:
		race.start_now()

## Teleports the frozen car along the centreline from s_from to s_to (unwrapped, increasing),
## one physics tick per `step` metres. Returns the number of ticks.
func _drive(s_from: float, s_to: float, step: float, skip: Vector2 = Vector2(-1, -1)) -> int:
	car.simulate = false
	car.linear_velocity = Vector3.ZERO
	var ticks := 0
	var x := s_from
	while x < s_to:
		x = minf(x + step, s_to)
		if skip.x >= 0.0 and x > skip.x and x < skip.y:
			x = skip.y
		car.global_transform = race.track.spawn_transform(x)
		await get_tree().physics_frame
		ticks += 1
	return ticks

func test_checkpoint_layout() -> void:
	_setup()
	var cps := race.checkpoints
	assert_true(cps.size() >= 8 and cps.size() <= 10, "checkpoint count %d" % cps.size())
	for b in data.sectors:
		if b > 0.0:
			assert_true(Array(cps).has(b), "sector boundary %.1f must be a checkpoint" % b)
	var prev := 0.0
	for c in cps:
		assert_between(c - prev, 300.0, 650.0, "checkpoint spacing before %.0f" % c)
		prev = c
	assert_between(data.length - prev, 300.0, 650.0, "last checkpoint to finish")

func test_countdown_blocks_movement() -> void:
	_setup(false)
	var p0 := car.global_position
	car.set_input_override(1.0, 0.0, 0.0)
	await physics_frames(360)  # 1.5 s of the 2.4 s countdown, throttle held
	assert_true(race.state == RaceManager.State.COUNTDOWN, "still counting down")
	assert_true(car.global_position.distance_to(p0) < 0.01, "car frozen during countdown (moved %.3f m)" % car.global_position.distance_to(p0))
	assert_true(race.lap_time() == 0.0, "clock not running in countdown")
	await physics_frames(360)
	assert_true(race.state == RaceManager.State.RACING, "racing after GO")
	assert_true(car.global_position.distance_to(p0) > 0.3, "car drives after GO")
	assert_between(race.lap_time(), 0.4, 0.7, "clock started at GO")
	car.clear_input_override()

func test_full_lap_by_teleport() -> void:
	_setup()
	var s0 := race.s
	var ticks := await _drive(s0, data.length + 20.0, 25.0)
	assert_true(race.laps_completed == 1, "one lap completed, got %d" % race.laps_completed)
	assert_true(race.next_checkpoint == 0, "new lap expects the first checkpoint")
	# Lap time = ticks until crossing s = 0 (interpolated), on the physics clock.
	var expected := (ticks - 20.0 / 25.0) / 240.0
	assert_between(race.last_lap, expected - 0.01, expected + 0.01, "lap time")
	assert_true(race.best_lap == race.last_lap, "first lap is the best")
	assert_true(race.best_splits.size() == race.checkpoints.size() + 1, "best splits stored")
	assert_true(race.current_sectors.size() == 0, "sectors reset for lap 2")
	# Sector times add up to the lap, and S1 spans the lap start to the first boundary.
	var b1 := race.checkpoint_sector.find(0)
	assert_between(race.best_sectors[0], race.best_splits[b1] - 0.001, race.best_splits[b1] + 0.001, "S1 time")
	var sum := 0.0
	for st in race.best_sectors:
		sum += st
	assert_between(sum, race.last_lap - 0.001, race.last_lap + 0.001, "sum of sectors")

func test_skipped_checkpoint_does_not_count() -> void:
	_setup()
	var cp := race.checkpoints[2]
	var invalid := [false]
	race.lap_invalidated.connect(func() -> void: invalid[0] = true)
	await _drive(race.s, data.length + 20.0, 25.0, Vector2(cp - 40.0, cp + 40.0))
	assert_true(race.laps_completed == 0, "lap with a skipped checkpoint must not count")
	assert_true(invalid[0], "lap_invalidated emitted")
	assert_true(race.best_lap < 0.0, "no best lap")

func test_split_sign() -> void:
	assert_true(RaceManager.format_delta(-0.234) == "-0.234", "negative delta: " + RaceManager.format_delta(-0.234))
	assert_true(RaceManager.format_delta(0.12) == "+0.120", "positive delta: " + RaceManager.format_delta(0.12))
	assert_true(RaceManager.delta_color(-0.1).b > 0.8, "faster is blue")
	assert_true(RaceManager.delta_color(0.1).r > 0.8, "slower is red")
	_setup()
	await _drive(race.s, data.length + 1.0, 25.0)
	assert_true(race.laps_completed == 1, "lap 1 done")
	var deltas: Array[float] = []
	race.checkpoint_passed.connect(func(_i: int, _t: float, dt: float, has: bool) -> void:
		if has: deltas.append(dt))
	# Lap 2 slower over the first checkpoint, much faster afterwards.
	var cp0 := race.checkpoints[0]
	await _drive(data.length + 1.0, data.length + cp0 + 5.0, 10.0)
	await _drive(data.length + cp0 + 5.0, data.length * 2.0 + 10.0, 49.0)
	assert_true(deltas.size() == race.checkpoints.size(), "a delta at every checkpoint (%d)" % deltas.size())
	if deltas.size() >= 2:
		assert_true(deltas[0] > 0.0, "slower to CP1 -> positive split (%.3f)" % deltas[0])
		assert_true(deltas[-1] < 0.0, "faster by the last CP -> negative split (%.3f)" % deltas[-1])
	assert_true(race.laps_completed == 2 and race.best_lap == race.last_lap, "lap 2 is the new best")
	await get_tree().process_frame
	var panel := _scene.get_node("UI/RacePanel")
	assert_true(String(panel.call(&"get_split_text")).begins_with("-"), "panel shows a negative lap delta: " + String(panel.call(&"get_split_text")))

func test_respawn_to_checkpoint_with_speed() -> void:
	_setup()
	await physics_frames(2)   # let the grid respawn queued by restart() apply first
	var cp := race.checkpoints[0]
	car.global_transform = race.track.spawn_transform(cp - 6.0)
	await get_tree().physics_frame
	race.s = data.closest_s(car.global_position)
	car.simulate = true
	car.set_input_override(0.0, 0.0, 0.0)
	var v0 := -car.global_transform.basis.z * 40.0
	car.linear_velocity = v0
	await physics_frames(60)
	assert_true(race.next_checkpoint == 1, "checkpoint 1 passed")
	var rec := car.spawn_transform
	assert_true(absf(data.delta_s(cp, data.closest_s(rec.origin))) < 2.0, "spawn point moved to the checkpoint")
	await physics_frames(120)
	car.respawn()
	await physics_frames(4)
	var speed := car.linear_velocity.length()
	assert_between(speed, 36.0, 44.0, "speed restored after respawn (m/s)")
	assert_true(car.linear_velocity.normalized().dot(-rec.basis.z) > 0.95, "heading along the track")
	assert_true(car.global_position.distance_to(rec.origin) < 1.0, "back at the checkpoint")
	assert_true(race.state == RaceManager.State.RACING and race.lap_time() > 0.7, "clock keeps running")
	car.clear_input_override()

func test_restart_returns_to_grid() -> void:
	_setup()
	await _drive(race.s, race.checkpoints[1] + 10.0, 25.0)
	race.restart()
	assert_true(race.state == RaceManager.State.COUNTDOWN, "countdown again")
	assert_true(race.next_checkpoint == 0 and race.laps_completed == 0, "lap reset")
	assert_true(car.global_position.distance_to(race._grid.origin) < 0.1, "back on the grid")
	assert_true(not car.simulate, "frozen")

func test_wrong_way() -> void:
	_setup()
	# Find a straight and slide backwards along it at ~54 km/h with the car frozen.
	var s0 := 300.0
	car.simulate = false
	var xf := race.track.spawn_transform(s0)
	car.global_transform = xf.rotated_local(Vector3.UP, PI)
	await get_tree().physics_frame
	race.s = s0
	car.linear_velocity = -data.tangent_at(s0) * 15.0
	await physics_frames(300)
	assert_true(not race.wrong_way, "not yet after 1.25 s")
	await physics_frames(240)
	assert_true(race.wrong_way, "WRONG WAY after > 2 s backwards")
	await get_tree().process_frame
	assert_true(bool(_scene.get_node("UI/RacePanel").call(&"is_wrong_way_shown")), "banner shown")
	car.linear_velocity = data.tangent_at(race.s) * 15.0
	await physics_frames(5)
	assert_true(not race.wrong_way, "cleared when driving forward")
	car.linear_velocity = Vector3.ZERO
