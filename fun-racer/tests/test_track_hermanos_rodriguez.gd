extends TestCase
## Autódromo Hermanos Rodríguez (Mexico City): centreline data, and the race scene on it.
## The autopilot lap runs with `--full-lap` only (fixed-fps, see tools/lap_demo.sh):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_hermanos_rodriguez --full-lap

const ID := "hermanos_rodriguez"
const PATH := "res://assets/tracks/hermanos_rodriguez/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 4304.0
const TICK := 1.0 / 240.0

var _saved_config: RaceConfig

func _spawn_race() -> Node:
	_saved_config = Game.config   # the race scene points Game.config at its track
	Game.config = _saved_config.copy()
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func _free_race(scene: Node) -> void:
	scene.queue_free()
	Game.config = _saved_config

func test_catalog_lists_it_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null, "TrackCatalog knows %s" % ID)
	if info == null:
		return
	assert_true(info.available, "track is playable")
	assert_true(info.country_code == "MX", "country code (%s)" % info.country_code)

func test_dimensions_match_real_circuit() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	assert_between(d.length, OFFICIAL_LENGTH * 0.99, OFFICIAL_LENGTH * 1.01, "lap length (m)")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	# The real lap is almost flat (a few metres); the city surface model must not add hills.
	assert_between(hi - lo, 0.5, 6.0, "elevation range (m)")
	assert_true(d.turns.size() == 17, "expected 17 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# Official numbering: right-left-right Ese Moisés Solana, ..., Peraltada (right) last.
	var dirs := "RLRLRRLRLRLRLRLRR"
	for i in mini(d.turns.size(), dirs.length()):
		var want := "right" if dirs[i] == "R" else "left"
		assert_true(String(d.turns[i]["direction"]) == want, "T%d must be a %s-hander" % [i + 1, want])
	assert_true(String(d.turns[0]["name"]).begins_with("Ese Moisés Solana"), "T1 is the Ese Moisés Solana")
	assert_true(String(d.turns[16]["name"]).contains("Peraltada"), "T17 is the Peraltada")
	# The main straight: about 1.2 km from the Peraltada to turn 1, with the grid on it.
	var straight := d.delta_s(float(d.turns[16]["s_apex"]), float(d.turns[0]["s_apex"]))
	assert_between(straight, 1150.0, 1400.0, "Peraltada apex -> T1 apex (m)")
	assert_between(d.start_s, 100.0, 400.0, "start line on the main straight (s)")
	# Widths measured on aerial imagery (tools/track/tracks/hermanos_rodriguez.toml): 15 m
	# on the pit straight, 12 m on the 1959 road (back straight, Eses), 14 m in the stadium.
	assert_between(d.width_at(100.0), 14.5, 15.5, "pit straight width (m)")
	assert_between(d.width_at(1700.0), 11.5, 12.5, "back straight width (m)")
	assert_between(d.width_at(2800.0), 11.5, 12.5, "Las Eses width (m)")
	assert_between(d.width_at(3870.0), 13.5, 14.5, "Foro Sol width (m)")
	# Clockwise: the signed plan area (x east, z south) is positive.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area > 0.0, "lap must run clockwise")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 333.3, 1216.0, 2292.0, 3840.5, 4290.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _spawn_race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID, "race scene built %s" % ID)
	if track != null and track.data != null:
		var s := track.data.closest_s(car.global_position)
		assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
		assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
		var road_y := track.data.position_at(s).y
		assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	# The surroundings: the Foro Sol, the pit straight and the other hand-built landmarks,
	# and the hand-made walled-in trackside table instead of the automatic one.
	var scenery := scene.find_child("Scenery", true, false) as Scenery
	assert_true(scenery != null and scenery.landmark_count == 6, "6 landmarks built (%d)" % (
			scenery.landmark_count if scenery != null else -1))
	assert_true(TracksideLayout.has_table(ID), "hand-made trackside table")
	_free_race(scene)

func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	Bootstrap.autodrive = true
	var scene := _spawn_race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node_or_null("Autodrive") as Autopilot
	var track := scene.get_node_or_null("Track") as Track
	assert_true(pilot != null and track != null and track.data != null, "race scene with autopilot")
	if pilot == null or track == null or track.data == null:
		Bootstrap.autodrive = false
		_free_race(scene)
		return
	var d := track.data
	var waited := 0
	while car.linear_velocity.length() < 1.0 and waited < 240 * 12:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 12, "car never started moving")
	var s := d.closest_s(car.global_position)
	var time := 0.0
	var progress := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var top := 0.0
	var laps_wanted := 2
	while time < 300.0 and pilot.laps_completed < laps_wanted:
		await physics_frames(1)
		time += TICK
		var pos := car.global_position
		var ns := d.closest_s(pos, s)
		progress += d.delta_s(s, ns)
		s = ns
		var edge := d.width_at(s) * 0.5 - absf(d.lateral_offset(pos, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		top = maxf(top, car.linear_velocity.length() * 3.6)
		if pilot.laps_completed == 1 and laps_wanted == 2 and not _lap1_printed:
			_lap1_printed = true
			print("\nLAP 1 (from the grid)\n" + pilot.report())
			assert_between(pilot.lap_time, 70.0, 110.0, "standing lap time (s)")
	assert_true(pilot.laps_completed >= laps_wanted, "laps not completed in 300 s of physics (progress %.0f m)" % progress)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	assert_between(pilot.lap_time, 70.0, 110.0, "flying lap time (s)")
	assert_true(top > 280.0, "top speed %.0f km/h, expected > 280 on the 1.2 km straight" % top)
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nLAP 2 (flying)\n" + pilot.report())
	print("       %.0f m in %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f\n" % [
			progress, time, top, worst_edge, worst_edge_s])
	Bootstrap.autodrive = false
	_free_race(scene)

var _lap1_printed := false
