extends TestCase
## The brakes of the simulation car (scripts/car/sim/brakes.gd): pedal map, bias, line
## pressure, disc temperature and fade as pure tests, then stopping distances, lock-ups and
## holding on a slope on the rig.
##
## Reference values for a 2020s Formula 1 car:
##   200-0 km/h in 65 m and 2.9 s, 100-0 km/h in 17 m and 1.4 s  (f1technical.net/articles/2)
##   334 -> 76 km/h in 139 m and 2.81 s, 4.3 g mean               (Brembo, Monza first chicane)
##   peaks of 5 to almost 6 g from 300+ km/h                      (Brembo race previews)
##   discs work up to about 1000 deg C, peaks above              (Brembo)

const FRONT: int = 0
const REAR: int = 2

func _part(spec: CarSpec) -> SimBrakes:
	var b := SimBrakes.new()
	b.setup(spec)
	return b

func _state(b: SimBrakes, spec: CarSpec) -> SimState:
	var s := SimState.new()
	s.reset(spec)
	b.reset(s, spec)
	return s

func _total(s: SimState) -> float:
	return s.brake_torque[0] + s.brake_torque[1] + s.brake_torque[2] + s.brake_torque[3]

# ---------------------------------------------------------------- pure tests

func test_torque_split_follows_the_bias() -> void:
	for bias: float in [0.50, 0.57, 0.62, 0.66]:
		var spec := CarSpec.new()
		spec.brake_bias_front = bias
		var b := _part(spec)
		var s := _state(b, spec)
		s.brake = 1.0
		b.step(s, spec, SimRig.TICK)
		var total := _total(s)
		assert_between(total, spec.brake_torque_max * 0.999, spec.brake_torque_max * 1.001, "full pedal total torque at bias %.2f (N m)" % bias)
		assert_between((s.brake_torque[0] + s.brake_torque[1]) / total, bias - 0.001, bias + 0.001, "front torque share at bias %.2f" % bias)
		assert_true(is_equal_approx(s.brake_torque[0], s.brake_torque[1]) and is_equal_approx(s.brake_torque[2], s.brake_torque[3]), "left and right wheels get the same torque")
		for i in 4:
			assert_true(s.brake_torque[i] >= 0.0, "torque is never negative")
	# The default system needs a believable line pressure and is not capped by it.
	var spec := CarSpec.new()
	var b := _part(spec)
	var s := _state(b, spec)
	s.brake = 1.0
	b.step(s, spec, SimRig.TICK)
	for c in 2:
		assert_between(b.line_pressure[c], 6.0e6, spec.brake_line_pressure_max * 0.999, "full pedal line pressure, circuit %d (Pa)" % c)
	# No pedal, no torque.
	s.brake = 0.0
	b.step(s, spec, SimRig.TICK)
	assert_true(_total(s) == 0.0, "no torque with the pedal released")
	# The line pressure is a real limit.
	spec.brake_line_pressure_max = 5.0e6
	s.brake = 1.0
	b.step(s, spec, SimRig.TICK)
	assert_between(s.brake_torque[0], 0.0, 5.0e6 * SimBrakes.wheel_gain(spec, true) * 1.001, "front torque under a low pressure limit (N m)")
	assert_true(_total(s) < spec.brake_torque_max * 0.6, "a low pressure limit cuts the torque")

func test_migration_and_regen_share() -> void:
	var spec := CarSpec.new()
	spec.brake_bias_migration = 0.04
	assert_between(SimBrakes.front_share(spec, 1.0), spec.brake_bias_front - 1e-6, spec.brake_bias_front + 1e-6, "no migration at full pedal")
	assert_between(SimBrakes.front_share(spec, 0.5), spec.brake_bias_front + 0.019, spec.brake_bias_front + 0.021, "half the migration at half pedal")
	var b := _part(spec)
	var s := _state(b, spec)
	s.brake = 0.5
	b.step(s, spec, SimRig.TICK)
	assert_between((s.brake_torque[0] + s.brake_torque[1]) / _total(s), spec.brake_bias_front + 0.019, spec.brake_bias_front + 0.021, "torque split follows the migrated bias")
	# Harvesting takes a share of the rear friction torque and leaves the fronts alone.
	spec = CarSpec.new()
	b = _part(spec)
	s = _state(b, spec)
	s.brake = 1.0
	b.step(s, spec, SimRig.TICK)
	var front := s.brake_torque[0]
	var rear := s.brake_torque[2]
	spec.brake_rear_regen_share = 0.25
	b.step(s, spec, SimRig.TICK)
	assert_between(s.brake_torque[2], rear * 0.749, rear * 0.751, "rear friction torque with a 25 % harvesting share (N m)")
	assert_between(s.brake_torque[0], front * 0.999, front * 1.001, "front torque unchanged by harvesting (N m)")

func test_pedal_map_is_monotonic_and_progressive() -> void:
	var spec := CarSpec.new()
	assert_true(SimBrakes.pedal_map(spec, 0.0) == 0.0, "zero pedal gives zero")
	assert_between(SimBrakes.pedal_map(spec, 1.0), 0.9999, 1.0001, "full pedal gives full demand")
	var prev := 0.0
	var b := _part(spec)
	var s := _state(b, spec)
	var prev_torque := 0.0
	for k in range(1, 101):
		var p := k / 100.0
		var m := SimBrakes.pedal_map(spec, p)
		assert_true(m > prev, "pedal map rises at %.2f" % p)
		assert_true(m <= p + 1e-6, "progressive: never above linear at %.2f" % p)
		prev = m
		s.brake = p
		b.step(s, spec, SimRig.TICK)
		assert_true(_total(s) > prev_torque, "torque rises with the pedal at %.2f" % p)
		prev_torque = _total(s)
	assert_between(SimBrakes.pedal_map(spec, 0.5), 0.30, 0.50, "half pedal demand")
	assert_true(SimBrakes.pedal_map(spec, -1.0) == 0.0 and SimBrakes.pedal_map(spec, 2.0) <= 1.0001, "pedal is clamped")

func test_friction_over_temperature() -> void:
	var spec := CarSpec.new()
	assert_between(SimBrakes.friction_factor(spec, 25.0), spec.brake_friction_cold - 1e-4, spec.brake_friction_cold + 1e-4, "cold disc friction")
	assert_true(SimBrakes.friction_factor(spec, 250.0) < 0.95, "still short of full friction at 250 deg C")
	for t: float in [400.0, 600.0, 800.0, 1000.0]:
		assert_between(SimBrakes.friction_factor(spec, t), 0.9999, 1.0001, "full friction at %d deg C" % int(t))
	assert_true(SimBrakes.friction_factor(spec, 1150.0) < 0.95, "fading at 1150 deg C")
	assert_between(SimBrakes.friction_factor(spec, 1500.0), spec.brake_friction_fade - 1e-4, spec.brake_friction_fade + 1e-4, "fully faded friction")
	# Shape: never falling up to the window, never rising after it, always within (0, 1].
	var prev := 0.0
	for t in range(0, 401, 10):
		var f := SimBrakes.friction_factor(spec, float(t))
		assert_true(f >= prev - 1e-6 and f > 0.0 and f <= 1.0, "friction rises to the window at %d deg C" % t)
		prev = f
	prev = 1.0
	for t in range(1000, 1601, 10):
		var f := SimBrakes.friction_factor(spec, float(t))
		assert_true(f <= prev + 1e-6 and f > 0.0, "friction falls beyond the window at %d deg C" % t)
		prev = f
	# A cold disc gives less torque for the same pedal.
	var b := _part(spec)
	var s := _state(b, spec)
	s.brake = 1.0
	b.step(s, spec, SimRig.TICK)
	var warm := _total(s)
	for i in 4:
		s.brake_temp[i] = 60.0
	b.step(s, spec, SimRig.TICK)
	assert_true(_total(s) < warm * 0.75, "cold discs: %.0f N m against %.0f warm" % [_total(s), warm])

func test_temperature_rises_braking_and_falls_rolling() -> void:
	var spec := CarSpec.new()
	var b := _part(spec)
	var s := _state(b, spec)
	assert_between(s.brake_temp[0], 400.0, 600.0, "discs start warm (deg C)")
	var start_front := s.brake_temp[0]
	var start_rear := s.brake_temp[2]
	# 2 s of full pedal at 250 km/h (wheels turning).
	s.speed = 250.0 / 3.6
	for i in 4:
		s.omega[i] = s.speed / (0.33 if i < 2 else 0.36)
	s.brake = 1.0
	for k in 2 * SimRig.HZ:
		b.step(s, spec, SimRig.TICK)
	var hot_front := s.brake_temp[0]
	assert_true(hot_front > start_front + 150.0, "front disc heats under braking: %.0f -> %.0f deg C" % [start_front, hot_front])
	assert_true(s.brake_temp[2] > start_rear + 100.0, "rear disc heats under braking: %.0f -> %.0f deg C" % [start_rear, s.brake_temp[2]])
	assert_true(is_equal_approx(s.brake_temp[0], s.brake_temp[1]), "left and right alike")
	# 10 s rolling at the same speed with the pedal released.
	s.brake = 0.0
	for k in 10 * SimRig.HZ:
		b.step(s, spec, SimRig.TICK)
	assert_true(s.brake_temp[0] < hot_front - 100.0, "front disc cools when rolling: %.0f -> %.0f deg C" % [hot_front, s.brake_temp[0]])
	# Airflow matters: the same 10 s at a standstill cool much less.
	var moving_drop := hot_front - s.brake_temp[0]
	for i in 4:
		s.brake_temp[i] = hot_front
		s.omega[i] = 0.0
	s.speed = 0.0
	for k in 10 * SimRig.HZ:
		b.step(s, spec, SimRig.TICK)
	var still_drop := hot_front - s.brake_temp[0]
	assert_true(still_drop > 0.0 and still_drop < moving_drop * 0.6, "less cooling at a standstill (%.0f against %.0f deg C)" % [still_drop, moving_drop])
	# A locked wheel dissipates nothing in its disc.
	var before := s.brake_temp[0]
	s.brake = 1.0
	s.speed = 30.0
	for k in SimRig.HZ:
		b.step(s, spec, SimRig.TICK)
	assert_true(s.brake_temp[0] <= before, "a locked wheel does not heat its disc")
	# Left for a long time the discs settle at the air temperature, never below.
	s.brake = 0.0
	for k in 600 * SimRig.HZ / 8:
		b.step(s, spec, SimRig.TICK * 8.0)
	assert_between(s.brake_temp[0], spec.brake_temp_ambient, spec.brake_temp_ambient + 5.0, "disc settles at ambient (deg C)")

func test_reverse_gear_swaps_the_pedals() -> void:
	var spec := CarSpec.new()
	var b := _part(spec)
	var s := _state(b, spec)
	s.gear = -1
	s.in_brake = 1.0
	s.brake = 1.0
	s.in_throttle = 0.0
	b.step(s, spec, SimRig.TICK)
	assert_true(_total(s) == 0.0, "in reverse the brake pedal does not brake")
	s.in_throttle = 1.0
	s.brake = 0.0
	b.step(s, spec, SimRig.TICK)
	assert_between(_total(s), spec.brake_torque_max * 0.999, spec.brake_torque_max * 1.001, "in reverse the throttle pedal brakes (N m)")

# ---------------------------------------------------------------- rig tests

## Braking from `kmh` with the pedal given by `pedal_at` (time -> 0..1) and a steering input.
## With `bypass` the pedal is written straight to the brakes (no anti-lock); otherwise it goes
## through the driving aids. Returns the distance, time, peak g, the time and speed of the first
## lock per axle (-1 if none), the share of the stop the fronts spent locked and the sideways
## displacement.
func _stop(car: Car, kmh: float, pedal_at: Callable, bypass: bool, steer: float = 0.0, to_kmh: float = 0.5) -> Dictionary:
	car.sim.reset()
	SimRig.set_speed(car, kmh)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(SimRig.HZ / 4)
	var start := car.global_position
	var right := car.global_transform.basis.x
	var st := car.sim.state
	var res := {"front_lock_t": -1.0, "rear_lock_t": -1.0, "front_lock_kmh": -1.0, "peak_g": 0.0}
	var t := 0.0
	var front_ticks := 0
	var ticks := 0
	while car.linear_velocity.length() * 3.6 > to_kmh and t < 20.0:
		var pedal: float = pedal_at.call(t)
		car.set_input_override(0.0, pedal, steer)
		car.sim.brakes.pedal_override = pedal if bypass else -1.0
		await get_tree().physics_frame
		t += SimRig.TICK
		ticks += 1
		res["peak_g"] = maxf(res["peak_g"], -st.accel_long / SimRig.G)
		if st.locked[0] or st.locked[1]:
			front_ticks += 1
			if res["front_lock_t"] < 0.0:
				res["front_lock_t"] = t
				res["front_lock_kmh"] = car.linear_velocity.length() * 3.6
		if (st.locked[2] or st.locked[3]) and res["rear_lock_t"] < 0.0:
			res["rear_lock_t"] = t
	car.sim.brakes.pedal_override = -1.0
	car.set_input_override(0.0, 0.0, 0.0)
	res["distance"] = car.global_position.distance_to(start)
	res["time"] = t
	res["front_locked_share"] = float(front_ticks) / maxf(ticks, 1)
	res["sideways"] = absf((car.global_position - start).dot(right))
	return res

func _full(_t: float) -> float:
	return 1.0

func _ramp(t: float) -> float:
	return clampf(0.2 + t * 0.4, 0.0, 1.0)

func test_stopping_distances_and_peak_g() -> void:
	var car := await SimRig.spawn(self)
	var b100 := await SimRig.brake_from(self, car, 100.0)
	car.sim.reset()
	var b200 := await SimRig.brake_from(self, car, 200.0)
	car.sim.reset()
	var b300 := await SimRig.brake_from(self, car, 300.0)
	car.sim.reset()
	var b31 := await SimRig.brake_from(self, car, 300.0, 100.0)
	car.sim.reset()
	var b330 := await SimRig.brake_from(self, car, 330.0, 100.0)
	print("    brakes 100-0: %.1f m, %.2f s, peak %.2f g, mean %.2f g" % [b100["distance"], b100["time"], b100["peak_g"], b100["mean_g"]])
	print("    brakes 200-0: %.1f m, %.2f s, peak %.2f g, mean %.2f g" % [b200["distance"], b200["time"], b200["peak_g"], b200["mean_g"]])
	print("    brakes 300-0: %.1f m, %.2f s, peak %.2f g, mean %.2f g" % [b300["distance"], b300["time"], b300["peak_g"], b300["mean_g"]])
	print("    brakes 300-100: %.1f m, %.2f s, peak %.2f g, mean %.2f g" % [b31["distance"], b31["time"], b31["peak_g"], b31["mean_g"]])
	print("    brakes 330-100: %.1f m, %.2f s, peak %.2f g, mean %.2f g" % [b330["distance"], b330["time"], b330["peak_g"], b330["mean_g"]])
	# Bands are the reference values, widened where the placeholder tyres (peak friction 1.75,
	# no rise at low load) set the limit rather than the brakes: 100-0 and 300-100.
	assert_between(b100["distance"], 15.0, 23.5, "100-0 km/h distance (m)")
	assert_between(b100["peak_g"], 1.8, 2.8, "100-0 km/h peak deceleration (g)")
	assert_between(b200["distance"], 55.0, 65.0, "200-0 km/h distance (m)")
	assert_between(b200["time"], 2.3, 3.0, "200-0 km/h time (s)")
	assert_between(b200["peak_g"], 3.0, 4.6, "200-0 km/h peak deceleration (g)")
	assert_between(b300["distance"], 95.0, 125.0, "300-0 km/h distance (m)")
	assert_between(b300["peak_g"], 4.7, 6.0, "300-0 km/h peak deceleration (g)")
	assert_between(b31["distance"], 70.0, 120.0, "300-100 km/h distance (m)")
	assert_between(b330["peak_g"], 5.0, 6.0, "peak deceleration from 330 km/h (g)")
	assert_true(b300["peak_g"] > b200["peak_g"] and b200["peak_g"] > b100["peak_g"], "deceleration rises with the downforce")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.99 and absf(car.global_position.x) < 2.0, "stops straight and upright")

func test_lockup_without_antilock() -> void:
	var car := await SimRig.spawn(self)
	var aided := await _stop(car, 80.0, _full, false)
	var raw := await _stop(car, 80.0, _full, true)
	print("    80-0 with anti-lock %.1f m; without, full pedal: %.1f m, fronts lock after %.3f s (rears %.3f s), fronts locked %.0f %% of the stop" % [
			aided["distance"], raw["distance"], raw["front_lock_t"], raw["rear_lock_t"], raw["front_locked_share"] * 100.0])
	assert_true(raw["front_lock_t"] >= 0.0 and raw["front_lock_t"] < 0.3, "full pedal at 80 km/h locks the front wheels at once (%.3f s)" % raw["front_lock_t"])
	assert_true(raw["front_locked_share"] > 0.7, "and they stay locked (%.0f %% of the stop)" % (raw["front_locked_share"] * 100.0))
	# With the placeholder tyre a locked wheel keeps its full longitudinal grip, so the stop is
	# not longer yet (the tyre unit's falling curve after the peak will make it so). What a
	# lock-up costs today is the steering: locked fronts make no side force.
	var aided_turn := await _stop(car, 80.0, _full, false, 0.6)
	var raw_turn := await _stop(car, 80.0, _full, true, 0.6)
	print("    80-0 while steering: %.2f m sideways with anti-lock, %.2f m with locked fronts" % [aided_turn["sideways"], raw_turn["sideways"]])
	assert_true(raw_turn["sideways"] < aided_turn["sideways"] * 0.5, "locked fronts do not steer (%.2f m against %.2f m sideways)" % [raw_turn["sideways"], aided_turn["sideways"]])

func test_fronts_lock_before_rears() -> void:
	var car := await SimRig.spawn(self)
	# A slowly rising pedal, anti-lock bypassed: the front axle must give up first (stable).
	for kmh: float in [250.0, 200.0, 150.0, 100.0]:
		var r := await _stop(car, kmh, _ramp, true)
		print("    pedal ramp from %.0f km/h: fronts lock at %.2f s, rears at %.2f s" % [kmh, r["front_lock_t"], r["rear_lock_t"]])
		assert_true(r["front_lock_t"] >= 0.0, "the ramp from %.0f km/h ends in a front lock-up" % kmh)
		assert_true(r["rear_lock_t"] < 0.0 or r["rear_lock_t"] > r["front_lock_t"], "from %.0f km/h the fronts lock before the rears (%.2f s, %.2f s)" % [kmh, r["front_lock_t"], r["rear_lock_t"]])

func test_full_pedal_at_speed_needs_the_downforce() -> void:
	var car := await SimRig.spawn(self)
	# Full pedal at 320 km/h without the anti-lock: the downforce carries it at first, and the
	# fronts lock as it bleeds away.
	var fast := await _stop(car, 320.0, _full, true)
	print("    full pedal from 320 km/h without anti-lock: peak %.2f g, fronts lock at %.2f s and %.0f km/h, %.1f m" % [
			fast["peak_g"], fast["front_lock_t"], fast["front_lock_kmh"], fast["distance"]])
	assert_between(fast["peak_g"], 5.0, 6.0, "peak deceleration from 320 km/h (g)")
	assert_true(fast["front_lock_t"] > 0.25, "no instant lock-up at 320 km/h (%.2f s)" % fast["front_lock_t"])
	assert_between(fast["front_lock_kmh"], 150.0, 290.0, "speed at which the fronts lock under full pedal (km/h)")

func test_holds_on_a_slope() -> void:
	var car := await SimRig.spawn(self)
	var ground: StaticBody3D = null
	for c in get_children():
		if c is StaticBody3D and not c is Car:
			ground = c
	var tilt := Transform3D(Basis(Vector3.RIGHT, -atan(0.15)), Vector3.ZERO)
	ground.global_transform = tilt
	car.global_transform = tilt * car.global_transform
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.sim.reset()
	car.set_input_override(0.0, 0.5, 0.0)
	await physics_frames(SimRig.HZ / 2)
	var p0 := car.global_position
	await physics_frames(SimRig.HZ * 4)
	var held := car.global_position.distance_to(p0)
	car.set_input_override(0.0, 0.0, 0.0)
	var p1 := car.global_position
	await physics_frames(SimRig.HZ * 2)
	var rolled := car.global_position.distance_to(p1)
	print("    15 %% slope: moved %.3f m in 4 s with the pedal held, %.2f m in 2 s released (gear %d)" % [held, rolled, car.gear])
	# The tyres creep a little under a steady force at a standstill (the slip model's low-speed
	# floor), so "holds" means centimetres, not zero.
	assert_true(held < 0.15, "held on a 15 %% slope with half pedal (moved %.3f m in 4 s)" % held)
	assert_true(rolled > 1.0, "the car rolls away when released (%.2f m in 2 s)" % rolled)

func test_discs_heat_in_a_stop() -> void:
	var car := await SimRig.spawn(self)
	var st := car.sim.state
	var t0f := st.brake_temp[0]
	var t0r := st.brake_temp[2]
	await SimRig.brake_from(self, car, 300.0, 80.0)
	print("    300-80 km/h: front discs %.0f -> %.0f deg C, rear %.0f -> %.0f deg C" % [t0f, st.brake_temp[0], t0r, st.brake_temp[2]])
	assert_between(st.brake_temp[0] - t0f, 150.0, 450.0, "front disc temperature rise in a 300-80 km/h stop (deg C)")
	assert_between(st.brake_temp[2] - t0r, 80.0, 450.0, "rear disc temperature rise in a 300-80 km/h stop (deg C)")
	assert_true(st.brake_temp[0] < 1000.0, "still inside the working window")
