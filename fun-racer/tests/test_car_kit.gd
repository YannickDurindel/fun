extends TestCase
## CarKit: an endurance track dresses the player and the bots in the endurance body with its
## wheelbase; an F1 track keeps the F1 car exactly as car.tscn builds it.

const ENDURANCE_TRACK := "road_atlanta"
const F1_SCENE := "res://scenes/race_red_bull_ring.tscn"

var _saved_track: String
var _saved_bots: int

func _begin(bots: int) -> void:
	_saved_track = Game.config.track_id
	_saved_bots = Game.config.bots
	Game.config.bots = bots
	Bootstrap.autodrive = false

func _end(scene: Node) -> void:
	scene.queue_free()
	await get_tree().process_frame
	Game.config.track_id = _saved_track
	Game.config.bots = _saved_bots

func _body_path(car: Car) -> String:
	var body := car.get_node_or_null(^"BodyVisual/Body")
	return body.scene_file_path if body != null else ""

func test_kit_lookup() -> void:
	assert_true(CarKit.for_track(ENDURANCE_TRACK) == CarKit.ENDURANCE, "Road Atlanta is an endurance track")
	assert_true(CarKit.for_track("red_bull_ring") == CarKit.F1, "Red Bull Ring is F1")
	assert_true(CarKit.for_track("no_such_track") == CarKit.F1, "unknown tracks fall back to F1")
	var f1: Array[Vector3] = []
	f1.assign(Car.WHEEL_OFFSETS)
	assert_true(CarKit.wheel_offsets(CarKit.F1) == f1, "F1 kit draws the wheels where the physics has them")
	var e := CarKit.wheel_offsets(CarKit.ENDURANCE)
	assert_true(is_equal_approx(e[2].z - e[0].z, 3.10), "endurance wheelbase 3.10 m")
	assert_true(e[0].x == f1[0].x and e[3].x == f1[3].x, "same track widths as the F1 car")

func test_endurance_track_spawns_endurance_car() -> void:
	if TrackCatalog.find(ENDURANCE_TRACK) == null or not TrackCatalog.find(ENDURANCE_TRACK).available:
		failures.append("%s is not built (tools/track/build_track.py %s)" % [ENDURANCE_TRACK, ENDURANCE_TRACK])
		return
	_begin(1)
	Game.config.track_id = ENDURANCE_TRACK
	var scene := spawn("res://scenes/race.tscn")
	await physics_frames(3)
	var bots := scene.get_node("Bots") as BotManager
	var cars: Array[Car] = [scene.get_node("Car") as Car]
	cars.append_array(bots.bots)
	assert_true(cars.size() == 2, "player and one bot (%d)" % cars.size())
	var expected := CarKit.wheel_offsets(CarKit.ENDURANCE)
	var e_spec := load("res://assets/car/specs/endurance.tres") as CarSpec
	for car in cars:
		assert_true(car.kit == CarKit.ENDURANCE, "%s wears the endurance kit" % car.name)
		assert_true(_body_path(car) == "res://assets/car/endurance/body.glb", "%s body: %s" % [car.name, _body_path(car)])
		assert_true(car.get_node(^"BodyVisual").get_script() != null, "%s keeps the head motion script" % car.name)
		assert_true(is_equal_approx(car.wheelbase, 3.10) and is_equal_approx(car.wheel_offsets[2].z, 1.55), "%s physics wheelbase 3.10 m" % car.name)
		assert_true(car.sim_spec_path.ends_with("endurance.tres") and is_equal_approx(car.mass, 1030.0), "%s own spec and mass" % car.name)
		assert_true(not CarEnvelope.for_spec(car.sim_spec_path, null).provisional, "%s: the committed envelope of its spec is current (tools/lap_grip_sweep.gd --envelope --spec=...)" % car.name)
		for i in 4:
			var w := car.get_node(["WheelFL", "WheelFR", "WheelRL", "WheelRR"][i]) as Node3D
			assert_true(is_equal_approx(w.position.z, expected[i].z) and is_equal_approx(w.position.x, expected[i].x),
					"%s wheel %d drawn at %s (got %s)" % [car.name, i, expected[i], w.position])
			assert_true(not (w.get_node(^"Suspension") as Node3D).visible and not (w.get_node(^"Steer/Upright") as Node3D).visible,
					"%s wheel %d hides the open-wheel parts" % [car.name, i])
	await _end(scene)

func test_endurance_spec_is_a_hypercar() -> void:
	var f1 := load(Car.SIM_SPEC_PATH) as CarSpec
	var e := load("res://assets/car/specs/endurance.tres") as CarSpec
	assert_true(is_equal_approx(e.wheelbase, 3.10) and is_equal_approx(f1.wheelbase, Car.WHEELBASE), "wheelbases")
	assert_true(is_equal_approx(e.dry_mass, 1030.0), "LMH minimum mass")
	assert_between(e.cl_a / e.cd_a, 3.5, 4.5, "lift to drag near 4")
	assert_true(e.cl_a < f1.cl_a and e.cd_a < f1.cd_a * 1.0 and e.cd_a > 0.0, "less downforce than F1")
	assert_between((e.engine_power + e.ers_power) / 1000.0, 500.0, 540.0, "combined power (kW)")
	assert_true(CarKit.for_spec("res://assets/car/specs/endurance.tres") == CarKit.ENDURANCE and CarKit.for_spec(Car.SIM_SPEC_PATH) == CarKit.F1, "spec to kit")

func test_f1_kit_is_a_no_op() -> void:
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	var mass := car.mass
	var grip := car.lateral_grip_g
	var curve := car.accel_curve_ms2.duplicate()
	CarKit.apply(car, CarKit.F1)
	assert_true(car.mass == mass and car.lateral_grip_g == grip and car.accel_curve_ms2 == curve, "arcade tuning untouched")
	assert_true(car.wheel_offsets == Car.WHEEL_OFFSETS and car.wheelbase == Car.WHEELBASE and car.sim_spec_path == Car.SIM_SPEC_PATH, "F1 contacts and spec")
	car.free()

func test_ghost_wears_the_kit() -> void:
	for pair in [[ENDURANCE_TRACK, CarKit.ENDURANCE], ["red_bull_ring", CarKit.F1]]:
		_begin(0)
		Game.config.track_id = pair[0]
		var scene := spawn("res://scenes/race.tscn")
		await physics_frames(2)
		var ghost := scene.get_node("Ghost") as GhostPlayer
		var body := ghost.ghost_car.get_node(^"BodyVisual/Body")
		var want := "res://assets/car/endurance/body.glb" if pair[1] == CarKit.ENDURANCE else "res://assets/car/body.glb"
		assert_true(body.scene_file_path == want, "%s ghost body: %s" % [pair[0], body.scene_file_path])
		var offsets := CarKit.wheel_offsets(pair[1])
		var fl := ghost.ghost_car.get_node(^"WheelFL") as Node3D
		assert_true(is_equal_approx(fl.position.z, offsets[0].z), "%s ghost front axle at %.2f (got %.2f)" % [pair[0], offsets[0].z, fl.position.z])
		assert_true((fl.get_node(^"Suspension") as Node3D).visible == (pair[1] == CarKit.F1), "%s ghost wishbones" % pair[0])
		await _end(scene)

func test_f1_track_keeps_f1_car() -> void:
	_begin(1)
	var scene := spawn(F1_SCENE)
	await physics_frames(3)
	var bots := scene.get_node("Bots") as BotManager
	var cars: Array[Car] = [scene.get_node("Car") as Car]
	cars.append_array(bots.bots)
	for car in cars:
		assert_true(car.kit == CarKit.F1, "%s is an F1 car" % car.name)
		assert_true(_body_path(car) == "res://assets/car/body.glb", "%s body: %s" % [car.name, _body_path(car)])
		var fl := car.get_node(^"WheelFL") as Node3D
		assert_true(is_equal_approx(fl.position.z, Car.WHEEL_OFFSETS[0].z), "%s front wheel at the F1 axle" % car.name)
		assert_true((fl.get_node(^"Suspension") as Node3D).visible, "%s shows its wishbones" % car.name)
	await _end(scene)

func test_gt_kit_is_a_gt3_car() -> void:
	assert_true(CarKit.for_track("gt_monza") == CarKit.GT and CarKit.for_track("jgt_suzuka") == CarKit.SUPER_GT, "GT events take the GT car")
	assert_true(TrackCatalog.find("gt_monza").available and TrackCatalog.find("jgt_fuji_3h").available, "GT events on built circuits are playable")
	assert_true(CarKit.KITS[CarKit.GT] == CarKit.KITS[CarKit.SUPER_GT], "one car for both GT series")
	var w := CarKit.wheel_offsets(CarKit.GT)
	assert_true(is_equal_approx(w[2].z - w[0].z, 2.65), "GT3 wheelbase 2.65 m")
	var gt := load("res://assets/car/specs/gt.tres") as CarSpec
	var e := load("res://assets/car/specs/endurance.tres") as CarSpec
	assert_true(is_equal_approx(gt.wheelbase, 2.65) and is_equal_approx(gt.dry_mass, 1300.0), "GT3 spec wheelbase and mass")
	assert_true(gt.cl_a < e.cl_a and gt.tyre_mu < e.tyre_mu and gt.engine_power + gt.ers_power < e.engine_power + e.ers_power,
			"less downforce, grip and power than the Hypercar")
	assert_true(not CarEnvelope.for_spec("res://assets/car/specs/gt.tres", null).provisional, "the committed GT envelope is current")
