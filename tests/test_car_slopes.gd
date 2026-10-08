extends TestCase
## Car on real terrain: sustained high-speed turns (the "skid in long fast corners" fix), the
## climb to Remus and the crest after T1 on the Red Bull Ring, grass grip and a kerb strip.

const HZ := 240

func _flat_car() -> Car:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(HZ / 2)
	return car

func _launch(car: Car, kmh: float) -> void:
	car.linear_velocity = -car.global_transform.basis.z * kmh / 3.6
	car.angular_velocity = Vector3.ZERO
	await physics_frames(2)

## Planar radius of the path (m) from speed / yaw rate.
func _radius(car: Car) -> float:
	var v := Vector2(car.linear_velocity.x, car.linear_velocity.z).length()
	return v / maxf(absf(car.angular_velocity.y), 1e-4)

## Holds a turn at ~300 km/h for 4 s (throttle keeps the speed) and checks it stays glued.
func _sustained_turn(steer: float) -> void:
	var car := await _flat_car()
	await _launch(car, 300.0)
	var drifted := false
	var max_slip := 0.0
	var r_min := INF
	var r_max := 0.0
	for i in 4 * HZ:
		car.set_input_override(1.0 if car.speed_kmh < 300.0 else 0.0, 0.0, steer)
		await get_tree().physics_frame
		drifted = drifted or car.is_drifting
		max_slip = maxf(max_slip, absf(car.slip_angle))
		if i >= HZ / 2:
			var r := _radius(car)
			r_min = minf(r_min, r)
			r_max = maxf(r_max, r)
	print("    300 km/h steer %.1f for 4 s: slip %.2f deg, radius %.0f..%.0f m, drift %s" % [
			steer, rad_to_deg(max_slip), r_min, r_max, drifted])
	assert_true(not drifted, "steer %.1f at 300 km/h must not drift" % steer)
	assert_true(rad_to_deg(max_slip) < 6.0, "slip stays small (%.2f deg)" % rad_to_deg(max_slip))
	assert_true(r_max < r_min * 1.15, "turn radius stays constant (%.0f..%.0f m)" % [r_min, r_max])
	assert_true(car.is_grounded, "still grounded")

func test_sustained_turn_half_lock() -> void:
	await _sustained_turn(0.5)

func test_sustained_turn_full_lock() -> void:
	await _sustained_turn(1.0)

## A brake tap mid-corner starts a drift (by design) but the slide must carve the corner,
## not wash wide (it used to: drift friction had no aero term, radius 274 -> 429 m).
func test_brake_tap_drift_does_not_wash_wide() -> void:
	var car := await _flat_car()
	await _launch(car, 300.0)
	car.set_input_override(1.0, 0.0, 1.0)
	await physics_frames(HZ / 2)
	var r_grip := _radius(car)
	car.set_input_override(1.0, 1.0, 1.0)
	await physics_frames(HZ / 10)
	car.set_input_override(1.0, 0.0, 1.0)
	var r_max := 0.0
	for i in int(1.2 * HZ):
		await get_tree().physics_frame
		if i > HZ / 4:
			r_max = maxf(r_max, _radius(car))
	print("    brake tap at 300 km/h: grip radius %.0f m, drift radius max %.0f m" % [r_grip, r_max])
	assert_true(r_max < r_grip * 1.1, "high-speed drift holds the line (%.0f vs %.0f m)" % [r_max, r_grip])

# ---------------------------------------------------------------- Red Bull Ring

func _track_car(s: float) -> Array:
	var race := spawn("res://scenes/race_red_bull_ring.tscn")
	var car := race.get_node("Car") as Car
	var track := race.get_node("Track") as Track
	var xf := track.spawn_transform(s)
	car.set_input_override(0.0, 0.0, 0.0)
	car.global_transform = xf
	car.spawn_transform = xf
	car.respawn()
	await physics_frames(HZ / 4)
	return [car, track]

## Pure-pursuit steering on the centreline, full throttle, never brakes.
func _drive(car: Car, track: Track, s_hint: float) -> float:
	var d := track.data
	var s := d.closest_s(car.global_position, s_hint)
	var v := car.linear_velocity.length()
	var target := d.position_at(s + 8.0 + v * 0.35)
	var local := car.global_transform.affine_inverse() * target
	car.set_input_override(1.0, 0.0, clampf(atan2(local.x, -local.z) * 2.5, -1.0, 1.0))
	return s

func test_climb_to_remus() -> void:
	var r := await _track_car(1150.0)
	var car: Car = r[0]
	var track: Track = r[1]
	var s := 1150.0
	var y0 := car.global_position.y
	var max_lat := 0.0
	var drifted := false
	var max_slip := 0.0
	var kmh_at: Array[float] = []
	for i in 4 * HZ:
		s = _drive(car, track, s)
		await get_tree().physics_frame
		max_lat = maxf(max_lat, absf(track.data.lateral_offset(car.global_position, s)))
		drifted = drifted or car.is_drifting
		max_slip = maxf(max_slip, absf(car.slip_angle))
		if (i + 1) % HZ == 0:
			kmh_at.append(roundf(car.speed_kmh))
	var climbed := car.global_position.y - y0
	print("    climb from s=1150 (to s=%.0f, grade %.1f%%): +%.1f m, km/h at 1..4 s %s, |lat| max %.1f m, slip %.1f deg" % [
			s, track.data.grade_at(s) * 100.0, climbed, str(kmh_at), max_lat, rad_to_deg(max_slip)])
	assert_true(climbed > 8.0, "car climbs (%.1f m)" % climbed)
	assert_between(kmh_at[3], 130.0, 220.0, "speed after 4 s uphill (km/h)")
	assert_true(max_lat < 5.0, "stays on the road (|lat| %.1f m)" % max_lat)
	assert_true(not drifted and rad_to_deg(max_slip) < 6.0, "no wheelspin slide on the climb")
	assert_true(car.is_grounded, "grounded at the end")

func test_crest_after_t1() -> void:
	var r := await _track_car(470.0)
	var car: Car = r[0]
	var track: Track = r[1]
	await _launch(car, 280.0)
	var s := 470.0
	var air_events := 0
	var was_air := false
	var max_up := 0.0
	for i in 3 * HZ:
		s = _drive(car, track, s)
		await get_tree().physics_frame
		if not car.is_grounded and not was_air:
			air_events += 1
		was_air = not car.is_grounded
		max_up = maxf(max_up, car.linear_velocity.dot(track.data.sample(s).basis.y))
	print("    crest after T1 at 280 km/h (to s=%.0f): air events %d, max v_up %.2f m/s" % [s, air_events, max_up])
	assert_true(air_events <= 1, "lands without bouncing (%d airborne phases)" % air_events)
	assert_true(max_up < 2.0, "no launch over the crest (v_up %.2f)" % max_up)
	assert_true(car.global_transform.basis.y.dot(track.data.sample(s).basis.y) > 0.98, "upright on the road")

# ---------------------------------------------------------------- surfaces

func _surface_box(parent: Node, surface: String, size: Vector3, pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.set_meta(&"surface", surface)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	body.position = pos
	parent.add_child(body)
	return body

## Full lock at 150 km/h, then brakes from 150 km/h; returns [stop distance, yaw rate].
func _brake_and_turn(car: Car) -> Array:
	await _launch(car, 150.0)
	car.set_input_override(1.0, 0.0, 1.0)
	await physics_frames(HZ / 3)
	var yaw_rate := absf(car.angular_velocity.y)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(HZ / 10)
	await _launch(car, 150.0)
	car.set_input_override(0.0, 1.0, 0.0)
	var p0 := car.global_position
	for i in 3 * HZ:
		await get_tree().physics_frame
		if car.speed_kmh < 2.0:
			break
	return [car.global_position.distance_to(p0), yaw_rate]

func test_grass_has_less_grip() -> void:
	var car := await _flat_car()
	var asphalt := await _brake_and_turn(car)
	_surface_box(car.get_parent(), "grass", Vector3(2000, 1, 2000), car.global_position - Vector3(0, 0.36 + 0.49, 0))
	await physics_frames(HZ / 8)
	var grass := await _brake_and_turn(car)
	print("    brake 150-0: asphalt %.1f m, grass %.1f m; yaw rate @150 km/h full lock: %.2f vs %.2f rad/s; surface %s" % [
			asphalt[0], grass[0], asphalt[1], grass[1], car.wheels[0].surface])
	assert_true(car.wheels[0].surface == &"grass", "wheel reports the grass surface")
	assert_true(grass[0] > asphalt[0] * 1.3, "braking distance longer on grass")
	assert_true(grass[1] < asphalt[1] * 0.95, "cornering lower on grass")
	assert_true(not car.is_drifting, "still controllable on grass")

func test_kerb_strip_no_launch() -> void:
	var car := await _flat_car()
	var fwd := -car.global_transform.basis.z
	var root := car.get_parent()
	for k in 24:   # 4 cm sawtooth: 0.3 m teeth every 0.6 m, across the car's path
		_surface_box(root, "kerb", Vector3(4, 0.08, 0.3), car.global_position + fwd * (12.0 + k * 0.6) - Vector3(0, 0.36, 0))
	await _launch(car, 180.0)
	car.set_input_override(1.0, 0.0, 0.0)
	var max_up := 0.0
	var max_w := 0.0
	var saw_kerb := false
	for i in int(1.2 * HZ):
		await get_tree().physics_frame
		max_up = maxf(max_up, car.linear_velocity.y)
		max_w = maxf(max_w, Vector2(car.angular_velocity.x, car.angular_velocity.z).length())
		for w in car.wheels:
			saw_kerb = saw_kerb or (w.contact and w.surface == &"kerb")
	print("    kerb strip at 180 km/h: max v_up %.2f m/s, max roll/pitch rate %.2f rad/s" % [max_up, max_w])
	assert_true(saw_kerb, "wheels report surface = kerb")
	assert_true(max_up < 1.0, "no launch over the kerb (v_up %.2f)" % max_up)
	assert_true(max_w < 1.5, "no spin from the kerb")
	assert_true(not car.is_drifting, "kerb does not start a drift")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.99, "upright")
