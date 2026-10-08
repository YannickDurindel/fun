extends TestCase
## Bahrain International Circuit (Grand Prix layout): centreline data against the published
## figures, and the race scene on it. With `--full-lap` the autopilot also drives a whole lap:
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_bahrain --full-lap

const ID := "bahrain"
const PATH := "res://assets/tracks/bahrain/track.json"
const RACE := "res://scenes/race.tscn"
const LENGTH := 5412.0
const TICK := 1.0 / 240.0
## Official order of the 15 turns.
const DIRECTIONS: Array[String] = ["right", "left", "right", "right", "left", "right", "left", "right",
		"left", "left", "left", "right", "right", "right", "right"]

func test_dimensions_match_real_circuit() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	if d == null:
		return
	assert_between(d.length, LENGTH * 0.99, LENGTH * 1.01, "lap length (m)")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	# Published: about 17 m. The DEM is a 30 m surface model, so allow a few metres more.
	assert_between(hi - lo, 12.0, 24.0, "elevation range (m)")
	assert_true(d.turns.size() == 15, "expected 15 turns, got %d" % d.turns.size())
	var last := -1.0
	for i in d.turns.size():
		var t: Dictionary = d.turns[i]
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
		if i < DIRECTIONS.size():
			assert_true(String(t["direction"]) == DIRECTIONS[i], "%s must turn %s" % [t["id"], DIRECTIONS[i]])
	assert_true(d.turns[0]["name"] == "Michael Schumacher", "T1 must be the Michael Schumacher turn")
	# The grid is 246 m before the finish line (race distance = 57 laps - 0.246 km).
	assert_between(d.delta_s(d.start_s, 0.0), 236.0, 256.0, "start line to finish line (m)")
	# The first corner follows shortly after the finish line; the pit straight is over 1 km.
	assert_between(float(d.turns[0]["s_apex"]), 150.0, 320.0, "finish line to the T1 apex (m)")
	assert_between(d.length - float(d.turns[14]["s_apex"]) + float(d.turns[0]["s_apex"]), 1000.0, 1200.0,
			"T15 apex to T1 apex along the pit straight (m)")
	# The circuit climbs from the pit straight to Turn 4 and to Turn 13.
	var grid_y := d.position_at(d.start_s).y
	assert_true(d.position_at(float(d.turns[3]["s_apex"])).y > grid_y + 8.0, "Turn 4 is well above the grid")
	assert_true(d.position_at(float(d.turns[12]["s_apex"])).y > grid_y + 8.0, "Turn 13 is well above the grid")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 333.3, 1390.0, 2500.5, 4300.0, 5400.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

func test_catalog_lists_it_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "bahrain must be available in the catalog")
	if info != null:
		assert_true(info.name == "Bahrain International Circuit", "catalog name (%s)" % info.name)

func _spawn_race() -> Node:
	var saved := Game.config.track_id
	Game.config.track_id = ID
	var scene := spawn(RACE)
	Game.config.track_id = saved
	return scene

func test_race_scene_spawns_car_on_track() -> void:
	var saved := Game.config.track_id
	var scene := _spawn_race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node("Track") as Track
	assert_true(track != null and track.track_id == ID, "the race scene built the Bahrain track")
	if track == null or track.data == null:
		Game.config.track_id = saved
		return
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	Game.config.track_id = saved

## One standing lap by the autopilot: never off the road, never into a wall.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	var saved := Game.config.track_id
	Bootstrap.autodrive = true
	var scene := _spawn_race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var data := (scene.get_node("Track") as Track).data
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	if pilot == null:
		Bootstrap.autodrive = false
		Game.config.track_id = saved
		return
	var waited := 0
	while car.linear_velocity.length() < 1.0 and waited < 240 * 12:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 12, "car never started moving")
	var s := data.closest_s(car.global_position)
	var time := 0.0
	var progress := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var top := 0.0
	var hardest := 0.0   # largest speed lost in one tick (m/s): a wall hit shows as a spike
	var hardest_s := 0.0
	var prev_speed := car.linear_velocity.length()
	while time < 240.0 and pilot.laps_completed < 1:
		await physics_frames(1)
		time += TICK
		var pos := car.global_position
		var ns := data.closest_s(pos, s)
		progress += data.delta_s(s, ns)
		s = ns
		var edge := data.width_at(s) * 0.5 - absf(data.lateral_offset(pos, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		var speed := car.linear_velocity.length()
		top = maxf(top, speed)
		if prev_speed - speed > hardest:
			hardest = prev_speed - speed
			hardest_s = s
		prev_speed = speed
	assert_true(pilot.laps_completed >= 1, "lap not completed in 240 s of physics (progress %.0f m)" % progress)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	# Full braking is about 0.2 m/s per tick; hitting a barrier loses several m/s at once.
	assert_true(hardest < 1.5, "hit something: lost %.1f m/s in one tick at s=%.0f" % [hardest, hardest_s])
	assert_between(pilot.lap_time, 85.0, 130.0, "lap time (s)")
	assert_true(top * 3.6 > 280.0, "top speed %.0f km/h, expected > 280" % (top * 3.6))
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nBAHRAIN LAP 1 (from the grid)\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, %.0f m driven, min edge margin %.2f m at s=%.0f, hardest tick -%.2f m/s at s=%.0f\n" % [
			pilot.lap_time, top * 3.6, progress, worst_edge, worst_edge_s, hardest, hardest_s])
	Bootstrap.autodrive = false
	Game.config.track_id = saved
