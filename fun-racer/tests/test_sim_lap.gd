extends TestCase
## The autopilot and the bots on the SIMULATION car: the performance envelope they plan from
## (analytic for the arcade car, measured for the simulation car) and laps of the Red Bull Ring.
## The suite drives one sector (grid -> past Remus, about 30 s of physics); the two full laps
## run with `--full-lap` (use --fixed-fps 240 --disable-vsync, or tools/lap_check.sh
## red_bull_ring --handling=simulation).

const SCENE := "res://scenes/race_red_bull_ring.tscn"
const CAR_SCENE := "res://scenes/car/car.tscn"
const TICK := 1.0 / 240.0

var _scene: Node
var _car: Car
var _pilot: Autopilot
var _data: TrackData
var _progress: float = 0.0
var _time: float = 0.0
var _worst_edge: float = INF
var _worst_edge_s: float = 0.0
var _impacts: int = 0
var _top: float = 0.0

# ================================================================ envelope
func test_arcade_envelope_is_the_tuning() -> void:
	var car := (load(CAR_SCENE) as PackedScene).instantiate() as Car
	car.handling = Car.HANDLING_ARCADE
	car.position = Vector3(0, 500, 0)
	add_child(car)
	car.simulate = false
	var eff := 0.9
	var env := CarEnvelope.for_car(car, eff)
	assert_true(env.analytic and not env.provisional, "the arcade car's envelope is analytic")
	for kmh: float in [0.0, 60.0, 100.0, 160.0, 200.0, 250.0, 300.0, 340.0]:
		var v := kmh / 3.6
		# The expressions the Autopilot used before the envelope existed, to the bit.
		var lat := eff * 9.81 * car.steer_grip_usage * (car.lateral_grip_g + car.aero_grip_g * v * v)
		assert_true(env.lat_at(v) == lat, "lat at %.0f km/h: %.6f, old value %.6f" % [kmh, env.lat_at(v), lat])
		assert_true(env.brake_at(v) == car.brake_decel, "brake at %.0f km/h" % kmh)
		assert_true(env.accel_at(v) == _old_accel(car, v), "accel at %.0f km/h: %.4f, old value %.4f" % [kmh, env.accel_at(v), _old_accel(car, v)])
		assert_true(env.coast_at(v) == car.coast_decel + car.drag_decel_coef * v * v, "coast at %.0f km/h" % kmh)
	# It reads the Car live: a retune carries over without a new envelope.
	car.brake_decel = 12.5
	assert_true(env.brake_at(50.0) == 12.5, "the analytic envelope follows the Car's tuning")
	car.queue_free()

## Autopilot._accel_at as it was: the Car's acceleration table, interpolated.
func _old_accel(car: Car, v: float) -> float:
	var kmh := v * Car.KMH
	var xs := car.accel_curve_kmh
	var ys := car.accel_curve_ms2
	var m := mini(xs.size(), ys.size())
	if kmh <= xs[0]:
		return ys[0]
	for i in range(1, m):
		if kmh <= xs[i]:
			return lerpf(ys[i - 1], ys[i], (kmh - xs[i - 1]) / maxf(xs[i] - xs[i - 1], 0.001))
	return ys[m - 1]

func test_sim_envelope_measured() -> void:
	var before := get_tree().root.get_child_count()
	var env: CarEnvelope = await CarEnvelope.measure(self)
	await physics_frames(2)
	assert_true(get_tree().root.get_child_count() == before and get_node_or_null("CarEnvelopeRig") == null,
			"the measurement rig is gone")
	print(env.describe().indent("       "))
	assert_true(env.is_sane(), "the measured envelope is usable")
	assert_true(not env.analytic and not env.provisional, "a measured envelope")
	assert_true(env.key == CarEnvelope.spec_key(Car.SIM_SPEC_PATH), "keyed by the spec and the part scripts")
	var n := env.speeds.size()
	var i100 := CarEnvelope.SPEEDS_KMH.find(110.0)
	var i250 := CarEnvelope.SPEEDS_KMH.find(250.0)
	# Cornering and braking rise with speed while the downforce grows.
	for i in range(2, n):
		assert_true(env.lat[i] >= env.lat[i - 1] * 0.99, "lat at %.0f km/h (%.2f) below the sample before (%.2f)" % [
				CarEnvelope.SPEEDS_KMH[i], env.lat[i], env.lat[i - 1]])
		assert_true(env.grip[i] >= env.grip[i - 1] * 0.99, "tyre grip does not fall with speed (%.0f km/h)" % CarEnvelope.SPEEDS_KMH[i])
		assert_true(env.brake[i] >= env.brake[i - 1] * 0.99, "braking at %.0f km/h (%.2f) below the sample before (%.2f)" % [
				CarEnvelope.SPEEDS_KMH[i], env.brake[i], env.brake[i - 1]])
		assert_true(env.grip[i] >= env.lat[i] - 1e-6, "grip is at least the cornering limit")
	assert_true(env.lat[i250] > 1.3 * env.lat[i100], "downforce: %.1f m/s^2 at 250 km/h against %.1f at 110" % [env.lat[i250], env.lat[i100]])
	assert_true(env.brake[i250] > 1.3 * env.brake[i100], "braking gains from downforce and drag")
	assert_between(env.lat_at(150.0 / 3.6) / 9.81, 1.5, 5.0, "lateral g at 150 km/h")
	assert_between(env.brake_at(200.0 / 3.6) / 9.81, 1.5, 6.5, "braking g at 200 km/h")
	# The engine runs out of breath at speed; the car coasts down faster the faster it goes.
	assert_true(env.accel[n - 1] < 0.6 * env.accel[i100], "acceleration falls at speed")
	assert_true(env.coast[n - 1] > env.coast[1], "drag grows with speed")
	for i in range(1, n):
		assert_true(env.accel[i] > 0.0, "the car still accelerates at %.0f km/h" % CarEnvelope.SPEEDS_KMH[i])
		assert_between(env.throttle_pedal[i], 0.05, 1.0, "throttle at the traction limit")
		assert_between(env.brake_pedal[i], 0.05, 1.0, "brake pedal at the limit")
		for j in range(1, CarEnvelope.STEER_FRACS.size()):
			assert_true(env.steer[i][j] > env.steer[i][j - 1], "more steering for more cornering (%.0f km/h)" % CarEnvelope.SPEEDS_KMH[i])
	# Interpolation stays inside the samples; the steering map inverts the cornering limit.
	var v := 100.0 / 3.6
	assert_between(env.lat_at(v), env.lat[i100 - 1] * 0.98, env.lat[i100], "lat between two samples")
	assert_true(env.steer_for(v, 0.0) == 0.0, "no steering on a straight")
	assert_true(env.steer_for(v, 0.5 * env.lat_at(v) / (v * v)) < env.steer_for(v, 0.9 * env.lat_at(v) / (v * v)),
			"the steering map is monotonic")
	assert_true(env.max_curvature() > 1.0 / 40.0 and env.max_curvature() < 1.0 / 5.0,
			"tightest practical radius %.1f m" % (1.0 / env.max_curvature()))
	# The stand-in used while a measurement runs asks for less than the car can do.
	CarEnvelope.clear_cache()
	var slow := CarEnvelope._provisional(Car.SIM_SPEC_PATH, env.key)
	assert_true(slow.provisional and slow.is_sane(), "provisional envelope usable")
	for i in range(1, n):
		assert_true(slow.lat[i] <= env.lat[i] and slow.brake[i] <= env.brake[i] and slow.accel[i] <= env.accel[i],
				"provisional limits are below the measured ones at %.0f km/h" % CarEnvelope.SPEEDS_KMH[i])
	# The committed file: when it is current it must be this very measurement (the
	# measurement is deterministic); a stale one is only reported, the game measures by itself.
	var filed := CarEnvelope.for_spec(Car.SIM_SPEC_PATH, null)
	if filed.provisional:
		print("       NOTE: %s is stale. Run: tools/bin/godot --headless --path . --fixed-fps 240 -s res://tools/lap_grip_sweep.gd -- --envelope" % CarEnvelope.res_path(Car.SIM_SPEC_PATH))
	else:
		for i in range(1, n):
			assert_true(absf(filed.lat[i] - env.lat[i]) < 0.02 * env.lat[i] and absf(filed.brake[i] - env.brake[i]) < 0.02 * env.brake[i],
					"the stored envelope is this measurement at %.0f km/h" % CarEnvelope.SPEEDS_KMH[i])
	# Later tests of this run plan from this measurement rather than measuring again.
	CarEnvelope.adopt(env)
	assert_true(not CarEnvelope.for_spec(Car.SIM_SPEC_PATH, null).provisional, "the adopted envelope is served")

# ================================================================ driving
func _start() -> bool:
	Bootstrap.handling_override = Car.HANDLING_SIMULATION
	Bootstrap.autodrive = true
	_scene = spawn(SCENE)
	_car = _scene.get_node("Car") as Car
	_pilot = _scene.get_node("Autodrive") as Autopilot
	_data = (_scene.get_node("Track") as Track).data
	assert_true(_car.sim != null and _car.handling == Car.HANDLING_SIMULATION, "the race car runs the simulation model")
	assert_true(_pilot != null and Bootstrap.autodrive_provider == _pilot, "the Autopilot drives")
	if _pilot == null or _car.sim == null:
		return false
	# Waits for the start, and for the envelope measurement if no valid file was there.
	var waited := 0
	while _car.linear_velocity.length() < 1.0 and waited < 240 * 25:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 25, "car never started moving")
	assert_true(not _pilot.envelope().analytic and not _pilot.envelope().provisional, "driving from a measured envelope")
	return waited < 240 * 25

func _finish() -> void:
	Bootstrap.autodrive = false
	Bootstrap.handling_override = &""

func _drive(done: Callable, timeout_s: float) -> bool:
	var s := _data.closest_s(_car.global_position)
	var prev_speed := _car.linear_velocity.length()
	while _time < timeout_s:
		await physics_frames(1)
		_time += TICK
		var pos := _car.global_position
		var ns := _data.closest_s(pos, s)
		_progress += _data.delta_s(s, ns)
		s = ns
		var edge := _data.width_at(s) * 0.5 - absf(_data.lateral_offset(pos, s))
		if edge < _worst_edge:
			_worst_edge = edge
			_worst_edge_s = s
		var speed := _car.linear_velocity.length()
		_top = maxf(_top, speed)
		# An impact: more than 8 m/s lost within one tick (hard braking is about 0.2).
		if prev_speed - speed > 8.0:
			_impacts += 1
		prev_speed = speed
		if done.call():
			return true
	return false

func _common_asserts() -> void:
	assert_true(_worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [_worst_edge, _worst_edge_s])
	assert_true(_impacts == 0, "%d impact(s)" % _impacts)
	assert_true(_car.global_transform.basis.y.dot(Vector3.UP) > 0.9, "car upright")

func test_sim_sector_grid_to_remus() -> void:
	if not await _start():
		_finish()
		return
	var target := _data.delta_s(_data.closest_s(_car.global_position), 1500.0)
	var ok := await _drive(func() -> bool: return _progress >= target, 60.0)
	assert_true(ok, "sector grid -> s=1500 not completed in 60 s (progress %.0f m)" % _progress)
	_common_asserts()
	assert_true(_top * 3.6 > 250.0, "top speed on the run to Remus %.0f km/h, expected > 250" % (_top * 3.6))
	assert_between(_time, 18.0, 50.0, "sector time grid -> s=1500 (s)")
	assert_true(_pilot.lateral_error_max < 2.5, "stays near its line (max error %.2f m)" % _pilot.lateral_error_max)
	print("       sim sector grid->1500 m: %.2f s, top %.0f km/h, min edge margin %.2f m, max line error %.2f m" % [
			_time, _top * 3.6, _worst_edge, _pilot.lateral_error_max])
	_finish()

func test_sim_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap; or tools/lap_check.sh red_bull_ring --handling=simulation)")
		return
	if not await _start():
		_finish()
		return
	var ok := await _drive(func() -> bool: return _pilot.laps_completed >= 1, 170.0)
	assert_true(ok, "lap not completed in 170 s of physics (progress %.0f m)" % _progress)
	_common_asserts()
	var standing := _pilot.lap_time
	assert_between(standing, 60.0, 115.0, "standing lap time (s)")
	print("\nSIM LAP 1 (from the grid)\n" + _pilot.report())
	ok = await _drive(func() -> bool: return _pilot.laps_completed >= 2, _time + 130.0)
	assert_true(ok, "flying lap not completed")
	_common_asserts()
	assert_between(_pilot.lap_time, 60.0, standing + 0.5, "flying lap time (s)")
	print("\nSIM LAP 2 (flying)\n" + _pilot.report())
	print("       plan %.2f s, min edge %.2f m at s=%.0f\n" % [_pilot.predicted_lap_time, _worst_edge, _worst_edge_s])
	_finish()

# ================================================================ bots
## A bot (BotDriver: DIRECT mode, thinking at 60 Hz) on the simulation car: off the grid and
## through the first corner on the road, then on rails at the simulation profile's speed and
## back to the physics.
func test_sim_bot_drives_and_goes_on_rails() -> void:
	var saved_bots := Game.config.bots
	var saved_level := Game.config.bot_difficulty
	Game.config.bots = 1
	Game.config.bot_difficulty = BotDriver.HARD
	Bootstrap.handling_override = Car.HANDLING_SIMULATION
	Bootstrap.autodrive = false
	Bootstrap.skip_countdown = true
	_scene = spawn(SCENE)
	var mgr := _scene.get_node("Bots") as BotManager
	mgr.rails_distance = 0.0
	var race := _scene.get_node("Track/Race") as RaceManager
	race.persist_best = false
	_data = race.data
	await physics_frames(10)
	assert_true(mgr.bots.size() == 1, "one bot spawned")
	if mgr.bots.size() == 1:
		var bot := mgr.bots[0]
		var driver := mgr.drivers[0]
		assert_true(bot.sim != null, "the bot's car runs the simulation model")
		assert_true(driver.prepare() and not driver.envelope().analytic and not driver.envelope().provisional,
				"the bot plans from the measured envelope")
		# Slower difficulties plan slower laps from the same envelope.
		var easy := BotDriver.new()
		easy.configure(bot, _scene.get_node("Track") as Track, BotDriver.EASY, 0)
		easy.set_physics_process(false)
		add_child(easy)
		assert_true(easy.prepare() and easy.predicted_lap_time > driver.predicted_lap_time + 3.0,
				"easy (%.1f s) plans a slower lap than hard (%.1f s)" % [easy.predicted_lap_time, driver.predicted_lap_time])
		easy.queue_free()
		var start := driver.progress
		var worst := INF
		var s := _data.closest_s(bot.global_position)
		for k in 240 * 14:
			await physics_frames(1)
			s = _data.closest_s(bot.global_position, s)
			worst = minf(worst, _data.width_at(s) * 0.5 - absf(_data.lateral_offset(bot.global_position, s)))
		assert_true(driver.progress - start > 400.0, "the bot raced %.0f m in 14 s" % (driver.progress - start))
		assert_true(worst > 0.0, "the bot left the road (edge margin %.2f m)" % worst)
		assert_true(driver.respawns == 0, "the bot needed a respawn")
		print("       sim bot: %.0f m in 14 s, min edge margin %.2f m" % [driver.progress - start, worst])
		# On rails: moved at the profile's speed, never above it.
		driver.set_on_rails(true)
		assert_true(driver.on_rails, "the bot goes on rails")
		var p0 := driver.progress
		var over := 0.0
		for k in 240 * 3:
			await physics_frames(1)
			over = maxf(over, driver.rail_speed - driver.target_speed_at(driver.current_s) * driver.speed_scale * 1.25)
		assert_true(driver.progress > p0 + 30.0, "on rails the bot keeps racing (%.0f m in 3 s)" % (driver.progress - p0))
		assert_true(over <= 0.0, "on rails the bot follows the simulation speed profile (%.1f m/s over)" % over)
		var v_rail := driver.speed()
		driver.set_on_rails(false)
		await physics_frames(120)
		s = _data.closest_s(bot.global_position)
		assert_true(absf(_data.lateral_offset(bot.global_position, s)) < _data.width_at(s) * 0.5, "on the road after the hand-over")
		assert_true(bot.global_transform.basis.y.dot(Vector3.UP) > 0.8, "upright after the hand-over")
		assert_true(bot.linear_velocity.length() > v_rail * 0.6, "still at speed 0.5 s after the hand-over (%.0f of %.0f m/s)" % [
				bot.linear_velocity.length(), v_rail])
		assert_true(driver.respawns == 0, "the hand-over needed a respawn")
	Game.config.bots = saved_bots
	Game.config.bot_difficulty = saved_level
	Bootstrap.handling_override = &""
