extends TestCase
## Circuit of the Americas (assets/tracks/cota): centreline data, the race scene on the grid,
## and (with `--full-lap`) one autopilot lap that must stay on the road:
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_cota --full-lap

const ID := "cota"
const PATH := "res://assets/tracks/cota/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5513.0
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
	# Published: 41 m (133 ft). The DEM build gives about 35 m.
	assert_between(hi - lo, 28.0, 46.0, "elevation range (m)")
	assert_true(d.turns.size() == 20, "expected 20 turns, got %d" % d.turns.size())
	var last := -1.0
	var lefts := 0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
		if String(t["direction"]) == "left":
			lefts += 1
	assert_true(lefts == 11, "anticlockwise lap: 11 left and 9 right turns (lefts: %d)" % lefts)
	assert_true(_signed_area(d) > 0.0, "the lap must run anticlockwise")
	assert_true(d.turns[0]["name"] == "Big Red", "T1 must be Big Red")
	# Turn 1 sits on the crest of the hill: the highest point of the lap, at the end of a climb
	# of more than 20 m from the grid.
	var t1 := float(d.turns[0]["s_apex"])
	var t1_y := d.position_at(t1).y
	assert_true(t1_y > hi - 1.5, "Big Red should be the top of the lap (y=%.1f, max %.1f)" % [t1_y, hi])
	assert_true(t1_y - d.position_at(d.start_s).y > 20.0,
			"climb from the grid to Turn 1 is %.1f m, expected > 20" % (t1_y - d.position_at(d.start_s).y))
	var steepest := 0.0
	var s := d.start_s
	while s < t1 - 40.0:
		steepest = maxf(steepest, (d.position_at(s + 40.0).y - d.position_at(s).y) / 40.0)
		s += 10.0
	assert_between(steepest, 0.09, 0.16, "steepest 40 m of the climb to Turn 1 (grade)")
	# The grid is on the pit straight, about 300 m after the timing line.
	assert_between(d.delta_s(0.0, d.start_s), 250.0, 350.0, "start line after the finish line (m)")

## Area enclosed by the lap seen from above with north up (x = east, z = -north):
## positive = anticlockwise.
func _signed_area(d: TrackData) -> float:
	var area := 0.0
	var n := d.points.size()
	for i in n:
		var a := d.points[i]
		var b := d.points[(i + 1) % n]
		area += a.x * -b.z - b.x * -a.z
	return area * 0.5

func _race() -> Node:
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_race_scene_spawns_car_on_grid() -> void:
	var saved_config := Game.config   # the race scene points Game.config at its track
	Game.config = saved_config.copy()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "the catalog lists cota as playable")
	var scene := _race()
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID and track.data != null, "race scene built the cota track")
	if track != null and track.data != null:
		(track.get_node("Race") as RaceManager).persist_best = false
		await physics_frames(240)
		var car := scene.get_node("Car") as Car
		var d := track.data
		var s := d.closest_s(car.global_position)
		assert_true(absf(d.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
		assert_true(absf(d.delta_s(d.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
		var road_y := d.position_at(s).y
		assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	scene.queue_free()
	Game.config = saved_config

func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap, see the top of this file)")
		return
	var saved_config := Game.config
	Game.config = saved_config.copy()
	Bootstrap.autodrive = true
	var scene := _race()
	var track := scene.get_node_or_null("Track") as Track
	var pilot := scene.get_node_or_null("Autodrive") as Autopilot
	assert_true(track != null and track.data != null and pilot != null, "race scene with the autopilot")
	if track != null and track.data != null and pilot != null:
		(track.get_node("Race") as RaceManager).persist_best = false
		var car := scene.get_node("Car") as Car
		var d := track.data
		var waited := 0
		while car.linear_velocity.length() < 1.0 and waited < 240 * 12:
			await physics_frames(1)
			waited += 1
		assert_true(waited < 240 * 12, "car never started moving")
		var time := 0.0
		var progress := 0.0
		var worst_edge := INF
		var worst_edge_s := 0.0
		var top := 0.0
		var s := d.closest_s(car.global_position)
		# One standing-start lap from the grid, as the autopilot times it.
		while pilot.laps_completed < 1 and time < 240.0:
			await physics_frames(1)
			time += TICK
			var ns := d.closest_s(car.global_position, s)
			progress += d.delta_s(s, ns)
			s = ns
			var edge := d.width_at(s) * 0.5 - absf(d.lateral_offset(car.global_position, s))
			if edge < worst_edge:
				worst_edge = edge
				worst_edge_s = s
			top = maxf(top, car.linear_velocity.length() * 3.6)
		assert_true(pilot.laps_completed >= 1, "lap not completed in 240 s of physics (progress %.0f m)" % progress)
		assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
		assert_between(pilot.lap_time, 85.0, 125.0, "lap time (s)")
		assert_true(top > 280.0, "top speed %.0f km/h, expected > 280" % top)
		for st in pilot.last_lap_turn_stats:
			assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
		print("\nCOTA LAP (standing start from the grid)\n" + pilot.report())
		print("       lap time %.2f s, top speed %.0f km/h; %.0f m in %.2f s, min edge margin %.2f m at s=%.0f\n" % [
				pilot.lap_time, top, progress, time, worst_edge, worst_edge_s])
	Bootstrap.autodrive = false
	scene.queue_free()
	Game.config = saved_config
