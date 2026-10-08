extends TestCase
## Generic track runtime (scenes/tracks/track.tscn): one scene builds any track folder.
##   * The Red Bull Ring keeps its hand-made trackside exactly (golden values captured before
##     the layout tables moved out of TracksideLayout).
##   * The automatic trackside layout gives a plausible Red Bull Ring too.
##   * A brand-new track (tests/fixtures/tracks/test_oval: just track.json + track_info.json)
##     builds, drives and races with every fallback: runtime road ribbon, plain ground,
##     shared kerb profiles, automatic trackside.

const GENERIC := "res://scenes/tracks/track.tscn"
const RBR := "res://scenes/tracks/red_bull_ring.tscn"
const RBR_JSON := "res://assets/tracks/red_bull_ring/track.json"
const GOLDEN := "res://tests/fixtures/tracks/red_bull_ring_trackside_golden.json"
const FIXTURES := "res://tests/fixtures/tracks"
const OVAL_DIR := "res://tests/fixtures/tracks/test_oval"
const OVAL_RACE := "res://tests/fixtures/tracks/race_test_oval.tscn"

func _built(ts: Trackside) -> void:
	var frames := 0
	while ts != null and not ts.is_built and frames < 600:
		await get_tree().physics_frame
		frames += 1
	assert_true(ts != null and ts.is_built, "Trackside finished building")

func _oval() -> Track:
	var track := (load(GENERIC) as PackedScene).instantiate() as Track
	track.track_dir = OVAL_DIR
	add_child(track)
	return track

## Every turn has a (non-sausage) kerb on its inside covering the apex.
func _assert_apex_kerbs(data: TrackData, kerbs: Array[Dictionary], what: String) -> void:
	for t: Dictionary in data.turns:
		var inside := 1.0 if String(t["direction"]) == "right" else -1.0
		var found := false
		for k in kerbs:
			if k["turn"] != t["id"] or k["kind"] == "sausage" or float(k["side"]) != inside:
				continue
			var rel := data.delta_s(float(k["s0"]), float(t["s_apex"]))
			found = found or (rel >= 0.0 and rel <= float(k["len"]))
		assert_true(found, "%s: turn %s has no apex kerb on its inside" % [what, t["id"]])

## Barrier lines: never on the road, no steps or kinks, and a wall is hit on both sides all round.
func _assert_walls(track: Track, ts: Trackside, ray_step: float, what: String) -> void:
	var d := track.data
	var n := d.points.size()
	for side: float in [-1.0, 1.0]:
		var worst_gap := INF
		var worst_jump := 0.0
		var worst_kink := 0.0
		for i in n:
			var s := i * d.step
			var off := ts.barrier_offset(s, side)
			worst_gap = minf(worst_gap, off - ts.edge_at(s))
			var next := ts.barrier_offset(s + d.step, side)
			worst_jump = maxf(worst_jump, absf(next - off))
			worst_kink = maxf(worst_kink, absf(next - 2.0 * off + ts.barrier_offset(s - d.step, side)))
		assert_true(worst_gap >= 1.5, "%s: barrier %.2f m from the road edge (side %d)" % [what, worst_gap, side])
		# Run-off zones ramp in at up to ~40 degrees; a step sideways would show as a kink.
		assert_true(worst_jump < 2.0, "%s: barrier line jumps %.2f m between points (side %d)" % [what, worst_jump, side])
		assert_true(worst_kink < 0.7, "%s: barrier line kinks by %.2f m at a point (side %d)" % [what, worst_kink, side])
	var space := track.get_world_3d().direct_space_state
	var misses: Array[String] = []
	var s := 0.0
	while s < d.length:
		var xf := ts.frame_at(s)
		var rh := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized()
		for side: float in [-1.0, 1.0]:
			var hit := {}
			var from := xf.origin
			for h: float in [0.5, 0.25, 0.0, -0.25]:
				from = xf.origin + Vector3.UP * h
				hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(
						from, from + rh * side * 60.0, Trackside.LAYER_BARRIER))
				if not hit.is_empty():
					break
			if hit.is_empty():
				misses.append("%.0f%s" % [s, "R" if side > 0.0 else "L"])
			else:
				var dist: float = (hit["position"] - from).length()
				assert_true(dist > ts.edge_at(s) + 1.5, "%s: wall on the road at s=%.0f (%.1f m)" % [what, s, dist])
		s += ray_step
	assert_true(misses.is_empty(), "%s: no wall within 60 m at: %s" % [what, ", ".join(misses)])

# ------------------------------------------------------------------ Red Bull Ring
func test_rbr_trackside_unchanged() -> void:
	var golden: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	var track := spawn(RBR) as Track
	assert_true(track.track_id == "red_bull_ring" and track.data != null, "wrapper scene sets the id")
	var road := track.get_node("Road") as RoadSurface
	assert_true(road != null and not road.is_runtime_mesh, "RBR road comes from road_mesh.glb")
	assert_true(not (track.get_node("Terrain") as Terrain).is_fallback, "RBR terrain is the baked one")
	var ts := track.get_node("Trackside") as Trackside
	assert_true(ts.layout != null and not ts.layout.is_auto, "RBR uses its hand-made table")
	for key: String in ["kerbs", "runoff"]:
		var want: Array = golden[key]
		var got: Array[Dictionary] = ts.kerbs if key == "kerbs" else ts.runoff
		assert_true(got.size() == want.size(), "%s count %d, was %d" % [key, got.size(), want.size()])
		for i in mini(got.size(), want.size()):
			var w: Dictionary = want[i]
			var g := got[i]
			assert_true(g.size() == w.size(), "%s[%d] has the same fields" % [key, i])
			for f: String in w:
				var same: bool = g.has(f) and (absf(float(g[f]) - float(w[f])) < 1e-3 if w[f] is float else g[f] == w[f])
				assert_true(same, "%s[%d].%s = %s, was %s" % [key, i, f, g.get(f), w[f]])
	var d := track.data
	var off_l: Array = golden["off_l"]
	var off_r: Array = golden["off_r"]
	var concrete: Array = golden["concrete"]
	assert_true(off_l.size() == d.points.size(), "golden covers every centreline point")
	var worst := 0.0
	var wall_changes := 0
	for i in mini(off_l.size(), d.points.size()):
		var s := i * d.step
		worst = maxf(worst, absf(ts.barrier_offset(s, -1.0) - float(off_l[i])))
		worst = maxf(worst, absf(ts.barrier_offset(s, 1.0) - float(off_r[i])))
		if ts.layout.is_concrete(s) != (int(concrete[i]) == 1):
			wall_changes += 1
	assert_true(worst < 2e-3, "barrier offsets moved by up to %.4f m" % worst)
	assert_true(wall_changes == 0, "wall type changed at %d points" % wall_changes)
	track.queue_free()

func test_rbr_auto_layout_is_plausible() -> void:
	var track := (load(RBR) as PackedScene).instantiate() as Track
	(track.get_node("Trackside") as Trackside).force_auto_layout = true
	add_child(track)
	var ts := track.get_node("Trackside") as Trackside
	await _built(ts)
	await physics_frames(2)
	assert_true(ts.layout.is_auto, "table ignored")
	var d := track.data
	_assert_apex_kerbs(d, ts.kerbs, "RBR auto")
	var sausage := {}
	for k in ts.kerbs:
		assert_between(float(k["len"]), 8.0, 130.0, "kerb length at %s" % k["turn"])
		if k["kind"] == "sausage":
			sausage[k["turn"]] = true
	# Tight corners only: Lauda, Remus, Schlossgold and Red Bull Mobile (R < 25 m).
	assert_true(sausage.keys() == ["T1", "T3", "T4", "T9"], "sausage kerbs at %s" % [sausage.keys()])
	var kinds := {}
	for r in ts.runoff:
		kinds["%s %s" % [r["turn"], r["kind"]]] = true
	for want: String in ["T1 tarmac", "T3 tarmac", "T4 tarmac", "T6 gravel", "T7 gravel", "T8 gravel"]:
		assert_true(kinds.has(want), "auto run-off should have %s (has %s)" % [want, kinds.keys()])
	assert_true(ts.layout.is_concrete(d.start_s) and ts.layout.is_concrete(0.0), "concrete along the start straight")
	assert_true(not ts.layout.is_concrete(2450.0), "armco on the back straight")
	# Faster arrival = wall further out: Remus (after the longest straight) vs the T2 kink side.
	var t3: float = TracksideLayout.turn_index(d)["T3"]["s_apex"]
	assert_true(ts.barrier_offset(t3, -1.0) - ts.edge_at(t3) > 20.0, "deep run-off outside Remus")
	_assert_walls(track, ts, 40.0, "RBR auto")
	track.queue_free()

func test_resolve_by_track_id() -> void:
	var d := TrackData.load_track(RBR_JSON)
	assert_true(TracksideLayout.has_table("red_bull_ring"), "RBR table found by id")
	assert_true(not TracksideLayout.has_table("test_oval") and not TracksideLayout.has_table(""), "no table for others")
	var table := TracksideLayout.for_track("red_bull_ring", d)
	var auto := TracksideLayout.for_track("red_bull_ring", d, true)
	var other := TracksideLayout.for_track("some_new_track", d)
	assert_true(not table.is_auto and auto.is_auto and other.is_auto, "table by id, auto otherwise")
	assert_true(table.kerbs.size() == 26 and table.runoff.size() == 11, "RBR table size")
	assert_true(auto.kerbs.size() == other.kerbs.size() and auto.kerbs.size() >= 10, "auto layout is id-independent")

func test_auto_detects_turns_without_a_turn_table() -> void:
	var d := TrackData.load_track(OVAL_DIR + "/track.json")
	var listed := d.turns.duplicate()
	assert_true(listed.size() == 6, "fixture lists 6 turns")
	d.turns.clear()
	var found := TracksideLayout.analyse_turns(d)
	assert_true(found.size() == listed.size(), "detected %d turns, the fixture has %d" % [found.size(), listed.size()])
	for i in mini(found.size(), listed.size()):
		var want: Dictionary = listed[i]
		var got := found[i]
		assert_true(absf(d.delta_s(float(want["s_apex"]), float(got["s_apex"]))) < 25.0,
				"turn %d apex at %.0f, expected ~%.0f" % [i + 1, got["s_apex"], want["s_apex"]])
		assert_true((float(got["sign"]) > 0.0) == (String(want["direction"]) == "right"), "turn %d direction" % (i + 1))
		assert_between(float(got["radius"]) / float(want["min_radius"]), 0.7, 1.4, "turn %d radius ratio" % (i + 1))
	var layout := TracksideLayout.for_track("", d)
	assert_true(layout.kerbs.size() >= 6 and not layout.concrete_ranges.is_empty(), "layout without a turn table")

func test_shared_profiles_match_the_cad_output() -> void:
	# cad/track/trackside_profiles.py writes the Red Bull Ring copy; the shared default that
	# every other track falls back on must not go stale.
	var cad := FileAccess.get_file_as_string("res://assets/tracks/red_bull_ring/trackside_profiles.json")
	var shared := FileAccess.get_file_as_string(Trackside.SHARED_PROFILES_PATH)
	assert_true(not shared.is_empty() and shared == cad,
			"assets/tracks/_shared/trackside_profiles.json differs from the Red Bull Ring's: copy it again")

# ------------------------------------------------------------------ synthetic fixture
func test_fixture_track_builds_with_fallbacks() -> void:
	var track := _oval()
	assert_true(track.track_id == "test_oval", "id from the folder name (%s)" % track.track_id)
	assert_true(track.data != null and track.data.points.size() > 200, "centreline loaded")
	if track.data == null:
		return
	var d := track.data
	assert_between(d.length, 600.0, 800.0, "fixture lap length (m)")
	var road := track.get_node("Road") as RoadSurface
	var terrain := track.get_node("Terrain") as Terrain
	var ts := track.get_node("Trackside") as Trackside
	assert_true(road.is_runtime_mesh, "no GLB: road ribbon built at runtime")
	assert_true(terrain.is_fallback, "no terrain.json: plain ground built")
	await _built(ts)
	await physics_frames(2)
	var kinds := {}
	for b: Node in road.find_children("*", "StaticBody3D", true, false):
		kinds[b.get_meta("surface", "")] = true
	assert_true(kinds.has("asphalt") and kinds.has("grass"), "road bodies: %s" % [kinds.keys()])
	assert_between(road.half_width_at(100.0), 5.99, 6.01, "half width from track.json")
	# The collision is the surface the queries describe; the ground stays below road and verge.
	var space := track.get_world_3d().direct_space_state
	var bad: Array[String] = []
	var s := 0.0
	while s < d.length:
		for lat: float in [0.0, -5.0, 5.0, -20.0, 20.0, 33.0]:
			if absf(lat) > road.half_width_at(s) + road.verge_at(s, lat) - 1.0:
				continue
			var p := road.surface_point(s, lat)
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 5.0, p + Vector3.DOWN * 5.0)
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				bad.append("s=%.0f lat=%.0f: nothing" % [s, lat])
				continue
			var col := hit["collider"] as Node
			if ts.is_ancestor_of(col):
				continue   # a kerb or run-off patch lies on top here
			var want := "asphalt" if absf(lat) < road.half_width_at(s) else "grass"
			if not road.is_ancestor_of(col) or col.get_meta("surface", "") != want \
					or absf(hit["position"].y - p.y) > 0.05:
				bad.append("s=%.0f lat=%.0f: %s at %.2f, expected %s at %.2f" % [
						s, lat, col.get_path(), hit["position"].y, want, p.y])
		s += 15.0
	assert_true(bad.is_empty(), "%d surface probes off, e.g. %s" % [bad.size(), bad.slice(0, 3)])
	var far := terrain.height_at(d.points[0].x + 150.0, d.points[0].z - 250.0)
	assert_true(not is_nan(far), "ground extends well beyond the lap")
	track.queue_free()

func test_fixture_auto_trackside() -> void:
	var track := _oval()
	var ts := track.get_node("Trackside") as Trackside
	await _built(ts)
	await physics_frames(2)
	if track.data == null or ts.layout == null:
		return
	var d := track.data
	assert_true(ts.layout.is_auto, "fixture has no table: automatic layout")
	_assert_apex_kerbs(d, ts.kerbs, "oval")
	var sausage := {}
	var exits := 0
	for k in ts.kerbs:
		if k["kind"] == "sausage":
			sausage[k["turn"]] = true
	for t: Dictionary in d.turns:
		var outside := -1.0 if String(t["direction"]) == "right" else 1.0
		for k in ts.kerbs:
			if k["turn"] == t["id"] and float(k["side"]) == outside:
				exits += 1
				break
	assert_true(sausage.keys() == ["T5", "T6"], "sausage kerbs only on the two R 22 m corners: %s" % [sausage.keys()])
	assert_true(exits >= 4, "exit kerbs on the outside of %d turns" % exits)
	var tarmac := 0
	var gravel := 0
	for r in ts.runoff:
		tarmac += 1 if r["kind"] == "tarmac" else 0
		gravel += 1 if r["kind"] == "gravel" else 0
	assert_true(tarmac >= 1 and ts.runoff[0]["turn"] == "T1", "tarmac behind the heavy braking zone of T1")
	assert_true(gravel >= 2, "gravel outside other corners (%d)" % gravel)
	assert_true(ts.layout.is_concrete(d.start_s) and ts.layout.is_concrete(d.length - 20.0), "concrete on the start straight")
	assert_true(not ts.layout.is_concrete(float(d.turns[2]["s_apex"])), "armco at the dent")
	# Kerbs have collision with the kerb surface, on top of the road edge.
	var space := track.get_world_3d().direct_space_state
	for k in ts.kerbs:
		if k["kind"] == "sausage":
			continue
		var s: float = float(k["s0"]) + float(k["len"]) * 0.5
		var xf := ts.frame_at(s)
		var p := ts.lateral_point(s, float(k["side"]), ts.edge_at(s) + 0.8, xf)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2.0, p - Vector3.UP * 2.0))
		assert_true(not hit.is_empty() and (hit["collider"] as Object).get_meta("surface", "") == "kerb",
				"kerb of %s at s=%.0f has kerb collision" % [k["turn"], s])
		if not hit.is_empty():
			assert_between((hit["position"] - p).dot(xf.basis.y), -0.03, 0.15, "%s kerb height above the road" % k["turn"])
	_assert_walls(track, ts, 10.0, "oval")
	track.queue_free()

func test_catalog_lists_a_fixture_folder() -> void:
	TrackCatalog.set_extra_dirs([FIXTURES])
	var info := TrackCatalog.find("test_oval")
	assert_true(info != null and info.available, "fixture track listed as playable")
	if info != null:
		assert_true(info.scene == TrackCatalog.GENERIC_SCENE, "no scene in track_info.json -> generic scene")
		assert_true(info.dir() == OVAL_DIR and info.track_json == OVAL_DIR + "/track.json", "folder: %s" % info.dir())
		assert_true(info.name == "Test Oval" and info.turns == 6, "info fields")
	var rbr := TrackCatalog.find("red_bull_ring")
	assert_true(rbr != null and rbr.available and rbr.dir() == "res://assets/tracks/red_bull_ring", "RBR still listed")
	assert_true(TrackCatalog.find("_shared") == null, "the shared defaults folder is not a track")
	var empty := TrackCatalog.find("no_data")
	assert_true(empty != null and not empty.available, "a folder without track.json is listed but not playable")
	TrackCatalog.reload()
	assert_true(TrackCatalog.find("test_oval") != null, "reload() keeps the extra folders")
	TrackCatalog.set_extra_dirs([])
	assert_true(TrackCatalog.find("test_oval") == null, "gone without the extra folder")

func test_fixture_race_spawns_and_drives() -> void:
	var saved_config := Game.config   # the race scene points Game.config at its track
	Game.config = saved_config.copy()
	Bootstrap.autodrive = true
	var scene := spawn(OVAL_RACE)
	var track := scene.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == "test_oval" and track.dir() == OVAL_DIR,
			"race scene built the fixture through the generic track scene")
	if track != null and track.data != null:
		var d := track.data
		var car := scene.get_node("Car") as Car
		var race := track.get_node("Race") as RaceManager
		race.persist_best = false
		await _built(track.get_node("Trackside") as Trackside)
		assert_true(race.sector_count == 3, "three sectors (%d)" % race.sector_count)
		assert_true(race.checkpoints.size() >= 2, "RaceManager computed checkpoints (%d)" % race.checkpoints.size())
		for i in race.checkpoints.size():
			assert_between(race.checkpoints[i], 1.0, d.length - 1.0, "checkpoint %d" % i)
			if i > 0:
				assert_true(race.checkpoints[i] > race.checkpoints[i - 1], "checkpoints in lap order")
		assert_true(race.state == RaceManager.State.RACING, "race running")
		var s := d.closest_s(car.global_position)
		assert_true(absf(d.delta_s(d.start_s - 8.0, s)) < 3.0, "car on the grid (s=%.1f)" % s)
		var progress := 0.0
		var worst_edge := INF
		var lowest := INF
		for f in 240 * 5:
			await get_tree().physics_frame
			var ns := d.closest_s(car.global_position, s)
			progress += d.delta_s(s, ns)
			s = ns
			worst_edge = minf(worst_edge, d.width_at(s) * 0.5 - absf(d.lateral_offset(car.global_position, s)))
			lowest = minf(lowest, car.global_position.y - d.position_at(s).y)
		assert_true(progress > 80.0, "drove %.0f m in 5 s" % progress)
		assert_true(worst_edge > 0.0, "car left the road (edge margin %.2f m)" % worst_edge)
		assert_between(lowest, 0.0, 1.5, "car height above the centreline (m)")
		assert_true(car.linear_velocity.length() > 15.0, "car at speed (%.0f km/h)" % (car.linear_velocity.length() * 3.6))
	Bootstrap.autodrive = false
	scene.queue_free()
	Game.config = saved_config
	TrackCatalog.set_extra_dirs([])
