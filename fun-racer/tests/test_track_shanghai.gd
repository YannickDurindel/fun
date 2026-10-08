extends TestCase
## Shanghai International Circuit: the built track data against the real circuit, and the
## race scene on it. `--full-lap` adds one autopilot lap (fast with --fixed-fps 240):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_shanghai --full-lap

const ID := "shanghai"
const PATH := "res://assets/tracks/shanghai/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5451.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_catalog_lists_it_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "shanghai must be a playable track")
	if info != null:
		assert_true(info.country_code == "CN" and info.turns == 16, "catalog entry: CN, 16 turns")

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
	# Reclaimed marshland: about 7 m in reality. The DEM predates the circuit, so the built
	# profile is only "nearly flat": no hill may come out of its noise.
	assert_between(hi - lo, 0.5, 10.0, "elevation range (m)")
	var worst_grade := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		worst_grade = maxf(worst_grade, absf(b.y - a.y) / maxf(Vector2(b.x - a.x, b.z - a.z).length(), 0.01))
	assert_true(worst_grade < 0.02, "steepest grade %.1f %%: a flat circuit" % (worst_grade * 100.0))

func test_turns_follow_the_official_numbering() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		return
	assert_true(d.turns.size() == 16, "expected 16 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# Clockwise: 9 right-handers, 7 left-handers.
	var dirs := ""
	for t in d.turns:
		dirs += "R" if String(t["direction"]) == "right" else "L"
	assert_true(dirs == "RRLLRRLRLLLRRRRL", "turn directions %s" % dirs)
	if d.turns.size() != 16:
		return
	# The two snails tighten: turn 2 is tighter than turn 1, and turns 12-13 open out again.
	assert_true(float(d.turns[1]["min_radius"]) < float(d.turns[0]["min_radius"]), "turn 2 tighter than turn 1")
	assert_true(float(d.turns[11]["min_radius"]) < float(d.turns[12]["min_radius"]), "turn 13 opens out of turn 12")
	# The back straight: more than 1.1 km between the apexes of turns 13 and 14.
	assert_true(float(d.turns[13]["s_apex"]) - float(d.turns[12]["s_apex"]) > 1100.0, "back straight T13 -> T14")
	# The grid is 190 m after the timing line, both on the pit straight (after T16, before T1).
	assert_between(d.start_s, 189.0, 191.0, "start line (m after the finish line)")
	assert_true(float(d.turns[0]["s_apex"]) > d.start_s + 250.0, "run from the grid to turn 1")
	assert_true(float(d.turns[15]["s_apex"]) < d.length - 200.0, "finish line well after turn 16")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		return
	for s: float in [0.0, 190.0, 814.7, 3300.0, 4812.0, 5440.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node("Track") as Track
	assert_true(track != null and track.track_id == ID and track.data != null, "race scene built the Shanghai track")
	if track == null or track.data == null:
		scene.queue_free()
		return
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	# The baked terrain is used (not the fallback ground) and stays a plain.
	var terrain := track.get_node("Terrain") as Terrain
	assert_true(terrain != null and not terrain.is_fallback, "baked terrain loaded")
	if terrain != null:
		var lo := INF
		var hi := -INF
		for h in terrain.near_h:
			lo = minf(lo, h)
			hi = maxf(hi, h)
		assert_true(hi - lo < 12.0, "terrain around the circuit spans %.1f m: it is a plain" % (hi - lo))
	scene.queue_free()

## One standing lap by the autopilot: never off the road, never into a wall.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	Bootstrap.autodrive = true
	var scene := _race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var d := (scene.get_node("Track") as Track).data
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	if pilot == null:
		Bootstrap.autodrive = false
		scene.queue_free()
		return
	var waited := 0
	while car.linear_velocity.length() < 1.0 and waited < 240 * 12:
		await physics_frames(1)
		waited += 1
	var time := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var top := 0.0
	var top_s := 0.0
	var worst_stop := 0.0   # biggest speed lost in one tick (m/s): a wall hit shows as a step
	var prev_speed := car.linear_velocity.length()
	var s := d.closest_s(car.global_position)
	while time < 240.0 and pilot.laps_completed < 1:
		await physics_frames(1)
		time += TICK
		s = d.closest_s(car.global_position, s)
		var edge := d.width_at(s) * 0.5 - absf(d.lateral_offset(car.global_position, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		var speed := car.linear_velocity.length()
		if speed > top:
			top = speed
			top_s = s
		worst_stop = maxf(worst_stop, prev_speed - speed)
		prev_speed = speed
	assert_true(pilot.laps_completed >= 1, "lap not completed in 240 s of physics (car at s=%.0f)" % s)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	assert_true(worst_stop < 2.0, "speed dropped %.1f m/s in one tick: the car hit something" % worst_stop)
	assert_between(pilot.lap_time, 80.0, 130.0, "lap time (s)")
	assert_true(top * 3.6 > 280.0, "top speed %.0f km/h, expected > 280 on the back straight" % (top * 3.6))
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nSHANGHAI LAP 1 (standing start)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h at s=%.0f, min edge margin %.2f m at s=%.0f\n" % [
			pilot.lap_time, top * 3.6, top_s, worst_edge, worst_edge_s])
	Bootstrap.autodrive = false
	scene.queue_free()
