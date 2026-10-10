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
	var lo_s := 0.0
	var hi_s := 0.0
	for i in d.points.size():
		var y := d.points[i].y
		if y < lo:
			lo = y
			lo_s = i * d.step
		if y > hi:
			hi = y
			hi_s = i * d.step
	# "The high point at Turn 2 is just 7.4 m higher than the low of the long back straight"
	# (formula1.com). The DEM predates the circuit, so the recipe pins the profile with height
	# keys: before them the built lap spanned 3.2 m and had the snail at its lowest point.
	assert_between(hi - lo, 7.2, 7.6, "elevation range (m), 7.4 m in reality")
	var t1 := float(d.turns[0]["s_apex"])
	var t2 := float(d.turns[1]["s_apex"])
	assert_true(hi_s > t1 and hi_s < t2 + 5.0, "highest point in the turn 1-2 spiral (s=%.0f)" % hi_s)
	assert_true(lo_s > float(d.turns[12]["s_apex"]) + 200.0 and lo_s < float(d.turns[13]["s_apex"]) - 100.0,
			"lowest point on the back straight (s=%.0f)" % lo_s)
	# "Maximum uphill slope: 3 %. Maximum downhill slope: 8 %" (FIA media kit 2026, tilke.de):
	# the climb into turn 1 and the fall from turn 2 to the turn 3 hairpin.
	var steepest_up := 0.0
	var steepest_down := 0.0
	var down_s := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		var grade := (b.y - a.y) / maxf(Vector2(b.x - a.x, b.z - a.z).length(), 0.01)
		steepest_up = maxf(steepest_up, grade)
		if -grade > steepest_down:
			steepest_down = -grade
			down_s = i * d.step
	assert_between(steepest_up * 100.0, 2.6, 3.3, "steepest climb (%), 3 % in reality")
	assert_between(steepest_down * 100.0, 7.4, 8.4, "steepest descent (%), 8 % in reality")
	assert_true(down_s > t2 - 30.0 and down_s < float(d.turns[2]["s_apex"]), "the 8 %% fall is between turns 2 and 3 (s=%.0f)" % down_s)

## "Track width: 13-15 m" (tilke.de); per section measured on Esri World Imagery, see the recipe.
func test_widths_follow_the_real_sections() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		return
	var narrowest := INF
	var widest := 0.0
	for i in d.points.size():
		var w := d.width_at(i * d.step)
		narrowest = minf(narrowest, w)
		widest = maxf(widest, w)
	assert_between(narrowest, 13.0, 13.6, "narrowest stretch (m): the esses of turns 4-5 and 7-8")
	assert_between(widest, 17.5, 18.5, "widest point (m): the turn 14 hairpin")
	assert_between(d.width_at(d.start_s), 14.9, 15.1, "grid width (m)")
	assert_between(d.width_at(4200.0), 14.9, 15.1, "back straight width (m)")
	assert_between(d.width_at(2900.0), 13.9, 14.1, "width between turns 10 and 11 (m)")
	assert_between(d.width_at(float(d.turns[5]["s_apex"])), 15.5, 16.1, "turn 6 hairpin apex width (m)")
	assert_between(d.width_at(float(d.turns[13]["s_apex"])), 17.3, 18.1, "turn 14 hairpin apex width (m)")

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
	# The turn 14 hairpin is built on the middle of its 18 m of tarmac (12 m), not on the
	# inside kerb as the map draws it (10 m).
	assert_between(float(d.turns[13]["min_radius"]), 11.0, 14.0, "turn 14 radius (m)")
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
		# A plain, with the man-made mound of turns 1-2 (5.9 m above the finish line) on it.
		assert_true(hi - lo < 14.0, "terrain around the circuit spans %.1f m: it is a plain" % (hi - lo))
	# The surroundings: the hand-made trackside table, the look and the three landmark models
	# (wings and main grandstand roof, the lotus canopies of stands H and K).
	var layout := TracksideLayout.for_track(ID, track.data)
	assert_true(not layout.is_auto and layout.kerbs.size() >= 30 and layout.runoff.size() >= 12,
			"hand-made trackside table: %d kerbs, %d run-offs" % [layout.kerbs.size(), layout.runoff.size()])
	assert_true(layout.is_concrete(100.0) and layout.is_concrete(4812.0) and not layout.is_concrete(2000.0),
			"walls on the pit straight and at the hairpin, armco elsewhere")
	assert_true(track.environment != null and track.environment.active and track.environment.time == "day",
			"environment.json: an afternoon race")
	assert_true(track.scenery != null and track.scenery.landmark_count == 3,
			"landmarks: %d" % (track.scenery.landmark_count if track.scenery != null else -1))
	if track.scenery != null and track.scenery.landmark_count == 3:
		# The wings span the road 30 m up: nothing of them may stand on it.
		var complex := track.scenery.get_node("Landmarks").get_child(0) as Node3D
		assert_true(absf(track.data.lateral_offset(complex.global_position)) < 1.0, "main complex anchored on the finish line")
		var road_y := track.data.position_at(0.0).y
		var nearest_low := INF
		for mi in Scenery.mesh_instances(complex):
			for v: Vector3 in mi.mesh.get_faces():
				var w := mi.global_transform * v
				if w.y - road_y < 7.0:   # everything a car could reach: towers, columns, gantry posts
					nearest_low = minf(nearest_low, absf(track.data.lateral_offset(w)))
		# The gantry posts stand 12.5 m from the centreline of a road 15 m wide.
		assert_true(nearest_low > 11.0, "nearest low landmark face: %.1f m from the centreline" % nearest_low)
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
