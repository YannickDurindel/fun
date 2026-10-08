extends TestCase
## Albert Park Circuit (Melbourne): track data, the race scene on the generic track runtime,
## and (with --full-lap) an autopilot lap.
##
##   tests/run_tests.sh --filter=track_albert_park
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_albert_park --full-lap

const ID := "albert_park"
const PATH := "res://assets/tracks/albert_park/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5278.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_catalog_lists_the_track_as_playable() -> void:
	TrackCatalog.reload()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "albert_park must be a playable track")
	if info == null:
		return
	assert_true(info.name == "Albert Park Circuit", "name '%s'" % info.name)
	assert_true(info.country_code == "AU", "country code '%s'" % info.country_code)

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
	# A flat park road round a lake: a few metres at most.
	assert_between(hi - lo, 0.5, 6.0, "elevation range (m)")
	assert_true(d.turns.size() == 14, "expected 14 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	# Right-left at Turns 1-2, the fast left-right of Turns 9-10, right-right-left-right home.
	var dirs := ""
	for t in d.turns:
		dirs += "R" if String(t["direction"]) == "right" else "L"
	assert_true(dirs == "RLRLRRLRLRRRLR", "turn directions %s" % dirs)
	assert_true(d.turns[0]["name"] == "Brabham", "T1 must be Brabham")
	# Clockwise: the signed area of the plan view (x east, z south) is positive.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area > 0.0, "the lap must run clockwise")
	# The lakeside run where the old Turn 9-10 chicane was (between Turn 8 and Turn 9) is
	# flat out: no bend tighter than 150 m.
	var s := float(d.turns[7]["s_apex"]) + 150.0
	var tightest := INF
	while s < float(d.turns[8]["s_apex"]) - 150.0:
		var bend := d.tangent_at(s - 10.0).angle_to(d.tangent_at(s + 10.0))
		tightest = minf(tightest, 20.0 / maxf(bend, 1e-6))
		s += 10.0
	assert_true(tightest > 150.0, "lakeside run has a %.0f m bend: is the old chicane back?" % tightest)

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 380.0, 1116.0, 1895.0, 2800.0, 4152.0, 5200.0]:
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
	while time < 200.0 and pilot.laps_completed < 1:
		await physics_frames(1)
		time += TICK
		s = data.closest_s(car.global_position, s)
		var edge := data.width_at(s) * 0.5 - absf(data.lateral_offset(car.global_position, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_s = s
	assert_true(pilot.laps_completed >= 1, "lap not completed in 200 s of physics (at s=%.0f)" % s)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_s])
	assert_true(respawns[0] == 0, "car was respawned %d time(s)" % respawns[0])
	assert_between(pilot.lap_time, 70.0, 110.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nALBERT PARK LAP (from the grid)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, min edge margin %.2f m at s=%.0f\n" % [
			pilot.lap_time, pilot.max_speed_kmh, worst_edge, worst_s])
	Bootstrap.autodrive = false
	scene.queue_free()
