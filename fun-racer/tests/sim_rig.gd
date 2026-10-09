class_name SimRig
extends RefCounted
## Test rig for the simulation car: a flat, infinite asphalt pad and standard manoeuvres that
## return measurements. All run headless on the physics clock (240 Hz), so results are
## deterministic. Use from a TestCase:
##     var car := await SimRig.spawn(self)
##     var r := await SimRig.launch(self, car)          # {"t_100": 2.6, "t_200": ..., ...}

const HZ: int = 240
const TICK: float = 1.0 / 240.0
const G: float = 9.81

## A car in simulation handling, settled on the pad at a standstill, inputs neutral.
## Pass `handling` = Car.HANDLING_ARCADE to compare with the arcade model.
static func spawn(tc: TestCase, handling: StringName = &"simulation") -> Car:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	ground.add_child(shape)
	tc.add_child(ground)
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	car.handling = handling
	car.position = Vector3(0, 0.40, 0)
	tc.add_child(car)
	car.set_input_override(0.0, 0.0, 0.0)
	await tc.physics_frames(HZ)
	return car

## Holds the given inputs for `seconds`; returns per-tick samples
## {t, speed (m/s), x (Vector3), ax, ay (m/s^2), yaw_rate}.
static func drive(tc: TestCase, car: Car, seconds: float, throttle: float, brake: float, steer: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	car.set_input_override(throttle, brake, steer)
	for k in int(seconds * HZ):
		await tc.get_tree().physics_frame
		out.append(_sample(car, (k + 1) * TICK))
	return out

static func _sample(car: Car, t: float) -> Dictionary:
	var st: SimState = car.sim.state if car.sim != null else null
	return {"t": t, "speed": car.linear_velocity.length(), "x": car.global_position,
			"ax": st.accel_long if st else 0.0, "ay": st.accel_lat if st else 0.0,
			"yaw_rate": car.angular_velocity.y}

## Puts the car at `kmh`, rolling straight (simulation handling only).
static func set_speed(car: Car, kmh: float) -> void:
	car.sim.set_speed(kmh / 3.6)

## Standing start at full throttle. Returns the time to reach each target speed (s, -1 if
## not reached within max_s), the distance covered and the final speed.
static func launch(tc: TestCase, car: Car, max_s: float = 25.0, targets: Array = [100.0, 200.0, 300.0]) -> Dictionary:
	var res := {"v_end_kmh": 0.0, "distance": 0.0, "peak_g": 0.0}
	for kmh: float in targets:
		res["t_%d" % int(kmh)] = -1.0
	car.set_input_override(1.0, 0.0, 0.0)
	var start := car.global_position
	for k in int(max_s * HZ):
		await tc.get_tree().physics_frame
		var kmh_now := car.linear_velocity.length() * 3.6
		for kmh: float in targets:
			var key := "t_%d" % int(kmh)
			if res[key] < 0.0 and kmh_now >= kmh:
				res[key] = (k + 1) * TICK
		if car.sim != null:
			res["peak_g"] = maxf(res["peak_g"], car.sim.state.accel_long / G)
	res["v_end_kmh"] = car.linear_velocity.length() * 3.6
	res["distance"] = car.global_position.distance_to(start)
	car.set_input_override(0.0, 0.0, 0.0)
	return res

## Full braking from `kmh` to a stop (or to `to_kmh`). Returns distance (m), time (s),
## peak and mean deceleration (g) and whether any wheel locked.
static func brake_from(tc: TestCase, car: Car, kmh: float, to_kmh: float = 0.5, pedal: float = 1.0) -> Dictionary:
	set_speed(car, kmh)
	car.set_input_override(0.0, 0.0, 0.0)
	await tc.physics_frames(HZ / 4)   # let the aero load settle
	var v0 := car.linear_velocity.length()
	var start := car.global_position
	var peak := 0.0
	var locked := false
	var t := 0.0
	car.set_input_override(0.0, pedal, 0.0)
	while car.linear_velocity.length() * 3.6 > to_kmh and t < 20.0:
		await tc.get_tree().physics_frame
		t += TICK
		peak = maxf(peak, -car.sim.state.accel_long / G)
		for i in 4:
			locked = locked or car.sim.state.locked[i]
	var v1 := car.linear_velocity.length()
	car.set_input_override(0.0, 0.0, 0.0)
	return {"distance": car.global_position.distance_to(start), "time": t, "peak_g": peak,
			"mean_g": (v0 - v1) / maxf(t, 1e-3) / G, "locked": locked, "v0_kmh": v0 * 3.6}

## Highest steady lateral acceleration (g) at about `kmh`: holds the speed with the throttle
## and winds the steering on slowly. Also returns the steering input and body slip (deg) at
## the peak, and the speed actually held.
static func max_lateral_g(tc: TestCase, car: Car, kmh: float, ramp_s: float = 5.0) -> Dictionary:
	set_speed(car, kmh)
	var target := kmh / 3.6
	var best := 0.0
	var best_steer := 0.0
	var best_slip := 0.0
	var window: Array[float] = []
	for k in int(ramp_s * HZ):
		var steer := float(k) / (ramp_s * HZ)
		var err := target - car.linear_velocity.length()
		car.set_input_override(clampf(0.4 + err * 0.5, 0.0, 1.0), 0.0, steer)
		await tc.get_tree().physics_frame
		window.append(absf(car.sim.state.accel_lat))
		if window.size() > HZ / 4:
			window.pop_front()
		if window.size() == HZ / 4:
			var mean := 0.0
			for a in window:
				mean += a
			mean /= window.size()
			if mean > best:
				best = mean
				best_steer = steer
				best_slip = rad_to_deg(car.sim.state.body_slip)
	car.set_input_override(0.0, 0.0, 0.0)
	return {"lat_g": best / G, "steer": best_steer, "slip_deg": best_slip,
			"speed_kmh": car.linear_velocity.length() * 3.6}

## Top speed: full throttle until the speed gains less than 0.5 km/h over 2 s (or max_s).
static func top_speed(tc: TestCase, car: Car, from_kmh: float = 250.0, max_s: float = 40.0) -> float:
	set_speed(car, from_kmh)
	car.set_input_override(1.0, 0.0, 0.0)
	var last := 0.0
	var t := 0.0
	while t < max_s:
		await tc.physics_frames(HZ * 2)
		t += 2.0
		var now := car.linear_velocity.length() * 3.6
		if now - last < 0.5:
			break
		last = now
	car.set_input_override(0.0, 0.0, 0.0)
	return car.linear_velocity.length() * 3.6
