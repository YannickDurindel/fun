extends TestCase
## Formula E: its events take the formula_e kit, an electric single-seater (cad/body/formula_body.py
## --formula-e) with a shorter wheelbase than F1, 350 kW through a single gear, little downforce
## and all-weather tyres.

const SERIES := "formula_e"
const SPEC := "res://assets/car/specs/formula_e.tres"
const GLB := "res://assets/car/formula_e/body.glb"

func test_series_takes_the_formula_e_kit() -> void:
	assert_true(CarKit.KITS.has(SERIES) and SERIES == CarKit.FORMULA_E, "Formula E has a car")
	for t in SeriesCatalog.tracks(SERIES):
		assert_true(CarKit.for_track(t.id) == CarKit.FORMULA_E, "%s is raced with the Formula E car" % t.id)
	assert_true(CarKit.KITS[CarKit.FORMULA_E]["open_wheel_parts"], "an open-wheeler shows its wishbones")
	var w := CarKit.wheel_offsets(CarKit.FORMULA_E)
	assert_true(is_equal_approx(w[2].z - w[0].z, 2.97), "2.97 m wheelbase")
	assert_true(absf(w[0].x) < absf(Car.WHEEL_OFFSETS[0].x), "narrower than F1")

func test_spec_is_an_electric_single_seater() -> void:
	var f1 := load(Car.SIM_SPEC_PATH) as CarSpec
	var s := load(SPEC) as CarSpec
	assert_true(is_equal_approx(s.dry_mass, 860.0), "860 kg with the driver")
	assert_true(is_equal_approx(s.wheelbase, 2.97), "spec wheelbase matches the kit")
	assert_between((s.engine_power + s.ers_power) / 1000.0, 340.0, 360.0, "about 350 kW")
	assert_true(s.gear_ratios.size() == 1, "single speed")
	assert_true(s.fuel_start == 0.0 and s.fuel_burn_full == 0.0, "no fuel")
	assert_true(s.cl_a < f1.cl_a * 0.35, "little downforce")
	assert_true(s.tyre_mu < f1.tyre_mu * 0.92, "all-weather tyres: clearly less grip than F1 slicks")
	var p := (s.engine_power + s.ers_power) * s.driveline_efficiency
	var v := pow(2.0 * p / (s.air_density * s.cd_a), 1.0 / 3.0) * 3.6
	assert_between(v, 305.0, 335.0, "drag-limited top speed near 320 km/h (%.0f)" % v)
	var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_true(top_gear_kmh > v, "the motor reaches the drag limit (%.0f > %.0f km/h)" % [top_gear_kmh, v])
	assert_true(CarKit.for_spec(SPEC) == CarKit.FORMULA_E, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var f1 := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var c := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(c, CarKit.FORMULA_E)
	assert_true(is_equal_approx(c.mass, 860.0) and c.sim_spec_path == SPEC, "Formula E physics")
	assert_true(is_equal_approx(c.wheelbase, 2.97), "arcade wheelbase")
	assert_true(c.gear_top_kmh.size() == 1, "one gear")
	assert_true(c.downforce_coef < f1.downforce_coef * 0.4 and c.lateral_grip_g < f1.lateral_grip_g, "far less grip than F1")
	assert_between(_top(c), 310.0, 330.0, "top speed near 320 km/h")
	for v in [100.0, 200.0, 300.0]:
		assert_true(_accel(c, v) < _accel(f1, v), "slower than F1 at %d km/h" % v)
	f1.free()
	c.free()

## The simulation car launches and reaches its top speed in one gear, the arcade car too.
func test_single_gear_drives() -> void:
	var car := await SimRig.spawn(self)
	CarKit.apply_physics(car, CarKit.FORMULA_E)
	await physics_frames(SimRig.HZ)
	assert_true(car.sim != null and car.sim.spec.gear_ratios.size() == 1, "simulation on the Formula E spec")
	var r := await SimRig.launch(self, car, 30.0, [100.0, 200.0, 300.0])
	print("  formula_e sim launch: %s" % r)
	assert_between(r["t_100"], 2.3, 3.6, "0-100 km/h near 2.8 s (%.2f)" % r["t_100"])
	assert_true(r["t_300"] > 0.0, "reaches 300 km/h (%.0f km/h after 30 s)" % r["v_end_kmh"])
	assert_between(r["v_end_kmh"], 300.0, 335.0, "top speed near 320 km/h")
	assert_true(car.gear == 1, "still in the one gear")
	car.queue_free()
	var arcade := await SimRig.spawn(self, Car.HANDLING_ARCADE)
	CarKit.apply_physics(arcade, CarKit.FORMULA_E)
	arcade.set_input_override(1.0, 0.0, 0.0)
	await physics_frames(SimRig.HZ * 6)
	assert_true(arcade.gear == 1 and arcade.speed_kmh > 160.0, "arcade: one gear, %.0f km/h after 6 s" % arcade.speed_kmh)
	assert_true(arcade.rpm > arcade.idle_rpm and arcade.rpm <= Car.MAX_RPM, "arcade revs sweep the one gear (%.0f)" % arcade.rpm)
	arcade.queue_free()

func test_body_on_a_car() -> void:
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	add_child(car)
	CarKit.apply(car, CarKit.FORMULA_E)
	var body := car.get_node_or_null(^"BodyVisual/Body")
	assert_true(body != null and body.scene_file_path == GLB, "Formula E body")
	assert_true(car.visual_wheel_offsets == CarKit.wheel_offsets(CarKit.FORMULA_E), "wheels drawn at the kit's offsets")
	assert_true((car.get_node(^"WheelFL/Suspension") as Node3D).visible, "wishbones shown")
	car.queue_free()
	await get_tree().process_frame

func test_event_race_spawns_formula_e_cars() -> void:
	await _race_check(self, SERIES, CarKit.FORMULA_E, GLB, 860.0, SPEC, true)

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
