extends TestCase
## Miami International Autodrome (Miami Gardens): track data, the race scene on the generic
## track runtime, and (with --full-lap) an autopilot lap.
##
##   tests/run_tests.sh --filter=track_miami
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_miami --full-lap

const ID := "miami"
const PATH := "res://assets/tracks/miami/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5412.0
## The finish (timing) line lies 158 m before the start line: 57 laps x 5.412 km - 308.326 km.
const START_OFFSET := 158.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_catalog_lists_the_track_as_playable() -> void:
	TrackCatalog.reload()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "miami must be a playable track")
	if info == null:
		return
	assert_true(info.name == "Miami International Autodrome", "name '%s'" % info.name)
	assert_true(info.country_code == "US", "country code '%s'" % info.country_code)

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
		var p := d.points[i]
		lo = minf(lo, p.y)
		if p.y > hi:
			hi = p.y
			hi_s = i * d.step
	# Flat stadium car parks; the only rise is the ramp of the turn 14-15 chicane.
	assert_between(hi - lo, 1.0, 5.0, "elevation range (m)")
	assert_true(d.turns.size() == 19, "expected 19 turns, got %d" % d.turns.size())
	if d.turns.size() != 19:
		return
	assert_between(hi_s, float(d.turns[13]["s_apex"]) - 20.0, float(d.turns[14]["s_apex"]) + 20.0,
			"the highest point is the crest of the turn 14-15 chicane (s)")
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	var dirs := ""
	for t in d.turns:
		dirs += "R" if String(t["direction"]) == "right" else "L"
	assert_true(dirs == "RLRLRLLRRLLRLLRLLLR", "turn directions %s" % dirs)
	assert_true(d.turns[16]["name"] == "Turn 17 (hairpin)", "T17 is the hairpin, got %s" % d.turns[16]["name"])
	# Anticlockwise: the signed area of the plan view (x east, z south) is negative.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area < 0.0, "the lap must run anticlockwise")
	# The back straight from turn 16 to the turn 17 hairpin is about 1.28 km, and straight.
	var back := float(d.turns[16]["s_apex"]) - float(d.turns[15]["s_apex"])
	assert_between(back, 1200.0, 1400.0, "turn 16 apex to turn 17 apex (m)")
	var s := float(d.turns[15]["s_apex"]) + 60.0
	var tightest := INF
	while s < float(d.turns[16]["s_apex"]) - 60.0:
		var bend := d.tangent_at(s - 10.0).angle_to(d.tangent_at(s + 10.0))
		tightest = minf(tightest, 20.0 / maxf(bend, 1e-6))
		s += 10.0
	assert_true(tightest > 400.0, "the back straight has a %.0f m bend" % tightest)
	# The hairpin and the chicane are the slowest corners of the lap.
	for i: int in [13, 14, 16]:
		assert_true(float(d.turns[i]["min_radius"]) < 20.0, "%s radius %.0f m" % [d.turns[i]["id"], d.turns[i]["min_radius"]])
	# The grid stands on the pit straight, a good 150 m before turn 1.
	assert_between(float(d.turns[0]["s_apex"]) - d.start_s, 120.0, 220.0, "start line to T1 apex (m)")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 158.0, 320.0, 1608.0, 2500.0, 3410.0, 4836.0, 5300.0]:
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

## A temporary circuit: the hand-made table (scripts/track/trackside_layouts/miami.gd) brings
## the concrete walls to the road edge all round, except behind the three run-off areas.
func test_walls_stand_at_the_road_edge() -> void:
	var scene := _race()
	await physics_frames(10)
	var track := scene.get_node("Track") as Track
	var ts := track.get_node_or_null("Trackside") as Trackside if track != null else null
	assert_true(ts != null and ts.layout != null, "the track has a trackside")
	if ts == null or ts.layout == null:
		scene.queue_free()
		return
	assert_true(not ts.layout.is_auto, "miami uses its hand-made trackside table")
	var d := track.data
	var n := d.points.size()
	var close := 0
	for side: float in [-1.0, 1.0]:
		var worst_gap := INF
		var worst_jump := 0.0
		var worst_kink := 0.0
		for i in n:
			var s := i * d.step
			var off := ts.barrier_offset(s, side)
			var gap := off - ts.edge_at(s)
			worst_gap = minf(worst_gap, gap)
			if gap < 4.5:
				close += 1
			assert_true(ts.layout.is_concrete(s), "concrete wall at s=%.0f" % s)
			var next := ts.barrier_offset(s + d.step, side)
			worst_jump = maxf(worst_jump, absf(next - off))
			worst_kink = maxf(worst_kink, absf(next - 2.0 * off + ts.barrier_offset(s - d.step, side)))
		assert_true(worst_gap >= 1.5, "barrier %.2f m from the road edge (side %d)" % [worst_gap, side])
		assert_true(worst_jump < 2.0, "barrier line jumps %.2f m between points (side %d)" % [worst_jump, side])
		assert_true(worst_kink < 0.7, "barrier line kinks by %.2f m at a point (side %d)" % [worst_kink, side])
	assert_true(close > 0.85 * 2.0 * n, "walls within 4.5 m of the road edge on %.0f %% of the lap" % [
			100.0 * close / (2.0 * n)])
	for k in ts.kerbs:
		assert_true(k["kind"] != "sausage", "no sausage kerbs: they would reach into the wall")
	for r in ts.runoff:
		assert_true(r["kind"] == "tarmac", "no gravel on a car park circuit")
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
