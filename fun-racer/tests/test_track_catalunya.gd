extends TestCase
## Circuit de Barcelona-Catalunya (assets/tracks/catalunya): the built data against the real
## circuit, and the race scene on it. The Grand Prix layout since 2023: 4657 m, 14 turns,
## clockwise, no chicane before the last corner.
## The full autopilot lap runs only with `--full-lap` (use --fixed-fps 240 --disable-vsync):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_catalunya --full-lap

const ID := "catalunya"
const PATH := "res://assets/tracks/catalunya/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 4657.0
const TICK := 1.0 / 240.0

var _previous_track: String = ""

func _data() -> TrackData:
	return TrackData.load_track(PATH)

## The race scene on this track. Opening it for a fixed track changes Game.config, so the
## previous id is put back by _restore().
func _race() -> Node:
	_previous_track = Game.config.track_id
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func _restore() -> void:
	Game.config.track_id = _previous_track

func test_catalog_lists_it_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null, "catalunya is in the catalog")
	if info == null:
		return
	assert_true(info.available, "catalunya is playable")
	assert_true(info.name == "Circuit de Barcelona-Catalunya", "name is '%s'" % info.name)
	assert_true(ResourceLoader.exists(info.scene), "track scene exists (%s)" % info.scene)

func test_dimensions_match_real_circuit() -> void:
	var d := _data()
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
	# Published: about 30 m between the lowest and the highest point; the ICGC lidar model the
	# recipe pins the road to gives 29.7 m.
	assert_between(hi - lo, 27.0, 32.0, "elevation range (m)")
	# Steepest grades on the lidar profile: +6.2 % from turn 8 to Campsa, -6.5 % out of Seat
	# (the 30 m DEM made the Campsa climb 8.5 %).
	var steepest := 0.0
	for g in d.grades:
		steepest = maxf(steepest, absf(g))
	assert_between(steepest * 100.0, 5.0, 7.0, "steepest gradient (%)")
	# Widths measured on the ICGC orthophoto (published: 12 m): 12.5 m on the main straight,
	# 12 m from Elf to Seat, 11.5 m from Wuerth on, 14 m at the apex of La Caixa.
	assert_between(d.width_at(d.start_s), 12.3, 12.7, "grid width (m)")
	assert_between(d.width_at(1400.0), 11.8, 12.2, "width between Renault and Repsol (m)")
	assert_between(d.width_at(3200.0), 11.3, 11.7, "back straight width (m)")
	assert_between(d.width_at(3495.0), 13.5, 14.5, "width at La Caixa (m)")
	assert_true(d.turns.size() == 14, "expected 14 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])

func test_layout_is_the_grand_prix_lap() -> void:
	var d := _data()
	if d == null or d.turns.size() != 14:
		assert_true(false, "track data missing or wrong turn count")
		return
	var dirs := ""
	for t in d.turns:
		dirs += "R" if String(t["direction"]) == "right" else "L"
	assert_true(dirs == "RLRRLLLRRLLRRR", "turn directions are %s, expected RLRRLLLRRLLRRR" % dirs)
	var names := {0: "Elf", 2: "Renault", 3: "Repsol", 4: "Seat", 6: "Würth", 8: "Campsa",
			9: "La Caixa", 11: "Banc Sabadell", 13: "New Holland"}
	for i: int in names:
		assert_true(d.turns[i]["name"] == names[i], "T%d must be %s, is %s" % [i + 1, names[i], d.turns[i]["name"]])
	# Clockwise: the signed area of the plan view (x east, z south) is positive.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area > 0.0, "the lap must run clockwise")
	# The grid is on the pit straight, 126 m after the timing line, and more than 500 m
	# before the first corner.
	assert_between(d.delta_s(0.0, d.start_s), 110.0, 140.0, "start line after the finish line (m)")
	assert_true(float(d.turns[0]["s_apex"]) - d.start_s > 500.0, "long run from the grid to turn 1")
	# No chicane: after Europcar (T13) only one more corner, and it is a fast one.
	var gap := float(d.turns[13]["s_apex"]) - float(d.turns[12]["s_apex"])
	assert_between(gap, 180.0, 320.0, "T13 -> T14 distance (m)")
	assert_true(float(d.turns[13]["min_radius"]) > 55.0,
			"T14 must be the fast right-hander, radius %.0f m" % float(d.turns[13]["min_radius"]))
	# The start/finish straight is the low part of the lap, the run to Banc Sabadell the high one.
	var grid_y := d.position_at(d.start_s).y
	var t12_y := d.position_at(float(d.turns[11]["s_apex"])).y
	assert_true(t12_y - grid_y > 15.0, "Banc Sabadell is %.1f m above the grid, expected > 15" % (t12_y - grid_y))

## The hand-made trackside table (deep gravel traps, walls 6 m from the main straight) and
## the race-day look (June afternoon, sun in the south-west) are the ones used.
func test_trackside_and_environment() -> void:
	var d := _data()
	if d == null:
		assert_true(false, "track data missing")
		return
	var layout := TracksideLayout.for_track(ID, d)
	assert_true(not layout.is_auto, "catalunya uses its trackside table")
	assert_true(layout.is_concrete(100.0) and not layout.is_concrete(2000.0),
			"wall on the main straight, armco at Seat")
	var deepest := 0.0
	for r in layout.runoff:
		if r["turn"] == "T1":
			deepest = maxf(deepest, float(r["u1"]))
	assert_true(deepest >= 40.0, "the Elf gravel trap is %.0f m deep, expected >= 40" % deepest)
	var env := FileAccess.get_file_as_string("res://assets/tracks/catalunya/environment.json")
	var parsed: Variant = JSON.parse_string(env)
	assert_true(parsed is Dictionary, "environment.json parses")
	if parsed is Dictionary:
		var sun: Dictionary = (parsed as Dictionary).get("sun", {})
		assert_between(float(sun.get("azimuth_deg", 0.0)), 200.0, 245.0, "afternoon sun bearing (deg)")
		assert_true((parsed as Dictionary).get("time", "") == "day", "the race is run by day")

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node("Track") as Track
	assert_true(track != null and track.data != null and track.track_id == ID, "the race runs on catalunya")
	if track == null or track.data == null:
		_restore()
		return
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	var road := track.get_node_or_null("Road")
	assert_true(road != null and road.find_children("*", "MeshInstance3D", true, false).size() > 0, "road mesh built")
	_restore()

func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	Bootstrap.autodrive = true
	var scene := _race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	var d := track.data
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	if pilot == null:
		Bootstrap.autodrive = false
		_restore()
		return
	var time := 0.0
	var top := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var worst_wall := INF
	var worst_wall_s := 0.0
	var s := d.closest_s(car.global_position)
	while time < 200.0 and pilot.laps_completed < 1:
		await physics_frames(1)
		time += TICK
		s = d.closest_s(car.global_position, s)
		var off := d.lateral_offset(car.global_position, s)
		var edge := d.width_at(s) * 0.5 - absf(off)
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		if ts != null and ts.is_built:
			var wall := ts.barrier_offset(s, signf(off) if off != 0.0 else 1.0) - absf(off)
			if wall < worst_wall:
				worst_wall = wall
				worst_wall_s = s
		top = maxf(top, car.linear_velocity.length() * 3.6)
	assert_true(pilot.laps_completed >= 1, "lap not completed in 200 s of physics (at s=%.0f)" % s)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	assert_true(worst_wall > 1.0, "car within %.2f m of a wall at s=%.0f" % [worst_wall, worst_wall_s])
	assert_between(pilot.lap_time, 70.0, 110.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nLAP 1 (from the grid, timed start line to start line)\n" + pilot.report())
	print("       lap time %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f, nearest wall %.2f m at s=%.0f\n" % [
			pilot.lap_time, top, worst_edge, worst_edge_s, worst_wall, worst_wall_s])
	Bootstrap.autodrive = false
	_restore()
