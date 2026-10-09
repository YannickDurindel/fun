extends TestCase
## The simulation car as a whole (placeholder parts): it stands, launches, stops, turns, and
## the arcade model is untouched. Each part has its own test file with tighter numbers.

func test_settles_at_ride_height() -> void:
	var car := await SimRig.spawn(self)
	assert_true(car.sim != null and car.handling == Car.HANDLING_SIMULATION, "simulation model active")
	assert_between(car.global_position.y, 0.33, 0.39, "hub height at rest (m)")
	assert_true(car.linear_velocity.length() < 0.05, "at rest (%.3f m/s)" % car.linear_velocity.length())
	var total := 0.0
	for i in 4:
		assert_true(car.wheels[i].contact, "wheel %d on the ground" % i)
		total += car.wheels[i].load
	assert_between(total, car.mass * 9.81 * 0.97, car.mass * 9.81 * 1.03, "wheel loads carry the weight (N)")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.999, "level")

func test_launch_brake_and_corner() -> void:
	var car := await SimRig.spawn(self)
	var l := await SimRig.launch(self, car, 12.0)
	print("    sim launch: 0-100 %.2f s, 0-200 %.2f s, 0-300 %.2f s, %.0f km/h after 12 s, peak %.2f g" % [
			l["t_100"], l["t_200"], l["t_300"], l["v_end_kmh"], l["peak_g"]])
	assert_between(l["t_100"], 1.5, 5.0, "0-100 km/h (s)")
	assert_true(l["t_200"] > l["t_100"], "0-200 after 0-100")
	assert_true(absf(car.global_position.x) < 1.0, "launch stays straight (x = %.2f m)" % car.global_position.x)
	assert_true(car.gear >= 4, "the gearbox shifted up (gear %d)" % car.gear)
	var b := await SimRig.brake_from(self, car, 200.0)
	print("    sim braking 200-0: %.1f m in %.2f s, peak %.2f g" % [b["distance"], b["time"], b["peak_g"]])
	assert_between(b["distance"], 40.0, 160.0, "200-0 stopping distance (m)")
	assert_true(car.linear_velocity.length() < 1.0, "stopped")
	var c := await SimRig.max_lateral_g(self, car, 150.0)
	print("    sim cornering at 150 km/h: %.2f g (steer %.2f, body slip %.1f deg)" % [c["lat_g"], c["steer"], c["slip_deg"]])
	assert_between(c["lat_g"], 1.0, 6.0, "lateral g at 150 km/h")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.98, "upright after cornering")

func test_arcade_is_the_default_and_unchanged() -> void:
	var car := await SimRig.spawn(self, &"")
	assert_true(car.handling == Car.HANDLING_ARCADE and car.sim == null, "arcade unless asked otherwise")
	assert_true(car.gear_count == 7 and car.wheels[0].load == 0.0, "simulation extras keep their defaults")
