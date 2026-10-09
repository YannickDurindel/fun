extends TestCase
## Suspension of the simulation car: static loads, ride height, load transfer under braking
## and in a corner against hand calculation, landing, kerbs, and no negative loads.
## Hand calculations use the body's real centre of mass (car.center_of_mass), so they stay
## right if the scene's centre of mass is moved.

const G: float = SimRig.G
const HZ: int = SimRig.HZ
const TICK: float = SimRig.TICK
## Hub height above the ground at the design ride height (m).
const DESIGN_HUB: float = SimHandling.DESIGN_DROP
## Bottom of the body's collision box below the hub (m): see scenes/car/car.tscn.
const FLOOR_BELOW_HUB: float = 0.28

# ---------------------------------------------------------------- pure tests (no physics)

func _fresh(spec: CarSpec) -> Array:
	var st := SimState.new()
	st.reset(spec)
	var sus := SimSuspension.new()
	sus.setup(spec)
	sus.reset(st, spec)
	for i in 4:
		st.contact[i] = true
		st.compression[i] = 0.0
		st.compression_vel[i] = 0.0
	return [st, sus]

func test_static_loads_carry_the_weight() -> void:
	var spec := CarSpec.new()
	var made := _fresh(spec)
	var st: SimState = made[0]
	var sus: SimSuspension = made[1]
	sus.step(st, spec, TICK)
	var weight := st.mass * G
	var front := st.load[0] + st.load[1]
	var rear := st.load[2] + st.load[3]
	assert_between(front + rear, weight * 0.9999, weight * 1.0001, "static loads sum to the weight (N)")
	assert_between(front / (front + rear), spec.weight_front - 1e-4, spec.weight_front + 1e-4, "front share of the static weight")
	assert_true(is_equal_approx(st.load[0], st.load[1]) and is_equal_approx(st.load[2], st.load[3]), "left = right at rest")

func test_spring_bar_and_heave_rates() -> void:
	var spec := CarSpec.new()
	var made := _fresh(spec)
	var st: SimState = made[0]
	var sus: SimSuspension = made[1]
	sus.step(st, spec, TICK)
	var f0 := st.load[0]
	var r0 := st.load[2]
	# Heave: both wheels of an axle 10 mm up.
	st.compression[0] = 0.01
	st.compression[1] = 0.01
	sus.step(st, spec, TICK)
	assert_between(st.load[0] - f0, (spec.spring_front + spec.heave_front) * 0.01 - 1.0, (spec.spring_front + spec.heave_front) * 0.01 + 1.0, "front heave rate x 10 mm (N)")
	# Roll: left up 3 mm, right down 3 mm. The axle total does not change.
	st.compression[0] = 0.003
	st.compression[1] = -0.003
	st.compression[2] = 0.003
	st.compression[3] = -0.003
	sus.step(st, spec, TICK)
	var roll_f := (spec.spring_front + 2.0 * spec.arb_front) * 0.003
	var roll_r := (spec.spring_rear + 2.0 * spec.arb_rear) * 0.003
	assert_between(st.load[0] - f0, roll_f - 1.0, roll_f + 1.0, "front roll rate x 3 mm (N)")
	assert_between(f0 - st.load[1], roll_f - 1.0, roll_f + 1.0, "the other side loses the same (N)")
	assert_between(st.load[2] - r0, roll_r - 1.0, roll_r + 1.0, "rear roll rate x 3 mm (N)")
	# One-wheel bump.
	st.compression[0] = 0.01
	st.compression[1] = 0.0
	sus.step(st, spec, TICK)
	var one := (spec.spring_front + spec.arb_front + 0.5 * spec.heave_front) * 0.01
	assert_between(st.load[0] - f0, one - 1.0, one + 1.0, "one-wheel bump rate x 10 mm (N)")
	# Mild understeer by design: the front takes more of the roll than of the weight.
	var split := SimSuspension.roll_split_front(spec)
	print("    roll stiffness: front %.0f, rear %.0f N m/rad, front share %.3f (weight %.2f front)" % [
			SimSuspension.roll_stiffness_front(spec), SimSuspension.roll_stiffness_rear(spec), split, spec.weight_front])
	assert_between(split, spec.weight_front + 0.04, 0.68, "front share of the roll stiffness")

func test_damper_bump_stop_and_droop() -> void:
	var spec := CarSpec.new()
	var made := _fresh(spec)
	var st: SimState = made[0]
	var sus: SimSuspension = made[1]
	sus.step(st, spec, TICK)
	var f0 := st.load[0]
	# Damper: rebound is firmer than bump, and both are digressive.
	st.compression_vel[0] = 0.1
	sus.step(st, spec, TICK)
	var bump_slow := st.load[0] - f0
	st.compression_vel[0] = -0.1
	sus.step(st, spec, TICK)
	var rebound_slow := f0 - st.load[0]
	st.compression_vel[0] = 2.0
	sus.step(st, spec, TICK)
	var bump_fast := st.load[0] - f0
	assert_between(bump_slow, spec.damper_front * 0.1 - 1.0, spec.damper_front * 0.1 + 1.0, "bump damping at 0.1 m/s (N)")
	assert_between(rebound_slow, spec.damper_rebound_front * 0.1 - 1.0, spec.damper_rebound_front * 0.1 + 1.0, "rebound damping at 0.1 m/s (N)")
	assert_true(bump_fast > bump_slow and bump_fast < spec.damper_front * 2.0, "digressive above the knee (%.0f N at 2 m/s)" % bump_fast)
	st.compression_vel[0] = 0.0
	# Bump stop: progressive beyond travel_bump.
	st.compression[0] = spec.travel_bump
	st.compression[1] = spec.travel_bump
	sus.step(st, spec, TICK)
	var at_stop := st.load[0]
	st.compression[0] = spec.travel_bump + 0.01
	st.compression[1] = spec.travel_bump + 0.01
	sus.step(st, spec, TICK)
	var first := st.load[0] - at_stop
	st.compression[0] = spec.travel_bump + 0.02
	st.compression[1] = spec.travel_bump + 0.02
	sus.step(st, spec, TICK)
	var second := st.load[0] - at_stop - first
	assert_true(first > spec.bump_stop_rate * 0.01, "the bump stop adds to the springs (%.0f N in 10 mm)" % first)
	assert_true(second > first * 1.3, "the bump stop is progressive (%.0f then %.0f N per 10 mm)" % [first, second])
	# Droop: a wheel in the air carries nothing, and the bar gives its partner no more than
	# the hanging wheel can react.
	st.compression[0] = 0.0
	st.compression[1] = 0.0
	st.contact[1] = false
	st.compression[1] = -spec.travel_droop
	sus.step(st, spec, TICK)
	assert_true(st.load[1] == 0.0, "a wheel in the air has no load")
	# The hanging wheel settles where its spring, the bar and the heave element balance; the
	# partner feels the bar and heave element at that travel, not at full droop.
	var hang := -f0 / (spec.spring_front + spec.arb_front + 0.5 * spec.heave_front)
	var partner := f0 - (spec.arb_front - 0.5 * spec.heave_front) * hang
	assert_true(hang > -spec.travel_droop, "the unloaded wheel hangs short of full droop")
	assert_between(st.load[0], partner - 1.0, partner + 1.0, "its partner feels the bar at the hanging wheel's travel (N)")
	# Fully extended but touching: zero, never negative, and the partner feels the same as
	# with the wheel in the air (no step in load as the ray loses the road).
	st.contact[1] = true
	sus.step(st, spec, TICK)
	assert_true(st.load[1] == 0.0, "full droop carries no load")
	assert_between(st.load[0], partner - 1.0, partner + 1.0, "partner of a touching, unloaded wheel (N)")
	# Unloaded by rebound damping only: the road still holds the wheel where it is, so the
	# partner is worked out against its measured travel.
	st.compression[1] = 0.002
	st.compression_vel[1] = -5.0
	sus.step(st, spec, TICK)
	var held := f0 - (spec.arb_front - 0.5 * spec.heave_front) * 0.002
	assert_true(st.load[1] == 0.0, "a fast-extending wheel can unload to zero")
	assert_between(st.load[0], held - 1.0, held + 1.0, "its partner sees the measured travel (N)")
	st.compression_vel[1] = 0.0
	# A heave element stiffer than twice the bar must not unload the wheel on the road when
	# its partner lifts.
	var stiff := CarSpec.new()
	stiff.heave_front = 300000.0
	var made2 := _fresh(stiff)
	var st2: SimState = made2[0]
	var sus2: SimSuspension = made2[1]
	st2.contact[0] = false
	st2.compression[0] = -stiff.travel_droop
	sus2.step(st2, stiff, TICK)
	assert_true(st2.load[1] > f0 * 0.5, "stiff heave element: the wheel on the road keeps its load (%.0f N)" % st2.load[1])

func test_loads_are_never_negative() -> void:
	var spec := CarSpec.new()
	var made := _fresh(spec)
	var st: SimState = made[0]
	var sus: SimSuspension = made[1]
	var worst := 0.0
	var bad := 0
	for a in 9:
		for b in 9:
			for c in 5:
				for d in 4:
					var xl := -0.08 + 0.02 * a
					var xr := -0.08 + 0.02 * b
					var vel := -5.0 + 2.5 * c
					st.contact[0] = d & 1 == 0
					st.contact[1] = d & 2 == 0
					st.contact[2] = st.contact[1]
					st.contact[3] = st.contact[0]
					st.compression[0] = xl
					st.compression[1] = xr
					st.compression[2] = xr
					st.compression[3] = xl
					st.compression_vel[0] = vel
					st.compression_vel[1] = -vel
					st.compression_vel[2] = vel
					st.compression_vel[3] = vel
					sus.step(st, spec, TICK)
					for i in 4:
						worst = minf(worst, st.load[i])
						if is_nan(st.load[i]) or is_inf(st.load[i]) or (not st.contact[i] and st.load[i] != 0.0):
							bad += 1
	assert_true(worst >= 0.0, "no negative load in the sweep (worst %.1f N)" % worst)
	assert_true(bad == 0, "loads are finite, and zero without contact (%d bad)" % bad)

# ---------------------------------------------------------------- rig helpers

var _min_load: float = 0.0

func _watch(car: Car) -> void:
	for i in 4:
		_min_load = minf(_min_load, car.sim.state.load[i])

## Height of the body's centre of mass above the pad (m).
func _cg_height(car: Car) -> float:
	return (car.global_transform * car.center_of_mass).y

## Share of the weight on the front axle from where the body's centre of mass really is.
func _front_share(car: Car) -> float:
	return (Car.WHEEL_OFFSETS[2].z - car.center_of_mass.z) / Car.WHEELBASE

func _throttle_for(car: Car, target: float) -> float:
	return clampf(0.4 + (target - car.linear_velocity.length()) * 0.5, 0.0, 1.0)

## Holds `kmh` in a straight line for `seconds`, then returns the mean front and rear travel
## (m), speed, downforce and drag over the last half second.
func _cruise(car: Car, kmh: float, seconds: float) -> Dictionary:
	var target := kmh / 3.6
	var st := car.sim.state
	if kmh > 1.0:
		SimRig.set_speed(car, kmh)
	var n := 0
	var xf := 0.0
	var xr := 0.0
	var v := 0.0
	var dff := 0.0
	var dfr := 0.0
	var drag := 0.0
	var total := int(seconds * HZ)
	for k in total:
		car.set_input_override(_throttle_for(car, target) if kmh > 1.0 else 0.0, 0.0, 0.0)
		await get_tree().physics_frame
		_watch(car)
		if k >= total - HZ / 2:
			n += 1
			xf += 0.5 * (st.compression[0] + st.compression[1])
			xr += 0.5 * (st.compression[2] + st.compression[3])
			v += car.linear_velocity.length()
			dff += st.downforce_front
			dfr += st.downforce_rear
			drag += st.drag
	return {"xf": xf / n, "xr": xr / n, "v": v / n, "dff": dff / n, "dfr": dfr / n, "drag": drag / n}

# ---------------------------------------------------------------- rig tests

func test_settles_at_design_ride_height() -> void:
	var car := await SimRig.spawn(self)
	var st := car.sim.state
	var spec := car.sim.spec
	var total := 0.0
	for i in 4:
		assert_true(st.contact[i], "wheel %d on the ground" % i)
		assert_between(st.compression[i], -0.002, 0.002, "wheel %d travel at rest (m)" % i)
		total += st.load[i]
	var weight := st.mass * G
	var share := _front_share(car)
	print("    at rest: hub %.4f m, travel %.2f / %.2f mm front / rear, loads %.0f %.0f %.0f %.0f N, cg %.3f m high, %.4f of the weight in front (spec: %.3f m, %.2f)" % [
			car.global_position.y, (st.compression[0] + st.compression[1]) * 500.0, (st.compression[2] + st.compression[3]) * 500.0,
			st.load[0], st.load[1], st.load[2], st.load[3], _cg_height(car), share, spec.cg_height, spec.weight_front])
	assert_between(car.global_position.y, DESIGN_HUB - 0.002, DESIGN_HUB + 0.002, "hub height at rest (m)")
	assert_between(total, weight * 0.995, weight * 1.005, "wheel loads carry the weight (N)")
	assert_between((st.load[0] + st.load[1]) / total, share - 0.005, share + 0.005, "front share of the weight")
	assert_true(car.linear_velocity.length() < 0.01 and car.angular_velocity.length() < 0.01, "at rest")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.99999, "level")

func test_ride_height_under_downforce() -> void:
	var car := await SimRig.spawn(self)
	var spec := car.sim.spec
	var h := _cg_height(car)
	_min_load = 0.0
	for kmh: float in [0.0, 150.0, 300.0]:
		var m := await _cruise(car, kmh, 3.0)
		# Hand calculation: downforce per wheel over the heave rate; the thrust that balances
		# the drag (drag acts at the centre of mass) moves drag * h / L from front to rear.
		var shift: float = m["drag"] * h / Car.WHEELBASE
		var hand_f: float = (m["dff"] - shift) * 0.5 / (spec.spring_front + spec.heave_front)
		var hand_r: float = (m["dfr"] + shift) * 0.5 / (spec.spring_rear + spec.heave_rear)
		var floor_gap: float = DESIGN_HUB - FLOOR_BELOW_HUB - maxf(m["xf"], m["xr"])
		print("    %3.0f km/h: downforce %5.0f N, travel front %5.2f mm (hand %5.2f), rear %5.2f mm (hand %5.2f), floor %4.1f mm above the road" % [
				m["v"] * 3.6, m["dff"] + m["dfr"], m["xf"] * 1000.0, hand_f * 1000.0, m["xr"] * 1000.0, hand_r * 1000.0, floor_gap * 1000.0])
		assert_between(m["xf"], hand_f - 0.0015, hand_f + 0.0015, "front travel at %.0f km/h (m)" % kmh)
		assert_between(m["xr"], hand_r - 0.0015, hand_r + 0.0015, "rear travel at %.0f km/h (m)" % kmh)
		assert_true(maxf(m["xf"], m["xr"]) < spec.travel_bump - 0.01, "off the bump stops at %.0f km/h" % kmh)
		assert_true(floor_gap > 0.04, "floor clear of the road at %.0f km/h (%.3f m)" % [kmh, floor_gap])
	assert_true(_min_load >= 0.0, "no negative wheel load")

func test_braking_moves_load_forward() -> void:
	var car := await SimRig.spawn(self)
	var st := car.sim.state
	_min_load = 0.0
	SimRig.set_speed(car, 200.0)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(HZ / 2)
	car.set_input_override(0.0, 0.4, 0.0)
	var n := 0
	var front := 0.0
	var rear := 0.0
	var hand := 0.0
	var plain := 0.0
	var decel := 0.0
	var share := _front_share(car)
	for k in int(1.0 * HZ):
		await get_tree().physics_frame
		_watch(car)
		if k < int(0.4 * HZ):
			continue
		n += 1
		var weight := st.mass * G
		var h := _cg_height(car)
		# Load the axle carries beyond its static and aero share.
		front += st.load[0] + st.load[1] - weight * share - st.downforce_front
		rear += st.load[2] + st.load[3] - weight * (1.0 - share) - st.downforce_rear
		# m a h / L, with the part of the deceleration that is air drag taken out: drag acts
		# at the centre of mass and moves no load.
		plain += st.mass * -st.accel_long * h / Car.WHEELBASE
		hand += (st.mass * -st.accel_long - st.drag) * h / Car.WHEELBASE
		decel += -st.accel_long
	front /= n
	rear /= n
	hand /= n
	plain /= n
	decel /= n
	print("    braking at %.2f g near %.0f km/h: front axle +%.0f N, rear %.0f N; hand m a h / L = %.0f N, less drag = %.0f N" % [
			decel / G, car.linear_velocity.length() * 3.6, front, rear, plain, hand])
	assert_between(decel / G, 1.0, 4.0, "deceleration in the window (g)")
	assert_between(front, hand * 0.93, hand * 1.07, "front axle gain against (m a - drag) h / L (N)")
	assert_between(front, plain * 0.85, plain * 1.15, "front axle gain against m a h / L (N)")
	assert_between(-rear, front * 0.93, front * 1.07, "the rear axle loses what the front gains (N)")
	assert_true(_min_load >= 0.0, "no negative wheel load")

func test_cornering_moves_load_outward() -> void:
	var car := await SimRig.spawn(self)
	var st := car.sim.state
	var spec := car.sim.spec
	_min_load = 0.0
	var target := 150.0 / 3.6
	var want := 1.5 * G
	SimRig.set_speed(car, 150.0)
	var steer := 0.0
	var n := 0
	var load := [0.0, 0.0, 0.0, 0.0]
	var ay := 0.0
	var h := 0.0
	var axle_f := 0.0
	var axle_f_hand := 0.0
	var total := 0.0
	var total_hand := 0.0
	var steps := 5 * HZ
	for k in steps:
		# Wind the steering on (to the right) until the car pulls 1.5 g, then it holds itself.
		steer = clampf(steer + (want - absf(st.accel_lat)) * 0.02 * TICK, 0.0, 1.0)
		car.set_input_override(_throttle_for(car, target), 0.0, steer)
		await get_tree().physics_frame
		_watch(car)
		if k < steps - HZ:
			continue
		n += 1
		for i in 4:
			load[i] += st.load[i]
		ay += st.accel_lat
		h += _cg_height(car)
		var weight := st.mass * G
		axle_f += st.load[0] + st.load[1]
		axle_f_hand += weight * _front_share(car) + st.downforce_front - (st.mass * st.accel_long + st.drag) * _cg_height(car) / Car.WHEELBASE
		total += st.load[0] + st.load[1] + st.load[2] + st.load[3]
		total_hand += weight + st.downforce_front + st.downforce_rear
	for i in 4:
		load[i] /= n
	ay /= n
	h /= n
	var track_f := Car.WHEEL_OFFSETS[1].x - Car.WHEEL_OFFSETS[0].x
	var track_r := Car.WHEEL_OFFSETS[3].x - Car.WHEEL_OFFSETS[2].x
	# Turning right (ay > 0): the left wheels are the outside ones.
	var out_sign := 1.0 if ay > 0.0 else -1.0
	var d_front: float = (load[0] - load[1]) * 0.5 * out_sign
	var d_rear: float = (load[2] - load[3]) * 0.5 * out_sign
	var moment := d_front * track_f + d_rear * track_r
	var moment_hand := st.mass * absf(ay) * h
	var split := d_front * track_f / moment
	var split_hand := SimSuspension.roll_split_front(spec)
	var roll_deg := rad_to_deg(asin(clampf(car.global_transform.basis.x.y, -1.0, 1.0)))
	print("    corner at %.2f g, %.0f km/h: loads %.0f %.0f %.0f %.0f N; transfer front %.0f N, rear %.0f N per wheel" % [
			absf(ay) / G, car.linear_velocity.length() * 3.6, load[0], load[1], load[2], load[3], d_front, d_rear])
	print("    roll moment %.0f N m (hand m a h = %.0f), front share %.3f (roll stiffness split %.3f), roll %.2f deg (hand %.2f)" % [
			moment, moment_hand, split, split_hand, absf(roll_deg),
			rad_to_deg(moment_hand / (SimSuspension.roll_stiffness_front(spec) + SimSuspension.roll_stiffness_rear(spec)))])
	assert_between(absf(ay) / G, 1.3, 1.7, "steady lateral acceleration (g)")
	assert_true(d_front > 0.0 and d_rear > 0.0, "the outside wheels carry more")
	# Outside gains what inside loses: each axle total and the car total are what they would
	# be in a straight line at this speed and thrust.
	assert_between(total / n, total_hand / n * 0.99, total_hand / n * 1.01, "total load = weight + downforce (N)")
	assert_between(axle_f / n, axle_f_hand / n * 0.98, axle_f_hand / n * 1.02, "front axle total unchanged by cornering (N)")
	assert_between(moment, moment_hand * 0.93, moment_hand * 1.07, "lateral transfer against m a h (N m)")
	assert_between(split, split_hand - 0.03, split_hand + 0.03, "front share of the lateral transfer")
	assert_true(_min_load >= 0.0, "no negative wheel load")

func _spawn_at(hub_height: float) -> Car:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	ground.add_child(shape)
	add_child(ground)
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	car.handling = Car.HANDLING_SIMULATION
	car.position = Vector3(0, hub_height, 0)
	add_child(car)
	car.set_input_override(0.0, 0.0, 0.0)
	return car

func test_landing_from_a_drop_settles() -> void:
	var car := _spawn_at(DESIGN_HUB + 0.3)
	_min_load = 0.0
	var touched := -1
	var settled := -1
	var relaunched := false
	var lowest := 1.0
	var rebound := 0.0
	var peak_load := 0.0
	for k in 3 * HZ:
		await get_tree().physics_frame
		_watch(car)
		var st := car.sim.state
		if touched < 0:
			if st.on_ground > 0:
				touched = k
			continue
		var y := car.global_position.y
		lowest = minf(lowest, y)
		if k - touched > HZ / 20:
			rebound = maxf(rebound, y)
		if st.on_ground == 0:
			relaunched = true
		for i in 4:
			peak_load = maxf(peak_load, st.load[i])
		if absf(y - DESIGN_HUB) > 0.003 or absf(car.linear_velocity.y) > 0.03:
			settled = k + 1
	var settle_s := (settled - touched) * TICK
	print("    0.3 m drop: lowest hub %.1f mm below design (floor %.1f mm above the road), rebound to %+.1f mm, settled in %.3f s, peak wheel load %.0f N" % [
			(DESIGN_HUB - lowest) * 1000.0, (lowest - FLOOR_BELOW_HUB) * 1000.0, (rebound - DESIGN_HUB) * 1000.0, settle_s, peak_load])
	assert_true(touched > 0, "the car fell and landed")
	assert_true(not relaunched, "the wheels stay on the ground after landing")
	assert_true(lowest - FLOOR_BELOW_HUB > 0.005, "the floor does not hit the road (%.3f m)" % (lowest - FLOOR_BELOW_HUB))
	assert_true(rebound - DESIGN_HUB < 0.01, "no bounce above ride height (%.4f m)" % (rebound - DESIGN_HUB))
	assert_between(settle_s, 0.0, 0.55, "time to settle after touching down (s)")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.9999, "level after landing")
	assert_true(_min_load >= 0.0, "no negative wheel load")

## A strip `height` m tall under the left wheels, square-faced, starting 30 m ahead.
func _add_kerb(height: float, length: float) -> void:
	var kerb := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.7, height, length)
	shape.shape = box
	kerb.add_child(shape)
	kerb.position = Vector3(-0.8, height * 0.5, -30.0 - length * 0.5)
	add_child(kerb)

func _kerb_run(height: float) -> Dictionary:
	var car := await SimRig.spawn(self)
	_add_kerb(height, 8.0)
	SimRig.set_speed(car, 150.0)
	car.set_input_override(0.0, 0.0, 0.0)
	var st := car.sim.state
	var top := 0.0
	var air := 0
	var air_max := 0
	var tilt := 1.0
	var peak_load := 0.0
	for k in int(2.5 * HZ):
		await get_tree().physics_frame
		_watch(car)
		top = maxf(top, car.global_position.y)
		tilt = minf(tilt, car.global_transform.basis.y.dot(Vector3.UP))
		air = air + 1 if st.on_ground == 0 else 0
		air_max = maxi(air_max, air)
		for i in 4:
			peak_load = maxf(peak_load, st.load[i])
	return {"rise": top - DESIGN_HUB, "air_s": air_max * TICK, "tilt_deg": rad_to_deg(acos(clampf(tilt, -1.0, 1.0))),
			"peak_load": peak_load, "end_y": car.global_position.y, "end_x": car.global_position.x,
			"end_up": car.global_transform.basis.y.dot(Vector3.UP), "end_vy": absf(car.linear_velocity.y),
			"kmh": car.linear_velocity.length() * 3.6, "on_ground": st.on_ground}

func _check_kerb(height: float) -> void:
	_min_load = 0.0
	var r := await _kerb_run(height)
	var mm := height * 1000.0
	print("    %.0f mm kerb under the left wheels at 150 km/h: hub rises %.1f mm, all wheels off for %.3f s, tilt %.2f deg, peak wheel load %.0f N, ends %.2f m off line at %.0f km/h" % [
			mm, r["rise"] * 1000.0, r["air_s"], r["tilt_deg"], r["peak_load"], r["end_x"], r["kmh"]])
	assert_true(r["rise"] < height + 0.02, "%.0f mm kerb: the body rises no more than the kerb plus 2 cm (%.3f m)" % [mm, r["rise"]])
	assert_true(r["air_s"] < 0.05, "%.0f mm kerb: never airborne for long (%.3f s)" % [mm, r["air_s"]])
	assert_true(r["tilt_deg"] < 4.0, "%.0f mm kerb: stays flat (%.2f deg)" % [mm, r["tilt_deg"]])
	assert_true(r["on_ground"] == 4 and r["end_up"] > 0.9999 and r["end_vy"] < 0.03, "%.0f mm kerb: settled on four wheels afterwards" % mm)
	assert_between(r["end_y"], DESIGN_HUB - 0.01, DESIGN_HUB + 0.002, "%.0f mm kerb: hub height afterwards (m)" % mm)
	assert_true(absf(r["end_x"]) < 3.0, "%.0f mm kerb: not thrown off line (%.2f m)" % [mm, r["end_x"]])
	assert_true(r["kmh"] > 100.0, "%.0f mm kerb: still rolling after 2.5 s of coasting (%.0f km/h)" % [mm, r["kmh"]])
	assert_true(_min_load >= 0.0, "no negative wheel load")

func test_low_kerb_at_150_does_not_launch() -> void:
	await _check_kerb(0.02)

func test_high_kerb_at_150_does_not_launch() -> void:
	await _check_kerb(0.05)

func test_hard_driving_keeps_loads_sane() -> void:
	var car := await SimRig.spawn(self)
	var st := car.sim.state
	_min_load = 0.0
	var bad := 0
	var peak := 0.0
	SimRig.set_speed(car, 220.0)
	# Full lock one way, the other, then full lock on the brakes.
	var plan := [[1.0, 0.0, 1.0], [1.0, 0.0, -1.0], [0.0, 1.0, 1.0], [0.0, 1.0, -1.0]]
	for step: Array in plan:
		car.set_input_override(step[0], step[1], step[2])
		for k in HZ:
			await get_tree().physics_frame
			_watch(car)
			for i in 4:
				peak = maxf(peak, st.load[i])
				if is_nan(st.load[i]) or is_inf(st.load[i]) or (not st.contact[i] and st.load[i] != 0.0):
					bad += 1
	print("    hard driving: lowest wheel load %.0f N, highest %.0f N" % [_min_load, peak])
	assert_true(_min_load >= 0.0, "no negative wheel load (%.1f N)" % _min_load)
	assert_true(bad == 0, "loads finite, and zero without contact")
	assert_true(peak < 60000.0, "no wild load spike (%.0f N)" % peak)
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.95, "the car stays on its wheels")
