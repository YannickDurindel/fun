extends TestCase
## Circuit de Monaco: centreline data, the street-circuit trackside, the race scene on the
## grid, and (with `--full-lap`) two autopilot laps that must stay on the road.
##
##   tests/run_tests.sh --filter=track_monaco
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_monaco --full-lap

const ID := "monaco"
const PATH := "res://assets/tracks/monaco/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 3337.0
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
	Bootstrap.autodrive = false
	scene.queue_free()
	Game.config = _saved_config

func test_catalog_lists_it_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null, "TrackCatalog knows %s" % ID)
	if info == null:
		return
	assert_true(info.available, "track is playable")
	assert_true(info.country_code == "MC", "country code (%s)" % info.country_code)
	assert_true(info.track_json == PATH, "track_json is %s" % info.track_json)
	assert_true(ResourceLoader.exists(info.scene), "track scene %s is missing" % info.scene)

func test_dimensions_match_real_circuit() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	assert_between(d.length, OFFICIAL_LENGTH * 0.99, OFFICIAL_LENGTH * 1.01, "lap length (m)")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	# 78 full laps make the race distance: the grid starts on the finish line.
	assert_between(d.start_s, 0.0, 5.0, "start line on the finish line (m)")
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	# Published: 42 m between the harbour front and Casino Square.
	assert_between(hi - lo, 38.0, 46.0, "elevation range (m)")
	# A street, not a rooftop profile: nothing steeper than the real climbs. Beau Rivage is the
	# steepest, "around 12 %" (Wikipedia, Circuit de Monaco); the build gives 11.3 %.
	var n := d.points.size()
	for i in n:
		var a := d.points[i]
		var b := d.points[(i + 1) % n]
		var run := Vector2(b.x - a.x, b.z - a.z).length()
		assert_true(absf(b.y - a.y) < 0.13 * run + 0.001, "grade above 13 %% at s=%.0f" % (i * d.step))
	assert_true(d.turns.size() == 19, "expected 19 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	if d.turns.size() != 19:
		return
	# Sainte Devote (right) first; the lap is clockwise.
	var dirs := "RLLRRLRRRLRLLRRLLRR"
	for i in dirs.length():
		var want := "right" if dirs[i] == "R" else "left"
		assert_true(String(d.turns[i]["direction"]) == want, "T%d must be a %s-hander" % [i + 1, want])
	var names := {0: "Sainte Dévote", 1: "Beau Rivage", 2: "Massenet", 3: "Casino", 4: "Mirabeau Haute",
			5: "Grand Hotel Hairpin", 7: "Portier", 8: "Tunnel", 9: "Nouvelle Chicane", 11: "Tabac",
			12: "Louis Chiron", 14: "Piscine", 17: "La Rascasse", 18: "Anthony Noghès"}
	for i: int in names:
		assert_true(d.turns[i]["name"] == names[i], "T%d must be %s, got %s" % [i + 1, names[i], d.turns[i]["name"]])
	# About 220 m from the line to the apex of Sainte Devote.
	assert_between(float(d.turns[0]["s_apex"]) - d.start_s, 170.0, 270.0, "start line to T1 apex (m)")
	# The hairpin is the tightest corner of the lap (and of the calendar): about 10 m.
	var tightest := 0
	for i in 19:
		if float(d.turns[i]["min_radius"]) < float(d.turns[tightest]["min_radius"]):
			tightest = i
	assert_true(tightest == 5, "the tightest corner must be the hairpin, got T%d" % (tightest + 1))
	assert_between(float(d.turns[5]["min_radius"]), 8.0, 14.0, "hairpin radius (m)")
	# Up Beau Rivage to Casino Square (the top), down to Portier and the tunnel, then flat along
	# the harbour, which is the low end.
	var y := func(i: int) -> float: return d.position_at(float(d.turns[i]["s_apex"])).y
	assert_true(y.call(3) > y.call(0) + 30.0, "Casino (y=%.1f) is 30 m above Sainte Devote (y=%.1f)" % [y.call(3), y.call(0)])
	assert_true(y.call(3) > y.call(5) + 15.0, "the hairpin (y=%.1f) is well below Casino" % y.call(5))
	assert_true(y.call(5) > y.call(7) + 8.0, "Portier (y=%.1f) is below the hairpin" % y.call(7))
	# The tunnel is at road level, not on the terraces of the hotel above it (20 m higher).
	assert_between(y.call(8) - y.call(7), -3.0, 3.0, "tunnel against Portier (m)")
	for i in range(9, 18):
		assert_between(y.call(i) - lo, 0.0, 3.5, "T%d on the harbour front, above the low point (m)" % (i + 1))

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 220.0, 500.0, 905.0, 1268.0, 1700.0, 2110.0, 2725.0, 3320.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0, s)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

## The road is a street: narrower than a permanent circuit, and track.json does not promise
## the autopilot more width than the road mesh has.
func test_road_is_street_width() -> void:
	var d := TrackData.load_track(PATH)
	var f := FileAccess.open("res://assets/tracks/monaco/road_profile.json", FileAccess.READ)
	assert_true(f != null, "road_profile.json is missing")
	if f == null:
		return
	var prof: Dictionary = JSON.parse_string(f.get_as_text())
	var widths: Array = prof["width"]
	assert_true(widths.size() == d.points.size(), "one width per centreline point")
	var narrowest := INF
	for i in widths.size():
		narrowest = minf(narrowest, float(widths[i]))
		assert_true(d.width_at(i * d.step) <= float(widths[i]) + 0.01,
				"track.json is wider than the road at s=%.0f" % (i * d.step))
	# Measured kerb to kerb on the IGN aerial photograph (see the recipe): 7.5 to 8 m from
	# Mirabeau Haute down to the hairpin, 12 m and more on the grid. The hairpin itself is
	# built 14 m wide so that the game's car gets round it (really 9 to 9.5 m).
	var widest := 0.0
	for w: float in widths:
		widest = maxf(widest, w)
	assert_between(narrowest, 7.5, 8.5, "narrowest road (m)")
	assert_between(widest, 12.0, 14.0, "widest road (m)")
	assert_between(float(widths[int(1160.0 / d.step)]), 7.5, 8.5, "Mirabeau Haute (m)")
	assert_between(float(widths[int(770.0 / d.step)]), 8.5, 9.5, "Massenet (m)")
	assert_between(float(widths[int(400.0 / d.step)]), 9.5, 10.5, "Beau Rivage (m)")
	assert_between(float(widths[int(3300.0 / d.step)]), 11.5, 12.5, "grid (m)")
	# The drivers plan on the same widths (no nominal 10 m any more).
	assert_true(absf(d.width_at(1160.0) - float(widths[int(1160.0 / d.step)])) < 0.3,
			"track.json has the built width at Mirabeau (%.1f m)" % d.width_at(1160.0))

## A street circuit: its own trackside table, no run-off, and the barrier beside the road for
## the whole lap without ever standing on it.
func test_walls_stand_beside_the_road() -> void:
	var d := TrackData.load_track(PATH)
	var layout := TracksideLayout.for_track(ID, d)
	assert_true(not layout.is_auto, "monaco has a hand-made trackside table")
	assert_true(layout.runoff.is_empty(), "no run-off areas")
	assert_true(not layout.kerbs.is_empty(), "apex kerbs")
	var scene := _spawn_race()
	await physics_frames(10)
	var track := scene.get_node_or_null("Track") as Track
	var side := track.get_node_or_null("Trackside") as Trackside if track != null else null
	assert_true(side != null, "the track has a trackside")
	if side == null:
		_free_race(scene)
		return
	var worst_far := 0.0
	var worst_near := INF
	var n := d.points.size()
	for i in range(0, n, 4):
		var s := i * d.step
		var edge := side.edge_at(s)
		for sgn: float in [-1.0, 1.0]:
			var gap := side.barrier_offset(s, sgn) - edge
			worst_far = maxf(worst_far, gap)
			worst_near = minf(worst_near, gap)
	# The real armco stands on the kerb line; the game keeps 2 m, and the table asks for no more.
	assert_true(worst_far <= 3.0, "a barrier stands %.1f m from the road edge (street circuit: at most 3 m)" % worst_far)
	# Between two legs of the lap the wall takes what room there is, but never the road.
	assert_true(worst_near >= 0.0, "a barrier stands on the road (%.2f m inside the edge)" % -worst_near)
	_free_race(scene)

## What stands round the lap on race day: the tunnel under the Fairmont (a closed tube, open
## towards the harbour only before its exit), the temporary grandstands, the swimming pool, a daytime
## Riviera sky, paved ground beside the road instead of grass, and the landmark models.
func test_surroundings_are_monaco() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/tracks/monaco/scenery.json"))
	var roofs: Array = meta.get("roofs", [])
	assert_true(roofs.size() == 2, "two roof shells make the tunnel, got %d" % roofs.size())
	if roofs.size() == 2:
		assert_true(String(roofs[0]["kind"]) == "tunnel", "closed under the hotel and the auditorium")
		assert_true(String(roofs[1]["kind"]) == "gallery_left", "the exit is open towards the harbour (left)")
		assert_between(float(roofs[0]["s"][0]), 1500.0, 1540.0, "tunnel entry after Portier (s)")
		assert_between(float(roofs[1]["s"][1]), 1870.0, 1900.0, "tunnel exit (s)")
		assert_true(absf(float(roofs[0]["s"][1]) - float(roofs[1]["s"][0])) < 0.5, "the two shells join")
		assert_between(float(roofs[0]["length"]) + float(roofs[1]["length"]), 340.0, 380.0, "tunnel length (m)")
	# The Olympic basin of the Stade Nautique, right of the track between Louis Chiron and
	# Piscine: a water body of about 50 x 25 m whose middle is 26 m from the centreline.
	var d := TrackData.load_track(PATH)
	var pool := false
	for body: Dictionary in meta.get("water", []):
		var poly: Array = body["polygon"]
		if poly.size() > 40:
			continue
		var c := Vector2.ZERO
		for q: Array in poly:
			c += Vector2(float(q[0]), float(q[1]))
		c /= float(poly.size())
		var at := Vector3(c.x, 0.0, c.y)
		var s := d.closest_s(at)
		if s > 2600.0 and s < 2700.0 and d.lateral_offset(at, s) > 15.0 and d.lateral_offset(at, s) < 40.0:
			pool = true
	assert_true(pool, "the swimming pool is a water body beside T13 to T16")
	var counts: Dictionary = meta.get("counts", {})
	assert_true(int(counts.get("grandstands", 0)) >= 11, "temporary grandstands (%d)" % int(counts.get("grandstands", 0)))
	var env := TrackEnvironment.load_file("res://assets/tracks/monaco/environment.json")
	assert_true(env.active, "monaco has an environment.json")
	assert_true(String(env.values["time"]) == "day", "the race is run by day")
	assert_true(not env.mowing_stripes(), "no mowed grass beside a street")
	var verge := env.color("verge", "grass_color")
	assert_true(absf(verge.g - verge.r) < 0.06 and absf(verge.g - verge.b) < 0.06,
			"the ground beside the road is paving grey, not green (%s)" % verge)
	var scene := _spawn_race()
	await physics_frames(10)
	var track := scene.get_node_or_null("Track") as Track
	var scenery: Scenery = null
	if track != null:
		for c in track.get_children():
			if c is Scenery:
				scenery = c
	assert_true(scenery != null and scenery.is_built, "the track has built scenery")
	if scenery != null:
		assert_true(scenery.landmark_count == 4, "harbour, pits, gantries, casino: %d landmarks" % scenery.landmark_count)
	_free_race(scene)

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _spawn_race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.data != null, "race scene built the Monaco track")
	if track == null or track.data == null:
		_free_race(scene)
		return
	assert_true(track.track_id == ID, "track id is %s" % track.track_id)
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 5.0, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	_free_race(scene)

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
		_free_race(scene)
		return
	var data := track.data
	var road := track.get_node_or_null("Road") as RoadSurface
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
		# Against the real road (10 m), not the nominal width.
		var half := road.half_width_at(s) if road != null else data.width_at(s) * 0.5
		var edge := half - off
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
		# The real pole laps are about 70 s; the autopilot keeps 1.5 m from the edges.
		assert_between(standing, 68.0, 100.0, "standing lap time (s)")
		assert_between(pilot.lap_time, 66.0, standing + 0.5, "flying lap time (s)")
		assert_true(pilot.max_speed_kmh > 230.0, "top speed %.0f km/h, expected > 230" % pilot.max_speed_kmh)
		for st in pilot.last_lap_turn_stats:
			assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("       %.0f m in %.2f s, max |offset| %.2f m, min edge margin %.2f m at s=%.0f\n" % [
			progress, time, max_offset, worst_edge, worst_edge_s])
	_free_race(scene)
