extends TestCase
## Baku City Circuit: track data, the race scene on the generic track runtime with the
## street-circuit walls, and (with --full-lap) an autopilot lap.
##
##   tests/run_tests.sh --filter=track_baku
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_baku --full-lap

const ID := "baku"
const PATH := "res://assets/tracks/baku/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 6003.0
## The finish (timing) line lies 104 m before the start line: 51 laps x 6.003 km - 306.049 km.
const START_OFFSET := 104.0
const TICK := 1.0 / 240.0
## Turn 6 -> Turn 7 and the main straight are the two carriageways of Neftchilar Avenue.
const OUTBOUND := [2190.0, 2520.0]
const MAIN_BESIDE_IT := [4700.0, 5100.0]

func _race() -> Node:
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func _built(ts: Trackside) -> void:
	var frames := 0
	while ts != null and not ts.is_built and frames < 900:
		await get_tree().physics_frame
		frames += 1
	assert_true(ts != null and ts.is_built, "Trackside finished building")

func test_catalog_lists_the_track_as_playable() -> void:
	TrackCatalog.reload()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "baku must be a playable track")
	if info == null:
		return
	assert_true(info.name == "Baku City Circuit", "name '%s'" % info.name)
	assert_true(info.country_code == "AZ", "country code '%s'" % info.country_code)

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
	var hi_s := 0.0
	for i in d.points.size():
		var y := d.points[i].y
		lo = minf(lo, y)
		if y > hi:
			hi = y
			hi_s = i * d.step
	# About 27 m is quoted for the lap; the surface model of a city is noisy, so allow some more.
	assert_between(hi - lo, 20.0, 34.0, "elevation range (m)")
	assert_true(d.turns.size() == 20, "expected 20 turns, got %d" % d.turns.size())
	if d.turns.size() != 20:
		return
	var last := -1.0
	var dirs := ""
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
		dirs += "R" if String(t["direction"]) == "right" else "L"
	# Three left-hand right angles, right at 4, the left-right chicane 5-6, right at 7, the
	# castle section 8-12, the long left-handers 13-16, and the bends of the run to the line.
	assert_true(dirs == "LLLRLRRLRLRLLLLLRLRR", "turn directions %s" % dirs)
	assert_true(d.turns[7]["name"] == "Turn 8 (Castle)", "T8 is the castle corner, got %s" % d.turns[7]["name"])
	# Anticlockwise: the signed area of the plan view (x east, z south) is negative.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area < 0.0, "the lap must run anticlockwise")
	# The top of the lap is behind the old city, between Turn 12 and Turn 15, and the castle
	# section is on the way up: well above the seafront, well below the top.
	assert_true(hi_s > float(d.turns[11]["s_apex"]) and hi_s < float(d.turns[14]["s_apex"]),
			"highest point at s=%.0f, expected between Turn 12 and Turn 15" % hi_s)
	var castle_y := d.position_at(float(d.turns[7]["s_apex"])).y
	assert_between(castle_y, 3.0, hi - 8.0, "height of Turn 8 above the finish line (m)")
	# The flat-out run: from the exit of Turn 16 to the line, 1.8 km without a corner tighter
	# than 60 m and without a gradient worth the name.
	var run_from := float(d.turns[15]["s_apex"]) + 80.0
	assert_between(d.length - run_from, 1700.0, 1900.0, "Turn 16 exit to the finish line (m)")
	for i in range(16, 20):
		assert_true(float(d.turns[i]["min_radius"]) > 60.0, "%s is a fast bend (radius %.0f m)" % [
				d.turns[i]["id"], float(d.turns[i]["min_radius"])])
	var s := run_from + 100.0
	while s < d.length:
		assert_true(absf(d.position_at(s).y - d.position_at(0.0).y) < 1.5,
				"the seafront straight is level (y=%.2f at s=%.0f)" % [d.position_at(s).y, s])
		s += 50.0

## track.json carries the real widths (recipe key track_json_widths), so the drivers know how
## narrow the castle section is. Two figures are published, 13 m at the widest (the pit
## straight) and 7.6 m at the narrowest (Turn 8); the streets between them follow the lane
## counts of OpenStreetMap at 3.5 m a lane (estimates, see tools/track/tracks/baku.toml).
func test_widths() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null and d.turns.size() == 20, "track.json loads with its 20 turns")
	if d == null or d.turns.size() != 20:
		return
	assert_between(d.width_at(d.start_s), 12.9, 13.1, "width on the grid (m)")
	assert_between(d.width_at(5600.0), 12.9, 13.1, "width of the four-lane main straight (m)")
	assert_between(d.width_at(4400.0), 11.9, 12.1, "width of the run from Turn 16 (m)")
	assert_between(d.width_at(500.0), 11.9, 12.1, "width of Pushkin Street, Turn 1 to Turn 2 (m)")
	assert_between(d.width_at(1100.0), 9.9, 10.1, "width of Khagani Street, Turn 2 to Turn 3 (m)")
	assert_between(d.width_at(1650.0), 10.4, 10.6, "width of Bulbul Avenue, Turn 3 to Turn 4 (m)")
	assert_between(d.width_at(1900.0), 10.4, 10.6, "width of Zarifa Aliyeva Street, Turn 4 to Turn 5 (m)")
	assert_between(d.width_at(3150.0), 11.9, 12.1, "width of Istiglaliyyat Street (m)")
	assert_between(d.width_at(3950.0), 9.9, 10.1, "width of Niyazi Street, Turn 15 to Turn 16 (m)")
	assert_between(d.width_at(float(d.turns[7]["s_apex"]) + 10.0), 7.5, 7.8, "width in the castle section (m)")
	var widest := 0.0
	for w in d.widths:
		widest = maxf(widest, w)
	assert_between(widest, 12.9, 13.1, "widest point of the lap (m)")
	var narrowest := INF
	for w in d.widths:
		narrowest = minf(narrowest, w)
	assert_between(narrowest, 7.5, 7.7, "narrowest point of the lap (m)")

## The two carriageways of Neftchilar Avenue (the recipe's [[road.pair]]): side by side at their
## own widths, never overlapping, level with each other, with a median for one wall between.
## Before the pair existed the OSM centrelines (9.5 to 11.7 m apart) forced both roads down to
## 8 m; now the recipe moves them 14 m apart: 11 m for Turn 6 to Turn 7 (3 lanes), 12 m for the
## main straight (4 lanes) and 2.5 m of median. Estimates, see tools/track/tracks/baku.toml.
func test_the_two_carriageways_do_not_overlap() -> void:
	var d := TrackData.load_track(PATH)
	assert_between(d.width_at(2350.0), 10.9, 11.1, "width of the Turn 6 to Turn 7 road (m)")
	assert_between(d.width_at(4900.0), 11.9, 12.1, "width of the main straight beside it (m)")
	var s: float = OUTBOUND[0]
	var closest := INF
	while s <= float(OUTBOUND[1]):
		var p := d.position_at(s)
		var best := INF
		var best_t := 0.0
		var t: float = MAIN_BESIDE_IT[0]
		while t <= float(MAIN_BESIDE_IT[1]):
			var q := d.position_at(t)
			var dist := Vector2(p.x - q.x, p.z - q.z).length()
			if dist < best:
				best = dist
				best_t = t
			t += 2.0
		var gap := best - 0.5 * (d.width_at(s) + d.width_at(best_t))
		closest = minf(closest, best)
		assert_true(gap > 2.3, "the roads are %.2f m apart at s=%.0f / s=%.0f" % [gap, s, best_t])
		assert_true(absf(p.y - d.position_at(best_t).y) < 0.4, "step of %.2f m between the carriageways at s=%.0f" % [
				p.y - d.position_at(best_t).y, s])
		s += 10.0
	assert_between(closest, 13.8, 14.3, "closest approach of the two centrelines (m)")

## One wall stands between the carriageways, on the middle of the median, not one per road:
## looking left from either road the first barrier is the same wall, and the only one before
## the other road's tarmac.
func test_one_wall_between_the_carriageways() -> void:
	var scene := _race()
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	var road := track.get_node("Road") as RoadSurface
	await _built(ts)
	var d := track.data
	assert_true(road.pairs.size() == 1, "road_profile.json declares the pair (%d)" % road.pairs.size())
	var space := scene.get_viewport().world_3d.direct_space_state
	for s: float in [2230.0, 2350.0, 2480.0]:
		var xf := ts.frame_at(s)
		var from := xf.origin + Vector3.UP * 0.5
		var left := -xf.basis.x
		# The main straight, straight across: it runs the other way, s = 2350 beside s = 4905.
		var other := d.closest_s(from + left * 14.0, 7255.0 - s)
		var q := PhysicsRayQueryParameters3D.create(from, from + left * 30.0)
		q.collision_mask = Trackside.LAYER_BARRIER
		var hit := space.intersect_ray(q)
		assert_true(not hit.is_empty(), "no wall between the carriageways at s=%.0f" % s)
		if hit.is_empty():
			continue
		var dist := from.distance_to(hit["position"])
		var mid := road.half_width_at(s) + 0.5 * (14.0 - road.half_width_at(s) - road.half_width_at(other))
		assert_between(dist, mid - 0.6, mid + 0.6, "wall on the middle of the median at s=%.0f (m from the centre)" % s)
		# From the other road, looking back: the same wall, seen from behind.
		var back_from := d.position_at(other) + Vector3.UP * 0.5
		var q2 := PhysicsRayQueryParameters3D.create(back_from, from)
		q2.collision_mask = Trackside.LAYER_BARRIER
		var hit2 := space.intersect_ray(q2)
		assert_true(not hit2.is_empty(), "no wall seen from the main straight at s=%.0f" % other)
		if not hit2.is_empty():
			var thick := (hit2["position"] as Vector3).distance_to(hit["position"])
			assert_true(thick < 0.8, "two walls %.2f m apart between the carriageways at s=%.0f" % [thick, s])
		# Both barrier lines are that wall.
		assert_true(absf(ts.barrier_offset(s, -1.0) + ts.barrier_offset(other, -1.0) + 0.58
				- from.distance_to(back_from)) < 0.5, "the two barrier lines are one wall at s=%.0f" % s)
	scene.queue_free()

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	# Not on the avenue's two carriageways: closest_s without a hint may pick either there.
	for s: float in [0.0, 324.0, 1100.0, 1760.0, 2747.0, 3400.0, 4125.0, 5600.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 2.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node("Track") as Track
	assert_true(track != null and track.data != null, "the race scene builds the track")
	if track == null or track.data == null:
		scene.queue_free()
		return
	assert_true(track.track_id == ID, "track id '%s'" % track.track_id)
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	var road := track.get_node("Road") as RoadSurface
	assert_true(not road.is_runtime_mesh, "the road comes from road_mesh.glb")
	assert_true(not (track.get_node("Terrain") as Terrain).is_fallback, "the terrain comes from terrain.json")
	scene.queue_free()

## Street circuit: concrete walls close to the road all the way round, never on it. Between
## the carriageways the wall is nearer still, but beside the tarmac. The only run-off is the
## tarmac of the three escape areas that are open ground (Turns 1, 3 and 16), where the wall
## stands back by the depth of the escape area.
func test_walls_stand_close_to_the_road() -> void:
	var scene := _race()
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	var road := track.get_node("Road") as RoadSurface
	await _built(ts)
	var d := track.data
	assert_true(ts.layout != null and not ts.layout.is_auto, "Baku uses its hand-made trackside table")
	assert_true(ts.layout.runoff.size() == 3, "three escape areas, got %d" % ts.layout.runoff.size())
	var escapes: Array = []
	for r in ts.layout.runoff:
		assert_true(String(r["kind"]) == "tarmac", "no gravel on a street circuit (%s)" % r["turn"])
		escapes.append([float(r["s0"]) - 45.0, float(r["s0"]) + float(r["len"]) + 45.0])
	var widest := 0.0
	var tightest := INF
	var n := d.points.size()
	for i in n:
		var s := i * d.step
		assert_true(absf(ts.edge_at(s) - road.half_width_at(s)) < 0.01, "trackside and road agree on the edge at s=%.0f" % s)
		assert_true(ts.layout.is_concrete(s), "concrete wall at s=%.0f" % s)
		for side: float in [-1.0, 1.0]:
			var gap := ts.barrier_offset(s, side) - ts.edge_at(s)
			tightest = minf(tightest, gap)
			var escape := false
			for e: Array in escapes:
				escape = escape or road.s_in_range(s, e)
			if escape:
				assert_true(gap <= 13.0, "wall %.2f m behind the escape area at s=%.0f (side %d)" % [gap, s, side])
				continue
			widest = maxf(widest, gap)
			assert_true(gap <= 3.0, "wall %.2f m from the road edge at s=%.0f (side %d)" % [gap, s, side])
			assert_true(gap >= 0.7, "wall %.2f m from the road edge at s=%.0f (side %d)" % [gap, s, side])
			var between := side < 0.0 and (road.s_in_range(s, [2150.0, 2550.0]) or road.s_in_range(s, MAIN_BESIDE_IT))
			if not between:
				assert_true(gap >= 1.9, "wall %.2f m from the road edge at s=%.0f (side %d)" % [gap, s, side])
	assert_between(widest, 2.0, 3.0, "widest gap between road edge and wall away from the escape areas (m)")
	# The shared wall is 0.58 m thick and stands on the middle of a median of 2.5 m or more.
	assert_between(tightest, 0.7, 1.5, "tightest gap, between the carriageways (m)")
	# A wall really is there: beside the grid, in the castle section, behind the old city, and
	# between the carriageways (to the left of both).
	var space := scene.get_viewport().world_3d.direct_space_state
	for s: float in [d.start_s, 1000.0, float(d.turns[7]["s_apex"]) + 12.0, 3400.0, 2350.0, 4900.0, 5600.0]:
		var xf := ts.frame_at(s)
		for side: float in [-1.0, 1.0]:
			var from := xf.origin + Vector3.UP * 0.5
			var q := PhysicsRayQueryParameters3D.create(from, from + xf.basis.x * side * 30.0)
			q.collision_mask = Trackside.LAYER_BARRIER
			var hit := space.intersect_ray(q)
			assert_true(not hit.is_empty(), "no barrier beside the road at s=%.0f (side %d)" % [s, side])
			if hit.is_empty():
				continue
			var dist := from.distance_to(hit["position"])
			assert_true(dist > road.half_width_at(s), "barrier on the road at s=%.0f (side %d): %.1f m from the centre" % [
					s, side, dist])
			assert_true(dist < road.half_width_at(s) + 4.0, "barrier %.1f m from the centre at s=%.0f (side %d)" % [
					dist, s, side])
	scene.queue_free()

## The surroundings: day race, paved ground instead of grass verges, the race-weekend
## grandstands, and the hand-made models (pit building, start gantry, Flame Towers, TV tower,
## fortress wall / Maiden Tower / street trees).
func test_surroundings() -> void:
	var scene := _race()
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	await _built(ts)
	var scenery := track.scenery
	assert_true(scenery != null, "the track has a Scenery node")
	if scenery == null:
		scene.queue_free()
		return
	var frames := 0
	while not scenery.is_built and frames < 900:
		await get_tree().physics_frame
		frames += 1
	assert_true(scenery.is_built, "Scenery finished building")
	assert_true(scenery.landmark_count == 5, "five landmark models, got %d" % scenery.landmark_count)
	assert_true(scenery.building_chunks > 100, "the city is there (%d chunks)" % scenery.building_chunks)
	var env := track.environment
	assert_true(env.active, "baku has an environment.json")
	assert_true(env.time == "day", "the Grand Prix is an afternoon race")
	assert_true(not env.mowing_stripes(), "no mowing stripes in a city")
	# Pavement, not lawn, beside the road: grey, with no more green than red.
	var verge := env.color("verge", "grass_color")
	assert_true(absf(verge.g - verge.r) < 0.03, "the verge is paving, not grass (%s)" % verge)
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/tracks/baku/scenery.json"))
	assert_true(int(meta["counts"]["grandstands"]) == 12, "12 grandstands, got %d" % int(meta["counts"]["grandstands"]))
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
	var track := scene.get_node("Track") as Track
	var data: TrackData = track.data if track != null else null
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	assert_true(car != null and data != null, "the race scene has a car and a track")
	if pilot == null or car == null or data == null:
		Bootstrap.autodrive = false
		scene.queue_free()
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
	while time < 240.0 and pilot.laps_completed < 1:
		await physics_frames(1)
		time += TICK
		s = data.closest_s(car.global_position, s)
		var edge := data.width_at(s) * 0.5 - absf(data.lateral_offset(car.global_position, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_s = s
	assert_true(pilot.laps_completed >= 1, "lap not completed in 240 s of physics (at s=%.0f)" % s)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_s])
	assert_true(respawns[0] == 0, "car was respawned %d time(s)" % respawns[0])
	assert_between(pilot.lap_time, 95.0, 135.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nBAKU LAP (from the grid)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f\n" % [
			pilot.lap_time, pilot.max_speed_kmh, worst_edge, worst_s])
	Bootstrap.autodrive = false
	scene.queue_free()
