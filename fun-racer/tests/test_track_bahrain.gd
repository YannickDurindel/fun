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
	# Published: 17 to 18 m ("relief from 0 to 18 m", the circuit's data sheet). The recipe pins
	# the two hilltops of the DEM profile so that the lap has that range (18.1 m built).
	assert_between(hi - lo, 16.5, 19.5, "elevation range (m)")
	assert_true(d.turns.size() == 15, "expected 15 turns, got %d" % d.turns.size())
	var last := -1.0
	for i in d.turns.size():
		var t: Dictionary = d.turns[i]
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
		if i < DIRECTIONS.size():
			assert_true(String(t["direction"]) == DIRECTIONS[i], "%s must turn %s" % [t["id"], DIRECTIONS[i]])
	assert_true(d.turns[0]["name"] == "Michael Schumacher", "T1 must be the Michael Schumacher turn")
	# The race distance (57 laps - 0.246 km) makes the first lap 246 m short: the grid is
	# 246 m AFTER the finish line, which lies level with the south end of the pit building.
	assert_between(d.start_s, 236.0, 256.0, "finish line to start line (m)")
	# Pole position is about 475 m before the Turn 1 apex (353 m to the braking point).
	assert_between(float(d.turns[0]["s_apex"]) - d.start_s, 430.0, 520.0, "start line to the T1 apex (m)")
	assert_between(d.length - float(d.turns[14]["s_apex"]) + float(d.turns[0]["s_apex"]), 1000.0, 1200.0,
			"T15 apex to T1 apex along the pit straight (m)")
	# The circuit climbs from the pit straight to Turn 4 and to Turn 13.
	var grid_y := d.position_at(d.start_s).y
	assert_true(d.position_at(float(d.turns[3]["s_apex"])).y > grid_y + 8.0, "Turn 4 is well above the grid")
	assert_true(d.position_at(float(d.turns[12]["s_apex"])).y > grid_y + 8.0, "Turn 13 is well above the grid")

## Widths measured on aerial imagery, inside the published 14 to 22 m (see the recipe).
func test_widths_follow_the_real_circuit() -> void:
	var d := TrackData.load_track(PATH)
	var lo := INF
	var hi := -INF
	for s: float in range(0, int(d.length), 10):
		lo = minf(lo, d.width_at(s))
		hi = maxf(hi, d.width_at(s))
	assert_between(lo, 13.9, 14.1, "narrowest road (m)")
	assert_between(hi, 20.5, 22.0, "widest road (m)")
	assert_between(d.width_at(d.start_s), 14.9, 15.1, "grid (m)")
	assert_between(d.width_at(float(d.turns[0]["s_apex"])), 20.5, 21.5, "Turn 1 (m)")
	assert_between(d.width_at(float(d.turns[3]["s_apex"])), 20.5, 21.5, "Turn 4 (m)")
	assert_between(d.width_at(float(d.turns[7]["s_apex"])), 17.5, 18.5, "Turn 8 (m)")
	assert_between(d.width_at(float(d.turns[9]["s_apex"])), 13.9, 14.1, "Turn 10 (m)")
	var t11 := float(d.turns[10]["s_apex"])
	var t13 := float(d.turns[12]["s_apex"])
	assert_between(d.width_at(t11 - 370.0), 13.9, 14.1, "Turn 10 to Turn 11 straight (m)")
	assert_between(d.width_at(t13 + 370.0), 13.9, 14.1, "back straight (m)")

## The race is run at night under floodlights, in a desert: no green ground except the lawns.
func test_environment_is_a_floodlit_desert_night() -> void:
	var env := TrackEnvironment.load_file("res://assets/tracks/bahrain/environment.json")
	assert_true(env.is_night() and env.floodlit(), "night race under floodlights")
	var names := TrackEnvironment.CLASSES
	for cls: String in ["grass", "sand", "rock", "gravel", "scrub"]:
		var a: Color = env.palette(0)[names.find(cls)]
		assert_true(a.r > a.g and a.g > a.b, "%s is sand-coloured, not green (%s)" % [cls, a])
	var lawn: Color = env.palette(0)[names.find("farmland")]
	assert_true(lawn.g > lawn.r and lawn.g > lawn.b, "the irrigated lawns are green")
	var verge := env.color("verge", "grass_color")
	assert_true(verge.r > verge.g and verge.g > verge.b, "the verge is sand-coloured paint, not grass")

## Every run-off of the Grand Prix lap is tarmac, and the lap has its hand-made table.
func test_trackside_table_has_no_gravel() -> void:
	var d := TrackData.load_track(PATH)
	var layout := TracksideLayout.for_track(ID, d)
	assert_true(not layout.is_auto, "bahrain uses its hand-made trackside table")
	assert_true(layout.runoff.size() >= 10, "run-off areas: %d" % layout.runoff.size())
	for r: Dictionary in layout.runoff:
		assert_true(String(r["kind"]) == "tarmac", "run-off at %s is tarmac" % r["turn"])
	var seen := {}
	for k: Dictionary in layout.kerbs:
		seen[k["turn"]] = true
	assert_true(seen.size() == 15, "every turn has a kerb (%d of 15)" % seen.size())
	var drag := float(d.turns[10]["s_apex"]) - 370.0
	var climb := float(d.turns[3]["s_apex"]) - 300.0
	assert_true(layout.is_concrete(d.start_s) and layout.is_concrete(drag) and not layout.is_concrete(climb),
			"concrete walls on the pit straight and along the drag strip")

## The landmark models exist and stand where the real structures do.
func test_landmarks() -> void:
	var path := "res://assets/tracks/bahrain/landmarks.json"
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(parsed is Array and (parsed as Array).size() >= 14, "landmarks.json lists the landmarks")
	if not parsed is Array:
		return
	var models := {}
	for e: Dictionary in parsed:
		models[e["model"]] = e
		assert_true(ResourceLoader.exists("res://assets/tracks/bahrain/landmarks/%s.glb" % e["model"]),
				"model %s exists" % e["model"])
	for name: String in ["sakhir_tower", "main_grandstand", "batelco_stand", "pit_building", "start_gantry"]:
		assert_true(models.has(name), "%s is placed" % name)
	var d := TrackData.load_track(PATH)
	# The grandstand and the pit building face each other across the grid; the tower stands
	# inside Turn 1, right of the road.
	var grid := d.position_at(d.start_s)
	var stand := _xz(models["main_grandstand"])
	var pits := _xz(models["pit_building"])
	# Footprint centres (OSM): the grandstand 30 m deep behind its wall, the pit building 25 m
	# deep behind the pit lane.
	assert_between(d.lateral_offset(Vector3(stand.x, grid.y, stand.y)), -60.0, -25.0, "main grandstand, left of the straight (m)")
	assert_between(d.lateral_offset(Vector3(pits.x, grid.y, pits.y)), 30.0, 45.0, "pit building, right of the straight (m)")
	var tower := _xz(models["sakhir_tower"])
	var apex := d.position_at(float(d.turns[0]["s_apex"]))
	assert_between(Vector2(tower.x - apex.x, tower.y - apex.z).length(), 120.0, 220.0, "tower to the Turn 1 apex (m)")
	assert_between(float(models["start_gantry"]["at"]["s"]) - d.start_s, 0.0, 30.0, "start lights ahead of the grid (m)")

## Plan position of a landmarks.json entry placed by "latlon" (as Terrain.latlon_to_xz).
func _xz(e: Dictionary) -> Vector2:
	var t: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/tracks/bahrain/terrain.json"))
	var o: Array = t["origin_latlon"]
	var ll: Array = e["at"]["latlon"]
	var m := 111320.0 * float(t["plan_scale"])
	return Vector2((float(ll[1]) - float(o[1])) * m * cos(deg_to_rad(float(o[0]))), -(float(ll[0]) - float(o[0])) * m)

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
