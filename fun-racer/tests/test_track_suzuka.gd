extends TestCase
## Suzuka Circuit: centreline data, the crossover (the lap is a figure of eight: the back
## straight crosses the road between Degner 2 and the hairpin on a bridge), and the race scene.

const ID := "suzuka"
const PATH := "res://assets/tracks/suzuka/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5807.0
const S_LOWER := 2509.7   ## the road under the bridge, metres from the finish line
const S_UPPER := 4888.7   ## the bridge deck

func _race() -> Node:
	var scene := (load(RACE) as PackedScene).instantiate()
	scene.set(&"track_id", ID)
	add_child(scene)
	return scene

func _built(ts: Trackside) -> void:
	var frames := 0
	while ts != null and not ts.is_built and frames < 900:
		await get_tree().physics_frame
		frames += 1
	assert_true(ts != null and ts.is_built, "Trackside finished building")

func test_dimensions_match_real_circuit() -> void:
	var info := TrackCatalog.find(ID)
	assert_true(info != null and info.available, "suzuka is a playable track of the catalog")
	var d := TrackData.load_track(PATH)
	assert_true(d != null, "track.json failed to load")
	assert_between(d.length, OFFICIAL_LENGTH * 0.99, OFFICIAL_LENGTH * 1.01, "lap length (m)")
	assert_between(d.points.size() * d.step, d.length - 0.01, d.length + 0.01, "points cover the lap")
	assert_true(d.points[0].distance_to(d.points[d.points.size() - 1]) < d.step * 1.5, "loop must be closed")
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	assert_between(hi - lo, 32.0, 50.0, "elevation range (m), about 40 m published")
	assert_true(d.turns.size() == 18, "expected 18 turns, got %d" % d.turns.size())
	var last := -1.0
	for t in d.turns:
		assert_true(float(t["s_apex"]) > last, "turns must be in lap order (%s)" % t["id"])
		last = float(t["s_apex"])
	var names := {"T1": "First Curve", "T7": "Dunlop", "T9": "Degner 2", "T11": "Hairpin",
			"T14": "Spoon Curve", "T15": "130R", "T17": "Casio Triangle"}
	for t in d.turns:
		if names.has(t["id"]):
			assert_true(t["name"] == names[t["id"]], "%s must be %s, is %s" % [t["id"], names[t["id"]], t["name"]])
	# The first half of the eight runs clockwise, the second anticlockwise.
	assert_true(d.turns[0]["direction"] == "right" and d.turns[1]["direction"] == "right", "T1 and T2 turn right")
	assert_true(d.turns[10]["direction"] == "left", "the hairpin turns left")
	assert_true(d.turns[13]["direction"] == "left" and d.turns[14]["direction"] == "left", "Spoon and 130R turn left")
	# The grid is 300 m after the timing line, on the main straight, which runs downhill to T1.
	assert_between(d.start_s, 295.0, 305.0, "start line (m after the finish line)")
	assert_true(d.position_at(float(d.turns[0]["s_apex"])).y < d.position_at(0.0).y - 8.0, "T1 is below the finish line")
	assert_true(d.position_at(float(d.turns[13]["s_apex"])).y > hi - 8.0, "Spoon is near the top of the circuit")

func test_sampling_round_trip() -> void:
	var d := TrackData.load_track(PATH)
	for s: float in [0.0, 333.3, 1390.0, S_LOWER, 3900.5, S_UPPER, 5800.0]:
		var xf := d.sample(s)
		assert_true(absf(xf.basis.y.dot(Vector3.UP)) > 0.95, "road normal mostly up at s=%.0f" % s)
		var back := d.closest_s(xf.origin + xf.basis.x * 3.0)
		assert_true(absf(d.delta_s(s, back)) < 1.0, "closest_s round trip at %.0f -> %.2f" % [s, back])
		assert_between(d.lateral_offset(xf.origin + xf.basis.x * 3.0, s), 2.9, 3.1, "lateral offset at s=%.0f" % s)

## The two roads cross in plan view once, 6 to 8 m apart in height.
func test_crossover_geometry() -> void:
	var d := TrackData.load_track(PATH)
	var low := d.position_at(S_LOWER)
	var high := d.position_at(S_UPPER)
	assert_true(Vector2(low.x - high.x, low.z - high.z).length() < 2.5,
			"the two roads cross in plan view (%.1f m apart)" % Vector2(low.x - high.x, low.z - high.z).length())
	assert_between(high.y - low.y, 6.0, 8.0, "height of the bridge over the lower road (m)")
	for off: float in [-150.0, -75.0, 0.0, 75.0, 150.0]:
		assert_true(absf(d.grade_at(S_UPPER + off)) < 0.04, "no steep ramp on the back straight at %+.0f m" % off)
		assert_true(absf(d.grade_at(S_LOWER + off)) < 0.06, "no steep ramp under the bridge at %+.0f m" % off)

func test_race_scene_spawns_car_on_track() -> void:
	var scene := _race()
	await physics_frames(240)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node("Track") as Track
	assert_true(track != null and track.track_id == ID, "the race scene built Suzuka")
	if track == null or track.data == null:
		return
	var s := track.data.closest_s(car.global_position)
	assert_true(absf(track.data.lateral_offset(car.global_position)) < 6.5, "car on the road after spawn")
	assert_true(absf(track.data.delta_s(track.data.start_s, s)) < 30.0, "car spawns near the start line (s=%.1f)" % s)
	var road_y := track.data.position_at(s).y
	assert_between(car.global_position.y - road_y, 0.2, 0.6, "car resting on road surface")
	var road := track.get_node("Road") as RoadSurface
	assert_true(not road.is_runtime_mesh, "the road comes from road_mesh.glb")
	assert_true(not (track.get_node("Terrain") as Terrain).is_fallback, "the terrain comes from terrain.json")

## Both levels of the crossover: a surface to drive on, nothing in the way, walls on both sides.
func test_crossover_is_drivable_on_both_levels() -> void:
	var scene := _race()
	var track := scene.get_node("Track") as Track
	var road := track.get_node("Road") as RoadSurface
	var ts := track.get_node("Trackside") as Trackside
	var terrain := track.get_node("Terrain") as Terrain
	await _built(ts)
	var d := track.data
	assert_true(road.bridges.size() == 1, "one bridge, got %d" % road.bridges.size())
	if road.bridges.is_empty():
		return
	var deck: Array = road.bridges[0]["deck"]
	assert_true(road.on_bridge(S_UPPER) and not road.on_bridge(S_LOWER), "the back straight is the upper road")
	assert_true(float(deck[1]) - float(deck[0]) < 160.0, "deck length %.0f m" % (float(deck[1]) - float(deck[0])))
	var space := scene.get_viewport().world_3d.direct_space_state
	# Lower road, 80 m either side of the crossing: tarmac under the wheels across the whole
	# width, and at least 4.5 m of free height above it.
	for k in range(-40, 41):
		var s := S_LOWER + k * 2.0
		var hw := road.half_width_at(s)
		for lat: float in [-hw + 0.5, 0.0, hw - 0.5]:
			var p := road.surface_point(s, lat)
			var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.0, p + Vector3.DOWN * 1.0))
			assert_true(not down.is_empty() and absf((down["position"] as Vector3).y - p.y) < 0.05
					and (down["collider"] as Node).get_meta("surface", "") == "asphalt",
					"lower road: tarmac at s=%.0f lat=%.1f" % [s, lat])
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.3, p + Vector3.UP * 4.5)
			q.hit_back_faces = true
			q.hit_from_inside = true
			var above := space.intersect_ray(q)
			assert_true(above.is_empty(), "lower road: something %.1f m above the tarmac at s=%.0f lat=%.1f (%s)" % [
					((above.get("position", p) as Vector3).y - p.y), s, lat, above.get("collider", null)])
		assert_true(terrain.height_at(d.position_at(s).x, d.position_at(s).z) < d.position_at(s).y,
				"terrain below the lower road at s=%.0f" % s)
	# Upper road over the same distance: tarmac from above, first thing hit.
	for k in range(-40, 41):
		var s := S_UPPER + k * 2.0
		var hw := road.half_width_at(s)
		for lat: float in [-hw + 0.5, 0.0, hw - 0.5]:
			var p := road.surface_point(s, lat)
			var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 5.0, p + Vector3.DOWN * 1.0))
			assert_true(not down.is_empty() and absf((down["position"] as Vector3).y - p.y) < 0.05
					and (down["collider"] as Node).get_meta("surface", "") == "asphalt",
					"upper road: tarmac at s=%.0f lat=%.1f" % [s, lat])
	# Barriers: beside the road everywhere on both levels (never across it), close on the deck.
	for base: float in [S_LOWER, S_UPPER]:
		for k in range(-70, 71):
			var s := base + k * 2.0
			for side: float in [-1.0, 1.0]:
				var gap := ts.barrier_offset(s, side) - ts.edge_at(s)
				assert_true(gap >= 0.9, "barrier %.2f m from the road edge at s=%.0f (side %d)" % [gap, s, side])
				if road.s_in_range(s, road.bridges[0]["span"]):   # above open ground: the parapet
					assert_true(gap <= 2.5, "parapet %.2f m from the edge on the deck at s=%.0f" % [gap, s])
	# A wall is in the way of a car leaving the road sideways, on both levels at the crossing.
	for s: float in [S_LOWER, S_UPPER, S_UPPER - 40.0, S_UPPER + 30.0]:
		var xf := ts.frame_at(s)
		for side: float in [-1.0, 1.0]:
			var from := xf.origin + Vector3.UP * 0.5
			var q := PhysicsRayQueryParameters3D.create(from, from + xf.basis.x * side * 30.0)
			q.collision_mask = Trackside.LAYER_BARRIER
			var hit := space.intersect_ray(q)
			assert_true(not hit.is_empty(), "no barrier beside the road at s=%.0f (side %d)" % [s, side])
			if not hit.is_empty():
				assert_true(from.distance_to(hit["position"]) < 12.0, "barrier %.1f m away at s=%.0f (side %d)" % [
						from.distance_to(hit["position"]), s, side])
