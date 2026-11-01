extends TestCase
## NASCAR: its events take the stock car kit, a heavy closed-wheel oval racer with a big V8,
## a lot of drag, little downforce and soft suspension, about 320 km/h flat out.

const SERIES := "nascar"
const SPEC := "res://assets/car/specs/stock.tres"
const KitTest := preload("res://tests/test_indycar_kit.gd")

func test_series_takes_the_stock_car() -> void:
	assert_true(CarKit.KITS.has(SERIES) and SERIES == CarKit.NASCAR, "NASCAR has a car")
	var events := SeriesCatalog.tracks(SERIES)
	assert_true(events.size() >= 10, "a season of events (%d)" % events.size())
	for t in events:
		assert_true(CarKit.for_track(t.id) == CarKit.NASCAR, "%s is raced with the stock car" % t.id)
	assert_true(not CarKit.STOCK_KIT["open_wheel_parts"], "the wheels are inside the fenders")
	var w := CarKit.wheel_offsets(CarKit.NASCAR)
	assert_true(is_equal_approx(w[2].z - w[0].z, 2.8), "2.80 m wheelbase")

func test_spec_is_a_heavy_stock_car() -> void:
	var s := load(SPEC) as CarSpec
	var gt := load("res://assets/car/specs/gt.tres") as CarSpec
	assert_true(is_equal_approx(s.dry_mass, 1550.0) and is_equal_approx(s.wheelbase, 2.8), "1550 kg, 2.80 m")
	assert_between((s.engine_power + s.ers_power) / 1000.0, 480.0, 520.0, "about 500 kW")
	assert_true(s.cl_a < gt.cl_a and s.cd_a > gt.cd_a, "less downforce and more drag than a GT3 car")
	assert_true(s.tyre_mu < gt.tyre_mu and s.cg_height > gt.cg_height, "less grip, higher centre of mass")
	assert_true(s.arb_front < gt.arb_front and s.spring_front < gt.spring_front, "softer: it leans")
	var p := s.engine_power * s.driveline_efficiency
	var v := pow(2.0 * p / (s.air_density * s.cd_a), 1.0 / 3.0) * 3.6
	assert_between(v, 305.0, 335.0, "drag-limited top speed near 320 km/h (%.0f)" % v)
	var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_true(top_gear_kmh > v, "top gear reaches the drag limit (%.0f > %.0f km/h)" % [top_gear_kmh, v])
	assert_true(CarKit.for_spec(SPEC) == CarKit.NASCAR, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var c := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var gt := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(c, CarKit.NASCAR)
	CarKit.apply_physics(gt, CarKit.GT)
	assert_true(is_equal_approx(c.mass, 1550.0) and c.sim_spec_path == SPEC, "stock car physics")
	assert_true(c.anti_roll_rate < gt.anti_roll_rate and c.spring_rate < gt.spring_rate, "softer than the GT car")
	assert_true(c.downforce_coef < gt.downforce_coef and c.lateral_grip_g < gt.lateral_grip_g, "less grip than the GT car")
	assert_between(KitTest._top(c), 310.0, 335.0, "top speed near 320 km/h")
	c.free()
	gt.free()

func test_event_race_spawns_stock_cars() -> void:
	await KitTest._race_check(self, SERIES, CarKit.NASCAR, "res://assets/car/stock/body.glb", 1550.0, SPEC, false)
