extends TestCase
## Marina Bay Street Circuit (Singapore): track data (length, widths per street, the two
## bridges), the street-circuit walls, the night scenery, the race scene on the generic track
## runtime, and (with --full-lap) an autopilot lap.
##
##   tests/run_tests.sh --filter=track_marina_bay
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_marina_bay --full-lap

const ID := "marina_bay"
const PATH := "res://assets/tracks/marina_bay/track.json"
const RACE := "res://scenes/race.tscn"
## Official lap length since 2025 (formula1.com; 4.940 km in 2023 and 2024).
const OFFICIAL_LENGTH := 4927.0
const TICK := 1.0 / 240.0

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
	assert_true(info != null and info.available, "marina_bay must be a playable track")
	if info == null:
		return
	assert_true(info.name == "Marina Bay Street Circuit", "name '%s'" % info.name)
	assert_true(info.country_code == "SG", "country code '%s'" % info.country_code)

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
	# Published: 5.3 m of elevation change (formula1.com). Level streets and two bridges.
	assert_between(hi - lo, 5.0, 5.6, "elevation range (m)")
	assert_true(d.turns.size() == 19, "expected 19 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# Left-right-left at Turns 1-3, ..., right-left at 16-17 and two lefts onto the pit straight.
	var dirs := ""
	for t in d.turns:
		dirs += "R" if String(t["direction"]) == "right" else "L"
	assert_true(dirs == "LRLLRRLRLLRLLRLRLLL", "turn directions %s" % dirs)
	assert_true(d.turns[0]["name"] == "Sheares", "T1 must be Sheares")
	assert_true(d.turns[6]["name"] == "Memorial", "T7 must be Memorial")
	# Anticlockwise: the signed area of the plan view (x east, z south) is negative.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area < 0.0, "the lap must run anticlockwise")
	# The start line is 137 m after the finish line (305.337 km for 62 laps of 4.927 km).
	assert_between(d.start_s, 130.0, 145.0, "start line after the finish line (m)")
	# Since 2023 the run from Turn 15 to Turn 16 is one straight: the four corners under the
	# Float grandstand are gone.
	var s := float(d.turns[14]["s_apex"]) + 100.0
	var tightest := INF
	while s < float(d.turns[15]["s_apex"]) - 100.0:
		var bend := d.tangent_at(s - 10.0).angle_to(d.tangent_at(s + 10.0))
		tightest = minf(tightest, 20.0 / maxf(bend, 1e-6))
		s += 10.0
	assert_true(float(d.turns[15]["s_apex"]) - float(d.turns[14]["s_apex"]) > 450.0, "Turn 15 to Turn 16 is a long straight")
	assert_true(tightest > 300.0, "the straight to Turn 16 has a %.0f m bend: is the Float section back?" % tightest)
	# No corner tighter than the road can follow (junction vertices are rounded in the recipe).
	for t in d.turns:
		assert_true(float(t["min_radius"]) >= 12.0, "%s radius %.1f m" % [t["id"], float(t["min_radius"])])
	# Turn 8 and Turn 14 are at the same junction: the two legs touch there but must leave room
	# for both roads and the walls between them.
	var gap := d.position_at(float(d.turns[7]["s_apex"])).distance_to(d.position_at(float(d.turns[13]["s_apex"])))
	assert_between(gap, 30.0, 60.0, "distance between the Turn 8 and Turn 14 apexes (m)")

## Widths follow the streets (lane counts, see the recipe): the wide boulevards, the two-lane
## bay of the Anderson Bridge, the four-lane carriageway of the Esplanade Bridge.
func test_widths_and_bridges_follow_the_streets() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	for row: Array in [[150.0, 14.0, "pit straight"], [800.0, 11.0, "Republic Boulevard"],
			[1400.0, 15.0, "Raffles Boulevard"], [2400.0, 13.0, "St Andrew's Road"],
			[2750.0, 9.5, "Connaught Drive"], [2940.0, 8.0, "Anderson Bridge"],
			[3300.0, 14.0, "Esplanade Bridge"], [4000.0, 15.0, "Raffles Avenue"],
			[4550.0, 12.0, "past the Singapore Flyer"]]:
		assert_between(d.width_at(row[0]), float(row[1]) - 0.3, float(row[1]) + 0.3, "width on %s (m)" % row[2])
	var narrowest := INF
	var narrowest_s := 0.0
	var highest := -INF
	var highest_s := 0.0
	var lowest := INF
	var lowest_s := 0.0
	var s := 0.0
	while s < d.length:
		if d.width_at(s) < narrowest:
			narrowest = d.width_at(s)
			narrowest_s = s
		var y := d.position_at(s).y
		if y > highest:
			highest = y
			highest_s = s
		if y < lowest:
			lowest = y
			lowest_s = s
		s += 5.0
	assert_between(narrowest_s, 2890.0, 3000.0, "the narrowest point is the Anderson Bridge (s)")
	assert_between(highest_s, 3150.0, 3290.0, "the highest point is the crown of the Esplanade Bridge (s)")
	assert_between(lowest_s, 3850.0, 4350.0, "the lowest point is Raffles Avenue beside the bay (s)")
	# The Anderson Bridge is a hump of about a metre between two level streets.
	var hump := d.position_at(2960.0).y - maxf(d.position_at(2880.0).y, d.position_at(3030.0).y)
	assert_between(hump, 0.8, 1.4, "hump of the Anderson Bridge (m)")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 437.0, 972.0, 1826.0, 2683.0, 3063.0, 3599.0, 4100.0, 4810.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
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
	scene.queue_free()

## A street circuit: concrete walls close to the road on both sides all the way round, never
## on the road, and the terrain never above the tarmac. The only room is the asphalt run-off
## at Turn 1, at Turn 7 and outside the last two corners.
func test_walls_stand_beside_the_road_all_round() -> void:
	var scene := _race()
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	var terrain := track.get_node("Terrain") as Terrain
	await _built(ts)
	var d := track.data
	assert_true(not ts.layout.is_auto, "marina_bay uses its own trackside table")
	assert_true(ts.layout.runoff.size() == 4, "run-off at Turns 1, 7, 18 and 19 only (%d)" % ts.layout.runoff.size())
	for r: Dictionary in ts.layout.runoff:
		assert_true(r["kind"] == "tarmac", "no gravel on a street circuit (%s)" % r["turn"])
	var s := 0.0
	var widest := 0.0
	var close := 0
	var samples := 0
	while s < d.length:
		assert_true(ts.layout.is_concrete(s), "concrete wall at s=%.0f" % s)
		for side: float in [-1.0, 1.0]:
			var gap := ts.barrier_offset(s, side) - ts.edge_at(s)
			assert_true(gap >= 1.9, "wall %.2f m from the road edge at s=%.0f (side %d)" % [gap, s, side])
			assert_true(gap >= ts.kerb_extent(s, side), "wall inside the kerb at s=%.0f (side %d)" % [s, side])
			widest = maxf(widest, gap)
			samples += 1
			if gap <= 2.6:
				close += 1
		var p := d.position_at(s)
		assert_true(terrain.height_at(p.x, p.z) < p.y, "terrain above the road at s=%.0f" % s)
		s += 10.0
	assert_true(widest <= 13.0, "walls up to %.1f m from the road edge" % widest)
	assert_true(close > samples * 0.9, "walls within 2.6 m of the road edge on %d of %d samples" % [close, samples])
	# A wall really is in the way of a car leaving the road sideways.
	var space := scene.get_viewport().world_3d.direct_space_state
	for at: float in [100.0, 1200.0, 2035.0, 2450.0, 2960.0, 3063.0, 3300.0, 4100.0]:
		var xf := ts.frame_at(at)
		for side: float in [-1.0, 1.0]:
			var from := xf.origin + Vector3.UP * 0.5
			var q := PhysicsRayQueryParameters3D.create(from, from + xf.basis.x * side * 30.0)
			q.collision_mask = Trackside.LAYER_BARRIER
			var hit := space.intersect_ray(q)
			assert_true(not hit.is_empty(), "no wall beside the road at s=%.0f (side %d)" % [at, side])
			if not hit.is_empty():
				var dist := from.distance_to(hit["position"])
				assert_between(dist, ts.edge_at(at) + 1.0, ts.edge_at(at) + 4.5, "wall distance from the centreline at s=%.0f (side %d)" % [at, side])
	scene.queue_free()

## The race is run at night under floodlights, on paved city ground, with the structures that
## have a shape of their own as models.
func test_night_scenery() -> void:
	var scene := _race()
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	await _built(ts)
	var env := track.environment
	assert_true(env != null and env.active, "marina_bay has an environment.json")
	if env != null:
		assert_true(str(env.values["time"]) == "night", "night race (%s)" % env.values["time"])
		assert_true(env.floodlit(), "floodlit")
		# 10 m trusses on pylons 32 m apart (grandprix.com, "How to light up F1", 2008).
		assert_between(env.number("floodlights", "spacing_m"), 30.0, 34.0, "pylon spacing (m)")
		assert_between(env.number("floodlights", "height_m"), 9.0, 12.0, "truss height (m)")
		assert_true(not env.mowing_stripes(), "no mown verges")
		var verge := env.color("verge", "grass_color")
		assert_true(absf(verge.r - verge.g) < 0.03 and absf(verge.g - verge.b) < 0.03, "verges are paved, not green (%s)" % verge)
	var scenery := track.get_node_or_null("Scenery") as Scenery
	assert_true(scenery != null and scenery.is_built, "scenery built")
	if scenery != null:
		assert_true(scenery.landmark_count == 5, "pit building, Flyer, Anderson Bridge and the two Esplanade shells (%d)" % scenery.landmark_count)
		assert_true(scenery.building_chunks > 20, "city blocks baked (%d chunks)" % scenery.building_chunks)
		assert_true(scenery.water_bodies >= 2, "the bay and the river (%d)" % scenery.water_bodies)
		assert_true(scenery.lamp_count > 100, "floodlight pylons round the lap (%d)" % scenery.lamp_count)
	# The bake stays small enough for the integrated-graphics budget (it was 16 MB).
	var glb := FileAccess.open("res://assets/tracks/marina_bay/scenery.glb", FileAccess.READ)
	assert_true(glb != null and glb.get_length() < 8 * 1024 * 1024, "scenery.glb under 8 MB")
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
	assert_between(pilot.lap_time, 85.0, 130.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nMARINA BAY LAP (from the grid)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f\n" % [
			pilot.lap_time, pilot.max_speed_kmh, worst_edge, worst_s])
	Bootstrap.autodrive = false
	scene.queue_free()
