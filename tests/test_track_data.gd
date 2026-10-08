extends TestCase
## Red Bull Ring centreline data and the TrackData contract.

const PATH := "res://assets/tracks/red_bull_ring/track.json"

func test_dimensions_match_real_circuit() -> void:
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	assert_between(d.length, 4318.0 - 45.0, 4318.0 + 45.0, "lap length (m)")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	assert_between(hi - lo, 55.0, 75.0, "elevation range (m)")
	assert_true(d.turns.size() == 10, "expected 10 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	assert_true(d.turns[2]["name"] == "Remus", "T3 must be Remus")
	# Remus is the highest corner on the lap.
	var remus_y := d.position_at(float(d.turns[2]["s_apex"])).y
	assert_true(remus_y > hi - 10.0, "Remus should be near the top of the hill (y=%.1f, max %.1f)" % [remus_y, hi])

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 333.3, 1390.0, 2500.5, 4300.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)
	assert_true(absf(d.delta_s(4310.0, 5.0) - 13.0) < 0.01, "delta_s wraps")

func test_race_scene_spawns_car_on_track() -> void:
	var scene := spawn("res://scenes/race_red_bull_ring.tscn")
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node("Track") as Track
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
