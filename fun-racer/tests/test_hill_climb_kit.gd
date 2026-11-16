extends TestCase
## Hill climb: its events take the hill-climb prototype, a light open-cockpit sports racer with
## enclosed wheels, high downforce for its weight and short gearing.

const SERIES := "hill_climb"
const SPEC := "res://assets/car/specs/hill_climb.tres"
const KitTest := preload("res://tests/test_indycar_kit.gd")
const RallyTest := preload("res://tests/test_rally_kit.gd")

func test_series_takes_the_prototype() -> void:
	assert_true(CarKit.KITS.has(SERIES) and SERIES == CarKit.HILL_CLIMB, "hill climb has a car")
	var events := SeriesCatalog.tracks(SERIES)
	assert_true(events.size() >= 5, "a season of events (%d)" % events.size())
	for t in events:
		assert_true(CarKit.for_track(t.id) == CarKit.HILL_CLIMB, "%s is raced with the prototype" % t.id)
	assert_true(not CarKit.HILL_CLIMB_KIT["open_wheel_parts"], "the wheels are inside fenders")
	var w := CarKit.wheel_offsets(CarKit.HILL_CLIMB)
	assert_true(is_equal_approx(w[2].z - w[0].z, 2.6), "2.60 m wheelbase")

func test_spec_is_a_light_downforce_car() -> void:
	var s := load(SPEC) as CarSpec
	var gt := load("res://assets/car/specs/gt.tres") as CarSpec
	var junior := load("res://assets/car/specs/junior.tres") as CarSpec
	assert_true(is_equal_approx(s.dry_mass, 650.0) and is_equal_approx(s.wheelbase, 2.6), "650 kg, 2.60 m")
	assert_between((s.engine_power + s.ers_power) / 1000.0, 380.0, 420.0, "about 400 kW")
	assert_true(s.dry_mass < junior.dry_mass, "lighter than a feeder single-seater")
	assert_true(s.cl_a / s.dry_mass > 2.0 * gt.cl_a / gt.dry_mass, "far more downforce per kilogram than a GT3 car")
	assert_true((s.engine_power / s.dry_mass) > 1.5 * (gt.engine_power / gt.dry_mass), "far more power per kilogram")
	var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_between(top_gear_kmh, 255.0, 285.0, "short gearing for the climbs (%.0f km/h)" % top_gear_kmh)
	assert_true(CarKit.for_spec(SPEC) == CarKit.HILL_CLIMB, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var c := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var gt := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(c, CarKit.HILL_CLIMB)
	CarKit.apply_physics(gt, CarKit.GT)
	assert_true(is_equal_approx(c.mass, 650.0) and c.sim_spec_path == SPEC, "prototype physics")
	assert_true(c.downforce_coef > gt.downforce_coef and c.aero_grip_g > gt.aero_grip_g and c.lateral_grip_g > gt.lateral_grip_g,
			"more grip and downforce than the GT car")
	assert_true(c.max_steer_angle > gt.max_steer_angle, "a big lock for the hairpins")
	assert_between(KitTest._top(c), 265.0, 290.0, "top speed near 275 km/h")
	assert_between(RallyTest.time_to(c, 100.0), 2.0, 2.6, "0-100 km/h in about 2.3 s (%.2f)" % RallyTest.time_to(c, 100.0))
	for v in [50.0, 100.0, 150.0, 200.0]:
		assert_true(KitTest._accel(c, v) > KitTest._accel(gt, v), "quicker than the GT car at %d km/h" % v)
	c.free()
	gt.free()

func test_body_dresses_a_car() -> void:
	await RallyTest.dress_check(self, CarKit.HILL_CLIMB, "res://assets/car/hill_climb/body.glb", 650.0)

func test_event_race_spawns_prototypes() -> void:
	await KitTest._race_check(self, SERIES, CarKit.HILL_CLIMB, "res://assets/car/hill_climb/body.glb", 650.0, SPEC, false)
