extends TestCase
## Circuit Gilles Villeneuve (Montréal): centreline data, catalog entry and the race scene.
## The autopilot lap runs only with `--full-lap` (headless, --fixed-fps 240 --disable-vsync):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_gilles_villeneuve --full-lap

const ID := "gilles_villeneuve"
const PATH := "res://assets/tracks/gilles_villeneuve/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 4361.0
const TICK := 1.0 / 240.0

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
	# A flat island: about 5 m published. More than 8 m would mean a DEM void or a bridge deck.
	assert_between(hi - lo, 1.0, 8.0, "elevation range (m)")
	assert_true(d.turns.size() == 14, "expected 14 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# Senna S: left then right. Hairpin: right. Final chicane: right then left.
	var want := {"T1": "left", "T2": "right", "T10": "right", "T13": "right", "T14": "left"}
	for t in d.turns:
		if want.has(t["id"]):
			assert_true(t["direction"] == want[t["id"]], "%s must turn %s" % [t["id"], want[t["id"]]])
	assert_true(d.turns[9]["name"] == "L'Épingle", "T10 must be L'Épingle, got %s" % d.turns[9]["name"])
	# The hairpin is the northern end of the lap (z = -north) and the Senna curve the southern.
	var north := INF
	var south := -INF
	for p in d.points:
		north = minf(north, p.z)
		south = maxf(south, p.z)
	assert_true(d.position_at(float(d.turns[9]["s_apex"])).z < north + 30.0, "hairpin at the north end")
	assert_true(d.position_at(float(d.turns[1]["s_apex"])).z > south - 80.0, "Senna curve at the south end")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 333.3, 1290.0, 2697.0, 3925.0, 4340.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

func test_catalog_lists_track_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "catalog must list the track as playable")
	if info != null:
		assert_true(info.name == "Circuit Gilles Villeneuve", "name, got %s" % info.name)
		assert_true(ResourceLoader.exists(info.scene), "track scene exists")

func _spawn_race() -> Node:
	var before := Game.config.track_id
	Game.config.track_id = ID
	var scene := spawn(RACE)
	Game.config.track_id = before
	return scene

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _spawn_race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID, "race scene built the Montréal track")
	if track == null:
		return
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	var terrain := track.get_node("Terrain") as Node
	assert_true(not bool(terrain.get("is_fallback")), "baked terrain loaded")

func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	Bootstrap.autodrive = true
	var scene := _spawn_race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	var data := track.data
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	if pilot == null:
		Bootstrap.autodrive = false
		return
	var time := 0.0
	var top := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var worst_wall := INF
	var s := data.closest_s(car.global_position)
	while pilot.laps_completed < 1 and time < 240.0:
		await physics_frames(1)
		time += TICK
		var pos := car.global_position
		s = data.closest_s(pos, s)
		var off := data.lateral_offset(pos, s)
		var edge := data.width_at(s) * 0.5 - absf(off)
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		if ts != null and ts.is_built:
			worst_wall = minf(worst_wall, ts.barrier_offset(s, signf(off) if off != 0.0 else 1.0) - absf(off))
		top = maxf(top, car.linear_velocity.length() * 3.6)
	Bootstrap.autodrive = false
	assert_true(pilot.laps_completed >= 1, "lap not completed in 240 s of physics (at s=%.0f)" % s)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	assert_true(worst_wall > 1.0, "car came within %.2f m of a barrier" % worst_wall)
	assert_between(pilot.lap_time, 60.0, 110.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nLAP 1 (from the grid)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f, min barrier gap %.2f m\n" % [
			pilot.lap_time, top, worst_edge, worst_edge_s, worst_wall])
