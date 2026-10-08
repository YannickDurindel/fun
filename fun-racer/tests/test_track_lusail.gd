extends TestCase
## Lusail International Circuit (assets/tracks/lusail, built by tools/track/tracks/lusail.toml):
## the centreline data and the race scene on it.

const ID := "lusail"
const PATH := "res://assets/tracks/lusail/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5419.0
## Official turn directions, T1 .. T16 (10 right, 6 left).
const DIRECTIONS := ["right", "left", "right", "right", "right", "left", "right", "left",
		"right", "left", "left", "right", "right", "right", "left", "right"]

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
	# Nearly flat desert site: a few metres at most, and never dead flat.
	assert_between(hi - lo, 1.0, 10.0, "elevation range (m)")
	# No fake crests from DEM noise: the steepest 20 m of the lap stays under 2 %.
	var steepest := 0.0
	var s := 0.0
	while s < d.length:
		steepest = maxf(steepest, absf(d.position_at(s + 20.0).y - d.position_at(s).y) / 20.0)
		s += 10.0
	assert_true(steepest < 0.02, "steepest grade %.1f %%, expected under 2 %%" % (steepest * 100.0))
	assert_true(d.turns.size() == 16, "expected 16 turns, got %d" % d.turns.size())
	var last := -1.0
	for i in d.turns.size():
		var t: Dictionary = d.turns[i]
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
		assert_true(t["id"] == "T%d" % (i + 1), "turn %d is numbered %s" % [i + 1, t["id"]])
		if i < DIRECTIONS.size():
			assert_true(t["direction"] == DIRECTIONS[i], "%s turns %s, expected %s" % [t["id"], t["direction"], DIRECTIONS[i]])
	# The lap starts on the main straight: at least 450 m from the line to the first apex and
	# at least 450 m from the last apex back to the line.
	assert_true(float(d.turns[0]["s_apex"]) > 450.0, "T1 apex at s=%.0f" % float(d.turns[0]["s_apex"]))
	assert_true(d.length - last > 450.0, "T16 apex %.0f m before the line" % (d.length - last))

func test_clockwise() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	# Signed area in the x (east) / z (south) plane: positive = clockwise seen from above.
	var area := 0.0
	var n := d.points.size()
	for i in n:
		var a := d.points[i]
		var b := d.points[(i + 1) % n]
		area += a.x * b.z - b.x * a.z
	assert_true(area > 0.0, "lap must run clockwise (signed area %.0f)" % (area * 0.5))

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 333.3, 1928.0, 3120.0, 5400.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

func test_catalog_lists_the_track() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "lusail is playable in the catalog")
	if info != null:
		assert_true(info.name == "Lusail International Circuit", "name (%s)" % info.name)
		assert_true(info.turns == 16 and is_equal_approx(info.length_m, OFFICIAL_LENGTH), "official length and turn count")

func test_race_scene_spawns_car_on_track() -> void:
	var saved_config := Game.config   # the race scene points Game.config at its track
	Game.config = saved_config.copy()
	var scene: Node = (load(RACE) as PackedScene).instantiate()
	scene.set("track_id", ID)
	add_child(scene)
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID and track.data != null, "race scene built lusail")
	if track != null and track.data != null:
		var race := track.get_node("Race") as RaceManager
		race.persist_best = false
		await physics_frames(240)
		var car := scene.get_node("Car") as Car
		var s := track.data.closest_s(car.global_position)
		assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
		assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
		var road_y := track.data.position_at(s).y
		assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
		var terrain := track.get_node("Terrain") as Terrain
		assert_true(terrain != null and not terrain.is_fallback, "baked terrain loaded")
		var trackside := track.get_node("Trackside") as Trackside
		var frames := 0
		while trackside != null and not trackside.is_built and frames < 600:
			await get_tree().physics_frame
			frames += 1
		assert_true(trackside != null and trackside.is_built, "trackside built")
	scene.queue_free()
	Game.config = saved_config
