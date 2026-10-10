extends TestCase
## Circuit de Spa-Francorchamps (assets/tracks/spa, built by tools/track/build_track.py spa):
## the data against the real circuit, the track in the catalog, the race scene on the grid, and
## (with `--full-lap`, see tools/lap_demo.sh spa) an autopilot lap that stays on the road.

const ID := "spa"
const PATH := "res://assets/tracks/spa/track.json"
const RACE := "res://scenes/race.tscn"
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
	assert_between(d.length, 7004.0 - 70.0, 7004.0 + 70.0, "lap length (m)")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	var lo := INF
	var hi := -INF
	var area := 0.0   # shoelace in (east, north): negative = clockwise
	for i in d.points.size():
		var p := d.points[i]
		var q := d.points[(i + 1) % d.points.size()]
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
		area += p.x * -q.z - q.x * -p.z
	assert_true(area < 0.0, "Spa runs clockwise")
	# Published: 102 m between Stavelot and Les Combes. The road is pinned to the Walloon
	# LiDAR ground model (see the recipe), which gives 102.2 m.
	assert_between(hi - lo, 100.0, 104.5, "elevation range (m)")
	assert_true(d.turns.size() == 19, "expected 19 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	for want: Array in [["T1", "La Source", "right"], ["T2", "Eau Rouge", "left"], ["T3", "Raidillon", "right"],
			["T5", "Les Combes", "right"], ["T10", "Pouhon", "left"], ["T16", "Blanchimont", "left"],
			["T18", "Bus Stop", "right"]]:
		var t := _turn(d, want[0])
		assert_true(t.get("name", "") == want[1] and t.get("direction", "") == want[2],
				"%s must be %s (%s), is %s (%s)" % [want[0], want[1], want[2], t.get("name"), t.get("direction")])
	# La Source is a hairpin a short run after the line, at the north-west end of the lap.
	var source := _turn(d, "T1")
	assert_between(float(source["s_apex"]), 150.0, 400.0, "La Source apex (m after the line)")
	assert_true(float(source["min_radius"]) < 25.0, "La Source is a hairpin")
	var north := INF
	for p in d.points:
		north = minf(north, p.z)
	assert_true(d.position_at(float(source["s_apex"])).z < north + 40.0, "La Source is the northern tip")
	# The lap's high point is at Les Combes / Malmedy and its low point at Stavelot.
	var top := d.position_at(float(_turn(d, "T7")["s_apex"])).y
	var bottom := d.position_at(float(_turn(d, "T15")["s_apex"])).y
	assert_true(top > hi - 6.0, "Malmedy near the top of the lap (y=%.1f, max %.1f)" % [top, hi])
	assert_true(bottom < lo + 6.0, "Stavelot near the bottom of the lap (y=%.1f, min %.1f)" % [bottom, lo])
	# Eau Rouge is a dip; Raidillon climbs out of it: 28 m in 330 m and 15.4 % at its steepest
	# on the centreline of the LiDAR model (the terrain tiles, smoothed over 45 m, gave 12.8 %).
	var eau_rouge := float(_turn(d, "T2")["s_apex"])
	var dip := d.position_at(eau_rouge).y
	assert_true(dip < d.position_at(eau_rouge - 200.0).y - 8.0, "the run down to Eau Rouge descends")
	assert_between(d.position_at(eau_rouge + 330.0).y - dip, 26.0, 30.0, "Raidillon climb over 330 m (m)")
	var steepest := 0.0
	var s := eau_rouge
	while s < eau_rouge + 330.0:
		steepest = maxf(steepest, d.grade_at(s))
		s += d.step
	assert_between(steepest, 0.145, 0.165, "steepest gradient on Raidillon")
	# Nowhere else is the lap steeper than 9 %: the terrain tiles read the tree tops and put a
	# 17 % drop at Speaker's Corner, which is a steady 7 % in reality.
	var drop := 0.0
	var climb := 0.0
	for i in d.points.size():
		var at := i * d.step
		drop = minf(drop, d.grade_at(at))
		if at < eau_rouge or at > eau_rouge + 330.0:
			climb = maxf(climb, d.grade_at(at))
	assert_between(drop, -0.09, -0.07, "steepest descent of the lap (Pouhon)")
	assert_true(climb < 0.09, "no climb but Raidillon above 9 %% (%.3f)" % climb)
	# La Source is 7 m above the line and the foot of Eau Rouge 27 m below it.
	assert_between(d.position_at(float(source["s_apex"])).y, 6.0, 8.5, "La Source above the line (m)")
	assert_between(dip, -28.0, -26.0, "Eau Rouge below the line (m)")

func test_widths_match_real_circuit() -> void:
	# Measured on the 2023 orthophoto of the Service public de Wallonie (see the recipe): Spa is
	# 9.3 to 10 m wide for most of the lap, not the 13 m default.
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	assert_between(d.width_at(0.0), 14.2, 15.2, "Formula 1 start straight (m)")
	assert_between(d.width_at(6900.0), 14.2, 15.2, "grid (m)")
	assert_between(d.width_at(float(_turn(d, "T1")["s_apex"])), 16.0, 18.5, "La Source (m)")
	assert_between(d.width_at(800.0), 9.0, 10.0, "descent to Eau Rouge (m)")
	assert_between(d.width_at(1187.0), 8.7, 9.4, "Raidillon crest (m)")
	assert_between(d.width_at(1850.0), 10.2, 11.0, "Kemmel straight (m)")
	assert_between(d.width_at(float(_turn(d, "T10")["s_apex"])), 9.0, 10.0, "Pouhon (m)")
	assert_between(d.width_at(float(_turn(d, "T16")["s_apex"])), 9.7, 10.6, "Blanchimont (m)")
	assert_between(d.width_at(6500.0), 11.0, 12.0, "approach to the chicane (m)")
	var narrowest := INF
	var total := 0.0
	for w in d.widths:
		narrowest = minf(narrowest, w)
		total += w
	assert_between(narrowest, 8.4, 9.0, "narrowest point, Fagnes (m)")
	assert_between(total / d.widths.size(), 9.8, 10.8, "mean width (m)")

func test_landmarks_exist() -> void:
	# Every model landmarks.json places is in the folder (tools/track/landmarks/spa.py).
	var dir := PATH.get_base_dir()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("landmarks.json")))
	assert_true(parsed is Array and (parsed as Array).size() >= 17, "landmarks.json lists the landmarks")
	if not parsed is Array:
		return
	var models := {}
	for e: Dictionary in parsed:
		models[str(e["model"])] = true
		assert_true(ResourceLoader.exists(dir.path_join("landmarks/%s.glb" % e["model"])), "landmark model %s" % e["model"])
		assert_between(float(e["at"]["s"]), 0.0, 7004.0, "landmark %s is placed on the lap" % e["model"])
	for want: String in ["start_gantry", "pit_lane_f1", "stand_f1", "stand_raidillon", "stand_speakers", "signal_gantry_1"]:
		assert_true(models.has(want), "landmark %s is placed" % want)
	assert_true(TracksideLayout.has_table(ID), "Spa has a hand-made trackside table")

func test_listed_as_playable() -> void:
	TrackCatalog.reload()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "Spa is listed as playable")
	if info == null:
		return
	assert_true(info.name == "Circuit de Spa-Francorchamps" and info.turns == 19, "catalog entry: %s, %d turns" % [info.name, info.turns])
	assert_true(info.track_json == PATH and ResourceLoader.exists(info.scene), "catalog paths")
	var found := false
	for t in TrackCatalog.playable():
		found = found or t.id == ID
	assert_true(found, "Spa is in the playable list")

## The race scene on Spa, built the way the menu does it (Game.config is restored by _end).
var _saved_config: RaceConfig

func _begin() -> Node:
	_saved_config = Game.config
	Game.config = _saved_config.copy()
	Bootstrap.autodrive = true
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func _end(scene: Node) -> void:
	Bootstrap.autodrive = false
	scene.queue_free()
	Game.config = _saved_config

func _built(ts: Trackside) -> void:
	var frames := 0
	while ts != null and not ts.is_built and frames < 2400:
		await get_tree().physics_frame
		frames += 1
	assert_true(ts != null and ts.is_built, "Trackside finished building")

func test_race_scene_spawns_car_on_the_grid() -> void:
	var scene := _begin()
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID and track.data != null, "race scene built Spa")
	if track == null or track.data == null:
		_end(scene)
		return
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	var terrain := track.get_node("Terrain") as Terrain
	var ts := track.get_node("Trackside") as Trackside
	assert_true(not road.is_runtime_mesh, "road comes from road_mesh.glb")
	assert_true(not terrain.is_fallback, "terrain is the baked one")
	await _built(ts)
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var s := d.closest_s(car.global_position)
	assert_true(absf(d.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(d.delta_s(d.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	assert_between(car.global_position.y - d.position_at(s).y, 0.2, 0.6, "car resting on road surface")
	# Barriers all round: never on the road, and a wall within 60 m on both sides.
	var space := track.get_world_3d().direct_space_state
	var misses: Array[String] = []
	var worst_gap := INF
	var at := 0.0
	while at < d.length:
		var xf := ts.frame_at(at)
		var rh := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized()
		for side: float in [-1.0, 1.0]:
			worst_gap = minf(worst_gap, ts.barrier_offset(at, side) - ts.edge_at(at))
			var hit := {}
			var from := xf.origin
			for h: float in [0.5, 0.25, 0.0, -0.25]:
				from = xf.origin + Vector3.UP * h
				hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(
						from, from + rh * side * 60.0, Trackside.LAYER_BARRIER))
				if not hit.is_empty():
					break
			if hit.is_empty():
				misses.append("%.0f%s" % [at, "R" if side > 0.0 else "L"])
			elif (hit["position"] - from).length() < ts.edge_at(at) + 1.5:
				assert_true(false, "wall on the road at s=%.0f (%.1f m from the centreline)" % [
						at, (hit["position"] - from).length()])
		at += 20.0
	assert_true(worst_gap >= 1.5, "barrier %.2f m from the road edge" % worst_gap)
	assert_true(misses.is_empty(), "no wall within 60 m at: %s" % ", ".join(misses))
	_end(scene)

## Two autopilot laps (standing, then flying). Only with --full-lap: about 5 minutes of physics.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap, see tools/lap_demo.sh spa)")
		return
	var scene := _begin()
	var track := scene.get_node("Track") as Track
	var d := track.data
	var ts := track.get_node("Trackside") as Trackside
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	await _built(ts)
	var worst_edge := INF
	var worst_edge_s := 0.0
	var worst_wall := INF
	var worst_wall_s := 0.0
	var time := 0.0
	var s := d.closest_s(car.global_position)
	var standing := -1.0
	var speeds := {}   # probe name -> [min km/h, max km/h] in a window of the flying lap
	var probes := {"Eau Rouge - Raidillon": [900.0, 1200.0], "Pouhon": [3650.0, 4050.0], "Blanchimont": [5650.0, 6200.0]}
	while time < 420.0 and pilot != null and pilot.laps_completed < 2:
		await get_tree().physics_frame
		time += TICK
		var pos := car.global_position
		s = d.closest_s(pos, s)
		var off := d.lateral_offset(pos, s)
		var edge := d.width_at(s) * 0.5 - absf(off)
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		var wall := ts.barrier_offset(s, signf(off)) - absf(off)
		if wall < worst_wall:
			worst_wall = wall
			worst_wall_s = s
		if pilot.laps_completed == 1:
			if standing < 0.0:
				standing = pilot.lap_time
				print("\nLAP 1 (from the grid, timed start line to start line)\n" + pilot.report())
			var kmh := car.linear_velocity.length() * 3.6
			for key: String in probes:
				if s >= probes[key][0] and s <= probes[key][1]:
					var mm: Array = speeds.get(key, [INF, 0.0])
					speeds[key] = [minf(mm[0], kmh), maxf(mm[1], kmh)]
	assert_true(pilot != null and pilot.laps_completed >= 2, "two laps not completed in %.0f s of physics" % time)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	assert_true(worst_wall > 1.0, "car within %.2f m of a wall at s=%.0f" % [worst_wall, worst_wall_s])
	if pilot != null and pilot.laps_completed >= 2:
		# The Formula 1 lap record is 1:41.3; this car is slower in the fast corners.
		assert_between(pilot.lap_time, 95.0, 150.0, "flying lap time (s)")
		assert_true(pilot.lap_time < standing + 0.5, "flying lap (%.2f s) not slower than the standing one (%.2f s)" % [pilot.lap_time, standing])
		for st in pilot.last_lap_turn_stats:
			assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
		print("\nLAP 2 (flying)\n" + pilot.report())
		for key: String in speeds:
			print("       %-22s min %3.0f km/h, max %3.0f km/h" % [key, speeds[key][0], speeds[key][1]])
	print("       min edge margin %.2f m at s=%.0f, min wall clearance %.2f m at s=%.0f\n" % [
			worst_edge, worst_edge_s, worst_wall, worst_wall_s])
	_end(scene)
