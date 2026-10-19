extends TestCase
## Junior Formula: its events are raced on the built F1 circuits with the junior car, a feeder
## single-seater with the F1 car's chassis and less power, downforce and top speed.

const EVENT := "jnr_red_bull_ring"
const SPEC := "res://assets/car/specs/junior.tres"

func test_calendar_is_playable_on_f1_circuits() -> void:
	assert_true(SeriesCatalog.is_playable("junior"), "Junior Formula can be raced")
	var events := SeriesCatalog.tracks("junior")
	assert_true(events.size() >= 10, "a season of events (%d)" % events.size())
	var playable := 0
	for t in events:
		if t.circuit.is_empty():
			assert_true(not t.available, "%s without a circuit is coming soon" % t.id)
			continue
		var circuit := TrackCatalog.find(t.circuit)
		assert_true(circuit != null and circuit.series == "f1", "%s is raced on an F1 circuit (%s)" % [t.id, t.circuit])
		assert_true(t.available == circuit.available and t.dir() == circuit.dir(), "%s uses the %s folder" % [t.id, t.circuit])
		assert_true(t.best_path() != circuit.best_path(), "%s keeps its own best laps" % t.id)
		assert_true(CarKit.for_track(t.id) == CarKit.JUNIOR, "%s is a junior event" % t.id)
		if t.available:
			playable += 1
	assert_true(playable >= 10, "most events are playable (%d)" % playable)
	assert_true(CarKit.for_track("red_bull_ring") == CarKit.F1, "the F1 race at the same circuit keeps the F1 car")

func test_spec_is_a_feeder_car() -> void:
	var f1 := load(Car.SIM_SPEC_PATH) as CarSpec
	var j := load(SPEC) as CarSpec
	assert_true(is_equal_approx(j.dry_mass, 795.0), "795 kg")
	assert_between((j.engine_power + j.ers_power) / 745.7, 600.0, 640.0, "about 620 hp")
	assert_true(j.ers_power == 0.0, "no hybrid")
	assert_true(j.cl_a < f1.cl_a * 0.75, "clearly less downforce than F1")
	assert_true(is_equal_approx(j.wheelbase, f1.wheelbase), "F1 chassis")
	assert_true(CarKit.for_spec(SPEC) == CarKit.JUNIOR, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning_is_slower_than_f1() -> void:
	var f1 := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var j := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(j, CarKit.JUNIOR)
	assert_true(j.downforce_coef < f1.downforce_coef and j.lateral_grip_g < f1.lateral_grip_g, "less grip")
	var top := 0.0
	for i in j.accel_curve_kmh.size():
		if j.accel_curve_ms2[i] > 0.0:
			top = j.accel_curve_kmh[i + 1]
	assert_between(top, 320.0, 350.0, "top speed near 335 km/h")
	for v in [100.0, 200.0, 300.0]:
		var fa := _accel(f1, v)
		var ja := _accel(j, v)
		assert_true(ja < fa, "slower at %d km/h (%.1f < %.1f)" % [v, ja, fa])
	f1.free()
	j.free()

func _accel(car: Car, kmh: float) -> float:
	var xs := car.accel_curve_kmh
	for i in xs.size() - 1:
		if kmh <= xs[i + 1]:
			return lerpf(car.accel_curve_ms2[i], car.accel_curve_ms2[i + 1], (kmh - xs[i]) / (xs[i + 1] - xs[i]))
	return 0.0

func test_event_race_spawns_junior_cars() -> void:
	var saved_track := Game.config.track_id
	var saved_bots := Game.config.bots
	Game.config.track_id = EVENT
	Game.config.bots = 1
	Bootstrap.autodrive = false
	var scene := spawn("res://scenes/race.tscn")
	await physics_frames(3)
	var track := scene.get_node("Track") as Track
	assert_true(track.track_id == "red_bull_ring" and track.race_id() == EVENT, "the Red Bull Ring folder, recorded as the event")
	var cars: Array[Car] = [scene.get_node("Car") as Car]
	cars.append_array((scene.get_node("Bots") as BotManager).bots)
	assert_true(cars.size() == 2, "player and one bot")
	for car in cars:
		assert_true(car.kit == CarKit.JUNIOR, "%s wears the junior kit" % car.name)
		var body := car.get_node_or_null(^"BodyVisual/Body")
		assert_true(body != null and body.scene_file_path == "res://assets/car/junior/body.glb", "%s junior body" % car.name)
		assert_true(is_equal_approx(car.mass, 795.0) and car.sim_spec_path == SPEC, "%s junior physics" % car.name)
		assert_true((car.get_node(^"WheelFL/Suspension") as Node3D).visible, "%s shows its wishbones" % car.name)
	scene.queue_free()
	await get_tree().process_frame
	Game.config.track_id = saved_track
	Game.config.bots = saved_bots
