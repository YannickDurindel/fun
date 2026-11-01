extends TestCase
## Motorcycle Grand Prix: its events take the moto kit, a prototype race bike (cad/body/moto_body.py)
## ridden on the Car's physics (four hidden contacts close together, bike tuning) with a lean,
## wheelie / stoppie and rider layer on the visual (scripts/car/bike_visual.gd).

const KIT := "moto"
const SPEC := "res://assets/car/specs/moto.tres"
const GLB := "res://assets/car/moto/body.glb"
const HZ := 240
const LINKED := {
	"mgp_austin": "cota", "mgp_lusail": "lusail", "mgp_catalunya": "catalunya",
	"mgp_sachsenring": "sachsenring", "mgp_silverstone": "silverstone", "mgp_misano": "misano",
	"mgp_spielberg": "red_bull_ring", "mgp_sepang": "sepang",
}

func test_series_takes_the_bike() -> void:
	assert_true(CarKit.KITS.has(KIT) and CarKit.MOTO == KIT and CarKit.is_bike(KIT), "the motorcycle series has a bike")
	assert_true(not CarKit.is_bike(CarKit.F1) and not CarKit.is_bike(CarKit.KART), "cars are not bikes")
	var w := CarKit.wheel_offsets(KIT)
	assert_true(is_equal_approx(w[2].z - w[0].z, 1.45), "1.45 m wheelbase")
	assert_true(absf(w[0].x) <= 0.25, "the hidden contacts sit close together")
	for t in SeriesCatalog.tracks(KIT):
		assert_true(CarKit.for_track(t.id) == KIT, "%s is raced on the bike" % t.id)
	for id: String in LINKED:
		var t := TrackCatalog.find(id)
		assert_true(t != null and t.series == KIT and t.circuit == LINKED[id] and t.available,
				"%s is playable on %s" % [id, LINKED[id]])
	assert_true(SeriesCatalog.is_playable(KIT), "the series can be raced")
	var other := TrackCatalog.find("mgp_mugello")
	assert_true(other != null and not other.available, "events on unbuilt circuits stay coming soon")

func test_spec_is_a_gp_bike() -> void:
	var s := load(SPEC) as CarSpec
	assert_true(is_equal_approx(s.wheelbase, 1.45), "spec wheelbase matches the kit")
	assert_true(is_equal_approx(s.dry_mass, 227.0), "157 kg bike + 70 kg rider")
	assert_between(s.engine_power / 1000.0, 190.0, 210.0, "about 200 kW")
	assert_true(s.gear_ratios.size() == 6, "six speeds")
	var v := pow(2.0 * s.engine_power * s.driveline_efficiency / (s.air_density * s.cd_a), 1.0 / 3.0) * 3.6
	assert_between(v, 340.0, 370.0, "drag-limited top speed near 355 km/h (%.0f)" % v)
	var top_gear := s.rpm_max * TAU / 60.0 * Car.REAR_WHEEL_RADIUS / (s.gear_ratios[-1] * s.final_drive) * 3.6
	assert_true(top_gear > v, "the engine reaches the drag limit in top gear (%.0f km/h)" % top_gear)
	assert_true(s.brake_bias_front > 0.7, "most of the braking on the front")
	assert_true(CarKit.for_spec(SPEC) == KIT, "spec to kit")
	assert_true(not CarEnvelope.for_spec(SPEC, null).provisional, "the committed envelope is current (tools/lap_grip_sweep.gd --envelope --spec=%s)" % SPEC)

func test_arcade_tuning() -> void:
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	CarKit.apply_physics(car, KIT)
	assert_true(is_equal_approx(car.mass, 227.0) and car.sim_spec_path == SPEC, "bike physics")
	assert_true(car.inertia.y < 100.0, "a bike's inertia")
	var bike := CarKit.bike(KIT)
	# Below 150 km/h the drive is the wheelie limit, never past it; the brakes stay under the
	# stoppie limit.
	for i in car.accel_curve_kmh.size():
		assert_true(car.accel_curve_ms2[i] <= float(bike["wheelie_accel"]) + 1e-3, "no looping wheelie at %d km/h" % car.accel_curve_kmh[i])
	assert_true(car.brake_decel < float(bike["stoppie_decel"]) and car.brake_decel > 11.0, "very strong brakes, short of a stoppie")
	# 0-100 km/h and top speed from the table.
	var t := 0.0
	var v := 0.0
	while v < 100.0 / 3.6 and t < 10.0:
		v += car._accel_at(v * 3.6) / HZ
		t += 1.0 / HZ
	assert_between(t, 2.4, 2.9, "0-100 km/h in about 2.6 s (%.2f)" % t)
	var top := 0.0
	for i in car.accel_curve_kmh.size():
		if car.accel_curve_ms2[i] > 0.0:
			top = car.accel_curve_kmh[i + 1]
	assert_between(top, 345.0, 365.0, "about 355 km/h flat out")
	# The cornering budget is what a lean of up to 60 deg holds.
	var lean := rad_to_deg(atan(car.steer_grip_usage * car.lateral_grip_g))
	assert_between(lean, 52.0, 60.0, "full cornering leans the bike %.0f deg" % lean)
	assert_true(car.drift_min_speed_kmh > 1000.0 and car.overdrive_min_speed_kmh > 1000.0, "no car slides")
	var box := car.get_node(^"Collision") as CollisionShape3D
	var size := (box.shape as BoxShape3D).size
	assert_true(size.x < 0.8 and size.z < 2.2, "a bike-sized box")
	assert_true(box.position.y - 0.5 * size.y > -0.36 + 0.08, "the box clears the road")
	car.free()

## Arcade: rests upright, launches, tops out, brakes; the body never rolls whatever it does.
func test_rides_on_flat_ground() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	CarKit.apply(car, KIT)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(HZ)
	var body := car.get_node_or_null(^"BodyVisual/Lean/Pitch/Body")
	assert_true(body != null and body.scene_file_path == GLB, "bike body")
	assert_true(car.get_node_or_null(^"BodyVisual/Lean/Pitch/Rider/Torso/RiderUpper/Helmet") != null, "a rider with a helmet")
	for n: String in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		assert_true(not (car.get_node(n) as Node3D).visible, "%s hidden: the bike draws its own two" % n)
	var rear := car.get_node(^"BodyVisual/Lean/Pitch/RearSpin") as Node3D
	assert_between(rear.global_position.y - 0.33, -0.03, 0.03, "rear tyre stands on the road")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.999, "rests upright")
	assert_true(car.linear_velocity.length() < 0.05, "at rest, no buzz")
	car.set_input_override(1.0, 0.0, 0.0)
	var t100 := -1.0
	var vis := car.get_node(^"BodyVisual")
	var max_pitch := 0.0
	for tick in range(1, 30 * HZ + 1):
		await get_tree().physics_frame
		max_pitch = maxf(max_pitch, float(vis.get(&"pitch")))
		if t100 < 0.0 and car.speed_kmh >= 100.0:
			t100 = tick / float(HZ)
	assert_between(t100, 2.3, 3.1, "0-100 km/h (%.2f s)" % t100)
	assert_between(car.speed_kmh, 340.0, 362.0, "flat out (%.0f km/h)" % car.speed_kmh)
	assert_between(rad_to_deg(max_pitch), 0.5, 4.5, "the front goes light on the launch")
	assert_true(float(vis.get(&"tuck")) > 0.7, "tucked in on the straight")
	car.set_input_override(0.0, 1.0, 0.0)
	var v0 := car.linear_velocity.length()
	await physics_frames(HZ)
	var decel := (v0 - car.linear_velocity.length())
	assert_between(decel, 12.0, 15.0, "about 1.3 g of braking at speed (%.1f m/s^2)" % decel)
	assert_true(float(vis.get(&"pitch")) < -0.02, "the rear lifts under the hardest braking")
	assert_true(float(vis.get(&"tuck")) < 0.0, "the rider sits up on the brakes")
	var stop := -1.0
	for tick in range(1, 30 * HZ + 1):
		await get_tree().physics_frame
		if car.speed_kmh < 1.0:
			stop = tick / float(HZ)
			break
	assert_true(stop > 0.0, "stops")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.999, "still upright")

## The lean: the bike leans into the corner by atan(a_lat / g) (to the right in a right-hand
## turn), the rider hangs off the inside, the physics body stays level, and it stands up again
## on the straight.
func test_lean_follows_the_cornering() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	CarKit.apply(car, KIT)
	var vis := car.get_node(^"BodyVisual")
	var lean_node := car.get_node(^"BodyVisual/Lean") as Node3D
	car.set_input_override(1.0, 0.0, 0.0)
	while car.speed_kmh < 120.0:
		await get_tree().physics_frame
	for dir: float in [1.0, -1.0]:
		# Hold about 120 km/h on a steady turn.
		var a_lat := 0.0
		var min_up := 1.0
		for k in 4 * HZ:
			var thr := clampf(0.5 + (120.0 - car.speed_kmh) * 0.05, 0.0, 1.0)
			car.set_input_override(thr, 0.0, dir * 0.8)
			await get_tree().physics_frame
			min_up = minf(min_up, car.global_transform.basis.y.dot(Vector3.UP))
			a_lat = -car.angular_velocity.y * car.linear_velocity.length()
		await get_tree().process_frame
		var lean := float(vis.get(&"lean"))
		var expect := atan(a_lat / 9.81)
		assert_true(signf(lean) == dir, "leans into a %s-hand turn (%.0f deg)" % ["right" if dir > 0 else "left", rad_to_deg(lean)])
		assert_between(absf(rad_to_deg(lean)), 25.0, 60.0, "a real lean (%.0f deg at %.0f km/h)" % [rad_to_deg(lean), car.speed_kmh])
		assert_between(rad_to_deg(lean - expect), -4.0, 4.0, "lean = atan(a_lat / g) (%.1f vs %.1f deg)" % [rad_to_deg(lean), rad_to_deg(expect)])
		# The visual lean rolls the bike about its contact line: the top of the bike moves to the inside.
		var top := lean_node.transform * Vector3(0.0, 0.5, 0.0)
		assert_true(signf(top.x) == dir, "the bike's top moves to the inside")
		assert_true(signf(float(vis.get(&"hang"))) == dir and absf(float(vis.get(&"hang"))) > 0.5, "the rider hangs off the inside")
		assert_true(min_up > 0.995, "the physics body never rolls (%.4f)" % min_up)
	# Straight again: it stands up.
	for k in 2 * HZ:
		car.set_input_override(clampf(0.5 + (120.0 - car.speed_kmh) * 0.05, 0.0, 1.0), 0.0, 0.0)
		await get_tree().physics_frame
	await get_tree().process_frame
	assert_between(rad_to_deg(float(vis.get(&"lean"))), -2.0, 2.0, "stands up on the straight")
	# Full lock at 60 km/h never leans past the limit.
	for k in 3 * HZ:
		car.set_input_override(clampf(0.5 + (60.0 - car.speed_kmh) * 0.1, 0.0, 1.0), 0.0, 1.0)
		await get_tree().physics_frame
		assert_true(absf(float(vis.get(&"lean"))) <= deg_to_rad(60.0) + 1e-4, "never past 60 deg")

## Without a Car (the ghost, a bot on rails) the lean comes from the visual's own motion.
func test_lean_from_motion_alone() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var vis := (load(CarKit.MOTO_KIT["body"]) as PackedScene).instantiate() as Node3D
	holder.add_child(vis)
	vis.set_process(false)
	# A left turn of 80 m radius at 25 m/s: 7.8 m/s^2, atan(7.8 / 9.81) = 38.5 deg.
	var r := 80.0
	var v := 25.0
	var dt := 1.0 / 60.0
	for k in 240:
		var a := v / r * k * dt
		holder.global_transform = Transform3D(Basis(Vector3.UP, a), Vector3(-r + r * cos(a), 0.0, -r * sin(a)))
		vis.call(&"step", dt)
	var lean := rad_to_deg(float(vis.get(&"lean")))
	assert_between(lean, -41.0, -36.0, "leans left about 38.5 deg from the motion (%.1f)" % lean)
	assert_between(float(vis.get(&"speed")), 24.0, 26.0, "speed from the motion")
	holder.queue_free()
	await get_tree().process_frame

## Simulation: the same stand-in contacts on the force model. Launches, tops out, corners
## upright.
func test_simulation_rides() -> void:
	var car := await SimRig.spawn(self)
	CarKit.apply_physics(car, KIT)
	await physics_frames(HZ)
	assert_true(car.sim != null and car.sim.spec.gear_ratios.size() == 6, "simulation on the bike spec")
	var r := await SimRig.launch(self, car, 25.0, [100.0, 200.0, 300.0])
	print("  moto sim launch: %s" % r)
	assert_between(r["t_100"], 2.2, 3.8, "0-100 km/h near 2.6 s (%.2f)" % r["t_100"])
	assert_true(r["t_300"] > 0.0, "reaches 300 km/h")
	assert_between(r["v_end_kmh"], 330.0, 370.0, "top speed near 355 km/h")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.99, "upright")
	var lat := await SimRig.max_lateral_g(self, car, 120.0)
	print("  moto sim lateral: %s" % lat)
	assert_between(lat["lat_g"], 1.2, 2.0, "corners at %.2f g" % lat["lat_g"])
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.97, "stays upright at the limit")
	var b := await SimRig.brake_from(self, car, 200.0)
	print("  moto sim brake: %s" % b)
	assert_between(b["mean_g"], 0.9, 1.6, "strong brakes (%.2f g)" % b["mean_g"])
	car.queue_free()

## A Motorcycle GP event: the player and the bots are on bikes, and the bots ride a lap
## start on the real circuit (the player's bike on the autopilot) without leaving the road.
func test_event_race_bots_ride() -> void:
	await _ride_event(&"")

## The same in the simulation (opt-in): bots and the autopilot plan from the measured envelope.
func test_event_race_bots_ride_simulation() -> void:
	await _ride_event(Car.HANDLING_SIMULATION)

func _ride_event(handling: StringName) -> void:
	var saved_track := Game.config.track_id
	var saved_bots := Game.config.bots
	var saved_handling := Bootstrap.handling_override
	Bootstrap.handling_override = handling
	Game.config.track_id = "mgp_spielberg"
	Game.config.bots = 3
	Bootstrap.autodrive = true
	var scene := spawn("res://scenes/race.tscn")
	await physics_frames(3)
	var track := scene.get_node("Track") as Track
	(track.get_node("Race") as RaceManager).persist_best = false
	var player := scene.get_node("Car") as Car
	var mgr := scene.get_node("Bots") as BotManager
	var cars: Array[Car] = [player]
	cars.append_array(mgr.bots)
	assert_true(cars.size() == 4, "player and three bots")
	for car in cars:
		assert_true(car.kit == KIT and car.sim_spec_path == SPEC, "%s rides the bike" % car.name)
		assert_true((car.sim != null) == (handling == Car.HANDLING_SIMULATION), "%s on the %s model" % [car.name, handling])
		var body := car.get_node_or_null(^"BodyVisual/Lean/Pitch/Body")
		assert_true(body != null and body.scene_file_path == GLB, "%s bike body" % car.name)
	assert_true(BotManager.far_wheel_mesh(KIT).get_surface_count() == 0, "no four-wheel stand-in for far bikes")
	var d := track.data
	var waited := 0
	while player.linear_velocity.length() < 1.0 and waited < HZ * 12:
		await physics_frames(1)
		waited += 1
	var start: Array[float] = []
	for i in mgr.drivers.size():
		start.append(mgr.drivers[i].progress)
	var worst := INF
	var top := 0.0
	var max_lean := 0.0
	for k in 30 * HZ:
		await physics_frames(1)
		for car in cars:
			var s := d.closest_s(car.global_position)
			worst = minf(worst, d.width_at(s) * 0.5 + 1.0 - absf(d.lateral_offset(car.global_position, s)))
			top = maxf(top, car.speed_kmh)
		max_lean = maxf(max_lean, absf(float(player.get_node(^"BodyVisual").get(&"lean"))))
	assert_true(worst > 0.0, "every bike stays on the road (worst margin %.2f m, 1 m of kerb allowed)" % worst)
	assert_true(top > 250.0, "flat out on the straights (%.0f km/h)" % top)
	assert_between(rad_to_deg(max_lean), 35.0, 60.0, "knee down in the corners (%.0f deg)" % rad_to_deg(max_lean))
	for i in mgr.drivers.size():
		var gone: float = mgr.drivers[i].progress - start[i]
		assert_true(gone > 1000.0 and mgr.drivers[i].respawns == 0, "bot %d rode %.0f m without a respawn" % [i + 1, gone])
	Bootstrap.autodrive = false
	scene.queue_free()
	await get_tree().process_frame
	Bootstrap.handling_override = saved_handling
	Game.config.track_id = saved_track
	Game.config.bots = saved_bots
