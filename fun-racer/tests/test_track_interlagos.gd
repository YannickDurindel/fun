extends TestCase
## Interlagos (Autódromo José Carlos Pace): centreline data, catalogue entry and the race scene.
## The full autopilot lap runs with `--full-lap` (use --fixed-fps 240 --disable-vsync):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_interlagos --full-lap

const ID := "interlagos"
const PATH := "res://assets/tracks/interlagos/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 4309.0
const TICK := 1.0 / 240.0

func _turn(d: TrackData, id: String) -> Dictionary:
	for t in d.turns:
		if t["id"] == id:
			return t
	return {}

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
	# Published: 43 m between the highest and the lowest point (formula1.com, 2016). Built
	# 42.5 m once the start straight climbs steadily (the terrain model had 42.9 m with a
	# hump and two dips beside the stands).
	assert_between(hi - lo, 40.0, 45.0, "elevation range (m)")
	assert_true(d.turns.size() == 15, "expected 15 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# Anticlockwise: the lefts outnumber the rights, and the lap starts with left - right - left.
	var lefts := 0
	for t in d.turns:
		lefts += 1 if String(t["direction"]) == "left" else 0
	assert_true(lefts == 10, "10 left-handers, got %d" % lefts)
	assert_true(d.turns[0]["direction"] == "left" and d.turns[1]["direction"] == "right"
			and d.turns[2]["direction"] == "left", "Senna S and Curva do Sol: left, right, left")
	assert_true(d.turns[0]["name"] == "S do Senna" and d.turns[2]["name"] == "Curva do Sol", "T1 / T3 names")
	assert_true(d.turns[9]["name"] == "Bico de Pato" and d.turns[11]["name"] == "Junção", "T10 / T12 names")
	# The grid stands 60 m after the timing line.
	assert_between(d.start_s, 50.0, 70.0, "start line after the finish line (m)")
	# Downhill from the grid through the Senna S to the lake, then the climb from Junção.
	var grid_y := d.position_at(d.start_s).y
	var lake_y := d.position_at(float(_turn(d, "T5")["s_apex"])).y
	var juncao_y := d.position_at(float(_turn(d, "T12")["s_apex"])).y
	assert_true(d.position_at(float(_turn(d, "T3")["s_apex"])).y < grid_y - 5.0, "Senna S runs downhill")
	assert_true(lake_y < lo + 3.0, "Descida do Lago is the low point (y=%.1f, min %.1f)" % [lake_y, lo])
	assert_true(grid_y > hi - 5.0, "the grid is near the top (y=%.1f, max %.1f)" % [grid_y, hi])
	assert_between(d.position_at(0.0).y - juncao_y, 25.0, 40.0, "climb from Junção to the line (m)")

## Widths measured on the aerial picture (the recipe gives the method): a narrow circuit, 14 m
## on the grid, 10 to 11 m on the Reta Oposta and into Junção. The build used to have the
## default 13 m everywhere and 15 m on the grid.
func test_widths_are_the_measured_ones() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	var lo := INF
	var hi := -INF
	for i in d.points.size():
		var w := d.width_at(i * d.step)
		lo = minf(lo, w)
		hi = maxf(hi, w)
	assert_between(lo, 9.9, 10.1, "narrowest point: the run to Junção (m)")
	assert_between(hi, 13.9, 14.1, "widest point: the grid (m)")
	assert_between(d.width_at(d.start_s), 13.9, 14.1, "grid (m)")
	assert_between(d.width_at(1100.0), 10.9, 11.1, "Reta Oposta (m)")
	assert_between(d.width_at(float(_turn(d, "T3")["s_apex"]) + 30.0), 13.4, 13.6, "Curva do Sol (m)")
	assert_between(d.width_at(float(_turn(d, "T1")["s_apex"])), 12.4, 12.6, "Senna S (m)")
	assert_between(d.width_at(3900.0), 13.4, 13.6, "Subida dos Boxes (m)")

## Curva do Sol and the Subida dos Boxes / Arquibancadas are banked to the left over their whole
## length (at the road step's limit of 0.03 rad; the real banking is steeper), and the road
## climbs without a dip from the foot of the Subida dos Boxes to the crest before the Senna S.
func test_banking_and_the_climb_to_the_line() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	# The built cross-section is in road_profile.json (track.json carries no bank).
	var profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
			PATH.get_base_dir().path_join("road_profile.json")))
	var bank: Array = profile["bank"]
	var step := float(profile["step"])
	for s: float in [600.0, 680.0, 3700.0, 3900.0, 4080.0]:
		# Negative = right-hand edge higher: banked into a left-hander.
		assert_between(float(bank[roundi(s / step)]), -0.0301, -0.029, "bank at s=%.0f (rad)" % s)
	var s := 3460.0
	var last := d.position_at(s).y
	var dips := 0.0
	while s < d.length + 270.0:
		s += 10.0
		var y := d.position_at(d.wrap_s(s)).y
		dips = maxf(dips, last - y)
		last = y
	assert_true(dips < 0.05, "the climb from Café to the crest never goes down (worst %.2f m)" % dips)
	# Steepest part: about 10 % on the Subida dos Boxes ramp after Café.
	var steepest := 0.0
	for k in 20:
		steepest = maxf(steepest, d.grade_at(3440.0 + k * 10.0))
	assert_between(steepest, 0.085, 0.105, "steepest gradient of the final climb")

## The hand-made trackside table is in use: tarmac run-off only, walls close to the road.
func test_trackside_table() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	var layout := TracksideLayout.for_track(ID, d)
	assert_true(not layout.is_auto, "interlagos has its own trackside table")
	assert_true(layout.barrier_straight <= 6.0, "walls stand close to the road")
	for r in layout.runoff:
		assert_true(r["kind"] == "tarmac", "no gravel at Interlagos (%s)" % r["turn"])
	assert_true(layout.is_concrete(0.0) and layout.is_concrete(4000.0) and layout.is_concrete(1000.0),
			"wall and fence in front of the pits, the terraces and sector G")
	assert_true(not layout.is_concrete(2500.0), "armco in the infield")
	for k in layout.kerbs:
		assert_true(k["len"] > 0.0, "kerb with a length (%s)" % k["turn"])

## Landmarks: every model named in landmarks.json exists, and the run-off paint is laid on
## the terrain node it was generated for (tools/track/landmarks/interlagos.py).
func test_landmark_files() -> void:
	var dir := PATH.get_base_dir()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("landmarks.json")))
	assert_true(parsed is Array and (parsed as Array).size() == 3, "three landmark entries")
	if not parsed is Array:
		return
	var names: Array[String] = []
	for e: Dictionary in parsed:
		names.append(String(e["model"]))
		assert_true(FileAccess.file_exists(dir.path_join("landmarks/%s.glb" % e["model"])), "model %s" % e["model"])
	assert_true("runoff_paint" in names and "start_gantry" in names and "pit_roof" in names, "models: %s" % [names])
	assert_true(FileAccess.file_exists(dir.path_join("environment.json")), "environment.json")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 387.9, 1453.7, 2809.3, 3295.2, 4300.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

func test_catalog_lists_it_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "interlagos is listed as playable")
	if info != null:
		assert_true(info.track_json == PATH, "track_json: %s" % info.track_json)
		assert_true(info.turns == 15 and info.country_code == "BR", "info fields")
		assert_true(ResourceLoader.exists(info.scene), "scene exists: %s" % info.scene)

func _race() -> Node:
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_race_scene_spawns_car_on_track() -> void:
	var saved := Game.config   # the race scene points Game.config at its track
	Game.config = saved.copy()
	var scene := _race()
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID and track.data != null, "race scene built Interlagos")
	if track != null and track.data != null:
		await physics_frames(240)
		var car := scene.get_node("Car") as Car
		var d := track.data
		var road := track.get_node("Road") as RoadSurface
		assert_true(road != null and not road.is_runtime_mesh, "road comes from road_mesh.glb")
		assert_true(not (track.get_node("Terrain") as Terrain).is_fallback, "terrain is the baked one")
		var s := d.closest_s(car.global_position)
		# The whole car (about 2 m wide) on the 14 m grid.
		assert_true(absf(d.lateral_offset(car.global_position)) < d.width_at(d.start_s) * 0.5 - 1.0,
				"car on the road after spawn")
		var scenery := track.get_node_or_null("Scenery") as Scenery
		assert_true(scenery != null and scenery.landmark_count == 3, "three landmarks placed")
		var terrain := track.get_node("Terrain") as Terrain
		for e: Dictionary in JSON.parse_string(FileAccess.get_file_as_string(PATH.get_base_dir().path_join("landmarks.json"))):
			if String(e["model"]) == "runoff_paint":
				# The paint is in track coordinates: its node must end up at y = 0.
				var at: Array = e["at"]["xz"]
				assert_between(terrain.height_at(float(at[0]), float(at[1])) + float(e["y_offset"]), -0.005, 0.005,
						"run-off paint sits at track height (regenerate the landmarks after a terrain rebuild)")
		assert_true(absf(d.delta_s(d.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
		assert_between(car.global_position.y - d.position_at(s).y, 0.2, 0.6, "car resting on road surface")
	scene.queue_free()
	Game.config = saved

## One standing lap by the autopilot: never off the road (the walls stand at least 1.5 m
## beyond the road edge, so that also means no wall contact), no drifting on straights.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	var saved := Game.config
	Game.config = saved.copy()
	Bootstrap.autodrive = true
	var scene := _race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var d := (scene.get_node("Track") as Track).data
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
	var hard_stops := 0
	var prev_speed := car.linear_velocity.length()
	while time < 200.0 and pilot.laps_completed < 1:
		await physics_frames(1)
		time += TICK
		var ns := d.closest_s(car.global_position, s)
		progress += d.delta_s(s, ns)
		s = ns
		var edge := d.width_at(s) * 0.5 - absf(d.lateral_offset(car.global_position, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_s = s
		var speed := car.linear_velocity.length()
		top = maxf(top, speed)
		# Brakes give about 0.1 m/s per tick; a wall takes far more at once.
		if prev_speed - speed > 2.0:
			hard_stops += 1
		prev_speed = speed
	assert_true(pilot.laps_completed >= 1, "lap not completed in 200 s (progress %.0f m)" % progress)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_s])
	assert_true(hard_stops == 0, "%d sudden stops (wall contact?)" % hard_stops)
	assert_true(pilot.straight_drift_ticks == 0, "drifted on a straight for %d ticks" % pilot.straight_drift_ticks)
	assert_between(pilot.lap_time, 60.0, 110.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nINTERLAGOS LAP 1 (from the grid, timing line to timing line)\n" + pilot.report())
	print("       test clock: %.0f m in %.2f s, top speed %.0f km/h, min edge %.2f m at s=%.0f\n" % [
			progress, time, top * 3.6, worst_edge, worst_s])
	Bootstrap.autodrive = false
	scene.queue_free()
	Game.config = saved
