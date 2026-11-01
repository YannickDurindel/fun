extends TestCase
## AutoBrake (Options > AUTO BRAKE): before a corner it cuts the throttle and adds brake so
## the player's car arrives at LEVEL_SCALE x the autopilot's entry speed. LIGHT < MEDIUM <
## STRONG in braking, close together; OFF and slow cars are untouched; no drift is started.

const SCENE := "res://scenes/race_red_bull_ring.tscn"

var _saved_bots: int
var _saved_level: Variant

func _open() -> Node:
	_saved_bots = Game.config.bots
	_saved_level = Settings.get_value("gameplay", "auto_brake")
	Game.config.bots = 0
	Bootstrap.autodrive = false
	var scene := spawn(SCENE)
	await physics_frames(3)
	return scene

func _close(scene: Node) -> void:
	scene.queue_free()
	await get_tree().process_frame
	Game.config.bots = _saved_bots
	Settings.set_value("gameplay", "auto_brake", _saved_level)

## Freezes `car` at centreline distance s, moving forward at v (m/s) with full throttle and
## no brake, and lets the assist act once. Returns the AutoBrake.
func _probe(car: Car, s: float, v: float, steer: float = 0.0) -> AutoBrake:
	var track := car.get_tree().get_first_node_in_group(&"track") as Track
	var xf := track.spawn_transform(s)
	car.simulate = false
	car.global_transform = xf
	car.linear_velocity = -xf.basis.z * v
	car.forward_speed = v
	car.speed_kmh = v * 3.6
	car.steer = steer
	car.throttle = 1.0
	car.brake_input = 0.0
	var ab := car.auto_brake
	ab._s = -1.0
	ab.apply(car)
	return ab

## A point 60 m before the slowest corner of the profile, and the profile speed there.
func _braking_point(ab: AutoBrake) -> Vector2:
	ab._ap.ensure_plan()
	var data := (ab.car.get_tree().get_first_node_in_group(&"track") as Track).data
	var best_s := 0.0
	var best_v := INF
	var s := 0.0
	while s < data.length:
		var v := ab._ap.target_speed_at(s)
		if v < best_v:
			best_v = v
			best_s = s
		s += 5.0
	var at := data.wrap_s(best_s - 60.0)
	return Vector2(at, ab._ap.target_speed_at(at))

func test_levels_brake_more_or_less() -> void:
	var scene := await _open()
	var car := scene.get_node("Car") as Car
	var ab := car.auto_brake
	assert_true(ab != null and ab.get_parent() == car, "the race gives the player's car an AutoBrake")
	var p := _braking_point(ab)
	var too_fast := p.y + 6.0   # m/s over the profile
	Settings.set_value("gameplay", "auto_brake", 0)
	_probe(car, p.x, too_fast)
	assert_true(ab.brake == 0.0 and car.throttle == 1.0 and car.brake_input == 0.0, "OFF leaves the pedals alone")
	var brakes: Array[float] = []
	var targets: Array[float] = []
	for level in [1, 2, 3]:
		Settings.set_value("gameplay", "auto_brake", level)
		_probe(car, p.x, too_fast)
		brakes.append(car.brake_input)
		targets.append(ab.target)
		assert_true(car.throttle == 0.0, "level %d cuts the throttle when too fast" % level)
		assert_true(ab.brake > 0.0, "level %d brakes (%.2f)" % [level, ab.brake])
	assert_true(targets[0] > targets[1] and targets[1] > targets[2], "LIGHT aims faster than MEDIUM, MEDIUM faster than STRONG: %s" % str(targets))
	assert_true(brakes[0] <= brakes[1] and brakes[1] <= brakes[2], "STRONG brakes at least as hard as MEDIUM, MEDIUM as LIGHT: %s" % str(brakes))
	assert_true(absf(targets[0] / targets[1] - 1.0) < 0.1 and absf(targets[2] / targets[1] - 1.0) < 0.1, "levels stay close together")
	# Well under the target nothing happens.
	Settings.set_value("gameplay", "auto_brake", 3)
	_probe(car, p.x, p.y * 0.5)
	assert_true(ab.brake == 0.0 and car.throttle == 1.0, "a slow car is left alone")
	# The player's own harder braking wins.
	_probe(car, p.x, too_fast)
	var assist := car.brake_input
	car.throttle = 1.0
	car.brake_input = 1.0
	ab.apply(car)
	assert_true(car.brake_input == 1.0 and assist <= 1.0, "the larger brake wins")
	await _close(scene)

func test_no_drift_on_the_players_behalf() -> void:
	var scene := await _open()
	var car := scene.get_node("Car") as Car
	var ab := car.auto_brake
	var p := _braking_point(ab)
	Settings.set_value("gameplay", "auto_brake", 3)
	var v := maxf(p.y + 15.0, car.drift_min_speed_kmh / 3.6 + 10.0)
	_probe(car, p.x, v, 0.9)
	assert_true(car.brake_input < car.drift_brake_threshold, "full lock: brake held under the drift threshold (%.2f)" % car.brake_input)
	_probe(car, p.x, v, 0.0)
	assert_true(car.brake_input > car.drift_brake_threshold, "straight: full assist (%.2f)" % car.brake_input)
	await _close(scene)

func test_assist_slows_a_real_corner_entry() -> void:
	# Drive flat out at the slowest corner with the assist on: the car must arrive much
	# slower than without it.
	var scene := await _open()
	var car := scene.get_node("Car") as Car
	var ab := car.auto_brake
	var p := _braking_point(ab)
	var track := scene.get_node("Track") as Track
	var apex_s := track.data.wrap_s(p.x + 60.0)
	var speeds: Array[float] = []
	for level in [0, 2]:
		Settings.set_value("gameplay", "auto_brake", level)
		var start := track.data.wrap_s(apex_s - 400.0)
		var xf := track.spawn_transform(start)
		car.simulate = true
		car.global_transform = xf
		car.spawn_transform = xf
		car.respawn()
		await physics_frames(2)
		car.linear_velocity = -xf.basis.z * (p.y + 25.0)
		Input.action_press(&"accelerate")
		var s := start
		var frames := 0
		var reached := false
		while frames < 3000:   # 240 Hz physics: 12.5 s
			await get_tree().physics_frame
			frames += 1
			s = track.data.closest_s(car.global_position, s)
			if track.data.wrap_s(s - (apex_s - 30.0)) < 50.0:
				reached = true
				break
		Input.action_release(&"accelerate")
		assert_true(reached, "level %d: the car reached the corner (s %.0f, apex %.0f)" % [level, s, apex_s])
		speeds.append(car.linear_velocity.length())
	assert_true(speeds[1] < speeds[0] - 3.0, "MEDIUM arrives slower than OFF: %.1f vs %.1f m/s" % [speeds[1], speeds[0]])
	await _close(scene)
