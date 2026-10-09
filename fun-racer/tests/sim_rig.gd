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

# ====================================================================== bench manoeuvres
# Used by tools/sim_bench.gd and tests/test_sim_bench.gd. They also run on an arcade car
# (car.sim == null): accelerations are then taken from the velocity, and quantities only the
# simulation knows (slip angles, wheel loads) come back as NAN.

## Width of the moving mean used for "at the limit" readings (ticks; 0.25 s).
const WINDOW: int = 60

## Back to the spawn point at a standstill with the simulation reset (fuel, tyres, gear).
static func reset(tc: TestCase, car: Car, settle_s: float = 1.0) -> void:
	if car.sim != null:
		car.sim.set_drs_button(false)
	car.set_input_override(0.0, 0.0, 0.0)
	car.respawn()
	await tc.physics_frames(int(settle_s * HZ))

## Puts the car at `kmh`, rolling straight, whatever its handling model.
static func place(car: Car, kmh: float) -> void:
	if car.sim != null:
		car.sim.set_speed(kmh / 3.6)
	else:
		car.linear_velocity = -car.global_transform.basis.z * (kmh / 3.6)
		car.angular_velocity = Vector3.ZERO

## Acceleration of the car in its own frame: x = to the right, y = forward (m/s^2).
static func _accel(car: Car, prev_v: Vector3) -> Vector2:
	if car.sim != null:
		return Vector2(car.sim.state.accel_lat, car.sim.state.accel_long)
	var a := (car.linear_velocity - prev_v) / TICK
	var b := car.global_transform.basis
	return Vector2(a.dot(b.x), -a.dot(b.z))

## Angle between the car's heading and its velocity (deg, + = sliding to its right).
static func _body_slip_deg(car: Car) -> float:
	var b := car.global_transform.basis
	var v := car.linear_velocity
	if v.length() < 2.0:
		return 0.0
	return rad_to_deg(atan2(v.dot(b.x), absf(v.dot(-b.z))))

## Mean of the absolute slip angles of one axle (deg); NAN without the simulation.
static func _axle_slip_deg(car: Car, front: bool) -> float:
	if car.sim == null:
		return NAN
	var s := car.sim.state
	var i := 0 if front else 2
	return rad_to_deg(0.5 * (absf(s.slip_angle[i]) + absf(s.slip_angle[i + 1])))

static func _mean(ring: PackedFloat32Array) -> float:
	var sum := 0.0
	for a in ring:
		sum += a
	return sum / ring.size()

## Speed holder (PI on the throttle). `pi` is a one-element array holding the integral term.
static func _hold_throttle(car: Car, target: float, pi: PackedFloat32Array) -> float:
	var err := target - car.linear_velocity.length()
	pi[0] = clampf(pi[0] + err * 1.5 * TICK, 0.0, 1.0)
	return clampf(pi[0] + err * 0.6, 0.0, 1.0)

## Holds `kmh` in a straight line for `seconds` so the aero load and the suspension settle.
static func settle_at(tc: TestCase, car: Car, kmh: float, seconds: float = 0.75) -> void:
	place(car, kmh)
	var pi := PackedFloat32Array([0.3])
	for k in int(seconds * HZ):
		car.set_input_override(_hold_throttle(car, kmh / 3.6, pi), 0.0, 0.0)
		await tc.get_tree().physics_frame

## The next steering input of a slow ramp: the front wheels turn at about `rate` rad/s whatever
## the steering ratio or the steering help (the input-to-angle gain is measured on the way).
static func _ramp_steer(car: Car, steer_in: float, rate: float) -> float:
	var gain := car.max_steer_angle
	if steer_in > 0.02 and absf(car.steer_angle) > 1e-4:
		gain = absf(car.steer_angle) / steer_in
	return minf(steer_in + minf(rate / maxf(gain, 0.005), 0.5) * TICK, 1.0)

## Wheel-angle rate (rad/s) that sweeps past any plausible limit at `mps` in `ramp_s`.
static func _ramp_rate(mps: float, ramp_s: float) -> float:
	return (Car.WHEELBASE * 6.5 * G / maxf(mps * mps, 25.0) + 0.12) / ramp_s

## Full braking in a straight line from exactly `kmh` (the speed is held until the pedal goes
## down) to `to_kmh`. Returns distance (m), time (s), peak deceleration (g, 50 ms mean), mean
## deceleration (g), locked / lock_s (any wheel locked, and for how long), drift_m (sideways
## deviation) and v0_kmh.
static func braking(tc: TestCase, car: Car, kmh: float, to_kmh: float = 0.5, pedal: float = 1.0) -> Dictionary:
	await settle_at(tc, car, kmh)
	var v0 := car.linear_velocity.length()
	var start := car.global_position
	var right := car.global_transform.basis.x
	var ring := PackedFloat32Array()
	ring.resize(12)
	var peak := 0.0
	var lock_ticks := 0
	var drift := 0.0
	var n := 0
	var prev_v := car.linear_velocity
	car.set_input_override(0.0, pedal, 0.0)
	while car.linear_velocity.length() * 3.6 > to_kmh and n < 20 * HZ:
		await tc.get_tree().physics_frame
		ring[n % ring.size()] = -_accel(car, prev_v).y
		prev_v = car.linear_velocity
		n += 1
		if n >= ring.size():
			peak = maxf(peak, _mean(ring))
		if car.sim != null:
			var any := false
			for i in 4:
				any = any or car.sim.state.locked[i]
			lock_ticks += 1 if any else 0
		drift = maxf(drift, absf((car.global_position - start).dot(right)))
	var t := n * TICK
	var v1 := car.linear_velocity.length()
	var dist := car.global_position.distance_to(start)
	car.set_input_override(0.0, 0.0, 0.0)
	return {"distance": dist, "time": t, "peak_g": peak / G, "mean_g": (v0 - v1) / maxf(t, 1e-3) / G,
			"locked": lock_ticks > 0, "lock_s": lock_ticks * TICK, "drift_m": drift, "v0_kmh": v0 * 3.6}

## Steady cornering limit at `kmh`: the speed is held with the throttle while the steering is
## wound on slowly (to the right) until the lateral acceleration stops rising. Returns the
## best 0.25 s mean lat_g and, at that moment: steer (input 0..1), steer_deg (front wheels),
## slip_deg (body), front_slip_deg and rear_slip_deg (mean tyre slip angle per axle),
## balance_deg (front minus rear: + = understeer, - = oversteer), speed_kmh, spun, and
## lock_limited (the best reading came at full steering input, so it is the steering's limit
## and perhaps not the tyres').
static func cornering(tc: TestCase, car: Car, kmh: float, ramp_s: float = 6.0) -> Dictionary:
	await settle_at(tc, car, kmh, 0.5)
	var target := kmh / 3.6
	var pi := PackedFloat32Array([0.3])
	var rate := _ramp_rate(target, ramp_s)
	var ring := PackedFloat32Array()
	ring.resize(WINDOW)
	var res := {"lat_g": 0.0, "steer": 0.0, "steer_deg": 0.0, "slip_deg": 0.0, "front_slip_deg": NAN,
			"rear_slip_deg": NAN, "balance_deg": NAN, "speed_kmh": kmh, "spun": false, "lock_limited": false}
	var best := 0.0
	var steer := 0.0
	var at_lock := 0
	var prev_v := car.linear_velocity
	for k in int(ramp_s * 2.0 * HZ):
		steer = _ramp_steer(car, steer, rate)
		car.set_input_override(_hold_throttle(car, target, pi), 0.0, steer)
		await tc.get_tree().physics_frame
		ring[k % WINDOW] = absf(_accel(car, prev_v).x)
		prev_v = car.linear_velocity
		var slip := _body_slip_deg(car)
		if absf(slip) > 30.0:
			res["spun"] = true
			break
		if k < WINDOW:
			continue
		var mean := _mean(ring)
		if mean > best:
			best = mean
			var front := _axle_slip_deg(car, true)
			var rear := _axle_slip_deg(car, false)
			res["lat_g"] = best / G
			res["steer"] = steer
			res["steer_deg"] = rad_to_deg(absf(car.steer_angle))
			res["slip_deg"] = slip
			res["front_slip_deg"] = front
			res["rear_slip_deg"] = rear
			res["balance_deg"] = front - rear
			res["speed_kmh"] = car.linear_velocity.length() * 3.6
			# Found with the steering on its stop: the tyres may have had more to give.
			res["lock_limited"] = steer >= 0.999
		elif best > 0.5 * G and mean < 0.8 * best:
			break   # well past the peak
		at_lock = at_lock + 1 if steer >= 1.0 else 0
		if at_lock > HZ / 2:
			break
	car.set_input_override(0.0, 0.0, 0.0)
	return res

## Winds the steering on (to the right) at `kmh` until the car corners at `lat_g`, then trims
## it until the car holds that steadily. Call it on a car already rolling at `kmh` (see
## settle_at). Leaves the car cornering and returns the steering input, or -1.0 if it never
## got there.
static func steer_for(tc: TestCase, car: Car, kmh: float, lat_g: float, ramp_s: float = 4.0) -> float:
	if lat_g < 0.05:
		return -1.0   # not a corner: any input would "reach" it
	var target := kmh / 3.6
	var pi := PackedFloat32Array([0.3])
	var rate := _ramp_rate(target, ramp_s) * 0.5
	var ring := PackedFloat32Array()
	ring.resize(WINDOW / 2)
	var steer := 0.0
	var prev_v := car.linear_velocity
	for k in int(ramp_s * 3.0 * HZ):
		steer = _ramp_steer(car, steer, rate)
		car.set_input_override(_hold_throttle(car, target, pi), 0.0, steer)
		await tc.get_tree().physics_frame
		ring[k % ring.size()] = absf(_accel(car, prev_v).x)
		prev_v = car.linear_velocity
		if k >= ring.size() and _mean(ring) >= lat_g * G:
			return await _trim_steer(tc, car, target, lat_g, steer)
		if steer >= 1.0 or absf(_body_slip_deg(car)) > 30.0:
			break
	return -1.0

## The car answers a steering ramp late, so the input that first reached `lat_g` gives more
## once it settles: trims the input for `seconds` until the car holds lat_g steadily.
static func _trim_steer(tc: TestCase, car: Car, target: float, lat_g: float, steer: float, seconds: float = 2.0) -> float:
	var pi := PackedFloat32Array([0.4])
	var prev_v := car.linear_velocity
	for k in int(seconds * HZ):
		car.set_input_override(_hold_throttle(car, target, pi), 0.0, steer)
		await tc.get_tree().physics_frame
		var lat := absf(_accel(car, prev_v).x) / G
		prev_v = car.linear_velocity
		steer = clampf(steer + 0.4 * (lat_g - lat) / maxf(lat_g, 0.1) * steer * TICK * 4.0, 0.0, 1.0)
	return steer

## Step-steer response at `kmh`: from a straight line the steering input jumps to `steer`
## (use steer_for() to pick one for a given lateral g) and is held for `hold_s`. Returns the
## steady yaw_rate_dps (mean of the last 0.5 s), rise_s (time to 90 % of it), overshoot_pct,
## settle_s (last time the yaw rate was more than 5 % away) and the steady lat_g.
static func step_steer(tc: TestCase, car: Car, kmh: float, steer: float, hold_s: float = 2.5) -> Dictionary:
	await settle_at(tc, car, kmh, 0.75)
	var target := kmh / 3.6
	var pi := PackedFloat32Array([0.3])
	var n := int(hold_s * HZ)
	var yaw := PackedFloat32Array()
	yaw.resize(n)
	var tail := HZ / 2
	var lat := 0.0
	var prev_v := car.linear_velocity
	for k in n:
		car.set_input_override(_hold_throttle(car, target, pi), 0.0, steer)
		await tc.get_tree().physics_frame
		# Steering right turns the car clockwise seen from above: a negative rate about +Y.
		yaw[k] = -car.angular_velocity.dot(car.global_transform.basis.y)
		if k >= n - tail:
			lat += absf(_accel(car, prev_v).x)
		prev_v = car.linear_velocity
	car.set_input_override(0.0, 0.0, 0.0)
	var steady := 0.0
	for k in range(n - tail, n):
		steady += yaw[k]
	steady /= tail
	var res := {"yaw_rate_dps": rad_to_deg(steady), "rise_s": -1.0, "overshoot_pct": 0.0, "settle_s": 0.0,
			"lat_g": lat / tail / G}
	if steady <= 1e-3:
		return res
	var peak := 0.0
	for k in n:
		peak = maxf(peak, yaw[k])
		if res["rise_s"] < 0.0 and yaw[k] >= 0.9 * steady:
			res["rise_s"] = (k + 1) * TICK
		if absf(yaw[k] - steady) > 0.05 * steady:
			res["settle_s"] = (k + 1) * TICK
	res["overshoot_pct"] = maxf(0.0, (peak - steady) / steady * 100.0)
	return res

## Lift-off in a corner: the car is settled at `kmh` cornering at `lat_g`, then the throttle
## is closed for `lift_s` with the front wheels held at their angle. Returns lat_g actually held, slip_before_deg
## and slip_peak_deg (body slip, absolute), yaw_gain (highest yaw rate after the lift over the
## yaw rate before it: above 1 the car tucks in), spun (body slip beyond 30 deg) and reached
## (false if the car could not corner at lat_g at all).
static func lift_off(tc: TestCase, car: Car, kmh: float, lat_g: float, lift_s: float = 2.0) -> Dictionary:
	await settle_at(tc, car, kmh, 0.5)
	var res := {"lat_g": 0.0, "slip_before_deg": 0.0, "slip_peak_deg": 0.0, "yaw_gain": 0.0, "spun": false,
			"reached": false}
	var steer := await steer_for(tc, car, kmh, lat_g)
	if steer < 0.0:
		car.set_input_override(0.0, 0.0, 0.0)
		return res
	res["reached"] = true
	var target := kmh / 3.6
	var pi := PackedFloat32Array([0.5])
	var hold := int(1.5 * HZ)
	var tail := HZ / 2
	var yaw0 := 0.0
	var slip0 := 0.0
	var lat := 0.0
	var prev_v := car.linear_velocity
	for k in hold:
		car.set_input_override(_hold_throttle(car, target, pi), 0.0, steer)
		await tc.get_tree().physics_frame
		if k >= hold - tail:
			yaw0 += absf(car.angular_velocity.dot(car.global_transform.basis.y))
			slip0 += absf(_body_slip_deg(car))
			lat += absf(_accel(car, prev_v).x)
		prev_v = car.linear_velocity
	yaw0 /= tail
	res["slip_before_deg"] = slip0 / tail
	res["lat_g"] = lat / tail / G
	var yaw_peak := 0.0
	var slip_peak := 0.0
	# "Steering held" means the front wheels: with a speed-sensitive steering ratio the same
	# input would turn them further as the car slows, so the input follows the angle.
	var angle := absf(car.steer_angle)
	for k in int(lift_s * HZ):
		if angle > 1e-4 and absf(car.steer_angle) > 1e-4:
			steer = clampf(steer * clampf(angle / absf(car.steer_angle), 0.98, 1.02), 0.0, 1.0)
		car.set_input_override(0.0, 0.0, steer)
		await tc.get_tree().physics_frame
		yaw_peak = maxf(yaw_peak, absf(car.angular_velocity.dot(car.global_transform.basis.y)))
		slip_peak = maxf(slip_peak, absf(_body_slip_deg(car)))
		if slip_peak > 30.0:
			res["spun"] = true
			break
	res["slip_peak_deg"] = slip_peak
	res["yaw_gain"] = yaw_peak / maxf(yaw0, 1e-3)
	car.set_input_override(0.0, 0.0, 0.0)
	return res

## Ride height and loads in a straight line at `kmh` (0 = standing), averaged over 0.5 s.
## Returns front_mm / rear_mm (how much lower each axle rides than at its design height),
## load_n (sum of the four wheel loads), load_ratio (over the car's weight), downforce_n,
## drag_n and speed_kmh. NAN where the handling model does not know.
static func ride(tc: TestCase, car: Car, kmh: float, settle_s: float = 2.0) -> Dictionary:
	if kmh > 0.5:
		place(car, kmh)
	var pi := PackedFloat32Array([0.3])
	var n := int(settle_s * HZ)
	var tail := HZ / 2
	var front := 0.0
	var rear := 0.0
	var total := 0.0
	var down := 0.0
	var drag := 0.0
	for k in n:
		car.set_input_override(_hold_throttle(car, kmh / 3.6, pi) if kmh > 0.5 else 0.0, 0.0, 0.0)
		await tc.get_tree().physics_frame
		if k >= n - tail and car.sim != null:
			var s := car.sim.state
			front += 0.5 * (s.compression[0] + s.compression[1])
			rear += 0.5 * (s.compression[2] + s.compression[3])
			total += s.load[0] + s.load[1] + s.load[2] + s.load[3]
			down += s.downforce_front + s.downforce_rear
			drag += s.drag
	var speed := car.linear_velocity.length() * 3.6
	car.set_input_override(0.0, 0.0, 0.0)
	if car.sim == null:
		return {"front_mm": NAN, "rear_mm": NAN, "load_n": NAN, "load_ratio": NAN, "downforce_n": NAN,
				"drag_n": NAN, "speed_kmh": speed}
	return {"front_mm": front / tail * 1000.0, "rear_mm": rear / tail * 1000.0, "load_n": total / tail,
			"load_ratio": total / tail / (car.sim.state.mass * G), "downforce_n": down / tail,
			"drag_n": drag / tail, "speed_kmh": speed}

## Top speed with the DRS button held or released: full throttle from `from_kmh` until the
## speed changes by less than 0.3 km/h over 2 s (or max_s). Returns kmh, time (s), settled
## (false if max_s ran out first), drs_opened
## (whether the wing ever opened: false if the car has no DRS or refused it) and ers_left
## (0..1 of the electric energy left at the end).
static func top_speed_drs(tc: TestCase, car: Car, drs: bool, from_kmh: float = 280.0, max_s: float = 40.0) -> Dictionary:
	place(car, from_kmh)
	car.set_input_override(1.0, 0.0, 0.0)
	var opened := false
	var last := -1000.0
	var t := 0.0
	var settled := false
	while t < max_s:
		for k in HZ * 2:
			if car.sim != null:
				car.sim.set_drs_button(drs)
				opened = opened or car.sim.state.drs_open
			await tc.get_tree().physics_frame
		t += 2.0
		var now := car.linear_velocity.length() * 3.6
		if absf(now - last) < 0.3:
			settled = true
			break
		last = now
	if car.sim != null:
		car.sim.set_drs_button(false)
	car.set_input_override(0.0, 0.0, 0.0)
	return {"kmh": car.linear_velocity.length() * 3.6, "time": t, "settled": settled, "drs_opened": opened,
			"ers_left": car.ers_charge}
