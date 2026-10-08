extends TestCase
## Vehicle physics: ride height, acceleration curve, top speed, braking/reverse, drift,
## high-speed stability and respawn. Everything is timed with the physics clock (240 Hz).

const HZ := 240

func _spawn_car() -> Car:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(HZ / 2)   # drop from spawn height and settle
	return car

func _fwd(car: Car) -> Vector3:
	return -car.global_transform.basis.z

## Launch the car straight ahead at the given speed (km/h) from its settled pose.
func _launch(car: Car, kmh: float) -> void:
	car.linear_velocity = _fwd(car) * kmh / 3.6
	car.angular_velocity = Vector3.ZERO
	await physics_frames(2)

func test_ride_height() -> void:
	var car := await _spawn_car()
	await physics_frames(HZ / 2)
	for i in 4:
		var c := car.wheel_center_world(i)
		assert_between(c.y, 0.31, 0.41, "wheel %d centre height" % i)
		assert_true(car.wheels[i].contact, "wheel %d should touch the ground" % i)
		assert_between(c.y - car.wheel_radius(i), -0.01, 0.01, "wheel %d bottom vs ground" % i)
	assert_between(car.global_position.y, 0.33, 0.39, "body origin height")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.9995, "body should rest level")
	assert_true(car.linear_velocity.length() < 0.05, "car should be at rest")
	assert_true(car.is_grounded, "is_grounded at rest")
	print("    ride: origin y=%.3f  FL=%.3f RL=%.3f" % [car.global_position.y,
			car.wheel_center_world(0).y, car.wheel_center_world(2).y])

func test_acceleration_top_speed_and_stability() -> void:
	var car := await _spawn_car()
	var start := car.global_position
	car.set_input_override(1.0, 0.0, 0.0)
	var t100 := -1.0
	var t200 := -1.0
	var t300 := -1.0
	var v15 := 0.0
	var lat10 := 0.0
	var v34 := 0.0
	var max_gear := 0
	var max_rpm := 0.0
	var min_rpm_high_gear := 99999.0
	for tick in range(1, 35 * HZ + 1):
		await get_tree().physics_frame
		var t := tick / float(HZ)
		var kmh := car.speed_kmh
		if t100 < 0.0 and kmh >= 100.0: t100 = t
		if t200 < 0.0 and kmh >= 200.0: t200 = t
		if t300 < 0.0 and kmh >= 300.0: t300 = t
		if tick == 15 * HZ: v15 = kmh
		if tick == 34 * HZ: v34 = kmh
		if tick <= 10 * HZ:
			lat10 = maxf(lat10, absf(car.global_position.x - start.x))
		max_gear = maxi(max_gear, car.gear)
		max_rpm = maxf(max_rpm, car.rpm)
		if car.gear >= 3 and t > 3.0:
			min_rpm_high_gear = minf(min_rpm_high_gear, car.rpm)
	var v35 := car.speed_kmh
	print("    accel: 0-100 %.2fs  0-200 %.2fs  0-300 %.2fs  @15s %.0f km/h  @35s %.0f km/h  lateral %.3fm" % [
			t100, t200, t300, v15, v35, lat10])
	assert_between(t100, 1.4, 2.1, "0-100 km/h time (s)")
	assert_between(t200, 4.3, 6.2, "0-200 km/h time (s)")
	assert_between(v15, 290.0, 360.0, "speed after 15 s (km/h)")
	assert_between(v35, 430.0, 530.0, "speed after 35 s (km/h)")
	assert_between(v35 - v34, 0.0, 6.0, "speed gain in the 35th second (asymptote)")
	assert_between(lat10, 0.0, 0.5, "lateral deviation over 10 s straight (m)")
	assert_true(max_gear == 7, "gearbox should reach 7th, got %d" % max_gear)
	assert_between(max_rpm, 10000.0, Car.MAX_RPM + 1.0, "max rpm")
	assert_between(min_rpm_high_gear, 3500.0, 5500.0, "rpm floor after upshifts")
	assert_true(car.is_grounded and not car.is_drifting, "stays grounded, no drift")

func test_braking_and_reverse() -> void:
	var car := await _spawn_car()
	await _launch(car, 200.0)
	car.set_input_override(0.0, 1.0, 0.0)
	var t_stop := -1.0
	for tick in range(1, 6 * HZ + 1):
		await get_tree().physics_frame
		if car.speed_kmh < 1.0 and car.forward_speed > -0.5:
			t_stop = tick / float(HZ)
			break
	print("    brake: 200-0 %.2fs" % t_stop)
	assert_between(t_stop, 2.5, 3.5, "200-0 km/h braking time (s)")
	await physics_frames(5 * HZ)
	print("    reverse: %.1f km/h gear %d" % [car.forward_speed * 3.6, car.gear])
	assert_true(car.gear == -1, "holding brake at standstill engages reverse")
	assert_between(-car.forward_speed * 3.6, 60.0, 81.0, "reverse speed (km/h)")
	car.set_input_override(1.0, 0.0, 0.0)
	await physics_frames(3 * HZ)
	assert_true(car.forward_speed > 10.0 and car.gear >= 1, "throttle brings it back to forward")

func test_drift() -> void:
	var car := await _spawn_car()
	await _launch(car, 150.0)
	car.set_input_override(1.0, 0.0, 0.0)
	await physics_frames(HZ / 4)
	var start_kmh := car.speed_kmh
	var peak := 0.0
	var seen_drift := false
	var rear_slip := 0.0
	# A drift is a deliberate move: brake + steer held (drift_entry_time), and it only lasts
	# while the brake is held. Releasing the brake hands grip back within a fraction of a second.
	car.set_input_override(0.0, 1.0, 1.0)   # full right + brake, held
	for i in int(1.2 * HZ):
		await get_tree().physics_frame
		peak = maxf(peak, absf(car.slip_angle))
		seen_drift = seen_drift or car.is_drifting
		if car.is_drifting:
			rear_slip = maxf(rear_slip, minf(car.wheels[2].slip, car.wheels[3].slip))
	var still_drifting := car.is_drifting
	var mid_kmh := car.speed_kmh
	print("    drift: peak slip %.1f deg, speed %.0f -> %.0f km/h" % [rad_to_deg(peak), start_kmh, mid_kmh])
	assert_true(seen_drift, "brake + steer held at 150 km/h should start a drift")
	assert_true(still_drifting, "drift is sustained while brake + steer are held")
	assert_between(rad_to_deg(peak), 15.0, 50.0, "peak drift slip angle (deg)")
	assert_true(rear_slip > 0.7, "rear wheel slip should be high while drifting")
	assert_true(mid_kmh < start_kmh - 5.0, "drift bleeds speed (%.0f -> %.0f km/h)" % [start_kmh, mid_kmh])
	car.set_input_override(1.0, 0.0, 1.0)   # brake released, steer still held: grip comes back
	await physics_frames(int(0.8 * HZ))
	assert_true(not car.is_drifting, "drift ends shortly after the brake is released, even with steer held")
	assert_true(absf(rad_to_deg(car.slip_angle)) < 4.0, "car re-aligns with its velocity (%.1f deg)" % rad_to_deg(car.slip_angle))
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.99, "car stays upright")

func test_high_speed_steering_is_stable() -> void:
	var car := await _spawn_car()
	await _launch(car, 400.0)
	car.set_input_override(1.0, 0.0, -1.0)   # full left lock at 400 km/h
	var yaw0 := car.global_rotation.y
	var max_slip := 0.0
	var drifted := false
	for i in HZ:
		await get_tree().physics_frame
		max_slip = maxf(max_slip, absf(car.slip_angle))
		drifted = drifted or car.is_drifting
	var turned := rad_to_deg(wrapf(car.global_rotation.y - yaw0, -PI, PI))
	print("    400 km/h full lock: turned %.1f deg in 1 s, max slip %.1f deg" % [turned, rad_to_deg(max_slip)])
	assert_true(not drifted, "full lock at 400 km/h must not break traction")
	assert_true(rad_to_deg(max_slip) < 6.0, "slip stays small at 400 km/h full lock")
	assert_between(turned, 10.0, 60.0, "heading change in 1 s at 400 km/h (deg, + = left)")

func test_respawn() -> void:
	var car := await _spawn_car()
	var spawn_xf := car.spawn_transform
	var fired := [false]
	car.respawned.connect(func() -> void: fired[0] = true)
	car.set_input_override(1.0, 0.0, 0.4)
	await physics_frames(2 * HZ)
	assert_true(car.global_position.distance_to(spawn_xf.origin) > 5.0, "car moved before respawn")
	car.respawn()
	await physics_frames(1)
	assert_true(fired[0], "respawned signal emitted")
	assert_true(car.global_position.distance_to(spawn_xf.origin) < 0.05, "position reset")
	assert_true(car.global_transform.basis.is_equal_approx(spawn_xf.basis), "rotation reset")
	assert_true(car.linear_velocity.length() < 0.2 and car.angular_velocity.length() < 0.05, "velocities reset")
	assert_true(car.gear == 1 and not car.is_drifting and car.speed_kmh < 1.0, "drivetrain reset")

func test_turn_in_response() -> void:
	var car := await _spawn_car()
	await _launch(car, 100.0)
	car.set_input_override(1.0, 0.0, 1.0)   # full right
	var t90 := -1.0
	var rates: Array[float] = []
	for i in int(0.6 * HZ):
		await get_tree().physics_frame
		rates.append(-car.angular_velocity.y)
	var steady := rates[rates.size() - 1]
	for i in rates.size():
		if rates[i] >= 0.9 * steady:
			t90 = (i + 1) / float(HZ)
			break
	print("    turn-in @100 km/h: yaw rate %.2f rad/s, 90%% after %.3fs" % [steady, t90])
	assert_true(steady > 0.4, "full lock at 100 km/h turns decisively")
	assert_between(t90, 0.02, 0.15, "time to 90% yaw rate (s)")
	assert_true(not car.is_drifting, "pure steering does not drift")

func test_jump_landing() -> void:
	var car := await _spawn_car()
	car.global_position = Vector3(0, 3.0, 0)
	car.linear_velocity = _fwd(car) * 150.0 / 3.6
	var min_y := 10.0
	var air_ticks := 0
	var landed := false
	var rebound_ticks := 0
	for i in 2 * HZ:
		await get_tree().physics_frame
		if not car.is_grounded:
			if landed:
				rebound_ticks += 1
			else:
				air_ticks += 1
		else:
			landed = landed or air_ticks > 0
			if landed:
				min_y = minf(min_y, car.global_position.y)
	var air_time := air_ticks / float(HZ)
	print("    jump: airtime %.2fs (1g would be %.2fs), lowest body y %.3f" % [air_time, sqrt(2.0 * 2.5 / 9.81), min_y])
	assert_between(air_time, 0.45, 0.68, "airtime from 3 m with heavy gravity (s)")
	assert_true(rebound_ticks == 0, "no bounce after landing (%d airborne ticks)" % rebound_ticks)
	assert_true(min_y > 0.285, "suspension absorbs the landing before the chassis box touches down")
	assert_between(car.global_position.y, 0.32, 0.40, "settled at ride height after landing")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.999, "lands flat and stays flat")
