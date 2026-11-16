extends TestCase
## Measured road cross-sections ([road] sections = "lidar", cad/track/road_sections.py), on
## tests/fixtures/tracks/measured_oval: the stadium oval built from a synthetic lidar grid with
## a known surface (make_measured_oval.py): a 2.5 % crown with a drainage break 4.5 m right of
## the centre on the straights, 4 % camber into the two turns. The road surface queries must be
## the mesh and its collision, the chunks must join without a step, cars must start and rest on
## the measured surface and the autopilot must lap it in both handling models.

const GENERIC := "res://scenes/tracks/track.tscn"
const FIXTURES := "res://tests/fixtures/tracks"
const OVAL_DIR := "res://tests/fixtures/tracks/measured_oval"
const OVAL_RACE := "res://tests/fixtures/tracks/race_test_oval.tscn"
const CAR_SCENE := "res://scenes/car/car.tscn"
const CROWN := 0.025         ## make_measured_oval.py
const CAMBER := 0.04
const STRAIGHT_S := 100.0    ## middle of the top half straight (the grid is at 60 m)
const TURN_S := 325.7        ## middle of the east turn
const HZ := 240

func _oval() -> Track:
	var track := (load(GENERIC) as PackedScene).instantiate() as Track
	track.track_dir = OVAL_DIR
	add_child(track)
	return track

## First hit of a downward ray through `at` on a body of the road.
func _road_hit(road: Node3D, at: Vector3) -> Dictionary:
	var space := road.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 5.0, at + Vector3.DOWN * 5.0)
	var exclude: Array[RID] = []
	for attempt in 8:
		q.exclude = exclude
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return hit
		var col := hit["collider"] as Node
		if col != null and road.is_ancestor_of(col):
			return hit
		exclude.append(hit["rid"])
	return {}

func test_profile_has_the_measured_sections() -> void:
	var track := _oval()
	await physics_frames(2)
	var road := track.get_node("Road") as RoadSurface
	assert_true(road.has_sections(), "the profile has measured sections")
	# Mesh columns at most 1 m apart (cad/track/road_sections.py MESH_SPACING).
	var widest := 0.0
	for w in track.data.widths:
		widest = maxf(widest, w)
	assert_true(road.xsec_columns >= 3 and widest / (road.xsec_columns - 1) <= 1.0 + 1e-3
			and road.xsec.size() == road.xsec_columns * track.data.points.size(),
			"xsec: %d columns per point over %.1f m" % [road.xsec_columns, widest])
	assert_true(not road.is_runtime_mesh, "the CAD mesh is used")
	track.queue_free()

func test_surface_queries_are_the_mesh() -> void:
	var track := _oval()
	await physics_frames(3)
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	var rng := RandomNumberGenerator.new()
	rng.seed = 2207
	var worst := 0.0
	var misses := 0
	for k in 600:
		var s := rng.randf() * d.length
		var hw := road.half_width_at(s)
		var lat := rng.randf_range(-hw + 0.01, hw - 0.01)
		var want := road.surface_point(s, lat)
		var hit := _road_hit(road, want)
		if hit.is_empty():
			misses += 1
			continue
		worst = maxf(worst, absf((hit["position"] as Vector3).y - want.y))
		assert_true((hit["collider"] as Node).get_meta("surface", "") == "asphalt", "asphalt at s=%.1f lat=%.2f" % [s, lat])
	assert_true(misses == 0, "%d probes found no road" % misses)
	assert_true(worst < 0.002, "surface_point() is the collision mesh to 2 mm (%.4f m)" % worst)
	print("    measured sections: surface_point() vs collision mesh %.4f m over 600 probes" % worst)
	track.queue_free()

func test_the_known_crown_and_camber() -> void:
	var track := _oval()
	await physics_frames(2)
	var road := track.get_node("Road") as RoadSurface
	# Straight: the centre is the ridge, both edges lower by the crown (the right one more,
	# beyond the drainage break).
	var hw := road.half_width_at(STRAIGHT_S)
	var c := road.surface_point(STRAIGHT_S, 0.0)
	var l := road.surface_point(STRAIGHT_S, -hw)
	var r := road.surface_point(STRAIGHT_S, hw)
	# (The fit rounds the ridge by a few mm and the grid's bilinear blur lifts the edges a little.)
	assert_between(c.y - l.y, CROWN * hw - 0.015, CROWN * hw + 0.015, "crown: centre above the left edge (m)")
	assert_between(c.y - r.y, CROWN * hw + 0.03 * (hw - 4.5) - 0.02, CROWN * hw + 0.03 * (hw - 4.5) + 0.01,
			"crown + drainage break: centre above the right edge (m)")
	assert_true(c.y - l.y < c.y - r.y - 0.03, "the right side falls further, beyond the drainage break")
	# Turn: one slope, right (inside of the right-hander) lower.
	hw = road.half_width_at(TURN_S)
	var tl := road.surface_point(TURN_S, -hw)
	var tr := road.surface_point(TURN_S, hw)
	assert_between((tl.y - tr.y) / (2.0 * hw), CAMBER - 0.003, CAMBER + 0.003, "camber into the turn")
	assert_between(road.bank_at(TURN_S), CAMBER - 0.003, CAMBER + 0.003, "bank = the measured cross slope")
	track.queue_free()

func test_no_step_at_chunk_joins() -> void:
	var track := _oval()
	await physics_frames(3)
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	assert_true(road.chunk_ranges.size() >= 4, "several chunks (%d)" % road.chunk_ranges.size())
	var worst := 0.0
	for ch: Array in road.chunk_ranges:
		var s := float(ch[0]) * d.step
		var hw := road.half_width_at(s)
		for lat: float in [-hw + 0.2, -2.1, 0.3, 3.3, hw - 0.2]:
			# Probes 2 cm either side of the shared cross-section land on the two chunks.
			var a := _road_hit(road, road.surface_point(s - 0.02, lat))
			var b := _road_hit(road, road.surface_point(s + 0.02, lat))
			assert_true(not a.is_empty() and not b.is_empty(), "road either side of the join at s=%.0f" % s)
			if a.is_empty() or b.is_empty():
				continue
			var ya := (a["position"] as Vector3).y
			var yb := (b["position"] as Vector3).y
			# The grade over 4 cm is a few mm at most; a step would be the sections' heights.
			worst = maxf(worst, absf(ya - yb))
	assert_true(worst < 0.003, "no step across chunk joins (%.4f m)" % worst)
	track.queue_free()

## A car of `handling` spawned at `s`, `lateral` m right of the centre, left alone.
func _parked(track: Track, handling: StringName, s: float, lateral: float) -> Car:
	var car := (load(CAR_SCENE) as PackedScene).instantiate() as Car
	car.handling = handling
	var xf := track.spawn_transform(s, lateral)
	car.transform = xf
	add_child(car)
	car.spawn_transform = xf
	car.set_input_override(0.0, 0.3 if handling == Car.HANDLING_SIMULATION else 0.0, 0.0)
	return car

func _rests_on_the_surface(handling: StringName) -> void:
	var track := _oval()
	await physics_frames(3)
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	# The spawn is on the measured surface: the right edge of the straight is ~20 cm below the
	# centreline, which a spawn in TrackData's flat frame would leave hanging in the air.
	var lat := road.half_width_at(STRAIGHT_S) - 1.5
	var xf := track.spawn_transform(STRAIGHT_S, lat)
	var surf := road.surface_point(STRAIGHT_S, lat)
	assert_between(xf.origin.y - surf.y, Car.REAR_WHEEL_RADIUS + 0.04, Car.REAR_WHEEL_RADIUS + 0.06,
			"spawn height above the measured surface (m)")
	var car := _parked(track, handling, STRAIGHT_S, lat)
	await physics_frames(3 * HZ)
	var p := car.global_position
	var grounded := 0
	for w: WheelState in car.wheels:
		grounded += 1 if w.contact else 0
	assert_true(grounded == 4, "%s: all four wheels on the measured road (%d)" % [handling, grounded])
	var s := d.closest_s(p)
	var under := road.surface_point(s, d.lateral_offset(p, s))
	assert_between(p.y - under.y, 0.2, 0.5, "%s: resting on the measured surface (m above it)" % handling)
	assert_true(car.linear_velocity.length() < 0.1, "%s: at rest (%.3f m/s)" % [handling, car.linear_velocity.length()])
	car.queue_free()
	track.queue_free()

func test_arcade_car_rests_on_the_measured_road() -> void:
	await _rests_on_the_surface(Car.HANDLING_ARCADE)

func test_simulation_car_rests_on_the_measured_road() -> void:
	await _rests_on_the_surface(Car.HANDLING_SIMULATION)

## One lap of the measured oval from the grid with the autopilot, clean.
func _lap(handling: StringName) -> void:
	var saved_config := Game.config
	Game.config = saved_config.copy()
	TrackCatalog.set_extra_dirs(PackedStringArray([FIXTURES]))
	Bootstrap.handling_override = handling
	Bootstrap.autodrive = true
	var scene := (load(OVAL_RACE) as PackedScene).instantiate()
	scene.set(&"track_id", "measured_oval")
	add_child(scene)
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var track := scene.get_node("Track") as Track
	var d := track.data
	var road := track.get_node("Road") as RoadSurface
	(track.get_node("Race") as RaceManager).persist_best = false
	assert_true(track.dir() == OVAL_DIR and road.has_sections(), "the %s car on the measured oval" % handling)
	var s := d.closest_s(car.global_position)
	var t := 0.0
	var worst_edge := INF
	var impacts := 0
	var prev_speed := 0.0
	var airborne := 0
	while t < 110.0 and pilot.laps_completed < 1:
		await get_tree().physics_frame
		t += 1.0 / HZ
		var pos := car.global_position
		s = d.closest_s(pos, s)
		worst_edge = minf(worst_edge, road.half_width_at(s) - absf(d.lateral_offset(pos, s)))
		var speed := car.linear_velocity.length()
		if prev_speed - speed > 8.0:
			impacts += 1
		prev_speed = speed
		var grounded := 0
		for w: WheelState in car.wheels:
			grounded += 1 if w.contact else 0
		airborne += 1 if grounded == 0 and t > 1.0 else 0
	assert_true(pilot.laps_completed >= 1, "%s: lap not completed in 110 s" % handling)
	assert_true(worst_edge > 0.0, "%s: car left the road (edge margin %.2f m)" % [handling, worst_edge])
	assert_true(impacts == 0, "%s: %d impact(s)" % [handling, impacts])
	assert_true(airborne < HZ / 10, "%s: airborne for %d ticks (a step in the road?)" % [handling, airborne])
	print("    %s lap of the measured oval: %.2f s, min edge %.2f m" % [handling, pilot.lap_time, worst_edge])
	Bootstrap.autodrive = false
	Bootstrap.handling_override = &""
	scene.queue_free()
	Game.config = saved_config
	TrackCatalog.set_extra_dirs([])

func test_arcade_autopilot_laps_the_measured_road() -> void:
	await _lap(Car.HANDLING_ARCADE)

func test_simulation_autopilot_laps_the_measured_road() -> void:
	await _lap(Car.HANDLING_SIMULATION)
