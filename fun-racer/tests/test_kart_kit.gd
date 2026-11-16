extends TestCase
## Karting: a 165 kg sprint kart with tiny wheels of its own size, no suspension to speak of,
## one gear, about 130 km/h, and the driver sitting in the open.

const KIT := "karting"
const SPEC := "res://assets/car/specs/kart.tres"
const HZ := 240

func test_spec_is_a_kart() -> void:
	assert_true(CarKit.KITS.has(KIT) and CarKit.KART == KIT, "the karting series has a car")
	var s := load(SPEC) as CarSpec
	var w := CarKit.wheel_offsets(KIT)
	assert_true(is_equal_approx(s.wheelbase, w[2].z - w[0].z) and is_equal_approx(s.wheelbase, 1.05), "1.05 m wheelbase")
	assert_between(w[1].x - w[0].x, 1.1, 1.3, "about 1.2 m front track")
	assert_true(is_equal_approx(s.dry_mass, 165.0), "165 kg with the driver")
	assert_between(s.engine_power / 1000.0, 20.0, 24.0, "about 22 kW")
	assert_true(s.gear_ratios.size() == 1, "direct drive")
	assert_true(s.brake_bias_front == 0.0, "rear brake only")
	assert_true(s.travel_bump < 0.03 and s.spring_front >= 50000.0, "no real suspension")
	var top_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[0] * s.final_drive) * 3.6
	assert_between(top_kmh, 120.0, 140.0, "about 130 km/h at the rev limit")
	assert_true(CarKit.for_spec(SPEC) == KIT, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(car, KIT)
	assert_true(is_equal_approx(car.mass, 165.0) and car.sim_spec_path == SPEC, "kart physics")
	assert_true(car.inertia.y < 100.0, "a kart's inertia, not an F1 car's")
	assert_true(car.gear_top_kmh.size() == 1, "one gear")
	assert_true(car.travel_up < 0.03 and car.downforce_coef == 0.0, "stiff, no downforce")
	var top := 0.0
	for i in car.accel_curve_kmh.size():
		if car.accel_curve_ms2[i] > 0.0:
			top = car.accel_curve_kmh[i + 1]
	assert_between(top, 125.0, 140.0, "top speed near 130 km/h")
	var box := car.get_node(^"Collision") as CollisionShape3D
	var size := (box.shape as BoxShape3D).size
	assert_true(size.z < 2.0 and size.x < 1.5, "a kart-sized chassis box")
	assert_true(box.position.y - 0.5 * size.y > -0.36 + 0.03, "the box clears the road")
	car.free()

func test_small_wheels_drawn_at_their_size() -> void:
	assert_between(CarKit.wheel_radius(KIT, 0), 0.12, 0.13, "10 in front tyres")
	assert_between(CarKit.wheel_radius(KIT, 2), 0.135, 0.145, "11 in rear tyres")
	var v := CarKit.visual_wheel_offsets(KIT)
	assert_true(v[0].y < -0.19 and v[2].y < -0.19, "wheel centres lowered by the size difference")
	var cam := CarKit.camera(KIT)
	assert_true(cam.get("low_distance", 99.0) < 4.0 and cam.get("low_height", 99.0) < 1.2, "the chase camera comes close")

func test_drives_on_flat_ground() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	CarKit.apply(car, KIT)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(HZ)
	var body := car.get_node_or_null(^"BodyVisual/Body")
	assert_true(body != null and body.scene_file_path == "res://assets/car/kart/body.glb", "kart body")
	assert_true(body.get_node_or_null(^"Helmet") != null and body.get_node_or_null(^"Suit") != null, "a driver in the open")
	var fl := car.get_node(^"WheelFL") as Node3D
	assert_true(fl.get_node_or_null(^"Steer/Spin/Wheel/kit_wheel") != null, "its own wheel mesh")
	for i in 4:
		var wv := car.get_node(["WheelFL", "WheelFR", "WheelRL", "WheelRR"][i]) as Node3D
		assert_between(wv.global_position.y - CarKit.wheel_radius(KIT, i), -0.02, 0.02, "wheel %d stands on the road" % i)
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.999, "rests level")
	assert_true(car.linear_velocity.length() < 0.05, "at rest, no buzz")
	car.set_input_override(1.0, 0.0, 0.0)
	var t100 := -1.0
	for tick in range(1, 15 * HZ + 1):
		await get_tree().physics_frame
		if t100 < 0.0 and car.speed_kmh >= 100.0:
			t100 = tick / float(HZ)
	assert_between(t100, 3.0, 7.0, "0-100 km/h (%.1f s)" % t100)
	assert_between(car.speed_kmh, 125.0, 135.0, "flat out")
	car.set_input_override(1.0, 0.0, 0.7)
	await physics_frames(2 * HZ)
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.95 and car.is_grounded, "corners flat")
	car.set_input_override(0.0, 1.0, 0.0)
	var stop := -1.0
	for tick in range(1, 8 * HZ + 1):
		await get_tree().physics_frame
		if stop < 0.0 and car.speed_kmh < 1.0:
			stop = tick / float(HZ)   # (holding the brake then selects reverse)
	assert_true(stop > 0.0, "stops (%.1f s)" % stop)
