extends TestCase
## Super Formula: its events take the super_formula kit, a high-downforce Japanese single-seater
## (cad/body/formula_body.py --super-formula) with the F1 car's aero on a shorter tub, a 410 kW
## turbo four, close to an F1 car's grip and about 300 km/h flat out.

const SERIES := "super_formula"
const SPEC := "res://assets/car/specs/super_formula.tres"
const GLB := "res://assets/car/super_formula/body.glb"

func test_series_takes_the_super_formula_kit() -> void:
	assert_true(CarKit.KITS.has(SERIES) and SERIES == CarKit.SUPER_FORMULA, "Super Formula has a car")
	for t in SeriesCatalog.tracks(SERIES):
		assert_true(CarKit.for_track(t.id) == CarKit.SUPER_FORMULA, "%s is raced with the Super Formula car" % t.id)
	assert_true(CarKit.KITS[CarKit.SUPER_FORMULA]["open_wheel_parts"], "an open-wheeler shows its wishbones")
	var w := CarKit.wheel_offsets(CarKit.SUPER_FORMULA)
	assert_true(is_equal_approx(w[2].z - w[0].z, 3.165), "3.165 m wheelbase")

func test_spec_is_a_high_downforce_single_seater() -> void:
	var f1 := load(Car.SIM_SPEC_PATH) as CarSpec
	var j := load("res://assets/car/specs/junior.tres") as CarSpec
	var s := load(SPEC) as CarSpec
	assert_true(is_equal_approx(s.dry_mass, 750.0), "750 kg with the driver")
	assert_true(is_equal_approx(s.wheelbase, 3.165), "spec wheelbase matches the kit")
	assert_between((s.engine_power + s.ers_power) / 1000.0, 395.0, 425.0, "about 410 kW")
	assert_true(s.ers_power == 0.0, "no hybrid")
	assert_true(s.cl_a > j.cl_a and s.cl_a < f1.cl_a, "more downforce than the junior car, less than F1")
	assert_true(s.tyre_mu > j.tyre_mu and s.tyre_mu <= f1.tyre_mu, "close to F1 grip")
	var p := (s.engine_power + s.ers_power) * s.driveline_efficiency
	var v := pow(2.0 * p / (s.air_density * s.cd_a), 1.0 / 3.0) * 3.6
	assert_between(v, 285.0, 315.0, "drag-limited top speed near 300 km/h (%.0f)" % v)
	var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_true(top_gear_kmh > v, "top gear reaches the drag limit (%.0f > %.0f km/h)" % [top_gear_kmh, v])
	assert_true(CarKit.for_spec(SPEC) == CarKit.SUPER_FORMULA, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var f1 := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var c := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(c, CarKit.SUPER_FORMULA)
	assert_true(is_equal_approx(c.mass, 750.0) and c.sim_spec_path == SPEC, "Super Formula physics")
	assert_true(is_equal_approx(c.wheelbase, 3.165), "arcade wheelbase")
	assert_true(c.downforce_coef < f1.downforce_coef and c.lateral_grip_g < f1.lateral_grip_g, "a little less grip than F1")
	var junior := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(junior, CarKit.JUNIOR)
	assert_true(c.downforce_coef > junior.downforce_coef and c.lateral_grip_g > junior.lateral_grip_g, "more grip than the junior car")
	assert_between(_top(c), 290.0, 315.0, "top speed near 300 km/h")
	for v in [100.0, 200.0, 300.0]:
		assert_true(_accel(c, v) < _accel(f1, v), "slower than F1 at %d km/h" % v)
	f1.free()
	c.free()
	junior.free()

func test_sim_launch() -> void:
	var car := await SimRig.spawn(self)
	CarKit.apply_physics(car, CarKit.SUPER_FORMULA)
	await physics_frames(SimRig.HZ)
	var r := await SimRig.launch(self, car, 30.0, [100.0, 200.0, 280.0])
	print("  super_formula sim launch: %s" % r)
	assert_between(r["t_100"], 2.3, 3.6, "0-100 km/h near 2.8 s (%.2f)" % r["t_100"])
	assert_true(r["t_280"] > 0.0, "reaches 280 km/h (%.0f km/h after 30 s)" % r["v_end_kmh"])
	assert_between(r["v_end_kmh"], 285.0, 315.0, "top speed near 300 km/h")
	car.queue_free()
	await get_tree().process_frame

func test_body_on_a_car() -> void:
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	add_child(car)
	CarKit.apply(car, CarKit.SUPER_FORMULA)
	var body := car.get_node_or_null(^"BodyVisual/Body")
	assert_true(body != null and body.scene_file_path == GLB, "Super Formula body")
	assert_true(car.visual_wheel_offsets == CarKit.wheel_offsets(CarKit.SUPER_FORMULA), "wheels drawn at the kit's offsets")
	assert_true((car.get_node(^"WheelFL/Suspension") as Node3D).visible, "wishbones shown")
	car.queue_free()
	await get_tree().process_frame

func test_event_race_spawns_super_formula_cars() -> void:
	await _race_check(self, SERIES, CarKit.SUPER_FORMULA, GLB, 750.0, SPEC, true)

static func _top(car: Car) -> float:
	var top := 0.0
	for i in car.accel_curve_kmh.size():
		if car.accel_curve_ms2[i] > 0.0:
			top = car.accel_curve_kmh[i + 1]
	return top

static func _accel(car: Car, kmh: float) -> float:
	var xs := car.accel_curve_kmh
	for i in xs.size() - 1:
		if kmh <= xs[i + 1]:
			return lerpf(car.accel_curve_ms2[i], car.accel_curve_ms2[i + 1], (kmh - xs[i]) / (xs[i + 1] - xs[i]))
	return 0.0

## Races the series' first playable event with one bot: both cars wear the kit. Passes with a
## note while the series has no event on a built circuit yet.
static func _race_check(t: TestCase, series: String, kit: String, glb: String, mass: float, spec: String,
		wishbones: bool) -> void:
	var event := ""
	for e in SeriesCatalog.tracks(series):
		if e.available:
			event = e.id
			break
	if event.is_empty():
		print("  (%s has no playable event yet: race check skipped)" % series)
		return
	var saved_track := Game.config.track_id
	var saved_bots := Game.config.bots
	Game.config.track_id = event
	Game.config.bots = 1
	Bootstrap.autodrive = false
	var scene := t.spawn("res://scenes/race.tscn")
	await t.physics_frames(3)
	var cars: Array[Car] = [scene.get_node("Car") as Car]
	cars.append_array((scene.get_node("Bots") as BotManager).bots)
	t.assert_true(cars.size() == 2, "player and one bot")
	for car in cars:
		t.assert_true(car.kit == kit, "%s wears the %s kit" % [car.name, kit])
		var body := car.get_node_or_null(^"BodyVisual/Body")
		t.assert_true(body != null and body.scene_file_path == glb, "%s %s body" % [car.name, kit])
		t.assert_true(is_equal_approx(car.mass, mass) and car.sim_spec_path == spec, "%s %s physics" % [car.name, kit])
		t.assert_true((car.get_node(^"WheelFL/Suspension") as Node3D).visible == wishbones, "%s wishbones shown: %s" % [car.name, wishbones])
	scene.queue_free()
	await t.get_tree().process_frame
	Game.config.track_id = saved_track
	Game.config.bots = saved_bots
