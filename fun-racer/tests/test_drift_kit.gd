extends TestCase
## Drifting: its events take the drift coupe, a front-engine coupe with a big V8 and wide
## arches. The Car has no drive layout: rear-wheel drive is in the tuning (a huge steering lock,
## an easy entry, low sliding friction, the power kept in a slide that lasts while the steering
## is held), and in the simulation spec (rear tyres that let go first, a locked differential).

const SERIES := "drift"
const SPEC := "res://assets/car/specs/drift.tres"
const KitTest := preload("res://tests/test_indycar_kit.gd")
const RallyTest := preload("res://tests/test_rally_kit.gd")

func test_series_takes_the_drift_car() -> void:
	assert_true(CarKit.KITS.has(SERIES) and SERIES == CarKit.DRIFT, "drifting has a car")
	var events := SeriesCatalog.tracks(SERIES)
	assert_true(events.size() >= 5, "a season of events (%d)" % events.size())
	for t in events:
		assert_true(CarKit.for_track(t.id) == CarKit.DRIFT, "%s is driven with the drift car" % t.id)
	assert_true(not CarKit.DRIFT_KIT["open_wheel_parts"], "the wheels are inside the arches")
	var w := CarKit.wheel_offsets(CarKit.DRIFT)
	assert_true(is_equal_approx(w[2].z - w[0].z, 2.6), "2.60 m wheelbase")

func test_spec_lets_the_rear_go() -> void:
	var s := load(SPEC) as CarSpec
	var gt := load("res://assets/car/specs/gt.tres") as CarSpec
	assert_true(is_equal_approx(s.dry_mass, 1300.0), "1300 kg")
	assert_between((s.engine_power + s.ers_power) / 1000.0, 530.0, 570.0, "about 550 kW")
	assert_true(s.weight_front > 0.5, "front engine: more weight on the front axle")
	assert_true(s.max_steer_angle > 2.0 * gt.max_steer_angle, "a huge steering lock")
	assert_true(s.tyre_peak_slip_angle_rear < s.tyre_peak_slip_angle and s.tyre_reference_load_rear < s.tyre_reference_load,
			"the rear tyres let go first")
	assert_true(s.tyre_mu < gt.tyre_mu and s.tyre_slide_grip_lat > gt.tyre_slide_grip_lat, "less grip, a progressive slide")
	assert_true(s.diff_preload > gt.diff_preload * 3.0 and s.diff_ramp_power > gt.diff_ramp_power, "a nearly locked differential")
	var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_between(top_gear_kmh, 240.0, 270.0, "geared top speed (%.0f km/h)" % top_gear_kmh)
	assert_true(CarKit.for_spec(SPEC) == CarKit.DRIFT, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning_holds_slides() -> void:
	var c := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var f1 := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(c, CarKit.DRIFT)
	assert_true(is_equal_approx(c.mass, 1300.0) and c.sim_spec_path == SPEC, "drift car physics")
	assert_true(c.max_steer_angle > f1.max_steer_angle * 1.5, "a huge steering lock")
	assert_true(c.drift_min_speed_kmh < 50.0 and c.drift_entry_time < f1.drift_entry_time, "slides start easily and slowly")
	assert_true(c.drift_lateral_grip_g < 0.7 * c.lateral_grip_g, "low sliding friction at the rear")
	assert_true(c.drift_drive_factor > f1.drift_drive_factor and c.drift_speed_retention > f1.drift_speed_retention,
			"the power and the speed are kept in a slide")
	assert_true(c.drift_brake_release_time == 0.0, "a slide lasts while the steering is held, no brake needed")
	assert_true(c.drift_base_angle_deg > f1.drift_base_angle_deg and c.drift_min_time > f1.drift_min_time, "big, lasting angles")
	assert_true(c.drift_yaw_time > f1.drift_yaw_time, "a smoother slide to hold")
	assert_between(KitTest._top(c), 260.0, 280.0, "top speed near 270 km/h")
	assert_between(RallyTest.time_to(c, 100.0), 2.7, 3.4, "0-100 km/h in about 3 s (%.2f)" % RallyTest.time_to(c, 100.0))
	c.free()
	f1.free()

## On the flat test ground: brake and full lock at 80 km/h break the rear loose, then the slide
## lasts on the steering alone with the brake released (the F1 car re-grips: test_car_physics).
func test_slide_is_held_on_the_steering() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	CarKit.apply(car, CarKit.DRIFT)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(120)
	car.linear_velocity = -car.global_transform.basis.z * (80.0 / 3.6)
	car.angular_velocity = Vector3.ZERO
	await physics_frames(2)
	car.set_input_override(0.0, 1.0, 1.0)
	var started := false
	for i in 120:
		await get_tree().physics_frame
		started = started or car.is_drifting
	car.set_input_override(0.6, 0.0, 1.0)
	await physics_frames(190)
	assert_true(started, "brake and full lock at 80 km/h break the rear loose")
	assert_true(car.is_drifting, "the slide lasts with the brake released while the lock is held (%.0f km/h, %.0f deg)"
			% [car.speed_kmh, rad_to_deg(car.slip_angle)])
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.99, "the car stays upright")

func test_body_dresses_a_car() -> void:
	await RallyTest.dress_check(self, CarKit.DRIFT, "res://assets/car/drift/body.glb", 1300.0)

func test_event_race_spawns_drift_cars() -> void:
	await KitTest._race_check(self, SERIES, CarKit.DRIFT, "res://assets/car/drift/body.glb", 1300.0, SPEC, false)
