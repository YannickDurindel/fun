extends TestCase
## Yas Marina Circuit (assets/tracks/yas_marina, built by tools/track/build_track.py): the
## centreline against the published figures, the catalog entry and the race scene.
## The autopilot lap runs with `--full-lap` (fixed-fps, see tools/lap_demo.sh):
##   tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync \
##       -s res://tests/runner.gd -- --filter=track_yas_marina --full-lap

const ID := "yas_marina"
const PATH := "res://assets/tracks/yas_marina/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5281.0
const TICK := 1.0 / 240.0

func _race() -> Node:
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

## Removes a race scene, so the next test starts with an empty grid.
func _free_race(scene: Node) -> void:
	Bootstrap.autodrive = false
	scene.queue_free()
	await physics_frames(2)

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
	# Published elevation change: 10.7 m. The DEM gives a little less on this flat island.
	assert_between(hi - lo, 4.0, 14.0, "elevation range (m)")
	assert_true(d.turns.size() == 16, "expected 16 turns, got %d" % d.turns.size())
	if d.turns.size() != 16:
		return
	var last := -1.0
	var lefts := 0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
		if String(t["direction"]) == "left":
			lefts += 1
	assert_true(lefts == 9, "anticlockwise lap: 9 left and 7 right turns, got %d left" % lefts)
	assert_true(d.turns[4]["name"] == "North Hairpin" and d.turns[4]["direction"] == "left", "T5 is the hairpin")
	assert_true(d.turns[8]["name"] == "Marsa Corner", "T9 must be Marsa Corner")
	# The longest straight (1.14 km published) lies between the hairpin and the chicane.
	var straight := float(d.turns[5]["s_apex"]) - float(d.turns[4]["s_apex"])
	assert_between(straight, 1100.0, 1300.0, "T5 apex to T6 apex (m)")
	# The grid is 115 m after the timing line.
	assert_between(d.delta_s(0.0, d.start_s), 114.0, 116.0, "start line after the finish line (m)")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 430.0, 1507.0, 2735.0, 3728.0, 4418.0, 5270.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])

func test_catalog_lists_track_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null, "yas_marina is in the catalog")
	if info == null:
		return
	assert_true(info.available, "yas_marina is playable")
	assert_true(info.name == "Yas Marina Circuit", "catalog name: %s" % info.name)
	assert_true(ResourceLoader.exists(info.scene), "track scene exists: %s" % info.scene)

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.data != null, "race scene built the Yas Marina track")
	if track == null or track.data == null:
		await _free_race(scene)
		return
	assert_true(track.track_id == ID, "track id: %s" % track.track_id)
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	await _free_race(scene)

## One standing lap by the autopilot: never off the road, never into a wall.
func test_full_lap() -> void:
	if not "--full-lap" in OS.get_cmdline_user_args():
		print("       (skipped: pass --full-lap with --fixed-fps 240)")
		return
	Bootstrap.autodrive = true
	var scene := _race()
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node_or_null("Autodrive") as Autopilot
	var track := scene.get_node_or_null("Track") as Track
	assert_true(pilot != null, "Autodrive node must run the Autopilot")
	assert_true(track != null and track.data != null, "race scene built the Yas Marina track")
	if pilot == null or track == null or track.data == null:
		await _free_race(scene)
		return
	var data := track.data
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
	var top_speed := 0.0
	var worst_drop := 0.0      # largest loss of speed in one tick: a wall hit shows up here
	var worst_drop_s := 0.0
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
		top_speed = maxf(top_speed, speed)
		if prev_speed - speed > worst_drop:
			worst_drop = prev_speed - speed
			worst_drop_s = s
		prev_speed = speed
	assert_true(pilot.laps_completed >= 1, "lap not completed in 240 s of physics (progress %.0f m)" % progress)
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_edge_s])
	# Full braking is under 0.1 m/s per tick; an impact loses several m/s at once.
	assert_true(worst_drop < 1.0, "speed dropped %.2f m/s in one tick at s=%.0f (collision?)" % [worst_drop, worst_drop_s])
	assert_between(pilot.lap_time, 80.0, 130.0, "lap time (s)")
	for st in pilot.last_lap_turn_stats:
		assert_true(float(st["min_kmh"]) > 0.0, "turn %s visited" % st["id"])
	print("\nYAS MARINA, lap 1 from the grid\n" + pilot.report())
	print("       lap %.2f s, top speed %.0f km/h, %.0f m driven, min edge margin %.2f m at s=%.0f, worst speed loss %.2f m/s per tick at s=%.0f\n" % [
			pilot.lap_time, top_speed * 3.6, progress, worst_edge, worst_edge_s, worst_drop, worst_drop_s])
	await _free_race(scene)
