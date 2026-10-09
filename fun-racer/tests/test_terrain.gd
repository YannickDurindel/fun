extends TestCase
## Valley terrain (scenes/tracks/rbr_terrain.tscn): coverage, corridor conformity against the
## CAD road (RoadSurface + road_profile.json), surface tags and agreement with the EU-DEM.

const TRACK := "res://assets/tracks/red_bull_ring/track.json"
const TERRAIN := "res://scenes/tracks/rbr_terrain.tscn"
const TRACK_SCENE := "res://scenes/tracks/red_bull_ring.tscn"
const COVER_SLACK := 2.0   ## same as tools/track/fetch_terrain.py

func _ray_y(x: float, z: float, top: float = 400.0) -> Variant:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, -150.0, z))
	var hit := space.intersect_ray(q)
	return null if hit.is_empty() else hit

## Downward ray that only reports bodies for which `keep` returns true.
func _ray_filtered(x: float, z: float, top: float, keep: Callable) -> Variant:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, top, z), Vector3(x, -150.0, z))
	var exclude: Array[RID] = []
	for i in 12:
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return null
		if keep.call(hit["collider"]):
			return hit
		exclude.append(hit["rid"])
	return null

var _tangents: PackedVector2Array = []

## [lowest, highest] CAD road / verge surface over p among the cross-sections that genuinely cover it
## (within COVER_SLACK + `slack` m along, inside road + that side's verge + a cell diagonal
## + `slack`, as baked by tools/track/fetch_terrain.py), each continued
## along its grade and rolled by its bank, including `y0`.
func _cover_range(road: Node, d: TrackData, p: Vector3, y0: float, slack: float) -> Vector2:
	if _tangents.size() != d.points.size():
		_tangents.resize(d.points.size())
		for i in d.points.size():
			var t := d.tangent_at(i * d.step)
			_tangents[i] = Vector2(t.x, t.z).normalized()
	var widths: PackedFloat32Array = road.widths
	var banks: PackedFloat32Array = road.banks
	var vl: PackedFloat32Array = road.verge_left
	var vr: PackedFloat32Array = road.verge_right
	var vdrop: float = road.verge_drop / road.verge_width
	var r := Vector2(y0, y0)
	for i in d.points.size():
		var c := d.points[i]
		var off := Vector2(p.x - c.x, p.z - c.z)
		if absf(off.x) > 60.0 or absf(off.y) > 60.0:
			continue
		var t2 := _tangents[i]
		var along := off.dot(t2)
		var lat_r := off.y * t2.x - off.x * t2.y   # + = right of the race direction
		var hw := widths[i] * 0.5
		var verge := vr[i] if lat_r > 0.0 else vl[i]
		if absf(along) > COVER_SLACK + slack or absf(lat_r) > hw + verge + 14.2 + slack:
			continue
		var y := c.y + d.grades[i] * along
		var out := absf(lat_r) - hw
		if out <= 0.0:
			y -= lat_r * sin(banks[i])
		else:
			y -= signf(lat_r) * hw * sin(banks[i]) + vdrop * out
		r = Vector2(minf(r.x, y), maxf(r.y, y))
	return r

## Probes beside the CAD road every 20 m, at `extras` m past the road edge on both sides:
## check(s, lat, expect, covered) -> error string or "". `expect` = RoadSurface.surface_point
## (verge plane, extrapolated past the verge); `covered` = inside that side's real verge.
func _probe_road(road: Node, d: TrackData, extras: Array, check: Callable) -> Array:
	var bad := []
	var s := 0.0
	while s < d.length:
		var hw: float = road.half_width_at(s)
		for side: float in [-1.0, 1.0]:
			for extra: float in extras:
				var lat := side * (hw + extra)
				var expect: Vector3 = road.surface_point(s, lat)
				var covered: bool = extra <= road.verge_at(s, side)
				if not covered:
					# Past a clamped verge (inside of corners) the point can be nearer another
					# part of the lap: the terrain follows the nearest cross-section there.
					var s2 := d.closest_s(expect, s)
					expect = road.surface_point(s2, d.lateral_offset(expect, s2))
				var err: String = check.call(s, lat, expect, covered)
				if not err.is_empty():
					bad.append("s=%.0f lat=%.1f: %s" % [s, lat, err])
		s += 20.0
	return bad

func test_terrain_conforms_to_track_corridor() -> void:
	# Terrain only (road and trackside bodies skipped): out to the end of the flat zone
	# (edge + 51 m) the ground follows the CAD verge plane ~0.3 m below it, never above
	# the real verge, and only dips further where another cross-section genuinely overlaps.
	var track := spawn(TRACK_SCENE) as Track
	await physics_frames(3)
	var d := track.data
	var road := track.get_node("Road")
	var terrain := track.get_node("Terrain")
	var is_terrain := func(c: Object) -> bool: return c is Node and (c as Node).get_parent() == terrain
	# Out to the flat-zone end (edge + 51 m) minus a cell diagonal: beyond, triangles start to
	# reach into the 40 m blend back to the DEM.
	var bad := _probe_road(road, d, [0.5, 10.0, 20.0, 29.0, 37.0],
			func(_s: float, _lat: float, expect: Vector3, covered: bool) -> String:
		var hit: Variant = _ray_filtered(expect.x, expect.z, expect.y + 30.0, is_terrain)
		if hit == null:
			return "no terrain"
		var y: float = (hit as Dictionary)["position"].y
		if covered and y > expect.y - 0.1:
			return "terrain %.2f pokes through verge %.2f" % [y, expect.y]
		# 0.3 m clearance + up to 0.4 m triangle interpolation / grade curvature.
		var lo := _cover_range(road, d, expect, expect.y, 14.2).x - 0.7
		if y < lo:
			return "terrain %.2f too far below verge plane %.2f (bound %.2f)" % [y, expect.y, lo]
		return "")
	assert_true(bad.is_empty(), "%d corridor probes off, e.g. %s" % [bad.size(), bad.slice(0, 4)])

func test_race_scene_ground_beside_road() -> void:
	# Full race scene (CAD road + verges + trackside + terrain): beside the real road edge there
	# is always ground at the road/verge height (RoadSurface.surface_point), allowing for
	# overlapping cross-sections on the inside of hairpins. Barriers are skipped, and so are
	# the buildings and grandstands that really stand within the verge (pit building).
	var scene := spawn("res://scenes/race_red_bull_ring.tscn")
	await physics_frames(3)
	var track := scene.get_node("Track") as Track
	var d: TrackData = track.data
	var road := track.get_node("Road")
	var not_barrier := func(c: Object) -> bool:
		return c != null and not (c.get_meta("barrier", false) or (c is Node and ((c as Node).is_in_group(&"trackside_barrier") or (c as Node).is_in_group(&"scenery_body"))))
	var bad := _probe_road(road, d, [3.0, 10.0, 20.0, 28.0],
			func(_s: float, _lat: float, expect: Vector3, _covered: bool) -> String:
		var hit: Variant = _ray_filtered(expect.x, expect.z, expect.y + 20.0, not_barrier)
		if hit == null:
			return "nothing below"
		var y: float = (hit as Dictionary)["position"].y
		var r := _cover_range(road, d, expect, expect.y, 14.2)
		var lo := r.x - 1.0
		var hi := r.y + 0.2   # the CAD verge mesh sits up to ~0.15 m off surface_point in corners
		if y < lo or y > hi:
			return "surface %.2f outside [%.2f, %.2f] (%s)" % [y, lo, hi, ((hit as Dictionary)["collider"] as Node).get_path()]
		return "")
	assert_true(bad.is_empty(), "%d probes off, e.g. %s" % [bad.size(), bad.slice(0, 4)])

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
