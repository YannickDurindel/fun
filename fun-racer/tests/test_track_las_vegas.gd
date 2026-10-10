extends TestCase
## Las Vegas Strip Circuit: track data, the race scene on the generic track runtime with the
## street-circuit trackside table, and (with --full-lap) an autopilot lap.
##
##   tests/run_tests.sh --filter=track_las_vegas
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_las_vegas --full-lap

const ID := "las_vegas"
const PATH := "res://assets/tracks/las_vegas/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 6201.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_catalog_lists_the_track_as_playable() -> void:
	TrackCatalog.reload()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "las_vegas must be a playable track")
	if info == null:
		return
	assert_true(info.name == "Las Vegas Strip Circuit", "name '%s'" % info.name)
	assert_true(info.country_code == "US", "country code '%s'" % info.country_code)

func test_dimensions_match_real_circuit() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	assert_between(d.length, OFFICIAL_LENGTH * 0.99, OFFICIAL_LENGTH * 1.01, "lap length (m)")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	assert_true(d.turns.size() == 17, "expected 17 turns, got %d" % d.turns.size())
	if d.turns.size() != 17:
		return
	var lo := INF
	var hi := -INF
	var hi_i := 0
	for i in d.points.size():
		var p := d.points[i]
		lo = minf(lo, p.y)
		if p.y > hi:
			hi = p.y
			hi_i = i
	# The valley floor slopes down to the east: about 15 m over the lap, no hills.
	assert_between(hi - lo, 8.0, 20.0, "elevation range (m)")
	# The high point is on the Strip / Harmon Avenue side (west), between Turns 13 and 17.
	var hi_s := hi_i * d.step
	assert_between(hi_s, float(d.turns[12]["s_apex"]), float(d.turns[16]["s_apex"]), "high point s (m)")
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# Hairpin (1-2), right-right onto Koval Lane, right at Turn 5, left-left-right-left round
	# the Sphere, right-left on Sands Avenue, left onto the Strip, the kink, the Harmon
	# Avenue chicane, left onto the pit straight.
	var dirs := ""
	for t in d.turns:
		dirs += "R" if String(t["direction"]) == "right" else "L"
	assert_true(dirs == "LLRRRLLRLRLLLLRLL", "turn directions %s" % dirs)
	# Anticlockwise: the signed area of the plan view (x east, z south) is negative.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area < 0.0, "the lap must run anticlockwise")
	# The start line is 92 m after the finish line (50 laps = 309.958 km).
	assert_between(d.start_s, 85.0, 100.0, "start line s (m)")

## Widths per section, as the recipe states them (estimates inside the published 12 to 15 m:
## formula1.com, "the track is around 12-15 m wide"). Before, the whole lap was the default
## 13 m with a 15 m grid.
func test_widths_follow_the_real_sections() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	for w in d.widths:
		if w < 11.99 or w > 15.01:
			assert_true(false, "width %.2f m outside 12 to 15 m" % w)
			break
	assert_between(d.width_at(d.start_s), 14.9, 15.1, "grid width (m)")
	assert_between(d.width_at(320.0), 14.9, 15.1, "Turn 1 hairpin width (m)")
	assert_between(d.width_at(1200.0), 13.9, 14.1, "Koval Lane width (m)")
	assert_between(d.width_at(2000.0), 11.9, 12.1, "Sphere road width (m)")
	assert_between(d.width_at(2800.0), 11.9, 12.1, "Sands Avenue width (m)")
	assert_between(d.width_at(4300.0), 13.9, 14.1, "the Strip width (m)")
	assert_between(d.width_at(5650.0), 12.9, 13.1, "Harmon Avenue width (m)")

## Turns 14 to 16 are left, right, left (official circuit map). OSM draws one straight
## diagonal there; the recipe's [[layout.shift]] gives the lap its right-hand kink.
func test_turn_15_is_a_right_hand_kink() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null and d.turns.size() == 17, "track.json with 17 turns")
	if d == null or d.turns.size() != 17:
		return
	var bends: Array[float] = []
	for i: int in [13, 14, 15]:
		var s := float(d.turns[i]["s_apex"])
		var a := d.tangent_at(s - 8.0)
		var b := d.tangent_at(s + 8.0)
		# Positive = the heading turns right (x east, z south, seen from above).
		bends.append(a.x * b.z - a.z * b.x)
	assert_true(bends[0] < -0.2, "Turn 14 turns left (%.3f)" % bends[0])
	assert_true(bends[1] > 0.08, "Turn 15 turns right (%.3f)" % bends[1])
	assert_true(bends[2] < -0.2, "Turn 16 turns left (%.3f)" % bends[2])
	assert_between(float(d.turns[14]["min_radius"]), 60.0, 140.0, "Turn 15 radius (m)")

## The Strip: 1.9 km flat out between Turn 12 and Turn 14, heading south, with nothing
## tighter than the Turn 13 kink.
func test_the_strip_is_one_long_straight() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null and d.turns.size() == 17, "track.json with 17 turns")
	if d == null or d.turns.size() != 17:
		return
	var s0 := float(d.turns[11]["s_apex"])
	var s1 := float(d.turns[13]["s_apex"])
	assert_between(s1 - s0, 1800.0, 2050.0, "Turn 12 to Turn 14 (m)")
	var a := d.position_at(s0 + 100.0)
	var b := d.position_at(s1 - 100.0)
	assert_true(b.z - a.z > 1500.0, "the Strip runs south (dz = %.0f m)" % (b.z - a.z))
	var s := s0 + 120.0
	var tightest := INF
	while s < s1 - 120.0:
		var bend := d.tangent_at(s - 10.0).angle_to(d.tangent_at(s + 10.0))
		tightest = minf(tightest, 20.0 / maxf(bend, 1e-6))
		s += 10.0
	assert_true(tightest > 400.0, "the Strip has a %.0f m bend" % tightest)

## The carriageway crossover on Sands Avenue (a 60 degree dogleg in OSM) is a flat-out S-bend.
func test_sands_avenue_crossover_is_flat_out() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null and d.turns.size() == 17, "track.json with 17 turns")
	if d == null or d.turns.size() != 17:
		return
	var s := float(d.turns[8]["s_apex"]) + 120.0
	var tightest := INF
	while s < float(d.turns[9]["s_apex"]) - 20.0:
		var bend := d.tangent_at(s - 10.0).angle_to(d.tangent_at(s + 10.0))
		tightest = minf(tightest, 20.0 / maxf(bend, 1e-6))
		s += 10.0
	assert_true(tightest > 90.0, "Sands Avenue has a %.0f m bend before Turn 10" % tightest)

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 322.0, 1100.0, 1615.0, 2068.0, 2600.0, 3242.0, 4500.0, 5183.0, 6050.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

## Street circuit: concrete walls all round, close to the road but never on it.
func test_walls_stand_close_to_the_road() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(TracksideLayout.has_table(ID), "las_vegas has a trackside table")
	var layout := TracksideLayout.for_track(ID, d)
	assert_true(not layout.is_auto, "the table is used")
	for r in layout.runoff:
		assert_true(r["kind"] == "tarmac", "no gravel on a street circuit")
	var s := 0.0
	while s < d.length:
		assert_true(layout.is_concrete(s), "concrete wall at s=%.0f" % s)
		s += 25.0
	var scene := _race()
	await physics_frames(10)
	var ts := scene.get_node("Track").find_child("Trackside", true, false) as Trackside
	assert_true(ts != null, "the track has a Trackside")
	if ts == null:
		scene.queue_free()
		return
	var close := 0
	var total := 0
	s = 0.0
	while s < d.length:
		var half := d.width_at(s) * 0.5
		for side: float in [-1.0, 1.0]:
			var gap := ts.barrier_offset(s, side) - half
			assert_true(gap >= 1.9, "wall %.2f m from the road edge at s=%.0f (side %+.0f)" % [gap, s, side])
			total += 1
			if gap <= 3.5:
				close += 1
		s += 10.0
	assert_true(close > total * 0.8, "only %d of %d wall samples within 3.5 m of the road" % [close, total])
	scene.queue_free()

## A night race under floodlights, with the landmarks of the lap standing round it.
func test_surroundings_are_the_strip_at_night() -> void:
	var env := TrackEnvironment.load_file("res://assets/tracks/las_vegas/environment.json")
	assert_true(env.active and env.is_night() and env.floodlit(), "a floodlit night race")
	assert_true(not env.mowing_stripes(), "no mowed grass beside a street circuit")
	# The verges are pavement: grey, not green.
	var verge := env.color("verge", "grass_color")
	assert_true(absf(verge.r - verge.g) < 0.03 and absf(verge.g - verge.b) < 0.03, "paved verges (%s)" % verge)
	var scene := _race()
	await physics_frames(10)
	var scenery := scene.get_node("Track").find_child("Scenery", true, false) as Scenery
	assert_true(scenery != null and scenery.is_built, "the track has scenery")
	if scenery == null:
		scene.queue_free()
		return
	# Sphere, Eiffel Tower, High Roller, the Strip (palms, signs, fountains) and the circuit's
	# own structures (gantries, Flamingo Road bridge, monorail).
	assert_true(scenery.landmark_count == 5, "landmarks: %d" % scenery.landmark_count)
	assert_true(scenery.lamp_count > 100, "floodlight masts: %d" % scenery.lamp_count)
	assert_true(scenery.building_chunks > 20, "building chunks: %d" % scenery.building_chunks)
	# The landmark models are baked in world heights by tools/track/landmarks/las_vegas.py, which
	# cancels the terrain height at each anchor: a mismatch means the track was rebuilt without
	# running that script again.
	var terrain := scene.get_node("Track").find_child("Terrain", true, false) as Terrain
	var placed: Array = JSON.parse_string(FileAccess.get_file_as_string("res://assets/tracks/las_vegas/landmarks.json"))
	assert_true(terrain != null and placed.size() == 5, "terrain and 5 landmark entries")
	if terrain != null:
		for e: Dictionary in placed:
			var xz: Array = e["at"]["xz"]
			var ground := terrain.height_at(float(xz[0]), float(xz[1]))
			if is_nan(ground):
				ground = 0.0
			assert_true(absf(ground + float(e["y_offset"])) < 0.05,
					"landmark %s is baked on another terrain (%.2f m off): run tools/track/landmarks/las_vegas.py" % [
					e["model"], ground + float(e["y_offset"])])
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/tracks/las_vegas/scenery.json"))
	var counts: Dictionary = meta.get("counts", {})
	# Main grandstand, East and West Harmon zones, the Sphere zone, the Bellagio Fountain Club.
	assert_true(int(counts.get("grandstands", 0)) >= 10, "grandstands: %s" % counts.get("grandstands", 0))
	# The Sphere stands inside Turns 5 to 9: 157 m wide, 112 m high, lit.
	var sphere := scenery.find_child("sphere_*", true, false) as Node3D
	assert_true(sphere != null, "the Sphere is a landmark")
	if sphere != null:
		var box := AABB()
		var first := true
		for mi in Scenery.mesh_instances(sphere):
			var b := mi.global_transform * mi.get_aabb()
			box = b if first else box.merge(b)
			first = false
		assert_between(box.size.x, 150.0, 175.0, "Sphere width (m)")
		assert_between(box.end.y, 100.0, 116.0, "Sphere top above the finish line (m)")
		var d := TrackData.load_track(PATH)
		var c := box.get_center()
		var s := d.closest_s(Vector3(c.x, 0.0, c.z))
		assert_between(s, float(d.turns[4]["s_apex"]), float(d.turns[9]["s_apex"]), "the Sphere is beside Turns 5 to 10")
	scene.queue_free()

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
	assert_between(pilot.lap_time, 85.0, 115.0, "lap time (s)")
	print("\nLAS VEGAS LAP (from the grid)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f\n" % [
			pilot.lap_time, pilot.max_speed_kmh, worst_edge, worst_s])
	Bootstrap.autodrive = false
	scene.queue_free()
