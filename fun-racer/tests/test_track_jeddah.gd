extends TestCase
## Jeddah Corniche Circuit: track data, the race scene on the generic track runtime with the
## street-circuit walls of its trackside table, and (with --full-lap) an autopilot lap.
##
##   tests/run_tests.sh --filter=track_jeddah
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_jeddah --full-lap

const ID := "jeddah"
const PATH := "res://assets/tracks/jeddah/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 6174.0
const TURNS := 27
## The timing line lies 250 m before the start line: 50 laps x 6.174 km - 308.450 km.
const START_OFFSET := 250.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_catalog_lists_the_track_as_playable() -> void:
	TrackCatalog.reload()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "jeddah must be a playable track")
	if info == null:
		return
	assert_true(info.name == "Jeddah Corniche Circuit", "name '%s'" % info.name)
	assert_true(info.country_code == "SA", "country code '%s'" % info.country_code)
	assert_true(info.track_json == PATH, "track_json is %s" % info.track_json)
	assert_true(ResourceLoader.exists(info.scene), "track scene %s is missing" % info.scene)

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
	var west := INF
	var east := -INF
	var north := INF
	var south := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
		west = minf(west, p.x)
		east = maxf(east, p.x)
		north = minf(north, p.z)
		south = maxf(south, p.z)
	# Reclaimed land at the shore: flat, a few metres at most.
	assert_between(hi - lo, 0.5, 6.0, "elevation range (m)")
	# Long and thin along the shore: about 2.75 km north to south, 0.6 km east to west.
	assert_between(south - north, 2500.0, 3000.0, "north-south extent (m)")
	assert_between(east - west, 450.0, 750.0, "east-west extent (m)")
	assert_true(d.turns.size() == TURNS, "expected %d turns, got %d" % [TURNS, d.turns.size()])
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	if d.turns.size() != TURNS:
		return
	# Left-right chicane at Turns 1-2, the left hairpins 13 and 27, left-right at Turns 22-23.
	var dirs := ""
	for t in d.turns:
		dirs += "R" if String(t["direction"]) == "right" else "L"
	assert_true(dirs == "LRLLRLLRRLRLLRRLRLRLRLRRLLL", "turn directions %s" % dirs)
	assert_true(String(d.turns[12]["name"]).contains("banked hairpin"), "T13 is the banked hairpin")
	assert_true(String(d.turns[26]["name"]).contains("final hairpin"), "T27 is the final hairpin")
	# Anticlockwise: the signed area of the plan view (x east, z south) is negative.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area < 0.0, "the lap must run anticlockwise")
	# The grid is on the pit straight: about 245 m to the apex of Turn 1, and the last hairpin
	# is about 570 m before the finish line.
	assert_between(float(d.turns[0]["s_apex"]) - d.start_s, 200.0, 290.0, "start line to T1 apex (m)")
	assert_between(d.length - float(d.turns[26]["s_apex"]), 500.0, 640.0, "T27 apex to the finish line (m)")
	# Turn 13 is the north end of the lap and Turn 27 the south end (z = -north).
	var t13 := d.position_at(float(d.turns[12]["s_apex"]))
	var t27 := d.position_at(float(d.turns[26]["s_apex"]))
	assert_true(t13.z < north + 120.0, "Turn 13 at the north end (z=%.0f, north end %.0f)" % [t13.z, north])
	assert_true(t27.z > south - 60.0, "Turn 27 at the south end (z=%.0f, south end %.0f)" % [t27.z, south])
	# Turn 4 is a fast corner (the OSM vertices there are rounded by the recipe).
	assert_true(float(d.turns[3]["min_radius"]) > 40.0, "Turn 4 radius %.0f m" % float(d.turns[3]["min_radius"]))

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 250.0, 495.0, 1004.0, 2381.0, 3208.0, 4292.0, 5605.0, 6100.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0, s)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.data != null, "the race scene builds the track")
	if track == null or track.data == null:
		scene.queue_free()
		return
	assert_true(track.track_id == ID, "track id '%s'" % track.track_id)
	var road := track.get_node("Road") as RoadSurface
	assert_true(road != null and not road.is_runtime_mesh, "the road comes from road_mesh.glb")
	assert_true(not (track.get_node("Terrain") as Terrain).is_fallback, "the terrain is the baked one")
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	scene.queue_free()

## A street circuit: concrete walls close to the road all the way round, never on it, and no
## gravel.
func test_walls_stand_close_to_the_road() -> void:
	var scene := _race()
	await physics_frames(8)
	var track := scene.get_node_or_null("Track") as Track
	var ts := track.get_node_or_null("Trackside") as Trackside if track != null else null
	assert_true(ts != null and ts.layout != null, "the track has a trackside")
	if ts == null or ts.layout == null:
		scene.queue_free()
		return
	assert_true(not ts.layout.is_auto, "jeddah uses its hand-made trackside table")
	for r in ts.runoff:
		assert_true(r["kind"] == "tarmac", "no gravel on a street circuit (%s)" % r["turn"])
	var d := track.data
	var closest := INF
	var close := 0
	var total := 0
	var s := 0.0
	while s < d.length:
		assert_true(ts.layout.is_concrete(s), "concrete wall at s=%.0f" % s)
		for side: float in [-1.0, 1.0]:
			var room := ts.barrier_offset(s, side) - ts.edge_at(s)
			closest = minf(closest, room)
			total += 1
			if room < 4.0:
				close += 1
		s += 10.0
	assert_true(closest >= 1.95, "a wall stands %.2f m from the road edge: too close" % closest)
	assert_true(close > total * 0.85, "walls within 4 m of the road on %d of %d samples" % [close, total])
	scene.queue_free()

## One autopilot lap from the grid: never off the road (so never in a wall), no respawn.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap with --fixed-fps 240 --disable-vsync)")
		return
	Bootstrap.autodrive = true
	var scene := _race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var data := (scene.get_node("Track") as Track).data
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	if pilot == null:
		Bootstrap.autodrive = false
		return
	var waited := 0
	while car.linear_velocity.length() < 1.0 and waited < 240 * 12:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 12, "car never started moving")
	var respawns := [0]
	car.respawned.connect(func() -> void: respawns[0] += 1)
	var time := 0.0
	var worst_edge := INF
	var worst_s := 0.0
	var s := data.closest_s(car.global_position)
	while time < 220.0 and pilot.laps_completed < 1:
		await physics_frames(1)
		time += TICK
		s = data.closest_s(car.global_position, s)
		var edge := data.width_at(s) * 0.5 - absf(data.lateral_offset(car.global_position, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_s = s
	assert_true(pilot.laps_completed >= 1, "lap not completed in 220 s of physics (at s=%.0f)" % s)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_s])
	assert_true(respawns[0] == 0, "car was respawned %d time(s)" % respawns[0])
	assert_between(pilot.lap_time, 85.0, 125.0, "lap time (s)")
	assert_true(pilot.max_speed_kmh > 300.0, "top speed %.0f km/h, expected > 300" % pilot.max_speed_kmh)
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nJEDDAH LAP (from the grid)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f\n" % [
			pilot.lap_time, pilot.max_speed_kmh, worst_edge, worst_s])
	Bootstrap.autodrive = false
	scene.queue_free()
