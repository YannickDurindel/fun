extends TestCase
## Imola (Autodromo Enzo e Dino Ferrari): centreline data built by tools/track/build_track.py
## from tools/track/tracks/imola.toml, and the race scene on it.

const ID := "imola"
const PATH := "res://assets/tracks/imola/track.json"
const OFFICIAL_LENGTH := 4909.0

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
	# Published: about 30 m between the pit straight / Rivazza and Piratella.
	assert_between(hi - lo, 25.0, 40.0, "elevation range (m)")
	assert_true(d.turns.size() == 19, "expected 19 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# The grid is 216 m after the timing line (a 63-lap Grand Prix is 218 m short of 63 laps).
	assert_between(d.start_s, 200.0, 235.0, "start line after the finish line (m)")

func test_turns_match_the_official_map() -> void:
	var d := TrackData.load_track(PATH)
	if d == null or d.turns.size() != 19:
		assert_true(false, "turn table missing")
		return
	var want := {
		"T2": ["Tamburello", "left"], "T3": ["Tamburello", "right"], "T4": ["Tamburello", "left"],
		"T5": ["Villeneuve", "left"], "T6": ["Villeneuve", "right"], "T7": ["Tosa", "left"],
		"T9": ["Piratella", "left"], "T11": ["Acque Minerali", "right"],
		"T12": ["Acque Minerali", "right"], "T13": ["Acque Minerali", "left"],
		"T14": ["Variante Alta", "right"], "T15": ["Variante Alta", "left"],
		"T17": ["Rivazza", "left"], "T18": ["Rivazza", "left"],
	}
	var lefts := 0
	for i in d.turns.size():
		var t: Dictionary = d.turns[i]
		assert_true(t["id"] == "T%d" % (i + 1), "turn %d has id %s" % [i + 1, t["id"]])
		lefts += 1 if String(t["direction"]) == "left" else 0
		if want.has(t["id"]):
			var w: Array = want[t["id"]]
			assert_true(t["name"] == w[0] and t["direction"] == w[1],
					"%s is %s (%s), expected %s (%s)" % [t["id"], t["name"], t["direction"], w[0], w[1]])
	assert_true(lefts > d.turns.size() - lefts, "anticlockwise: more left-handers than right-handers")
	# Piratella is the top of the hill; Rivazza is back down at the level of the pit straight.
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	var piratella := d.position_at(float(d.turns[8]["s_apex"])).y
	var rivazza := d.position_at(float(d.turns[17]["s_apex"])).y
	assert_true(piratella > hi - 5.0, "Piratella near the highest point (y=%.1f, max %.1f)" % [piratella, hi])
	assert_true(rivazza < lo + 5.0, "second Rivazza near the lowest point (y=%.1f, min %.1f)" % [rivazza, lo])

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 333.3, 1691.0, 2845.7, 3370.0, 4900.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

func test_catalog_lists_imola_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "imola is listed as playable")
	if info != null:
		assert_true(info.track_json == PATH, "track_json: %s" % info.track_json)
		assert_true(ResourceLoader.exists(info.scene), "scene exists: %s" % info.scene)
		assert_true(info.turns == 19 and absf(info.length_m - OFFICIAL_LENGTH) < 1.0, "info fields")

func test_race_scene_spawns_car_on_track() -> void:
	var saved_config := Game.config   # the race scene points Game.config at its track
	Game.config = saved_config.copy()
	Game.config.track_id = ID
	var scene := spawn("res://scenes/race.tscn")
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID and track.data != null, "race scene built imola")
	if track != null and track.data != null:
		var d := track.data
		assert_true(not (track.get_node("Road") as RoadSurface).is_runtime_mesh, "road comes from road_mesh.glb")
		assert_true(not (track.get_node("Terrain") as Terrain).is_fallback, "terrain is the baked one")
		await physics_frames(240)
		var car := scene.get_node("Car") as Car
		var s := d.closest_s(car.global_position)
		assert_true(absf(d.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
		assert_true(absf(d.delta_s(d.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
		var road_y := d.position_at(s).y
		assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	scene.queue_free()
	Game.config = saved_config

## The baked road mesh (road_mesh.glb) lies on the centreline of track.json all the way round:
## tarmac under the centre and 5 m either side, grass 3 m beyond the edge.
func test_road_mesh_follows_centreline() -> void:
	var saved_config := Game.config
	Game.config = saved_config.copy()
	Game.config.track_id = ID
	var scene := spawn("res://scenes/race.tscn")
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.data != null, "race scene built imola")
	if track != null and track.data != null:
		var d := track.data
		var road := track.get_node("Road") as RoadSurface
		var ts := track.get_node("Trackside") as Trackside
		var frames := 0
		while not ts.is_built and frames < 600:
			await physics_frames(1)
			frames += 1
		await physics_frames(2)
		var space := track.get_world_3d().direct_space_state
		var bad: Array[String] = []
		var probes := 0
		var s := 0.0
		while s < d.length:
			var hw := road.half_width_at(s)
			for lat: float in [0.0, -5.0, 5.0, -(hw + 3.0), hw + 3.0]:
				if absf(lat) > hw and road.verge_at(s, lat) < 4.0:
					continue
				# Nudged off the exact mesh vertices: a ray through a vertex shared by four
				# triangles (s = 0 on the centreline) can slip between them.
				var p := road.surface_point(s + 0.37, lat + 0.11)
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
						p + Vector3.UP * 5.0, p + Vector3.DOWN * 5.0))
				probes += 1
				if hit.is_empty():
					bad.append("s=%.0f lat=%.1f: nothing" % [s, lat])
					continue
				var col := hit["collider"] as Node
				if ts.is_ancestor_of(col):
					continue   # a kerb or run-off patch lies on top here
				var want := "asphalt" if absf(lat) < hw else "grass"
				if not road.is_ancestor_of(col) or col.get_meta("surface", "") != want \
						or absf(hit["position"].y - p.y) > 0.05:
					bad.append("s=%.0f lat=%.1f: %s at %.2f, expected %s at %.2f" % [
							s, lat, col.name, hit["position"].y, want, p.y])
			s += 20.0
		assert_true(probes > 1000, "probed the whole lap (%d)" % probes)
		assert_true(bad.is_empty(), "%d of %d surface probes off, e.g. %s" % [bad.size(), probes, bad.slice(0, 4)])
	scene.queue_free()
	Game.config = saved_config

## One standing lap by the autopilot, from the grid: it must stay on the tarmac all the way
## round (the walls are at least 1.5 m beyond the road edge, so that also means no contact).
## Only with `--full-lap`, under `--fixed-fps 240 --disable-vsync` (about 100 s of physics):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_imola --full-lap
func test_autopilot_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	var saved_config := Game.config
	Game.config = saved_config.copy()
	Game.config.track_id = ID
	Bootstrap.autodrive = true
	var scene := spawn("res://scenes/race.tscn")
	var track := scene.get_node_or_null("Track") as Track
	var pilot := scene.get_node_or_null("Autodrive") as Autopilot
	assert_true(track != null and track.data != null and pilot != null, "race scene with autopilot")
	if track != null and track.data != null and pilot != null:
		var d := track.data
		var car := scene.get_node("Car") as Car
		var waited := 0
		while car.linear_velocity.length() < 1.0 and waited < 240 * 12:
			await physics_frames(1)
			waited += 1
		assert_true(waited < 240 * 12, "car never started moving")
		var s := d.closest_s(car.global_position)
		var time := 0.0
		var progress := 0.0
		var worst_edge := INF
		var worst_s := 0.0
		var top := 0.0
		while time < 200.0 and pilot.laps_completed < 1:
			await physics_frames(1)
			time += 1.0 / 240.0
			var pos := car.global_position
			var ns := d.closest_s(pos, s)
			progress += d.delta_s(s, ns)
			s = ns
			var edge := d.width_at(s) * 0.5 - absf(d.lateral_offset(pos, s))
			if edge < worst_edge:
				worst_edge = edge
				worst_s = s
			top = maxf(top, car.linear_velocity.length() * 3.6)
		assert_true(pilot.laps_completed >= 1, "lap not completed in 200 s (progress %.0f m)" % progress)
		assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_s])
		assert_between(progress, d.length - 60.0, d.length + 60.0, "distance driven (m)")
		assert_between(pilot.lap_time, 70.0, 110.0, "lap time (s)")
		assert_true(top > 270.0, "top speed %.0f km/h, expected > 270" % top)
		for st in pilot.last_lap_turn_stats:
			assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
		print("\nIMOLA LAP 1 (from the grid, timed start line to start line)\n" + pilot.report())
		print("       lap %.2f s, top speed %.0f km/h, %.0f m driven, min edge margin %.2f m at s=%.0f\n" % [
				pilot.lap_time, top, progress, worst_edge, worst_s])
	Bootstrap.autodrive = false
	scene.queue_free()
	Game.config = saved_config
