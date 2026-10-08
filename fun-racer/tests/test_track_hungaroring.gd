extends TestCase
## Hungaroring: the built centreline against the published figures, and the race scene on it.
## The full autopilot lap runs only with `--full-lap` (fixed-fps, see tools/lap_demo.sh):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_hungaroring --full-lap

const ID := "hungaroring"
const PATH := "res://assets/tracks/hungaroring/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 4381.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func test_listed_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "the catalog lists the Hungaroring as playable")
	if info != null:
		assert_true(info.name == "Hungaroring" and info.country_code == "HU", "menu entry (%s, %s)" % [info.name, info.country_code])

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
	for i in d.points.size():
		var y := d.points[i].y
		if y < lo:
			lo = y
			lo_s = i * d.step
		hi = maxf(hi, y)
	# Published: about 35 m between the pit straight and the valley floor.
	assert_between(hi - lo, 28.0, 45.0, "elevation range (m)")
	assert_true(d.turns.size() == 14, "expected 14 turns, got %d" % d.turns.size())
	var last := -1.0
	var rights := 0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
		rights += 1 if String(t["direction"]) == "right" else 0
	assert_true(rights == 8, "8 right-handers and 6 left-handers, got %d rights" % rights)
	assert_true(d.turns[0]["direction"] == "right" and d.turns[1]["direction"] == "left"
			and d.turns[12]["direction"] == "left" and d.turns[13]["direction"] == "right",
			"T1 right, T2 left, T13 left, T14 right")
	# The T6 / T7 chicane: a right and a left within 60 m.
	assert_true(d.turns[5]["direction"] == "right" and d.turns[6]["direction"] == "left"
			and float(d.turns[6]["s_apex"]) - float(d.turns[5]["s_apex"]) < 60.0, "T6 / T7 form the chicane")
	# The circuit lies in a bowl: the pit straight is the top, the valley between T3 and T4 the
	# bottom, and the straight runs downhill into T1.
	assert_true(d.position_at(0.0).y > hi - 4.0, "the finish line is near the highest point")
	assert_true(lo_s > float(d.turns[2]["s_apex"]) and lo_s < float(d.turns[3]["s_apex"]),
			"lowest point between T3 and T4 (s=%.0f)" % lo_s)
	assert_true(d.position_at(float(d.turns[0]["s_apex"])).y < d.position_at(0.0).y - 8.0, "downhill into T1")
	# Clockwise: the signed area of the plan view (x east, z south) is positive.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area > 0.0, "the lap runs clockwise")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 613.8, 2374.0, 3771.2, 4370.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID, "race scene built the Hungaroring")
	if track == null:
		return
	assert_true(track.get_node("Road").find_children("*", "MeshInstance3D", true, false).size() > 0, "road mesh loaded")
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")

## The lap is twisty: the stretches T12 -> T13 and T13 -> T14 run 68 m apart. No barrier of one
## stretch may stand on, or right next to, the road of another.
func test_barriers_clear_of_neighbouring_sections() -> void:
	var scene := _race()
	var track := scene.get_node_or_null("Track") as Track
	var ts := track.get_node_or_null("Trackside") as Trackside if track != null else null
	var frames := 0
	while ts != null and not ts.is_built and frames < 600:
		await physics_frames(1)
		frames += 1
	assert_true(ts != null and ts.is_built, "Trackside finished building")
	if ts == null or not ts.is_built:
		return
	var d := track.data
	var worst := INF
	var worst_s := 0.0
	var s := 0.0
	while s < d.length:
		var xf := ts.frame_at(s)
		var rh := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized()
		for side: float in [-1.0, 1.0]:
			var off := ts.barrier_offset(s, side)
			assert_true(off - ts.edge_at(s) >= 1.5, "barrier %.2f m from its own road edge at s=%.0f" % [off - ts.edge_at(s), s])
			var p := xf.origin + rh * side * off
			# Nearest centreline point that is not on the barrier's own stretch of road.
			var i := 0
			while i < d.points.size():
				var other := i * d.step
				if absf(d.delta_s(s, other)) >= 120.0:
					var q := d.points[i]
					var gap := Vector2(p.x - q.x, p.z - q.z).length() - d.width_at(other) * 0.5
					if gap < worst:
						worst = gap
						worst_s = s
				i += 2
		s += 10.0
	assert_true(worst > 3.0, "a barrier at s=%.0f stands %.1f m from the edge of another stretch of road" % [worst_s, worst])
	print("       closest barrier to another stretch of road: %.1f m (s=%.0f)" % [worst, worst_s])

## One standing lap by the autopilot: never off the road (so never in a barrier, which stands
## at least 1.5 m beyond the edge), no sudden stop, every turn visited.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
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
	var time := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var worst_decel := 0.0
	var worst_decel_s := 0.0
	var s := data.closest_s(car.global_position)
	var speed := 0.0
	while pilot.laps_completed < 1 and time < 200.0:
		await physics_frames(1)
		time += TICK
		s = data.closest_s(car.global_position, s)
		var edge := data.width_at(s) * 0.5 - absf(data.lateral_offset(car.global_position, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		var v := car.linear_velocity.length()
		if speed - v > worst_decel:
			worst_decel = speed - v
			worst_decel_s = s
		speed = v
	Bootstrap.autodrive = false
	assert_true(pilot.laps_completed >= 1, "lap not completed in 200 s of physics (at s=%.0f)" % s)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	# Braking is about 5 g at most (0.2 m/s per tick); an impact loses far more in one tick.
	assert_true(worst_decel < 1.0, "speed dropped %.1f m/s in one tick at s=%.0f (impact?)" % [worst_decel, worst_decel_s])
	assert_between(pilot.lap_time, 60.0, 110.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nHUNGARORING LAP 1 (from the grid)\n" + pilot.report())
	print("       min edge margin %.2f m at s=%.0f, largest speed loss in one tick %.2f m/s at s=%.0f\n" % [
			worst_edge, worst_edge_s, worst_decel, worst_decel_s])
