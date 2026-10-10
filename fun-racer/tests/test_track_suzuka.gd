extends TestCase
## Suzuka Circuit: centreline data, the crossover (the lap is a figure of eight: the back
## straight crosses the road between Degner 2 and the hairpin on a bridge), and the race scene.

const ID := "suzuka"
const PATH := "res://assets/tracks/suzuka/track.json"
const RACE := "res://scenes/race.tscn"
const OFFICIAL_LENGTH := 5807.0
const S_LOWER := 2510.8   ## the road under the bridge, metres from the finish line
const S_UPPER := 4889.0   ## the bridge deck

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
	# 40.4 m published; the road is pinned to the GSI 5 m laser ground model, which gives 40.6 m
	# (the 30 m tile model the track was first built from gave 42.5 m).
	assert_between(hi - lo, 39.0, 42.0, "elevation range (m)")
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
	assert_true(d.position_at(float(d.turns[13]["s_apex"])).y > hi - 1.0, "Spoon is the top of the circuit")
	assert_true(d.position_at(float(d.turns[1]["s_apex"])).y < lo + 1.5, "Second Curve is the lowest point of the lap")

## Widths measured on the GSI orthophoto and gradients of the laser ground model (the sources
## are in tools/track/tracks/suzuka.toml). The track was first built 13 m wide all round.
func test_real_widths_and_gradients() -> void:
	var d := TrackData.load_track(PATH)
	assert_between(d.width_at(0.0), 14.5, 15.5, "pit straight (m)")
	assert_between(d.width_at(d.start_s), 14.5, 15.5, "grid (m)")
	assert_between(d.width_at(520.0), 12.0, 13.0, "braking zone of First Curve (m)")
	for s: float in [1000.0, 1200.0, 1400.0, 1600.0, 1800.0]:
		assert_between(d.width_at(s), 10.0, 11.0, "S Curves to Dunlop at s=%.0f (m)" % s)
	assert_between(d.width_at(2700.0), 9.0, 10.0, "110R climb, the narrowest part (m)")
	assert_between(d.width_at(2905.0), 14.5, 15.5, "hairpin apex (m)")
	assert_between(d.width_at(4500.0), 9.5, 10.5, "back straight (m)")
	var lo := INF
	var hi := -INF
	for w in d.widths:
		lo = minf(lo, w)
		hi = maxf(hi, w)
	assert_between(lo, 9.0, 10.0, "narrowest (m): 10 m published, 8.9 m measured between the lines")
	assert_between(hi, 14.5, 16.0, "widest (m): 14 to 16 m published")
	# The pit straight falls 2.8 % all the way to First Curve (Takenaka, 2009 grandstand).
	for s: float in [100.0, 250.0, 400.0, 550.0]:
		assert_between(d.grade_at(s), -0.034, -0.022, "pit straight gradient at s=%.0f" % s)
	# Dunlop is the steepest climb of the lap: 7.8 % published.
	var steepest := 0.0
	var where := 0.0
	for i in d.grades.size():
		if d.grades[i] > steepest:
			steepest = d.grades[i]
			where = i * d.step
	assert_between(steepest, 0.07, 0.09, "steepest climb")
	assert_between(where, 1700.0, 1820.0, "the steepest climb is Dunlop (s)")

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
	# 6.2 m in the laser ground model (deck against the road under it).
	assert_between(high.y - low.y, 5.6, 6.8, "height of the bridge over the lower road (m)")
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

## The hand-made trackside table, the per-track look and the landmarks are in use.
func test_surroundings_are_suzuka() -> void:
	var scene := _race()
	var track := scene.get_node("Track") as Track
	var ts := track.get_node("Trackside") as Trackside
	await _built(ts)
	assert_true(not ts.layout.is_auto, "Suzuka has its own trackside table")
	var kinds := {}
	for r in ts.layout.runoff:
		kinds["%s %s" % [r["turn"], r["kind"]]] = true
	for want: String in ["T1 gravel", "T2 tarmac", "T7 gravel", "T8 gravel", "T11 gravel", "T14 tarmac", "T15 gravel"]:
		assert_true(kinds.has(want), "run-off: %s" % want)
	# The wall of the pit straight is 4 m from the road on the left; on the right it stands
	# behind the pit lane.
	assert_between(ts.barrier_offset(100.0, -1.0) - ts.edge_at(100.0), 3.0, 5.0, "left wall on the pit straight (m)")
	assert_true(ts.barrier_offset(100.0, 1.0) - ts.edge_at(100.0) > 14.0, "the pit lane is inside the barrier line")
	assert_true(ts.layout.is_concrete(100.0) and not ts.layout.is_concrete(4500.0), "concrete wall on the pit straight, armco on the back straight")
	var env := track.environment
	assert_true(env.active and env.time == "day", "a day race")
	assert_between(env.number("sun", "azimuth_deg"), 200.0, 260.0, "afternoon sun in the south-west")
	var scenery := track.scenery
	var frames := 0
	while scenery != null and not scenery.is_built and frames < 900:
		await get_tree().physics_frame
		frames += 1
	assert_true(scenery != null and scenery.is_built, "Scenery finished building")
	if scenery == null:
		return
	assert_true(scenery.landmark_count == 3, "Ferris wheel and two gantries, got %d" % scenery.landmark_count)
	# The Ferris wheel stands behind the grandstands of Last Curve, 51 m tall.
	var landmarks := scenery.get_node_or_null("Landmarks")
	var wheel: Node3D = null
	if landmarks != null:
		for c in landmarks.get_children():
			if String(c.name).begins_with("ferris_wheel"):
				wheel = c as Node3D
	assert_true(wheel != null, "the Ferris wheel landmark is there")
	if wheel == null:
		return
	var box := AABB()
	var first := true
	for mi in Scenery.mesh_instances(wheel):
		var b := mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	assert_between(box.size.y, 49.0, 54.0, "height of the Ferris wheel (m)")
	var s_wheel := track.data.closest_s(wheel.global_position)
	assert_true(s_wheel > 5600.0 and s_wheel < 5780.0, "the wheel is beside Last Curve (s=%.0f)" % s_wheel)
	assert_between(track.data.lateral_offset(wheel.global_position, s_wheel), -110.0, -60.0, "the wheel is on the left, behind the stands")
