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
	for car in cars:
		assert_true(car.kit == CarKit.ENDURANCE, "%s wears the endurance kit" % car.name)
		assert_true(_body_path(car) == "res://assets/car/endurance/body.glb", "%s body: %s" % [car.name, _body_path(car)])
		assert_true(car.get_node(^"BodyVisual").get_script() != null, "%s keeps the head motion script" % car.name)
		for i in 4:
			var w := car.get_node(["WheelFL", "WheelFR", "WheelRL", "WheelRR"][i]) as Node3D
			assert_true(is_equal_approx(w.position.z, expected[i].z) and is_equal_approx(w.position.x, expected[i].x),
					"%s wheel %d drawn at %s (got %s)" % [car.name, i, expected[i], w.position])
			assert_true(not (w.get_node(^"Suspension") as Node3D).visible and not (w.get_node(^"Steer/Upright") as Node3D).visible,
					"%s wheel %d hides the open-wheel parts" % [car.name, i])
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
