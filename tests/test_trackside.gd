extends TestCase
## Trackside: kerbs on every turn with "kerb" collision, continuous barriers on both sides,
## and a car fired into a barrier at 100 km/h does not pass through it.

const TRACK := "res://scenes/tracks/red_bull_ring.tscn"
const RACE := "res://scenes/race_red_bull_ring.tscn"

func _trackside(root: Node) -> Trackside:
	var ts := root.find_child("Trackside", true, false) as Trackside
	assert_true(ts != null, "Trackside node present")
	var frames := 0
	while ts != null and not ts.is_built and frames < 600:   # polled, so a failed build can't hang
		await get_tree().physics_frame
		frames += 1
	assert_true(ts != null and ts.is_built, "Trackside finished building")
	return ts

func test_every_turn_has_a_kerb() -> void:
	var d := TrackData.load_track("res://assets/tracks/red_bull_ring/track.json")
	var kerbs := TracksideLayout.resolve_kerbs(d)
	for t: Dictionary in d.turns:
		var n := 0
		for k in kerbs:
			if k["turn"] == t["id"] and k["kind"] != "sausage":
				n += 1
		assert_true(n >= 1, "turn %s has no kerb" % t["id"])
	var yellow := {}
	for k in kerbs:
		if k["kind"] == "sausage":
			yellow[k["turn"]] = true
	for id: String in ["T1", "T3", "T4", "T9", "T10"]:
		assert_true(yellow.has(id), "%s should have a yellow sausage kerb" % id)

func test_kerb_collision_surface() -> void:
	var track := spawn(TRACK) as Track
	var ts: Trackside = await _trackside(track)
	await physics_frames(2)
	var space := track.get_world_3d().direct_space_state
	var d := track.data
	var checked := 0
	for k in ts.kerbs:
		if k["kind"] == "sausage":
			continue
		var s: float = float(k["s0"]) + float(k["len"]) * 0.5
		var xf := ts.frame_at(s)
		var p := ts.lateral_point(s, float(k["side"]), ts.edge_at(s) + 0.8, xf)
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2.0, p - Vector3.UP * 2.0)
		var hit := space.intersect_ray(q)
		assert_true(not hit.is_empty(), "ray onto %s kerb hits something" % k["turn"])
		if hit.is_empty():
			continue
		var col := hit["collider"] as Object
		assert_true(col.get_meta("surface", "") == "kerb",
				"%s kerb at s=%.0f reports surface '%s'" % [k["turn"], s, col.get_meta("surface", "")])
		# Raised only a few cm above the real (cambered) road surface under it; `p` comes from
		# the Road's surface_point when the CAD road is present.
		# The sawtooth peak on the Remus hairpin's inside sits on the verge pocket, ~13 cm above
		# the extrapolated road plane (10 cm above the grass under it), like a real sausage kerb.
		assert_between((hit["position"] - p).dot(xf.basis.y), -0.03, 0.15, "%s kerb height above road surface" % k["turn"])
		checked += 1
	assert_true(checked >= 10, "checked %d kerbs" % checked)
	track.queue_free()

func test_barriers_are_continuous() -> void:
	var track := spawn(TRACK) as Track
	var ts: Trackside = await _trackside(track)
	await physics_frames(2)
	var space := track.get_world_3d().direct_space_state
	var d := track.data
	var misses: Array[String] = []
	var s := 0.0
	while s < d.length:
		var xf := ts.frame_at(s)
		var rh := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized()
		for side: float in [-1.0, 1.0]:
			# Several heights: on cambered / descending sections the wall base can sit ~0.3 m
			# below the road centre, so one fixed-height ray may pass just over the top.
			var from := xf.origin + Vector3.UP * 0.5
			var hit := {}
			for h: float in [0.5, 0.25, 0.0, -0.25]:
				from = xf.origin + Vector3.UP * h
				var q := PhysicsRayQueryParameters3D.create(from, from + rh * side * 50.0, Trackside.LAYER_BARRIER)
				hit = space.intersect_ray(q)
				if not hit.is_empty():
					break
			if hit.is_empty():
				misses.append("%.0f%s" % [s, "R" if side > 0.0 else "L"])
			else:
				var dist: float = (hit["position"] - from).length()
				assert_true(dist > ts.edge_at(s) + 1.5, "barrier on the road at s=%.0f (%.1f m)" % [s, dist])
				assert_true((hit["collider"] as Node).is_in_group(&"trackside_barrier"), "barrier group")
		s += 20.0
	assert_true(misses.is_empty(), "no barrier within 50 m at: %s" % ", ".join(misses))
	track.queue_free()

func test_car_cannot_pass_through_barrier() -> void:
	var scene := spawn(RACE)
	var car := scene.get_node("Car") as Car
	var track := scene.get_node("Track") as Track
	var ts: Trackside = await _trackside(track)
	var d := track.data
	var s := 2450.0   # back straight between Schlossgold and the T5 kink
	for side: float in [1.0, -1.0]:
		var xf := track.spawn_transform(s, 0.0)
		xf.basis = xf.basis.rotated(xf.basis.y, -side * deg_to_rad(35.0))
		car.global_transform = xf
		car.reset_physics_interpolation()
		car.linear_velocity = -xf.basis.z * 100.0 / 3.6
		car.angular_velocity = Vector3.ZERO
		car.set_input_override(0.0, 0.0, 0.0)
		var wall := ts.barrier_offset(s, side)
		var worst := 0.0
		for f in 240 * 3:
			await get_tree().physics_frame
			worst = maxf(worst, d.lateral_offset(car.global_position, s) * side)
		assert_true(worst < wall + 0.5, "car passed the %s barrier (max %.1f m, wall at %.1f m)"
				% ["right" if side > 0.0 else "left", worst, wall])
		assert_true(worst > wall - 4.0, "car should have reached the barrier (max %.1f, wall %.1f)" % [worst, wall])
		assert_true(car.global_position.y > d.position_at(s).y - 5.0, "car stayed above ground")
	scene.queue_free()

## Stand-in for the Road slot API (scripts/track/road.gd): 7.5 m half width. Its collision is
## still the flat placeholder ribbon + shoulders, so surface_point stays on that plane.
class WideRoad extends "res://tests/fixtures/placeholder_road.gd":
	func half_width_at(_s: float) -> float:
		return 7.5
	func bank_at(_s: float) -> float:
		return 0.0
	func surface_point(s: float, lateral: float) -> Vector3:
		var d := (get_parent() as Track).data
		var fwd := d.tangent_at(s)
		var right := fwd.cross(Vector3.UP).normalized()
		return d.position_at(s) + right * lateral

func test_follows_road_slot_widths() -> void:
	var track := (load(TRACK) as PackedScene).instantiate() as Track
	track.get_node("Road").set_script(WideRoad)
	add_child(track)
	var ts: Trackside = await _trackside(track)
	await physics_frames(2)
	var space := track.get_world_3d().direct_space_state
	assert_between(ts.edge_at(100.0), 7.49, 7.51, "edge from the Road slot")
	var k: Dictionary = ts.kerbs[1]   # T1 apex kerb
	var s: float = float(k["s0"]) + float(k["len"]) * 0.5
	var xf := ts.frame_at(s)
	var p := ts.lateral_point(s, float(k["side"]), 7.5 + 0.8, xf)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2.0, p - Vector3.UP * 2.0))
	assert_true(not hit.is_empty() and (hit["collider"] as Object).get_meta("surface", "") == "kerb",
			"kerb sits on the wider road's edge")
	if not hit.is_empty():
		# Kerb is raised a few cm above the edge of the (wider) road surface.
		assert_between(hit["position"].y - p.y, -0.01, 0.06, "kerb height above the road edge")
	track.queue_free()
