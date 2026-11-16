extends TestCase
## IndyCar: its events take the indycar kit, the F1 tub shortened to a 3.00 m wheelbase in
## American oval trim (aeroscreen, small flat wings, rear wheel guards) with a turbo V6 on oval
## boost, half an F1 car's downforce and a low-drag top speed near 380 km/h.

const SERIES := "indycar"
const SPEC := "res://assets/car/specs/indycar.tres"

func test_series_takes_the_indycar_kit() -> void:
	assert_true(CarKit.KITS.has(SERIES) and SERIES == CarKit.INDYCAR, "IndyCar has a car")
	var events := SeriesCatalog.tracks(SERIES)
	assert_true(events.size() >= 10, "a season of events (%d)" % events.size())
	for t in events:
		assert_true(CarKit.for_track(t.id) == CarKit.INDYCAR, "%s is raced with the IndyCar" % t.id)
	assert_true(CarKit.KITS[CarKit.INDYCAR]["open_wheel_parts"], "an open-wheeler shows its wishbones")
	var w := CarKit.wheel_offsets(CarKit.INDYCAR)
	assert_true(is_equal_approx(w[2].z - w[0].z, 3.0), "a 3.00 m wheelbase, shorter than the F1 tub's")
	assert_true(is_equal_approx(load(SPEC).wheelbase, 3.0), "the simulation spec has the same wheelbase")

func test_spec_is_an_oval_open_wheeler() -> void:
	var f1 := load(Car.SIM_SPEC_PATH) as CarSpec
	var s := load(SPEC) as CarSpec
	assert_true(is_equal_approx(s.dry_mass, 805.0), "805 kg with the driver")
	assert_between((s.engine_power + s.ers_power) / 1000.0, 530.0, 570.0, "about 550 kW")
	assert_true(s.cl_a < f1.cl_a * 0.6 and s.cd_a < f1.cd_a * 0.6, "low-drag oval aero: far less downforce and drag than F1")
	assert_true(s.tyre_mu < f1.tyre_mu, "less tyre grip than F1")
	# Drag-limited top speed: P = 1/2 rho CdA v^3 (the driveline loses a few percent).
	var p := (s.engine_power + s.ers_power) * s.driveline_efficiency
	var v := pow(2.0 * p / (s.air_density * s.cd_a), 1.0 / 3.0) * 3.6
	assert_between(v, 365.0, 395.0, "drag-limited top speed near 380 km/h (%.0f)" % v)
	var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_true(top_gear_kmh > v, "top gear reaches the drag limit (%.0f > %.0f km/h)" % [top_gear_kmh, v])
	assert_true(CarKit.for_spec(SPEC) == CarKit.INDYCAR, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var f1 := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var c := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(c, CarKit.INDYCAR)
	assert_true(is_equal_approx(c.mass, 805.0) and c.sim_spec_path == SPEC, "IndyCar physics")
	assert_true(c.downforce_coef < f1.downforce_coef and c.lateral_grip_g < f1.lateral_grip_g, "less grip than F1")
	assert_between(_top(c), 370.0, 395.0, "top speed near 380 km/h")
	for v in [100.0, 200.0, 300.0]:
		assert_true(_accel(c, v) < _accel(f1, v), "slower than F1 at %d km/h" % v)
	f1.free()
	c.free()

func test_event_race_spawns_indycars() -> void:
	await _race_check(self, SERIES, CarKit.INDYCAR, "res://assets/car/indycar/body.glb", 805.0, SPEC, true)

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
