extends TestCase
## Valley terrain (scenes/tracks/rbr_terrain.tscn): coverage, corridor conformity, surface
## tags and agreement with the EU-DEM.

const TRACK := "res://assets/tracks/red_bull_ring/track.json"
const TERRAIN := "res://scenes/tracks/rbr_terrain.tscn"

func _ray_y(x: float, z: float, top: float = 400.0) -> Variant:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, -150.0, z))
	var hit := space.intersect_ray(q)
	return null if hit.is_empty() else hit

var _tangents: PackedVector2Array = []

## Road cross-sections (road + 36 m shoulder strip perpendicular to the centreline, extended
## along its grade and rolled by its bank) passing within `reach` m of p -> [lowest, highest]
## surface height there. On the inside of hairpins several overlap and the terrain must sit
## under all of them.
func _cover_range(d: TrackData, p: Vector3, y0: float, reach: float) -> Vector2:
	if _tangents.size() != d.points.size():
		_tangents.resize(d.points.size())
		for i in d.points.size():
			var t := d.tangent_at(i * d.step)
			_tangents[i] = Vector2(t.x, t.z).normalized()
	var r := Vector2(y0, y0)
	var lim := 65.0 + reach
	for i in d.points.size():
		var c := d.points[i]
		var off := Vector2(p.x - c.x, p.z - c.z)
		if absf(off.x) > lim or absf(off.y) > lim:
			continue
		var t2 := _tangents[i]
		var along := off.dot(t2)
		var lat_r := off.y * t2.x - off.x * t2.y   # + = right of the race direction
		if absf(along) <= reach and absf(lat_r) <= d.widths[i] * 0.5 + 36.0 + reach:
			var y := c.y + d.grades[i] * along - lat_r * sin(d.banks[i])
			r = Vector2(minf(r.x, y), maxf(r.y, y))
	return r

## Probes just outside the road, every 20 m: callable(p, xf, extra) -> error string or "".
func _probe_corridor(d: TrackData, check: Callable) -> Array:
	var bad := []
	var s := 0.0
	while s < d.length:
		var xf := d.sample(s)
		var hw := d.width_at(s) * 0.5
		for side: float in [-1.0, 1.0]:
			for extra: float in [0.5, 10.0, 20.0, 30.0]:
				var p := xf.origin + xf.basis.x * side * (hw + extra)
				var err: String = check.call(p, xf, extra)
				if not err.is_empty():
					bad.append("s=%.0f lat=%.1f: %s" % [s, side * (hw + extra), err])
		s += 20.0
	return bad

func test_terrain_conforms_to_track_corridor() -> void:
	var d := TrackData.load_track(TRACK)
	spawn(TERRAIN)
	await physics_frames(2)
	var bad := _probe_corridor(d, func(p: Vector3, xf: Transform3D, extra: float) -> String:
		var hit: Variant = _ray_y(p.x, p.z)
		if hit == null:
			return "no terrain"
		var y: float = (hit as Dictionary)["position"].y
		# Never above this cross-section's shoulder (the placeholder's drops 0.25 m over 35 m;
		# the CAD verge is at least as high) ...
		if y > xf.origin.y - 0.25 * extra / 35.0 - 0.02:
			return "terrain %.2f above shoulder of road %.2f" % [y, xf.origin.y]
		# ... and conforming to the road (within 1 m) or to a lower overlapping cross-section.
		# The bake keeps each mesh vertex under every strip within 14.2 m (a cell diagonal) of
		# it, so a point is bounded by strips within 14.2 m + 14.2 m.
		var lo := _cover_range(d, p, xf.origin.y, 28.4).x
		if y < lo - 1.0:
			return "terrain %.2f more than 1 m below road %.2f (lowest cover %.2f)" % [y, xf.origin.y, lo]
		return "")
	assert_true(bad.is_empty(), "%d corridor probes off, e.g. %s" % [bad.size(), bad.slice(0, 3)])

func test_race_scene_ground_beside_road() -> void:
	# Full race scene (road + terrain): just outside the road there is always a surface at the
	# road edge height, within 1 m (or within the range of overlapping cross-sections).
	var scene := spawn("res://scenes/race_red_bull_ring.tscn")
	await physics_frames(2)
	var d: TrackData = (scene.get_node("Track") as Track).data
	var bad := _probe_corridor(d, func(p: Vector3, xf: Transform3D, _extra: float) -> String:
		var hit: Variant = _ray_y(p.x, p.z, xf.origin.y + 20.0)
		if hit == null:
			return "nothing below"
		var y: float = (hit as Dictionary)["position"].y
		var r := _cover_range(d, p, xf.origin.y, 28.4)
		if y > r.y + 0.05 or y < r.x - 1.0:
			return "surface %.2f outside [%.2f, %.2f]" % [y, r.x - 1.0, r.y + 0.05]
		return "")
	assert_true(bad.is_empty(), "%d probes off, e.g. %s" % [bad.size(), bad.slice(0, 3)])

func test_terrain_covers_lap_without_holes() -> void:
	var d := TrackData.load_track(TRACK)
	spawn(TERRAIN)
	await physics_frames(2)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in d.points:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	lo -= Vector2(150, 150)
	hi += Vector2(150, 150)
	var misses := 0
	var count := 0
	var x := lo.x
	while x <= hi.x:
		var z := lo.y
		while z <= hi.y:
			count += 1
			if _ray_y(x, z) == null:
				misses += 1
			z += 17.0
		x += 17.0
	assert_true(count > 4000, "probe grid too small (%d)" % count)
	assert_true(misses == 0, "%d / %d probes found no terrain" % [misses, count])
	# Far hills exist well beyond the near grid, in every direction.
	for far: Vector2 in [Vector2(-4000, 0), Vector2(3500, -300), Vector2(-300, -4500), Vector2(-300, 4000)]:
		assert_true(_ray_y(far.x, far.y, 3000.0) != null, "far hills missing at %s" % far)

func test_terrain_bodies_are_grass() -> void:
	var t := spawn(TERRAIN)
	var bodies := 0
	for c in t.get_children():
		if c is StaticBody3D:
			bodies += 1
			assert_true(c.get_meta("surface", "") == "grass", "%s must carry surface=grass" % c.name)
	assert_true(bodies >= 10, "expected chunked terrain bodies, got %d" % bodies)
	await physics_frames(2)
	var hit: Variant = _ray_y(-1300.0, -200.0)
	assert_true(hit != null and ((hit as Dictionary)["collider"] as Node).get_meta("surface", "") == "grass",
			"raycast hit must report grass")

func test_terrain_matches_dem() -> void:
	spawn(TERRAIN)
	await physics_frames(2)
	# Raw EU-DEM heights (relative to the finish line) printed by tools/track/fetch_terrain.py,
	# at points far from the corridor, so they are unmodified.
	var refs := {
		"hill north of Remus": [150.0, -950.0, NORTH_OF_REMUS],
		"west field": [-1300.0, -200.0, WEST_FIELD],
		"south east": [600.0, 400.0, SOUTH_EAST],
	}
	for k: String in refs:
		var r: Array = refs[k]
		var hit: Variant = _ray_y(r[0], r[1])
		assert_true(hit != null, "no terrain at %s" % k)
		if hit != null:
			assert_between((hit as Dictionary)["position"].y, r[2] - 3.0, r[2] + 3.0, "terrain y at %s" % k)

const NORTH_OF_REMUS := 108.04
const WEST_FIELD := 24.40
const SOUTH_EAST := 7.17
