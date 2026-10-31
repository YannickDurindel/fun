extends TestCase
## Rally-Raid: the desert-raid prototype, a heavy T1-style 4WD pickup with big wheels of its own
## size, long suspension travel, a tall body and a 180 km/h limiter.

const KIT := "rally_raid"
const SPEC := "res://assets/car/specs/rally_raid.tres"
const HZ := 240

func test_spec_is_a_desert_raider() -> void:
	assert_true(CarKit.KITS.has(KIT) and CarKit.RALLY_RAID == KIT, "the rally_raid series has a car")
	var s := load(SPEC) as CarSpec
	var w := CarKit.wheel_offsets(KIT)
	assert_true(is_equal_approx(s.wheelbase, w[2].z - w[0].z) and is_equal_approx(s.wheelbase, 2.95), "2.95 m wheelbase")
	assert_true(is_equal_approx(s.dry_mass, 2000.0), "2000 kg")
	assert_between((s.engine_power + s.ers_power) / 1000.0, 250.0, 290.0, "about 270 kW")
	assert_true(s.ers_power == 0.0 and s.cl_a < 0.2, "no hybrid, no downforce")
	assert_true(s.travel_bump >= 0.2, "long suspension travel (%.2f m)" % s.travel_bump)
	var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_between(top_gear_kmh, 170.0, 190.0, "limiter in top gear near 180 km/h")
	assert_true(CarKit.for_spec(SPEC) == KIT, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(car, KIT)
	assert_true(is_equal_approx(car.mass, 2000.0) and car.sim_spec_path == SPEC, "raider physics")
	assert_true(is_equal_approx(car.wheelbase, 2.95), "wheelbase from the contacts")
	assert_true(car.travel_up >= 0.2 and car.downforce_coef == 0.0, "long travel, no downforce")
	assert_true(car.gravel_grip >= 0.8 and car.grass_grip >= 0.8, "made for loose ground")
	var top := 0.0
	for i in car.accel_curve_kmh.size():
		if car.accel_curve_ms2[i] > 0.0:
			top = car.accel_curve_kmh[i + 1]
	assert_between(top, 175.0, 190.0, "top speed near 180 km/h")
	var box := (car.get_node(^"Collision") as CollisionShape3D)
	var size := (box.shape as BoxShape3D).size
	assert_true(size.y > 1.0 and box.position.y - 0.5 * size.y > -0.36 + 0.15, "a tall chassis box clear of the road")
	car.free()

func test_big_wheels_drawn_at_their_size() -> void:
	assert_true(is_equal_approx(CarKit.wheel_radius(KIT, 0), 0.47), "37 in tyres")
	var v := CarKit.visual_wheel_offsets(KIT)
	assert_between(v[0].y, 0.13, 0.15, "front wheel centre raised by the size difference")
	assert_between(v[2].y, 0.10, 0.12, "rear wheel centre raised by the size difference")
	assert_true(CarKit.camera(KIT).get("low_height", 0.0) > 2.0, "the chase camera looks over the roof")

func test_drives_on_flat_ground() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	CarKit.apply(car, KIT)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(HZ)
	var body := car.get_node_or_null(^"BodyVisual/Body")
	assert_true(body != null and body.scene_file_path == "res://assets/car/rally_raid/body.glb", "raider body")
	var fl := car.get_node(^"WheelFL") as Node3D
	assert_true(fl.get_node_or_null(^"Steer/Spin/Wheel/kit_wheel") != null, "its own wheel mesh")
	assert_true(not (fl.get_node(^"Suspension") as Node3D).visible, "no F1 wishbones")
	for i in 4:
		var wv := car.get_node(["WheelFL", "WheelFR", "WheelRL", "WheelRR"][i]) as Node3D
		assert_between(wv.global_position.y - CarKit.wheel_radius(KIT, i), -0.02, 0.02, "wheel %d stands on the road" % i)
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.999, "rests level")
	car.set_input_override(1.0, 0.0, 0.0)
	var t100 := -1.0
	for tick in range(1, 20 * HZ + 1):
		await get_tree().physics_frame
		if t100 < 0.0 and car.speed_kmh >= 100.0:
			t100 = tick / float(HZ)
	assert_between(t100, 3.5, 8.0, "0-100 km/h (%.1f s)" % t100)
	assert_between(car.speed_kmh, 170.0, 185.0, "flat out at the limiter")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.99, "upright at speed")
	car.set_input_override(0.0, 0.0, 0.6)
	await physics_frames(2 * HZ)
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.95 and car.is_grounded, "turns without rolling over")
	car.set_input_override(0.0, 1.0, 0.0)
	var stop := -1.0
	for tick in range(1, 10 * HZ + 1):
		await get_tree().physics_frame
		if stop < 0.0 and car.speed_kmh < 1.0:
			stop = tick / float(HZ)   # (holding the brake then selects reverse)
	assert_true(stop > 0.0, "stops (%.1f s)" % stop)
