extends TestCase
## Real banking, on tests/fixtures/tracks/banked_oval: a stadium oval whose two turns (80 m
## radius) are banked at 18 degrees, built by the real pipeline with declared banking
## (make_banked_oval.py). Road and verge, the terrain under them, the trackside on them, a car
## standing on the banking, and the autopilot using it, in both handling models.

const GENERIC := "res://scenes/tracks/track.tscn"
const FIXTURES := "res://tests/fixtures/tracks"
const OVAL_DIR := "res://tests/fixtures/tracks/banked_oval"
const OVAL_RACE := "res://tests/fixtures/tracks/race_test_oval.tscn"
const CAR_SCENE := "res://scenes/car/car.tscn"
const BANK := 0.314          ## rad, make_banked_oval.py
const RADIUS := 80.0         ## m
const T1_APEX := 325.7       ## s of the middle of the east banking (the west one is half a lap on)
const HZ := 240

func _oval() -> Track:
	var track := (load(GENERIC) as PackedScene).instantiate() as Track
	track.track_dir = OVAL_DIR
	add_child(track)
	return track

func _built(ts: Trackside) -> void:
	var frames := 0
	while ts != null and not ts.is_built and frames < 600:
		await get_tree().physics_frame
		frames += 1
	assert_true(ts != null and ts.is_built, "Trackside finished building")

## First hit of a downward ray through `at` on a body for which `keep` returns true.
func _hit(at: Vector3, keep: Callable, above: float = 30.0) -> Dictionary:
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * above, at + Vector3.DOWN * 60.0)
	var exclude: Array[RID] = []
	for attempt in 12:
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if hit.is_empty() or keep.call(hit["collider"]):
			return hit
		exclude.append(hit["rid"])
	return {}

# ================================================================ road, verge and frames
func test_banked_road_and_verge_match_the_profile() -> void:
	var track := _oval()
	await physics_frames(3)
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	assert_true(not road.is_runtime_mesh and not road.verge_slope_left.is_empty(),
			"CAD road with a banked verge profile")
	var of_road := func(c: Object) -> bool: return c is Node and road.is_ancestor_of(c as Node)
	var steepest := 0.0
	var roll := 0.0
	for i in d.points.size():
		steepest = maxf(steepest, absf(road.banks[i]))
		roll = maxf(roll, absf(road.banks[(i + 1) % d.points.size()] - road.banks[i]) / d.step)
		assert_true(absf(d.banks[i] - road.banks[i]) < 2e-6, "track.json carries the built bank (point %d)" % i)
	assert_between(steepest, BANK - 0.001, BANK + 0.001, "steepest bank (rad)")
	assert_true(roll <= 0.0121, "the road twists by at most 0.012 rad/m (%.4f)" % roll)
	# TrackData's frame is the banked road plane: the outside (left) of the right-hander is up.
	var xf := d.sample(T1_APEX)
	var up := road.surface_point(T1_APEX, -5.0) - road.surface_point(T1_APEX, 5.0)
	assert_between(up.y, 10.0 * sin(BANK) - 0.05, 10.0 * sin(BANK) + 0.05, "rise across 10 m of banking (m)")
	assert_true(xf.basis.x.dot(-up.normalized()) > 0.9999, "TrackData.sample() rolls with the road")
	var p := road.surface_point(T1_APEX, 4.0)
	assert_between(d.lateral_offset(p, T1_APEX), 3.99, 4.01, "lateral offset measured in the road plane (m)")
	# The mesh is the profile's surface: on the road, on the shoulder and across the blend.
	var worst := 0.0
	var misses := 0
	var s := 1.0     # between cross-sections: a ray along a seam of the mesh can slip through
	while s < d.length:
		var hw := road.half_width_at(s)
		for side: float in [-1.0, 1.0]:
			var ext := road.verge_at(s, side)
			for out: float in [-hw, -3.0, -0.5, 0.5, 1.5, 3.0, 5.0, 7.0, 9.0, 11.0, 16.0, 24.0, 29.0]:
				if out > ext - 0.5:
					continue
				var want := road.surface_point(s, side * (hw + out))
				var hit := _hit(want, of_road)
				if hit.is_empty():
					misses += 1
					continue
				worst = maxf(worst, absf((hit["position"] as Vector3).y - want.y))
				var kind: String = (hit["collider"] as Node).get_meta("surface", "")
				assert_true(kind == ("asphalt" if out < 0.0 else "grass"), "%s at s=%.0f, %.1f m out" % [kind, s, out])
		s += 7.0
	assert_true(misses == 0, "%d probes found no road or verge" % misses)
	assert_true(worst < 0.06, "road / verge mesh within 6 cm of the profile surface (%.3f m)" % worst)
	# The verge leaves the high edge in the plane of the road (no shelf) and levels out as a
	# berm (no cliff); on the low side it is an apron that levels out too (no trough).
	var hw_t := road.half_width_at(T1_APEX)
	for side: float in [-1.0, 1.0]:
		var edge := road.surface_point(T1_APEX, side * hw_t)
		var shoulder := road.surface_point(T1_APEX, side * (hw_t + 3.0))
		var far := road.surface_point(T1_APEX, side * (hw_t + 11.0))
		var end := road.surface_point(T1_APEX, side * (hw_t + 29.0))
		assert_between((shoulder.y - edge.y) * -side, 3.0 * tan(BANK) - 0.1, 3.0 * tan(BANK) + 0.1,
				"the shoulder continues the banking (side %+.0f, m over 3 m)" % side)
		assert_between((far.y - edge.y) * -side, 1.8, 2.6, "berm / apron height against the road edge (m)")
		assert_between(far.y - end.y, 0.0, 0.3, "beyond the blend the verge has its normal fall (m)")
	print("    banked road: mesh within %.3f m of the profile, roll rate %.4f rad/m" % [worst, roll])
	track.queue_free()

# ================================================================ terrain
func test_terrain_stays_below_banked_road_and_verge() -> void:
	var track := _oval()
	await physics_frames(3)
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	var terrain := track.get_node("Terrain")
	var is_terrain := func(c: Object) -> bool: return c is Node and (c as Node).get_parent() == terrain
	var bad: Array[String] = []
	var probes := 0
	var closest := INF
	var deepest := 0.0
	var deepest_end := 0.0
	var s := 0.0
	while s < d.length:
		var hw := road.half_width_at(s)
		for side: float in [-1.0, 1.0]:
			var ext := road.verge_at(s, side)
			var lat := 0.0
			while lat <= hw + ext - 0.25:
				var surf := road.surface_point(s, side * lat)
				var hit := _hit(surf, is_terrain)
				probes += 1
				if hit.is_empty():
					bad.append("s=%.0f lat=%+.1f: no terrain" % [s, side * lat])
				else:
					var gap := surf.y - (hit["position"] as Vector3).y
					closest = minf(closest, gap)
					deepest = maxf(deepest, gap)
					if lat > hw + ext - 1.5:
						deepest_end = maxf(deepest_end, gap)
					if gap < 0.1:
						bad.append("s=%.0f lat=%+.1f: terrain %.2f m above the surface" % [s, side * lat, 0.3 - gap])
				lat += 1.25
		s += 3.0
	assert_true(probes > 15000, "probe grid too small (%d)" % probes)
	assert_true(bad.is_empty(), "%d of %d probes off, e.g. %s" % [bad.size(), probes, bad.slice(0, 4)])
	# Under the road the ground may hang lower (nobody sees it); at the outer end of the verge,
	# where the two meet in view, it must not.
	assert_true(deepest < 3.0, "terrain at most 3 m under the road (%.2f m)" % deepest)
	assert_true(deepest_end < 0.8, "terrain meets the outer end of the verge (%.2f m below it)" % deepest_end)
	print("    terrain under the banked road: %d probes, gap %.2f..%.2f m, %.2f m at the verge's end" % [
			probes, closest, deepest, deepest_end])
	track.queue_free()

# ================================================================ trackside
func test_trackside_sits_on_the_banking() -> void:
	var track := _oval()
	var ts := track.get_node("Trackside") as Trackside
	await _built(ts)
	await physics_frames(2)
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	assert_true(ts.snap_misses * 50 < ts.snap_hits, "%d of %d surface snaps missed" % [ts.snap_misses, ts.snap_hits + ts.snap_misses])
	# Kerbs and run-off: their surface is on the verge surface under them.
	var on_kerb := func(c: Object) -> bool: return c is Node and (c as Node).get_meta("surface", "") == "kerb"
	var banked_kerbs := 0
	var worst_kerb := 0.0
	for k in ts.kerbs:
		if k["kind"] == "sausage":
			continue
		var s := float(k["s0"]) + 0.5 * float(k["len"])
		if absf(road.bank_at(s)) < 0.25:
			continue
		banked_kerbs += 1
		var want := road.surface_point(s, float(k["side"]) * (road.half_width_at(s) + 0.75))
		var hit := _hit(want, on_kerb, 3.0)
		assert_true(not hit.is_empty(), "kerb of %s at s=%.0f is not where the verge is" % [k["turn"], s])
		if not hit.is_empty():
			worst_kerb = maxf(worst_kerb, absf((hit["position"] as Vector3).y - want.y))
	assert_true(banked_kerbs >= 2, "kerbs on the banked turns (%d)" % banked_kerbs)
	assert_true(worst_kerb < 0.15, "kerbs within 15 cm of the banked surface (%.3f m)" % worst_kerb)
	var is_runoff := func(c: Object) -> bool: return c is Node and String((c as Node).name).begins_with("Runoff_")
	var runoff_probes := 0
	var worst_runoff := 0.0
	for r in ts.runoff:
		var side: float = r["side"]
		for f: float in [0.3, 0.5, 0.7]:
			var s := float(r["s0"]) + f * float(r["len"])
			if absf(road.bank_at(s)) < 0.25:
				continue
			var e := road.half_width_at(s)
			var room := ts.barrier_offset(s, side) - e - 2.5 - ts.kerb_extent(s, side)
			var u := ts.kerb_extent(s, side) + minf(0.5 * (float(r["u0"]) + float(r["u1"])), room * 0.8)
			var want := road.surface_point(s, side * (e + u))
			var hit := _hit(want, is_runoff, 4.0)
			runoff_probes += 1
			assert_true(not hit.is_empty(), "run-off of %s at s=%.0f, %.1f m out is not on the verge" % [r["turn"], s, u])
			if not hit.is_empty():
				worst_runoff = maxf(worst_runoff, absf((hit["position"] as Vector3).y - want.y))
	assert_true(worst_runoff < 0.15, "run-off within 15 cm of the banked verge (%.3f m)" % worst_runoff)
	# Barriers: upright, standing on the verge on both sides (on the high side: on the berm).
	var space := get_viewport().world_3d.direct_space_state
	var worst_wall := 0.0
	var walls := 0
	var s := 0.0
	while s < d.length:
		if absf(road.bank_at(s)) > 0.25:
			for side: float in [-1.0, 1.0]:
				var off := ts.barrier_offset(s, side)
				var ground := road.surface_point(s, side * off)
				var out := (ground - road.surface_point(s, side * (off - 1.0)))
				out = Vector3(out.x, 0.0, out.z).normalized()
				# Just outside the line the wall's slab is under a ray from above: its top is
				# about a metre over the verge.
				var q := PhysicsRayQueryParameters3D.create(ground + out * 0.15 + Vector3.UP * 6.0,
						ground + out * 0.15 + Vector3.DOWN * 3.0, Trackside.LAYER_BARRIER)
				var hit := space.intersect_ray(q)
				walls += 1
				assert_true(not hit.is_empty(), "no barrier on the verge at s=%.0f side %+.0f" % [s, side])
				if not hit.is_empty():
					var top := (hit["position"] as Vector3).y - ground.y
					worst_wall = maxf(worst_wall, absf(top - 1.1))
					assert_between(top, 0.7, 1.5, "barrier top above the verge at s=%.0f side %+.0f (m)" % [s, side])
					# The top may climb along the track with the banking; across it, it is level.
					assert_true(absf((hit["normal"] as Vector3).dot(out)) < 0.02, "barrier upright at s=%.0f side %+.0f" % [s, side])
				if side < 0.0:
					assert_true(ground.y > road.surface_point(s, side * road.half_width_at(s)).y + 1.0,
							"the outside barrier stands on the berm above the road edge (s=%.0f)" % s)
		s += 10.0
	assert_true(walls >= 60, "barrier probes on the banking (%d)" % walls)
	print("    trackside on the banking: kerbs %.3f m, run-off %.3f m (%d probes), barrier tops within %.2f m, snaps %d / %d missed" % [
			worst_kerb, worst_runoff, runoff_probes, worst_wall, ts.snap_misses, ts.snap_hits + ts.snap_misses])
	track.queue_free()

# ================================================================ a car on the banking
## Puts a car of `handling` on the east banking, `lateral` m right of the centre, hands off.
func _parked(track: Track, handling: StringName, lateral: float) -> Car:
	var car := (load(CAR_SCENE) as PackedScene).instantiate() as Car
	car.handling = handling
	var xf := track.spawn_transform(T1_APEX, lateral)
	car.transform = xf
	add_child(car)
	car.spawn_transform = xf
	car.set_input_override(0.0, 0.0, 0.0)
	return car

func _rest_on_banking(handling: StringName) -> void:
	var track := _oval()
	await physics_frames(3)
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	var car := _parked(track, handling, -2.0)
	# The arcade car has a parking brake of its own; the simulation car is held on its brake
	# (below the pedal that selects reverse), or it rolls away along the 2 % grade.
	if handling == Car.HANDLING_SIMULATION:
		car.set_input_override(0.0, 0.3, 0.0)
	await physics_frames(2 * HZ)
	var p0 := car.global_position
	await physics_frames(6 * HZ)
	var p1 := car.global_position
	var up := d.sample(T1_APEX).basis.y
	var grounded := 0
	for w: WheelState in car.wheels:
		grounded += 1 if w.contact else 0
	assert_true(grounded == 4, "%s: all four wheels on the banking (%d)" % [handling, grounded])
	assert_true(car.global_transform.basis.y.dot(up) > 0.999, "%s: the car lies in the plane of the road (%.4f)" % [
			handling, car.global_transform.basis.y.dot(up)])
	assert_between(rad_to_deg(acos(car.global_transform.basis.y.dot(Vector3.UP))), 17.0, 19.0,
			"%s: the car leans with the 18 degree banking" % handling)
	var s := d.closest_s(p1)
	var surf := road.surface_point(s, d.lateral_offset(p1, s))
	assert_between((p1 - surf).dot(up), 0.25, 0.5, "%s: resting on the road surface (m above it)" % handling)
	# A real car stays where it is parked on 18 degrees (it would need 1 / 3 g to move it).
	assert_true(p0.distance_to(p1) < 0.05, "%s: the car crept %.3f m down the banking in 6 s" % [handling, p0.distance_to(p1)])
	assert_true(car.linear_velocity.length() < 0.05, "%s: at rest (%.3f m/s)" % [handling, car.linear_velocity.length()])
	print("    %s car parked on the banking: moved %.3f m in 6 s, %.3f m/s" % [handling, p0.distance_to(p1), car.linear_velocity.length()])
	# And it is not stuck there: it pulls away up the road.
	car.set_input_override(0.6, 0.0, 0.0)
	await physics_frames(3 * HZ)
	assert_true(car.forward_speed > 8.0, "%s: pulls away on the banking (%.1f m/s after 3 s)" % [handling, car.forward_speed])
	car.queue_free()
	track.queue_free()

func test_arcade_car_rests_on_the_banking() -> void:
	await _rest_on_banking(Car.HANDLING_ARCADE)

func test_simulation_car_rests_on_the_banking() -> void:
	await _rest_on_banking(Car.HANDLING_SIMULATION)

# ================================================================ the autopilot on the banking
## One lap of the banked oval from the grid with the autopilot, in `handling`: clean, and
## through the banked turn faster than the same car could go round the same line on a flat road.
func _lap(handling: StringName) -> void:
	var saved_config := Game.config   # the race scene points Game.config at its track
	Game.config = saved_config.copy()
	TrackCatalog.set_extra_dirs(PackedStringArray([FIXTURES]))
	Bootstrap.handling_override = handling
	Bootstrap.autodrive = true
	var scene := (load(OVAL_RACE) as PackedScene).instantiate()
	scene.set(&"track_id", "banked_oval")
	add_child(scene)
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var track := scene.get_node("Track") as Track
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	(track.get_node("Race") as RaceManager).persist_best = false
	assert_true(track.dir() == OVAL_DIR and car.handling == handling, "the %s car on the banked oval" % handling)
	var s := d.closest_s(car.global_position)
	var t2_apex := T1_APEX + 0.5 * d.length
	var t := 0.0
	var progress := 0.0
	var worst_edge := INF
	var worst_s := 0.0
	var impacts := 0
	var prev_speed := 0.0
	var apex_v := 0.0       # speed and line curvature where the car passes the west apex
	var apex_k := 0.0
	var seen_apex := false
	var low := INF          # lowest speed on the banked arc of the west turn
	while t < 110.0 and pilot.laps_completed < 1:
		await get_tree().physics_frame
		t += 1.0 / HZ
		var pos := car.global_position
		var ns := d.closest_s(pos, s)
		progress += d.delta_s(s, ns)
		s = ns
		var edge := road.half_width_at(s) - absf(d.lateral_offset(pos, s))
		if edge < worst_edge:
			worst_edge = edge
			worst_s = s
		var speed := car.linear_velocity.length()
		if prev_speed - speed > 8.0:
			impacts += 1
		prev_speed = speed
		if absf(d.delta_s(t2_apex, s)) < 90.0 and progress > 300.0:
			low = minf(low, speed)
		if not seen_apex and progress > 300.0 and absf(d.delta_s(t2_apex, s)) < 5.0:
			seen_apex = true
			apex_v = speed
			apex_k = absf(pilot.line_curvature_at(s))
	assert_true(pilot.laps_completed >= 1, "%s: lap not completed in 110 s (progress %.0f m)" % [handling, progress])
	assert_true(worst_edge > 0.0, "%s: car left the road, edge margin %.2f m at s=%.0f" % [handling, worst_edge, worst_s])
	assert_true(impacts == 0, "%s: %d impact(s)" % [handling, impacts])
	assert_true(seen_apex, "%s: never reached the west banking" % handling)
	if seen_apex:
		var env := pilot.envelope()
		# The same line on a flat road: the speed at which it takes the car's whole cornering
		# limit (no margin), from the same envelope the autopilot plans with.
		var v_flat := 5.0
		while v_flat < 120.0 and apex_k * v_flat * v_flat < env.lat_at(v_flat):
			v_flat += 0.1
		var a_lat := apex_k * apex_v * apex_v
		assert_true(apex_k > 1.0 / 130.0, "%s: the line still turns at the apex (radius %.0f m)" % [handling, 1.0 / maxf(apex_k, 1e-6)])
		assert_true(apex_v > 1.02 * v_flat, "%s: %.1f m/s at the banked apex, the flat-road limit of the line is %.1f" % [handling, apex_v, v_flat])
		assert_true(low > v_flat, "%s: slowest on the banking %.1f m/s, flat-road limit %.1f" % [handling, low, v_flat])
		assert_true(a_lat > 1.03 * env.lat_at(apex_v), "%s: %.1f m/s^2 round the banking, %.1f is the car's limit on the flat" % [
				handling, a_lat, env.lat_at(apex_v)])
		print("    %s lap of the banked oval: %.2f s; banked apex %.0f km/h on a %.0f m radius = %.1f m/s^2 (flat limit %.1f m/s^2, %.0f km/h), slowest %.0f km/h; min edge %.2f m at s=%.0f" % [
				handling, pilot.lap_time, apex_v * 3.6, 1.0 / apex_k, a_lat, env.lat_at(apex_v), v_flat * 3.6, low * 3.6, worst_edge, worst_s])
	Bootstrap.autodrive = false
	Bootstrap.handling_override = &""
	scene.queue_free()
	Game.config = saved_config
	TrackCatalog.set_extra_dirs([])

func test_arcade_autopilot_uses_the_banking() -> void:
	await _lap(Car.HANDLING_ARCADE)

func test_simulation_autopilot_uses_the_banking() -> void:
	await _lap(Car.HANDLING_SIMULATION)
