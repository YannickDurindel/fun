extends TestCase
## Autodromo Nazionale Monza: centreline data, the race scene on the grid, and (with
## `--full-lap`) one autopilot lap that must stay on the road.
##
##   tests/run_tests.sh --filter=track_monza
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_monza --full-lap

const ID := "monza"
const PATH := "res://assets/tracks/monza/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5793.0
## The finish (timing) line lies 309 m before the start line: 53 laps x 5.793 km - 306.720 km.
const START_OFFSET := 309.0
const TICK := 1.0 / 240.0

var _saved_track := ""

func test_dimensions_match_real_circuit() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	assert_between(d.length, OFFICIAL_LENGTH * 0.99, OFFICIAL_LENGTH * 1.01, "lap length (m)")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	assert_between(d.start_s, START_OFFSET - 5.0, START_OFFSET + 5.0, "start line after the finish line (m)")
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	# Published: about 13 m. The DEM is a surface model of a wooded park, so allow some more.
	assert_between(hi - lo, 8.0, 22.0, "elevation range (m)")
	assert_true(d.turns.size() == 11, "expected 11 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	if d.turns.size() != 11:
		return
	var names := ["Variante del Rettifilo", "Variante del Rettifilo", "Curva Grande", "Variante della Roggia",
			"Variante della Roggia", "Lesmo 1", "Lesmo 2", "Variante Ascari", "Variante Ascari",
			"Variante Ascari", "Curva Alboreto (Parabolica)"]
	var dirs := ["right", "left", "right", "left", "right", "right", "right", "left", "right", "left", "right"]
	for i in 11:
		assert_true(d.turns[i]["name"] == names[i], "T%d must be %s, got %s" % [i + 1, names[i], d.turns[i]["name"]])
		assert_true(d.turns[i]["direction"] == dirs[i], "T%d must turn %s" % [i + 1, dirs[i]])
	# The first chicane comes about 625 m after the start line; the lap is clockwise, so the
	# right-handers outweigh the left-handers.
	assert_between(float(d.turns[0]["s_apex"]) - d.start_s, 560.0, 690.0, "start line to T1 apex (m)")
	# The Lesmo corners are the high end of the park, the Parabolica the low end.
	var lesmo_y := d.position_at(float(d.turns[5]["s_apex"])).y
	var parabolica_y := d.position_at(float(d.turns[10]["s_apex"])).y
	assert_true(lesmo_y > parabolica_y + 5.0, "Lesmo 1 (y=%.1f) should be well above the Parabolica (y=%.1f)" % [
			lesmo_y, parabolica_y])

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 309.0, 950.0, 2170.0, 4100.0, 5140.0, 5780.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

func test_catalog_lists_monza_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null, "TrackCatalog has no entry for monza")
	if info == null:
		return
	assert_true(info.available, "monza must be playable")
	assert_true(info.track_json == PATH, "track_json is %s" % info.track_json)
	assert_true(ResourceLoader.exists(info.scene), "track scene %s is missing" % info.scene)

func _spawn_race() -> Node:
	_saved_track = Game.config.track_id
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func _restore() -> void:
	Bootstrap.autodrive = false
	Game.config.track_id = _saved_track

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _spawn_race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.data != null, "race scene built the Monza track")
	if track == null or track.data == null:
		_restore()
		return
	assert_true(track.track_id == ID, "track id is %s" % track.track_id)
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	_restore()

## One autopilot lap from the grid, then the lap that follows: never off the road (so never
## in a wall), every turn visited.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	Bootstrap.autodrive = true
	var scene := _spawn_race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node_or_null("Autodrive") as Autopilot
	var track := scene.get_node_or_null("Track") as Track
	assert_true(pilot != null and track != null, "race scene has the autopilot and the track")
	if pilot == null or track == null:
		_restore()
		return
	var data := track.data
	var time := 0.0
	var progress := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var max_offset := 0.0
	var s := data.closest_s(car.global_position)
	var standing := -1.0
	while time < 400.0 and pilot.laps_completed < 2:
		await physics_frames(1)
		time += TICK
		var pos := car.global_position
		var ns := data.closest_s(pos, s)
		progress += data.delta_s(s, ns)
		s = ns
		var off := absf(data.lateral_offset(pos, s))
		max_offset = maxf(max_offset, off)
		var edge := data.width_at(s) * 0.5 - off
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		if pilot.laps_completed == 1 and standing < 0.0:
			standing = pilot.lap_time
			print("\nLAP 1 (from the grid, start line to start line)\n" + pilot.report())
	assert_true(pilot.laps_completed >= 2, "two laps not completed in 400 s of physics (progress %.0f m)" % progress)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f (max |offset| %.2f m)" % [
			worst_edge, worst_edge_s, max_offset])
	if pilot.laps_completed >= 2:
		print("\nLAP 2 (flying)\n" + pilot.report())
		assert_between(standing, 75.0, 130.0, "standing lap time (s)")
		assert_between(pilot.lap_time, 75.0, standing + 0.5, "flying lap time (s)")
		assert_true(pilot.max_speed_kmh > 300.0, "top speed %.0f km/h, expected > 300" % pilot.max_speed_kmh)
		for st in pilot.last_lap_turn_stats:
			assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("       %.0f m in %.2f s, max |offset| %.2f m, min edge margin %.2f m at s=%.0f\n" % [
			progress, time, max_offset, worst_edge, worst_edge_s])
	_restore()
