extends TestCase
## Circuit Zandvoort: centreline data, the menu entry and the race scene.
## The autopilot lap runs only with `--full-lap`:
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_zandvoort --full-lap

const ID := "zandvoort"
const PATH := "res://assets/tracks/zandvoort/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 4259.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

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
	# The lidar (AHN) gives 8.5 m between the lowest and highest point of the real lap.
	assert_between(hi - lo, 7.0, 10.0, "elevation range (m)")
	assert_true(d.turns.size() == 14, "expected 14 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	var names := {"T1": "Tarzanbocht", "T3": "Hugenholtzbocht", "T4": "Hunserug", "T7": "Scheivlak",
			"T14": "Arie Luyendykbocht"}
	var dirs := {"T1": "right", "T3": "left", "T7": "right", "T10": "left", "T11": "right",
			"T12": "left", "T14": "right"}
	for t in d.turns:
		var id := String(t["id"])
		if names.has(id):
			assert_true(t["name"] == names[id], "%s must be %s, is %s" % [id, names[id], t["name"]])
		if dirs.has(id):
			assert_true(t["direction"] == dirs[id], "%s must turn %s" % [id, dirs[id]])
	# Clockwise seen from above: with x = east and z = south the shoelace sum is positive.
	var area := 0.0
	for i in d.points.size():
		var a := d.points[i]
		var b := d.points[(i + 1) % d.points.size()]
		area += a.x * b.z - b.x * a.z
	assert_true(area > 0.0, "the lap must run clockwise")
	# The pit straight runs north-north-east towards Tarzan, the northernmost point of the lap.
	var tan0 := d.tangent_at(d.start_s)
	assert_true(tan0.z < -0.8 and tan0.x > 0.0, "grid must point north-north-east (%s)" % tan0)
	var tarzan := d.position_at(float(d.turns[0]["s_apex"]))
	var north := INF
	for p in d.points:
		north = minf(north, p.z)
	assert_true(tarzan.z < north + 30.0, "Tarzan must be the north end of the lap")
	# Hunserug is a crest: well above both Hugenholtz before it and Slotemaker after it.
	var hunserug := d.position_at(float(d.turns[3]["s_apex"])).y
	assert_true(hunserug > d.position_at(float(d.turns[2]["s_apex"])).y + 3.0, "Hunserug above Hugenholtz")
	assert_true(hunserug > d.position_at(float(d.turns[4]["s_apex"])).y + 3.0, "Hunserug above Slotemaker")

func test_listed_as_playable() -> void:
	TrackCatalog.reload()
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "Zandvoort must be playable in the track list")
	if info != null:
		assert_true(info.name == "Circuit Zandvoort" and info.turns == 14 and is_equal_approx(info.length_m, OFFICIAL_LENGTH),
				"menu entry: %s, %d turns, %.0f m" % [info.name, info.turns, info.length_m])

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID, "race scene instanced Zandvoort")
	if track == null:
		return
	var terrain := track.get_node("Terrain") as Terrain
	assert_true(terrain != null and not terrain.is_fallback, "baked terrain loaded")
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")

## One autopilot lap from the grid plus a flying lap: never off the road (so never at a wall,
## which stands at least 1.5 m outside the edge), no stop, every turn visited.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap)")
		return
	Bootstrap.autodrive = true
	var scene := _race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var data := (scene.get_node("Track") as Track).data
	var waited := 0
	while car.linear_velocity.length() < 1.0 and waited < 240 * 12:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 12, "car never started moving")
	var time := 0.0
	var worst_edge := INF
	var worst_edge_s := 0.0
	var top := 0.0
	var slowest := INF
	var s := data.closest_s(car.global_position)
	var lap_times: Array[float] = []
	while time < 260.0 and lap_times.size() < 2:
		await physics_frames(1)
		time += TICK
		var pos := car.global_position
		s = data.closest_s(pos, s)
		var edge := data.width_at(s) * 0.5 - absf(data.lateral_offset(pos, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_edge_s = s
		var v := car.linear_velocity.length()
		top = maxf(top, v)
		if time > 5.0:
			slowest = minf(slowest, v)
		if pilot.laps_completed > lap_times.size():
			lap_times.append(pilot.lap_time)
			print("\nLAP %d\n%s" % [lap_times.size(), pilot.report()])
	Bootstrap.autodrive = false
	assert_true(lap_times.size() == 2, "two laps not completed in 260 s of physics (%d done)" % lap_times.size())
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	assert_true(slowest > 8.0, "car nearly stopped (%.0f km/h): a wall or a spin" % (slowest * 3.6))
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	if lap_times.size() == 2:
		assert_between(lap_times[0], 60.0, 100.0, "standing lap time (s)")
		assert_true(lap_times[1] < lap_times[0] + 0.5, "flying lap must not be slower than the standing lap")
		print("       standing lap %.2f s, flying lap %.2f s, top speed %.0f km/h, slowest %.0f km/h, min edge margin %.2f m at s=%.0f" % [
				lap_times[0], lap_times[1], top * 3.6, slowest * 3.6, worst_edge, worst_edge_s])
