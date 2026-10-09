class_name SimPowertrain
extends RefCounted
## Power unit, hybrid system and gearbox of the simulation car: a 1.6 L turbo V6 with a
## torque curve, engine inertia behind an automatic clutch, 8 gears and reverse with seamless
## shifts, a limited-slip differential and the electric motor with its battery.
##
## Writes state.drive_torque (N m at each wheel; rear-wheel drive, so indices 2 and 3),
## state.gear, state.rpm, state.shifting and state.ers_energy.
## Reads state.throttle (after the aids), state.shift_request, state.in_throttle and
## state.in_brake (reverse, launch), the rear wheels' state.omega, state.brake and
## state.brake_torque (harvest), state.speed and state.v_long.
##
## How it works, each tick:
##  - The engine is its own rotating mass (spec.engine_inertia) joined to the gearbox by a
##    clutch. The torque that would hold engine and wheels together through the tick is solved
##    from both inertias and the load the wheels felt in the last tick; if the clutch can carry
##    it, the clutch is locked and the wheels feel the engine's inertia, otherwise it slips at
##    its capacity and the engine speed runs free. The torque is continuous across the change,
##    so there is no chatter.
##  - The clutch capacity rises with engine speed: just above idle when rolling (anti-stall),
##    and around a launch rpm when pulling away in 1st or reverse, so the engine holds revs
##    while the wheels catch up.
##  - Upshift: the ratio changes at once, combustion is cut for spec.shift_time and the engine
##    is pulled down to the new speed through the clutch (drive continues from its inertia).
##    Downshift: the clutch opens and the engine is blipped up to the new speed, so the rear
##    wheels are not dragged. A downshift that would over-rev is refused.
##  - Hybrid: the MGU-K adds up to spec.ers_power at full throttle while energy and the lap's
##    deployment allowance remain, tapering before empty. It harvests under braking (the
##    brake-by-wire takes the same torque off the rear friction brakes, so the wheel torques do
##    not change) and at part throttle (from the engine's spare torque).

const RPM: float = TAU / 60.0   ## rad/s per rpm

# ---- read-only telemetry of the last tick (HUD, tests)
var engine_torque: float = 0.0       ## N m at the crank, combustion + electric
var clutch_torque: float = 0.0       ## N m through the clutch
var ers_flow: float = 0.0            ## W at the battery: + = deploying, - = harvesting
var lap_deployed: float = 0.0        ## J taken from the battery this lap
var lap_harvested: float = 0.0       ## J harvested under braking this lap
var clutch_locked: bool = false
var launching: bool = false          ## pulling away: the clutch bites around the launch rpm

var _scale: float = 1.0              ## N m per unit of spec.torque_curve
var _w_e: float = 0.0                ## engine speed, rad/s
var _gear: int = 1                   ## the gear this part last wrote
var _shift_dir: int = 0
var _prev_w2: float = 0.0
var _prev_w3: float = 0.0
var _prev_axle: float = 0.0          ## N m sent to the rear axle last tick
var _lap_distance: float = 0.0
var _lap_signal: bool = false

func setup(spec: CarSpec) -> void:
	# Scale the relative curve so its peak power is spec.engine_power.
	_scale = 1.0
	var peak := 0.0
	var rpm := spec.rpm_idle
	while rpm <= spec.rpm_max:
		peak = maxf(peak, _curve(spec, rpm) * rpm * RPM)
		rpm += 50.0
	if peak > 0.0:
		_scale = spec.engine_power / peak

func reset(state: SimState, spec: CarSpec) -> void:
	state.gear = 1
	state.rpm = spec.rpm_idle
	state.shifting = 0.0
	state.ers_energy = spec.ers_capacity
	state.drive_torque[2] = 0.0
	state.drive_torque[3] = 0.0
	_gear = 1
	_w_e = spec.rpm_idle * RPM
	_shift_dir = 0
	_prev_w2 = state.omega[2]
	_prev_w3 = state.omega[3]
	_prev_axle = 0.0
	clutch_locked = false
	launching = true
	engine_torque = 0.0
	clutch_torque = 0.0
	ers_flow = 0.0
	_lap_signal = false
	_begin_lap()

## Overall ratio of the selected gear (engine turns per wheel turn; negative in reverse).
func ratio(state: SimState, spec: CarSpec) -> float:
	return gear_ratio(spec, state.gear)

func gear_ratio(spec: CarSpec, gear: int) -> float:
	if gear >= 1 and gear <= spec.gear_ratios.size():
		return spec.gear_ratios[gear - 1] * spec.final_drive
	if gear == -1:
		return -spec.reverse_ratio * spec.final_drive
	return 0.0

## Full-throttle combustion torque (N m at the crank) at `rpm`, before the rev limiter.
func torque_at(spec: CarSpec, rpm: float) -> float:
	return _curve(spec, rpm) * _scale

## Full-throttle combustion power (W) at `rpm`.
func power_at(spec: CarSpec, rpm: float) -> float:
	return torque_at(spec, rpm) * rpm * RPM

## Road speed (m/s) at `rpm` in `gear` for a driven wheel of `wheel_radius` (m).
func speed_in_gear(spec: CarSpec, gear: int, rpm: float, wheel_radius: float) -> float:
	var r := gear_ratio(spec, gear)
	return rpm * RPM / r * wheel_radius if r != 0.0 else 0.0

## Starts a new lap for the per-lap energy limits. Call it at the start/finish line; until it
## is called once, the limits renew every spec.ers_lap_distance metres instead.
func new_lap(_state: SimState, _spec: CarSpec) -> void:
	_lap_signal = true
	_begin_lap()

func _begin_lap() -> void:
	lap_deployed = 0.0
	lap_harvested = 0.0
	_lap_distance = 0.0

func step(state: SimState, spec: CarSpec, dt: float) -> void:
	var w2 := state.omega[2]
	var w3 := state.omega[3]
	var w_c := 0.5 * (w2 + w3)
	var alpha := ((w2 - _prev_w2) + (w3 - _prev_w3)) / (2.0 * dt)
	# A gear set from outside or a jump in wheel speed: the car was placed somewhere.
	if state.gear != _gear or absf(alpha) > spec.driveline_accel_limit:
		_adopt(state, spec, w_c)
		alpha = 0.0
	_select_reverse(state, spec)
	_shift(state, spec, w_c)
	state.shifting = maxf(0.0, state.shifting - dt)

	var r := gear_ratio(spec, state.gear)
	var w_sync := r * w_c
	var i_e := maxf(spec.engine_inertia, 1e-4)
	var i_w := maxf(2.0 * spec.wheel_inertia_rear, 1e-4)
	# Losses take from the wheels when driving and add to the drag when the wheels drive the
	# engine (direction of the last tick's clutch torque).
	var eta := spec.driveline_efficiency if clutch_torque >= 0.0 else 1.0 / maxf(spec.driveline_efficiency, 0.1)

	# ---- what the driver asks of the engine
	var demand := clampf(state.throttle, 0.0, 1.0)
	var pedal := clampf(state.in_throttle, 0.0, 1.0)
	if state.gear == -1:
		# In reverse the brake pedal is the accelerator (SimBrakes swaps the pedals too).
		pedal = clampf(state.in_brake, 0.0, 1.0) * spec.reverse_throttle if state.v_long > -spec.reverse_speed_max else 0.0
		demand = pedal

	# ---- clutch capacity from the engine speed
	var w_bite := spec.rpm_clutch_bite * RPM
	if clutch_locked:
		if r != 0.0 and w_sync >= w_bite:
			_w_e = w_sync
		else:
			clutch_locked = false   # anti-stall: the engine keeps its speed, the clutch opens
	if absi(state.gear) != 1:
		launching = false
	elif not clutch_locked and w_sync < w_bite:
		launching = true
	var bite := w_bite
	var band := spec.rpm_clutch_band * RPM
	if launching:
		bite = lerpf(w_bite, (spec.rpm_launch - spec.rpm_launch_band) * RPM, pedal)
		band = lerpf(band, spec.rpm_launch_band * RPM, pedal)
	# The faster side of the clutch sets the capacity: a gearbox turning fast enough closes it
	# again on a slower engine (after locked wheels or a long coast).
	var cap := spec.clutch_torque_max * clampf((maxf(_w_e, w_sync) - bite) / maxf(band, 1.0), 0.0, 1.0)
	if r == 0.0:
		cap = 0.0

	# ---- engine torque at the crank
	var rpm := _w_e / RPM
	var limiter := clampf((spec.rpm_max - rpm) / maxf(spec.rpm_limiter_band, 1.0), 0.0, 1.0)
	var full := torque_at(spec, rpm) * limiter
	var friction := spec.engine_brake_torque * maxf(rpm - spec.rpm_idle, 0.0) / maxf(spec.engine_brake_rpm - spec.rpm_idle, 1.0)
	var t_e := 0.0
	ers_flow = 0.0
	# The engine is slower than a gearbox that wants the clutch closed (a downshift, or the
	# clutch closing again after it opened): rev-match before the clutch takes up.
	var match_revs := cap > 0.0 and not clutch_locked and not launching \
			and w_sync - _w_e > spec.shift_sync_rpm * RPM and w_sync < spec.rpm_max * RPM
	if state.shifting > 0.0 and _shift_dir < 0 and not match_revs:
		state.shifting = 0.0   # downshift done as soon as the revs match
	if match_revs:
		# Clutch open, blip the throttle up to the gearbox speed: the rear wheels are not dragged.
		cap = 0.0
		t_e = clampf(i_e * (w_sync - _w_e) / dt, -friction, full)
	elif state.shifting > 0.0:
		# Upshift: combustion cut; the clutch pulls the engine down to the new speed, passing
		# on no more than the wheels had before the shift (seamless, no kick).
		t_e = -friction
		if _shift_dir > 0:
			cap = minf(cap, maxf(_prev_axle, 0.0) / maxf(r * eta, 1e-3))
	else:
		t_e = demand * full - (1.0 - demand) * friction
		t_e += _deploy(state, spec, demand, limiter, spec.engine_torque_max - t_e, dt)
		_harvest(state, spec, demand, full, dt)
	if _w_e < spec.rpm_idle * RPM:
		t_e += minf(i_e * (spec.rpm_idle * RPM - _w_e) / maxf(spec.idle_response, dt), spec.idle_torque_max)

	# ---- clutch: the torque that keeps engine and wheels together, limited by the capacity
	var t_c := 0.0
	clutch_locked = false
	if cap > 0.0:
		# Load on the axle (tyres and brakes) seen last tick.
		var t_load := _prev_axle - i_w * alpha
		var t_lock := ((_w_e - w_sync) / dt + t_e / i_e + r * t_load / i_w) / (1.0 / i_e + eta * r * r / i_w)
		t_c = clampf(t_lock, -cap, cap)
		clutch_locked = absf(t_lock) <= cap
		if clutch_locked:
			launching = false
	_w_e = clampf(_w_e + (t_e - t_c) * dt / i_e, 0.0, spec.rpm_max * RPM)
	engine_torque = t_e
	clutch_torque = t_c
	state.rpm = _w_e / RPM

	# ---- differential: equal split, plus a locking torque from the faster to the slower wheel
	var axle := t_c * r * (spec.driveline_efficiency if t_c >= 0.0 else 1.0 / maxf(spec.driveline_efficiency, 0.1))
	var lock_cap := spec.diff_preload + absf(axle) * (spec.diff_ramp_power if t_c >= 0.0 else spec.diff_ramp_coast)
	# Never more than what removes the speed difference within the tick (no overshoot).
	var t_diff := clampf(spec.diff_lock_rate * spec.wheel_inertia_rear * (w2 - w3) / (2.0 * dt), -lock_cap, lock_cap)
	state.drive_torque[0] = 0.0
	state.drive_torque[1] = 0.0
	state.drive_torque[2] = 0.5 * axle - t_diff
	state.drive_torque[3] = 0.5 * axle + t_diff
	_prev_axle = axle
	_prev_w2 = w2
	_prev_w3 = w3

	# ---- per-lap energy limits
	_lap_distance += state.speed * dt
	if not _lap_signal and spec.ers_lap_distance > 0.0 and _lap_distance >= spec.ers_lap_distance:
		_begin_lap()

## The gear was changed from outside (the rig placed the car at a speed): follow it.
func _adopt(state: SimState, spec: CarSpec, w_c: float) -> void:
	_gear = state.gear
	_shift_dir = 0
	state.shifting = 0.0
	var w_sync := gear_ratio(spec, _gear) * w_c
	clutch_locked = w_sync >= (spec.rpm_clutch_bite + spec.rpm_clutch_band) * RPM
	launching = not clutch_locked and absi(_gear) == 1
	_w_e = clampf(w_sync, spec.rpm_idle * RPM, spec.rpm_max * RPM)
	_prev_w2 = state.omega[2]
	_prev_w3 = state.omega[3]
	_prev_axle = 0.0

## Reverse is selected at a standstill with the brake held and no throttle; throttle leaves it.
func _select_reverse(state: SimState, spec: CarSpec) -> void:
	if state.gear >= 1:
		if state.speed < spec.reverse_select_speed \
				and state.in_brake > spec.reverse_select_brake and state.in_throttle < spec.reverse_cancel_throttle:
			_set_gear(state, -1)
	elif state.gear == -1 and state.in_throttle > spec.reverse_cancel_throttle:
		_set_gear(state, 1)

func _set_gear(state: SimState, gear: int) -> void:
	state.gear = gear
	_gear = gear
	state.shifting = 0.0
	_shift_dir = 0
	clutch_locked = false

## Applies state.shift_request; a refused request is dropped.
func _shift(state: SimState, spec: CarSpec, w_c: float) -> void:
	if state.shift_request == 0 or state.shifting > 0.0 or state.gear < 1:
		return
	var target := state.gear + signi(state.shift_request)
	if not can_shift_to(spec, target, w_c):
		return
	_shift_dir = target - state.gear
	state.gear = target
	_gear = target
	state.shifting = spec.shift_time if _shift_dir > 0 else spec.shift_time_down
	clutch_locked = false   # the engine keeps its speed; the clutch brings it to the new ratio

## True when `gear` exists and the engine would not over-rev in it at the rear axle speed
## `w_c` (rad/s).
func can_shift_to(spec: CarSpec, gear: int, w_c: float) -> bool:
	if gear < 1 or gear > spec.gear_ratios.size():
		return false
	return gear_ratio(spec, gear) * w_c <= spec.rpm_downshift_limit * RPM

## Electric motor torque (N m at the crank) for this tick; takes its energy from the battery.
## `headroom` is the torque left under spec.engine_torque_max.
func _deploy(state: SimState, spec: CarSpec, demand: float, limiter: float, headroom: float, dt: float) -> float:
	if state.gear < 1 or _w_e <= 1.0 or headroom <= 0.0:
		return 0.0
	var f := clampf((demand - spec.ers_deploy_throttle) / maxf(1.0 - spec.ers_deploy_throttle, 1e-3), 0.0, 1.0)
	f *= clampf((state.speed - spec.ers_min_speed) / maxf(spec.ers_speed_band, 1e-3), 0.0, 1.0)
	var left := minf(state.ers_energy, spec.ers_deploy_limit - lap_deployed)
	f *= clampf(left / maxf(spec.ers_taper_energy, 1.0), 0.0, 1.0) * limiter
	if f <= 0.0:
		return 0.0
	var torque := minf(minf(spec.ers_power * f / _w_e, spec.ers_torque_max), headroom)
	var drawn := minf(torque * _w_e / spec.ers_efficiency * dt, left)
	state.ers_energy -= drawn
	lap_deployed += drawn
	ers_flow = drawn / dt
	return torque

## Charges the battery under braking and at part throttle. Neither changes the wheel torques:
## under braking the MGU-K replaces part of the rear friction brakes (brake-by-wire), at part
## throttle the engine makes up what the generator takes.
func _harvest(state: SimState, spec: CarSpec, demand: float, full: float, dt: float) -> void:
	if state.gear < 1 or not clutch_locked or ers_flow > 0.0 or state.ers_energy >= spec.ers_capacity:
		return
	var power := 0.0
	var braking := state.brake > spec.ers_harvest_brake_min
	if braking:
		if lap_harvested >= spec.ers_harvest_limit:
			return
		var rear := state.brake_torque[2] * absf(state.omega[2]) + state.brake_torque[3] * absf(state.omega[3])
		power = minf(minf(spec.ers_harvest_power, spec.ers_torque_max * _w_e), rear)
	elif demand > spec.ers_part_throttle_min and demand < spec.ers_deploy_throttle:
		power = minf(minf(spec.ers_part_throttle_power, spec.ers_torque_max * _w_e), (1.0 - demand) * full * _w_e)
	if power <= 0.0:
		return
	var stored := minf(power * spec.ers_efficiency * dt, spec.ers_capacity - state.ers_energy)
	if braking:
		stored = minf(stored, spec.ers_harvest_limit - lap_harvested)
		lap_harvested += stored
	state.ers_energy += stored
	ers_flow = -stored / dt

## Relative torque from the spec's table at `rpm` (linear between knots, flat outside).
func _curve(spec: CarSpec, rpm: float) -> float:
	var n := mini(spec.torque_curve_rpm.size(), spec.torque_curve.size())
	if n == 0:
		return 0.0
	if rpm <= spec.torque_curve_rpm[0]:
		return spec.torque_curve[0]
	for i in range(1, n):
		if rpm <= spec.torque_curve_rpm[i]:
			var a := spec.torque_curve_rpm[i - 1]
			var t := (rpm - a) / maxf(spec.torque_curve_rpm[i] - a, 1e-3)
			return lerpf(spec.torque_curve[i - 1], spec.torque_curve[i], t)
	return spec.torque_curve[n - 1]
