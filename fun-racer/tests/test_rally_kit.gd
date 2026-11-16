extends TestCase
## Rally and rallycross: their events take the rally family of cars, a high-riding 4WD hatchback
## with long soft suspension (rally) and its wider, more powerful rallycross version with a big
## wing. The Car has no drive layout: four-wheel drive is in the tuning (loose surfaces keep
## most of the grip, a slide keeps most of the drive).

const RALLY_SPEC := "res://assets/car/specs/rally.tres"
const RX_SPEC := "res://assets/car/specs/rallycross.tres"
const KitTest := preload("res://tests/test_indycar_kit.gd")
const MATERIAL_NODES := ["Livery", "LiveryWhite", "Accent", "Carbon", "Metal", "Helmet", "Visor", "Light",
		"Glass", "Headlight"]

func test_series_take_the_rally_cars() -> void:
	for pair in [["rally", CarKit.RALLY], ["rallycross", CarKit.RALLYCROSS]]:
		var series: String = pair[0]
		assert_true(CarKit.KITS.has(series) and series == pair[1], "%s has a car" % series)
		var events := SeriesCatalog.tracks(series)
		assert_true(events.size() >= 5, "%s: a season of events (%d)" % [series, events.size()])
		for t in events:
			assert_true(CarKit.for_track(t.id) == series, "%s is raced with the %s car" % [t.id, series])
		assert_true(not CarKit.KITS[series]["open_wheel_parts"], "%s: the wheels are inside the arches" % series)
		var w := CarKit.wheel_offsets(series)
		assert_true(is_equal_approx(w[2].z - w[0].z, 2.5), "%s: 2.50 m wheelbase" % series)
	var r := CarKit.wheel_offsets(CarKit.RALLY)
	var x := CarKit.wheel_offsets(CarKit.RALLYCROSS)
	assert_true(x[0].x < r[0].x and x[3].x > r[3].x, "the rallycross car has the wider track")

func test_specs_are_loose_surface_cars() -> void:
	var r := load(RALLY_SPEC) as CarSpec
	var x := load(RX_SPEC) as CarSpec
	var touring := load("res://assets/car/specs/touring.tres") as CarSpec
	assert_true(is_equal_approx(r.dry_mass, 1180.0) and is_equal_approx(r.wheelbase, 2.5), "rally: 1180 kg, 2.50 m")
	assert_between(r.engine_power / 1000.0, 270.0, 290.0, "rally: about 280 kW")
	assert_between(x.engine_power / 1000.0, 360.0, 380.0, "rallycross: about 370 kW")
	assert_true(r.ers_power == 0.0 and x.ers_power == 0.0, "no hybrid deployment")
	for s: CarSpec in [r, x]:
		assert_true(s.travel_bump > touring.travel_bump * 1.5 and s.travel_droop > touring.travel_droop * 1.5, "long travel")
		assert_true(s.spring_front < touring.spring_front and s.arb_front < touring.arb_front, "soft springs and bars")
		assert_true(s.cg_height > touring.cg_height, "a higher centre of mass")
		assert_true(s.tyre_slide_grip_lat > touring.tyre_slide_grip_lat, "progressive past the limit")
	assert_true(x.cl_a > r.cl_a and x.tyre_mu > r.tyre_mu, "the rallycross car grips more (wing, wider tyres)")
	# Short gearing: the rally car runs out of revs near 200 km/h, the rallycross car near 230.
	for pair in [[r, 190.0, 215.0], [x, 220.0, 245.0]]:
		var s: CarSpec = pair[0]
		var top_gear_kmh := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
		assert_between(top_gear_kmh, pair[1], pair[2], "geared top speed (%.0f km/h)" % top_gear_kmh)
	assert_true(CarKit.for_spec(RALLY_SPEC) == CarKit.RALLY and CarKit.for_spec(RX_SPEC) == CarKit.RALLYCROSS, "spec to kit")
	for spec in [RALLY_SPEC, RX_SPEC]:
		assert_true(not CarEnvelope.for_spec(spec, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % spec)

func test_arcade_tuning() -> void:
	var touring := _car(CarKit.TOURING)
	var r := _car(CarKit.RALLY)
	var x := _car(CarKit.RALLYCROSS)
	assert_true(is_equal_approx(r.mass, 1180.0) and r.sim_spec_path == RALLY_SPEC, "rally physics")
	assert_true(is_equal_approx(x.mass, 1300.0) and x.sim_spec_path == RX_SPEC, "rallycross physics")
	for c: Car in [r, x]:
		# Four-wheel drive and gravel tyres, by tuning: loose surfaces keep most of the grip.
		assert_true(c.gravel_grip >= 0.75 and c.gravel_grip > touring.gravel_grip * 1.5, "%s grips on gravel" % c.kit)
		assert_true(c.grass_grip > touring.grass_grip and c.gravel_drag < touring.gravel_drag, "%s runs on loose ground" % c.kit)
		assert_true(c.travel_up > touring.travel_up and c.travel_down > touring.travel_down, "%s: long travel" % c.kit)
		assert_true(c.bump_stop_start < c.travel_up, "%s: the bump stop is inside the travel" % c.kit)
		assert_true(c.spring_rate < touring.spring_rate and c.anti_roll_rate < touring.anti_roll_rate, "%s: soft" % c.kit)
		# Slide-friendly but controllable: an easy entry, the drive kept in a slide, grip back fast.
		assert_true(c.drift_min_speed_kmh < touring.drift_min_speed_kmh and c.drift_entry_time < touring.drift_entry_time,
				"%s slides easily" % c.kit)
		assert_true(c.drift_drive_factor > touring.drift_drive_factor and c.drift_speed_retention > touring.drift_speed_retention,
				"%s pulls through a slide" % c.kit)
		assert_true(c.drift_recover_grip > touring.drift_recover_grip, "%s: the grip comes back quickly" % c.kit)
		assert_true(c.drift_lateral_grip_g < c.lateral_grip_g, "%s: a slide still grips less than the tyres" % c.kit)
	assert_between(KitTest._top(r), 195.0, 215.0, "rally top speed near 205 km/h")
	assert_between(KitTest._top(x), 230.0, 250.0, "rallycross top speed near 240 km/h")
	assert_between(time_to(r, 100.0), 2.7, 3.6, "rally 0-100 km/h in about 3 s (%.2f)" % time_to(r, 100.0))
	assert_between(time_to(x, 100.0), 1.8, 2.3, "rallycross 0-100 km/h in about 2 s (%.2f)" % time_to(x, 100.0))
	for c: Car in [touring, r, x]:
		c.free()

func test_bodies_dress_a_car() -> void:
	await dress_check(self, CarKit.RALLY, "res://assets/car/rally/body.glb", 1180.0)
	await dress_check(self, CarKit.RALLYCROSS, "res://assets/car/rallycross/body.glb", 1300.0)

func test_event_races_spawn_rally_cars() -> void:
	await KitTest._race_check(self, "rally", CarKit.RALLY, "res://assets/car/rally/body.glb", 1180.0, RALLY_SPEC, false)
	await KitTest._race_check(self, "rallycross", CarKit.RALLYCROSS, "res://assets/car/rallycross/body.glb", 1300.0,
			RX_SPEC, false)

func _car(kit: String) -> Car:
	var c := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(c, kit)
	c.kit = kit
	return c

## Seconds from standstill to `kmh` at full throttle on the arcade acceleration curve.
static func time_to(car: Car, kmh: float) -> float:
	var t := 0.0
	var v := 0.0
	var dv := 0.5
	while v < kmh:
		var a := KitTest._accel(car, v + 0.5 * dv)
		if a <= 0.0:
			return INF
		t += dv / 3.6 / a
		v += dv
	return t

## Dresses the player's car on a built F1 circuit with `kit` (the series has no built event yet)
## and checks the body, its material nodes in the order the body scene overrides them, the
## hidden open-wheel parts, the wheels on the kit's axles and the kit's physics.
static func dress_check(t: TestCase, kit: String, glb: String, mass: float) -> void:
	var saved_track := Game.config.track_id
	var saved_bots := Game.config.bots
	Game.config.track_id = "red_bull_ring"
	Game.config.bots = 0
	Bootstrap.autodrive = false
	var scene := t.spawn("res://scenes/race.tscn")
	await t.physics_frames(2)
	var car := scene.get_node("Car") as Car
	CarKit.apply(car, kit)
	await t.physics_frames(2)
	for i in 2:   # the wheel visuals follow visual_wheel_offsets in _process
		await t.get_tree().process_frame
	var body := car.get_node_or_null(^"BodyVisual/Body")
	t.assert_true(body != null and body.scene_file_path == glb, "%s body %s" % [kit, glb])
	if body != null:
		for i in MATERIAL_NODES.size():
			var n := body.get_child(i) if i < body.get_child_count() else null
			t.assert_true(n != null and n.name == MATERIAL_NODES[i], "%s: material node %d is %s" % [kit, i, MATERIAL_NODES[i]])
	t.assert_true(car.get_node(^"BodyVisual").get_script() != null, "%s keeps the head motion script" % kit)
	t.assert_true(not (car.get_node(^"WheelFL/Suspension") as Node3D).visible, "%s hides the wishbones" % kit)
	var w := CarKit.wheel_offsets(kit)
	t.assert_true(is_equal_approx(car.wheelbase, w[2].z - w[0].z), "%s physics wheelbase" % kit)
	t.assert_true(is_equal_approx((car.get_node(^"WheelFL") as Node3D).position.z, w[0].z), "%s front wheel on its axle" % kit)
	t.assert_true(is_equal_approx(car.mass, mass) and car.sim_spec_path == CarKit.KITS[kit]["sim_spec"], "%s physics" % kit)
	scene.queue_free()
	await t.get_tree().process_frame
	Game.config.track_id = saved_track
	Game.config.bots = saved_bots
