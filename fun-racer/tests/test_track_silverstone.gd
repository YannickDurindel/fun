extends TestCase
## Silverstone Circuit (Grand Prix "Arena" layout): centreline data, catalog entry and the race
## scene. Built by tools/track/build_track.py from tools/track/tracks/silverstone.toml.

const ID := "silverstone"
const PATH := "res://assets/tracks/silverstone/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5891.0

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
	# Published: about 11 m between the lowest and the highest point.
	assert_between(hi - lo, 7.0, 18.0, "elevation range (m)")
	assert_true(d.turns.size() == 18, "expected 18 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	var names := {0: "Abbey", 3: "The Loop", 5: "Brooklands", 6: "Luffield", 8: "Copse", 14: "Stowe", 17: "Club"}
	for i: int in names:
		assert_true(d.turns[i]["name"] == names[i], "T%d must be %s, is %s" % [i + 1, names[i], d.turns[i]["name"]])
	# Clockwise: Abbey, Copse and Stowe are right-handers; The Loop and Brooklands turn left.
	for i: int in [0, 8, 14]:
		assert_true(d.turns[i]["direction"] == "right", "T%d turns right" % (i + 1))
	for i: int in [3, 5]:
		assert_true(d.turns[i]["direction"] == "left", "T%d turns left" % (i + 1))
	# The grid is on the Hamilton Straight, ahead of the timing line and before Abbey.
	assert_between(d.start_s, 100.0, 200.0, "start line after the finish line (m)")
	assert_true(float(d.turns[0]["s_apex"]) > d.start_s + 150.0, "Abbey comes after the grid")
	# Copse is the northern end of the lap, Stowe the southern one (z = -north).
	var copse := d.position_at(float(d.turns[8]["s_apex"]))
	var stowe := d.position_at(float(d.turns[14]["s_apex"]))
	assert_true(copse.z < -800.0 and stowe.z > 500.0, "Copse north (z=%.0f), Stowe south (z=%.0f)" % [copse.z, stowe.z])

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	if d == null:
		assert_true(false, "track.json failed to load")
		return
	for s: float in [0.0, 333.3, 1065.0, 2500.5, 3900.0, 5880.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

func test_catalog_lists_it_as_playable() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "Silverstone is listed and playable")
	if info != null:
		assert_true(info.name == "Silverstone Circuit" and info.turns == 18, "info fields")
		assert_true(info.track_json == PATH, "track.json path: %s" % info.track_json)

func test_race_scene_spawns_car_on_track() -> void:
	var saved_config := Game.config   # the race scene points Game.config at its track
	Game.config = saved_config.copy()
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == ID and track.data != null, "race scene built Silverstone")
	if track != null and track.data != null:
		var road := track.get_node("Road") as RoadSurface
		assert_true(road != null and not road.is_runtime_mesh, "road comes from road_mesh.glb")
		assert_true(not (track.get_node("Terrain") as Terrain).is_fallback, "terrain is the baked one")
		await physics_frames(240)
		var car := scene.get_node("Car") as Car
		var s := track.data.closest_s(car.global_position)
		assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
		assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
		var road_y := track.data.position_at(s).y
		assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	scene.queue_free()
	Game.config = saved_config
