extends TestCase
## Aerodynamics of the simulation car (SimAero) and the tow source (Slipstream).
## Pure tests step the part on a hand-built state; rig tests drive the whole car on the pad.

const G: float = 9.81
## A step long enough for the ride-height filter and the DRS flap to reach their targets.
const SETTLE_DT: float = 10.0

## Driving aids that always ask for DRS (the request belongs to the aids).
class DrsAids extends SimAids:
	func step(state: SimState, spec: CarSpec, dt: float) -> void:
		super.step(state, spec, dt)
		state.drs_request = true

func _state(kmh: float, compression: float = 0.0) -> SimState:
	var s := SimState.new()
	s.v_long = kmh / 3.6
	s.speed = kmh / 3.6
	s.in_throttle = 1.0
	s.throttle = 1.0
	for i in 4:
		s.compression[i] = compression
	return s

func _aero(s: SimState, spec: CarSpec) -> SimAero:
	var a := SimAero.new()
	a.setup(spec)
	a.reset(s, spec)
	return a

## Total downforce (N) of a settled step.
func _down(s: SimState, spec: CarSpec) -> float:
	_aero(s, spec).step(s, spec, SETTLE_DT)
	return s.downforce_front + s.downforce_rear

# ---------------------------------------------------------------- pure

func test_zero_at_standstill_and_quadratic_in_speed() -> void:
	var spec := CarSpec.new()
	var s0 := _state(0.0)
	assert_true(_down(s0, spec) == 0.0 and s0.drag == 0.0, "no aero force at a standstill")
	var s1 := _state(100.0)
	var d1 := _down(s1, spec)
	var s2 := _state(200.0)
	var d2 := _down(s2, spec)
	assert_true(d1 > 0.0 and s1.drag > 0.0, "downforce and drag at 100 km/h")
	assert_between(d2 / d1, 3.99, 4.01, "downforce x4 when the speed doubles")
	assert_between(s2.drag / s1.drag, 3.99, 4.01, "drag x4 when the speed doubles")
	# At the design ride height the totals are exactly q * cl_a and q * cd_a.
	var q := 0.5 * spec.air_density * pow(200.0 / 3.6, 2.0)
	assert_between(d2, q * spec.cl_a * 0.999, q * spec.cl_a * 1.001, "downforce = q cl_a at the design ride height (N)")
	assert_between(s2.drag, q * spec.cd_a * 0.999, q * spec.cd_a * 1.001, "drag = q cd_a (N)")
	# Rolling backwards: drag, no downforce.
	var sr := _state(100.0)
	sr.v_long = -sr.v_long
	assert_true(_down(sr, spec) == 0.0 and sr.drag > 0.0, "reversing: drag but no downforce")

func test_balance() -> void:
	var spec := CarSpec.new()
	var s := _state(200.0)
	var a := _aero(s, spec)
	a.step(s, spec, SETTLE_DT)
	var share := s.downforce_front / (s.downforce_front + s.downforce_rear)
	assert_between(share, spec.aero_balance_front - 0.001, spec.aero_balance_front + 0.001, "front share at the design ride height")
	assert_between(share, 0.44, 0.46, "default balance 44-46 % front")
	assert_between(a.balance_front, share - 1e-4, share + 1e-4, "balance_front reports the share")
	# Nose down (braking): the centre of pressure moves forward. Squat: rearward.
	var dive := _state(200.0)
	dive.compression[0] = 0.015
	dive.compression[1] = 0.015
	var a_dive := _aero(dive, spec)
	a_dive.step(dive, spec, SETTLE_DT)
	var squat := _state(200.0)
	squat.compression[2] = 0.015
	squat.compression[3] = 0.015
	var a_squat := _aero(squat, spec)
	a_squat.step(squat, spec, SETTLE_DT)
	assert_true(a_dive.balance_front > share + 0.003, "dive moves the balance forward (%.3f)" % a_dive.balance_front)
	assert_true(a_squat.balance_front < share - 0.003, "squat moves the balance rearward (%.3f)" % a_squat.balance_front)
	assert_between(a_dive.balance_front, 0.40, 0.52, "balance stays sane in a dive")
	assert_between(a_squat.balance_front, 0.38, 0.50, "balance stays sane in a squat")

func test_drs() -> void:
	var spec := CarSpec.new()
	var closed := _state(300.0)
	_down(closed, spec)
	var s := _state(300.0)
	s.drs_request = true
	var a := _aero(s, spec)
	# The flap takes drs_actuation_time to open.
	a.step(s, spec, SimRig.TICK)
	assert_true(s.drs_open, "DRS opens on request")
	assert_true(a.drs_position > 0.0 and a.drs_position < 1.0, "the flap travels (%.2f after one tick)" % a.drs_position)
	assert_true(s.drag < closed.drag and s.drag > closed.drag * spec.drs_drag_factor, "drag part-way while the flap moves")
	for k in int(spec.drs_actuation_time * SimRig.HZ) + 2:
		a.step(s, spec, SimRig.TICK)
	assert_true(a.drs_position == 1.0, "flap fully open after the actuation time")
	assert_between(s.drag / closed.drag, spec.drs_drag_factor - 0.001, spec.drs_drag_factor + 0.001, "drag with DRS open")
	assert_between(s.downforce_rear / closed.downforce_rear, spec.drs_downforce_factor - 0.001, spec.drs_downforce_factor + 0.001, "rear downforce with DRS open")
	assert_between(s.downforce_front / closed.downforce_front, 0.999, 1.001, "front downforce unchanged by DRS")
	assert_true(a.balance_front > spec.aero_balance_front, "DRS moves the balance forward")
	# The brake closes it, and it stays closed until the request is made again.
	s.brake = 0.3
	a.step(s, spec, SETTLE_DT)
	assert_true(not s.drs_open and a.drs_position == 0.0, "braking closes DRS")
	s.brake = 0.0
	a.step(s, spec, SETTLE_DT)
	assert_true(not s.drs_open, "DRS stays closed after the brake while the request is held")
	s.drs_request = false
	a.step(s, spec, SETTLE_DT)
	s.drs_request = true
	a.step(s, spec, SETTLE_DT)
	assert_true(s.drs_open and a.drs_position == 1.0, "a new request opens it again")
	# A request made while braking waits for the throttle instead of being lost.
	var early := _state(300.0)
	early.brake = 0.5
	early.in_throttle = 0.0
	early.drs_request = true
	var a_early := _aero(early, spec)
	a_early.step(early, spec, SETTLE_DT)
	assert_true(not early.drs_open and a_early.drs_position == 0.0, "no DRS while braking")
	early.brake = 0.0
	early.in_throttle = 1.0
	a_early.step(early, spec, SETTLE_DT)
	assert_true(early.drs_open and a_early.drs_position == 1.0, "an early request opens once on the throttle")
	# A lift closes it too.
	s.in_throttle = 0.0
	a.step(s, spec, SETTLE_DT)
	assert_true(not s.drs_open and a.drs_position == 0.0, "lifting closes DRS")
	assert_between(s.drag / closed.drag, 0.999, 1.001, "drag back to the closed value")
	a.reset(s, spec)
	assert_true(not s.drs_open and a.drs_position == 0.0, "reset closes DRS")

func test_tow() -> void:
	var spec := CarSpec.new()
	var clean := _state(250.0)
	_down(clean, spec)
	var half := _state(250.0)
	half.tow = 0.5
	_down(half, spec)
	var full := _state(250.0)
	full.tow = 1.0
	var a := _aero(full, spec)
	a.step(full, spec, SETTLE_DT)
	assert_true(full.drag < half.drag and half.drag < clean.drag, "the tow lowers drag")
	assert_true(full.downforce_front < half.downforce_front and half.downforce_front < clean.downforce_front, "the tow lowers front downforce")
	assert_true(full.downforce_rear < half.downforce_rear and half.downforce_rear < clean.downforce_rear, "the tow lowers rear downforce")
	var drag_loss := 1.0 - full.drag / clean.drag
	var down_loss := 1.0 - (full.downforce_front + full.downforce_rear) / (clean.downforce_front + clean.downforce_rear)
	assert_between(drag_loss, 0.10, 0.35, "drag lost in a full tow")
	assert_true(down_loss > drag_loss, "dirty air costs more downforce (%.2f) than drag (%.2f)" % [down_loss, drag_loss])
	assert_true(a.balance_front < spec.aero_balance_front, "dirty air moves the balance rearward (understeer)")
	var over := _state(250.0)
	over.tow = 3.0
	_down(over, spec)
	assert_between(over.drag / full.drag, 0.999, 1.001, "tow is clamped to 1")

func test_ride_height() -> void:
	var spec := CarSpec.new()
	# Monotonic from full droop down to the optimum: lower = more downforce.
	var prev := -1.0
	var steps := 24
	for k in steps + 1:
		var c := lerpf(-spec.travel_droop, spec.floor_optimal_compression, float(k) / steps)
		var d := _down(_state(250.0, c), spec)
		assert_true(d >= prev, "downforce does not fall as the car runs lower (compression %.3f m)" % c)
		prev = d
	var design := _down(_state(250.0, 0.0), spec)
	var best := _down(_state(250.0, spec.floor_optimal_compression), spec)
	var high := _down(_state(250.0, -0.02), spec)
	var too_low := _down(_state(250.0, spec.travel_bump), spec)
	assert_true(best > design and design > high, "lower car, more downforce")
	assert_between(best / design, 1.01, 1.15, "the ride-height gain is mild")
	assert_true(too_low < best, "too low: the floor loses downforce")
	assert_true(too_low > design * 0.7, "the loss on the bump stops is bounded")
	# Stable with the springs: the downforce slope against ride height at 330 km/h is far
	# below the suspension rate, so more load never means still more load without end.
	var slope := 0.0
	for k in steps:
		var c0 := lerpf(-0.02, spec.floor_optimal_compression, float(k) / steps)
		var c1 := lerpf(-0.02, spec.floor_optimal_compression, float(k + 1) / steps)
		slope = maxf(slope, (_down(_state(330.0, c1), spec) - _down(_state(330.0, c0), spec)) / (c1 - c0))
	var springs := 2.0 * (spec.spring_front + spec.spring_rear)
	assert_true(slope < springs * 0.35,"aero slope %.0f N/m well below the springs %.0f N/m" % [slope, springs])
	# The filter: a step in ride height reaches the aero gradually.
	var s := _state(250.0, 0.0)
	var a := _aero(s, spec)
	a.step(s, spec, SimRig.TICK)
	for i in 4:
		s.compression[i] = 0.01
	a.step(s, spec, SimRig.TICK)
	assert_true(a.compression_front > 0.0 and a.compression_front < 0.005, "ride height is filtered (%.4f m after one tick)" % a.compression_front)

func test_yaw_and_wing_level() -> void:
	var spec := CarSpec.new()
	var straight := _state(200.0)
	var d0 := _down(straight, spec)
	var slide := _state(200.0)
	slide.body_slip = 0.2
	slide.v_long = slide.speed * cos(0.2)
	var d1 := _down(slide, spec)
	var spin := _state(200.0)
	spin.body_slip = -1.2
	spin.v_long = spin.speed * cos(1.2)
	var d2 := _down(spin, spec)
	assert_true(d1 < d0 and d2 < d1, "downforce falls with yaw, either side")
	assert_between(d1 / d0, 0.80, 0.90, "a 11 degree slide costs 10-20 % of the downforce")
	assert_true(d2 > 0.0, "some downforce left in a spin")
	assert_true(slide.drag > straight.drag, "a sliding car has more drag")
	# Wing trims.
	var monza := CarSpec.new()
	monza.wing_level = 0.0
	var monaco := CarSpec.new()
	monaco.wing_level = 1.0
	var s_lo := _state(200.0)
	var s_hi := _state(200.0)
	var lo := _down(s_lo, monza)
	var hi := _down(s_hi, monaco)
	assert_true(lo < d0 and d0 < hi, "more wing, more downforce")
	assert_true(s_lo.drag < straight.drag and straight.drag < s_hi.drag, "more wing, more drag")

func test_slipstream_wake_shape() -> void:
	var slip := Slipstream.new()
	var v := Vector3(0.0, 0.0, -80.0)   # the leading car drives along -Z; behind it is +Z
	assert_true(slip.wake_at(Vector3(0, 0, 7.0), v) > 0.95, "full tow 7 m behind")
	assert_true(slip.wake_at(Vector3(0, 0, -7.0), v) == 0.0, "no tow in front of the other car")
	assert_true(slip.wake_at(Vector3(2.0, 0, 0.0), v) == 0.0, "no tow side by side")
	assert_true(slip.wake_at(Vector3(0, 0, 80.0), v) == 0.0, "gone by 80 m")
	assert_true(slip.wake_at(Vector3(3.0, 0, 8.0), v) == 0.0, "narrow: none 3 m to the side")
	assert_true(slip.wake_at(Vector3(0, 6.0, 8.0), v) == 0.0, "none on another level")
	assert_true(slip.wake_at(Vector3(0, 0, 7.0), Vector3(0, 0, -5.0)) == 0.0, "a slow car leaves no wake")
	var prev := 1.1
	for d: float in [10.0, 20.0, 30.0, 45.0, 60.0, 69.0]:
		var w := slip.wake_at(Vector3(0, 0, d), v)
		assert_true(w < prev and w >= 0.0, "the wake fades with distance (%.0f m: %.2f)" % [d, w])
		prev = w
	assert_true(slip.wake_at(Vector3(0.8, 0, 8.0), v) < slip.wake_at(Vector3(0, 0, 8.0), v), "weaker off the centre line")
	assert_between(slip.wake_at(Vector3(0, 0, 30.0), v), 0.2, 0.7, "partial tow at 30 m")
	# Through a 200 m left-hander the wake follows the road: 40 m back it is 4 m to the left.
	var yaw_rate := 80.0 / 200.0
	var on_line := Vector3(-4.0, 0, 40.0)
	assert_true(slip.wake_at(on_line, v, yaw_rate) > 0.2, "tow on the racing line behind a cornering car")
	assert_true(slip.wake_at(on_line, v) == 0.0, "and none there behind a car going straight")
	assert_true(slip.wake_at(Vector3(4.0, 0, 40.0), v, yaw_rate) == 0.0, "none on the outside of its line")
	assert_true(slip.wake_at(Vector3(0, 2.0, 40.0), v) > 0.2, "a gradient change does not break the tow")
	slip.free()

# ---------------------------------------------------------------- rig

## Holds `kmh` for a few seconds; returns the mean sum of wheel loads, downforce and mass.
func _hold(car: Car, kmh: float) -> Dictionary:
	SimRig.set_speed(car, kmh)
	var target := kmh / 3.6
	var st: SimState = car.sim.state
	var loads := 0.0
	var down := 0.0
	var front := 0.0
	var n := 0
	for k in SimRig.HZ * 4:
		var err := target - car.linear_velocity.length()
		car.set_input_override(clampf(0.3 + err * 0.6, 0.0, 1.0), 0.0, 0.0)
		await get_tree().physics_frame
		if k >= SimRig.HZ * 2:
			loads += st.load[0] + st.load[1] + st.load[2] + st.load[3]
			down += st.downforce_front + st.downforce_rear
			front += st.downforce_front
			n += 1
	car.set_input_override(0.0, 0.0, 0.0)
	return {"loads": loads / n, "down": down / n, "balance": front / maxf(down, 1.0),
			"weight": st.mass * G, "kmh": car.linear_velocity.length() * 3.6,
			"compression": 0.5 * (car.sim.aero.compression_front + car.sim.aero.compression_rear)}

func test_downforce_at_reference_speeds() -> void:
	var car := await SimRig.spawn(self)
	var a := await _hold(car, 150.0)
	var b := await _hold(car, 300.0)
	print("    aero at %.0f km/h: downforce %.0f N = %.2f x weight, balance %.3f, wheel loads %.0f N, mean compression %.1f mm" % [
			a["kmh"], a["down"], a["down"] / a["weight"], a["balance"], a["loads"], a["compression"] * 1000.0])
	print("    aero at %.0f km/h: downforce %.0f N = %.2f x weight, balance %.3f, wheel loads %.0f N, mean compression %.1f mm" % [
			b["kmh"], b["down"], b["down"] / b["weight"], b["balance"], b["loads"], b["compression"] * 1000.0])
	assert_between(a["kmh"], 147.0, 153.0, "speed held near 150 km/h")
	assert_between(b["kmh"], 296.0, 304.0, "speed held near 300 km/h")
	# The wheels carry the weight plus the downforce the aero reports.
	assert_between(a["loads"], (a["weight"] + a["down"]) * 0.97, (a["weight"] + a["down"]) * 1.03, "wheel loads at 150 km/h (N)")
	assert_between(b["loads"], (b["weight"] + b["down"]) * 0.97, (b["weight"] + b["down"]) * 1.03, "wheel loads at 300 km/h (N)")
	# Downforce equals the weight around 150-160 km/h: just under it at 150.
	assert_between(a["down"] / a["weight"], 0.85, 1.02, "downforce / weight at 150 km/h")
	assert_between(b["down"] / b["weight"], 2.5, 3.6, "downforce / weight at 300 km/h")
	assert_between(a["balance"], 0.42, 0.48, "aero balance at 150 km/h")
	assert_between(b["balance"], 0.42, 0.48, "aero balance at 300 km/h")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.999, "level under load")

func test_top_speed_with_and_without_drs() -> void:
	var car := await SimRig.spawn(self)
	var closed := await SimRig.top_speed(self, car, 300.0)
	assert_true(not car.sim.state.drs_open, "DRS closed without a request")
	car.sim.aids = DrsAids.new()
	car.sim.aids.setup(car.sim.spec)
	var open := await SimRig.top_speed(self, car, 300.0)
	print("    top speed: %.1f km/h, with DRS %.1f km/h (+%.1f)" % [closed, open, open - closed])
	assert_between(closed, 330.0, 350.0, "top speed, medium wing (km/h)")
	assert_between(open - closed, 10.0, 16.0, "DRS gain (km/h)")
	assert_true(absf(car.global_position.x) < 2.0, "straight at top speed (x = %.2f m)" % car.global_position.x)

func test_slipstream_sets_the_tow() -> void:
	var lead := await SimRig.spawn(self)
	var slip := Slipstream.new()
	add_child(slip)
	await physics_frames(4)
	assert_true(slip.car_count() == 1 and lead.sim.state.tow == 0.0, "one car: nothing to do")
	var chaser := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	chaser.handling = Car.HANDLING_SIMULATION
	chaser.position = Vector3(0.0, 0.40, 9.0)   # forward is -Z: 9 m behind the leader
	add_child(chaser)
	chaser.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(SimRig.HZ)
	assert_true(slip.car_count() == 2, "the second car is found")
	assert_true(chaser.sim.state.tow == 0.0, "no tow at a standstill")
	SimRig.set_speed(lead, 250.0)
	SimRig.set_speed(chaser, 250.0)
	await physics_frames(6)
	var gap := chaser.global_position.z - lead.global_position.z
	print("    tow %.2f at %.1f m behind; drag %.0f N against %.0f N in clean air" % [
			chaser.sim.state.tow, gap, chaser.sim.state.drag, lead.sim.state.drag])
	assert_true(chaser.sim.state.tow > 0.8, "the car behind is in the tow (%.2f)" % chaser.sim.state.tow)
	assert_true(lead.sim.state.tow == 0.0, "the car ahead is in clean air")
	assert_true(chaser.sim.state.drag < lead.sim.state.drag * 0.9, "less drag in the tow")
	assert_true(chaser.sim.state.downforce_front < lead.sim.state.downforce_front * 0.9, "less front downforce in dirty air")
	remove_child(chaser)
	chaser.free()
	await physics_frames(2)
	assert_true(slip.car_count() == 1, "the removed car is forgotten")
