class_name SimAids
extends RefCounted
## Driving aids: turns the raw driver input (state.in_*) into the demands the parts act on
## (state.throttle, brake, steer_angle, shift_request, drs_request). Called first every tick.
##
##   * Traction control: a PI controller holds the worst driven wheel at a slip target near
##     the tyre's peak. It works on slip *speed* (m/s), so its gains hold at every road speed.
##   * ABS: the same controller on the wheel closest to locking, releasing the one pedal.
##   * Automatic gearbox: shifts up at rpm_shift_up, down from the road speed, kicks down on
##     full throttle; a manual shift takes over for a few seconds.
##   * Steering help: the lock falls with speed so full input asks for a little more than
##     the tyres can turn; analog input is softened around the centre and smoothed.
##   * Stability help: in a slide it adds a little opposite lock and eases the throttle.
##
## The player picks each aid in Options (Settings `gameplay/aid_*`), applied live. With every
## aid off the pedals and the steering pass straight through and shifts are manual.
## Every number is in CarSpec, group "Aids". Slip values read here are from the previous tick.

const SECTION := "gameplay"
const G: float = 9.81

## When true the switches below follow the player's Settings. Set false to drive them by
## hand (a bot that must keep its aids whatever the player chose, or a bench).
var follow_settings: bool = true
var traction_control: int = 2      ## 0 off, 1 low, 2 high
var anti_lock: bool = true
var auto_gearbox: bool = true
var steering_help: bool = true
var stability_help: bool = true

# ---- what the aids are doing right now (for the HUD and tests)
var tc_cut: float = 0.0            ## 0..1 throttle removed by traction control
var abs_release: float = 0.0       ## 0..1 pedal released by ABS
var stability: float = 0.0         ## 0..1 strength of the stability help
var overdrive: float = 0.0         ## 0..1, how far the driver is into the steering overdrive
var steer_lock: float = 0.0        ## rad at the front wheels for full input, at this speed

var _tc_int: float = 1.0           # integral part of the throttle ceiling
var _abs_int: float = 1.0          # integral part of the pedal ceiling
var _steer_filtered: float = 0.0   # analog input after the low-pass
var _steer_norm: float = 0.0       # -1..1 after shaping and the rate limit
var _countersteer: float = 0.0     # rad, + = left
var _understeer: float = 0.0       # 0..1, smoothed
var _a_lat_max: float = 0.0        # m/s^2 the tyres can hold at this speed (estimate)
var _pending_shift: int = 0
var _manual_hold: float = 0.0
var _shift_cooldown: float = 0.0
var _limiter_time: float = 0.0
var _drs_on: bool = false
var _drs_prev: bool = false
var _drs_press_time: float = 0.0

func setup(_spec: CarSpec) -> void:
	_read_settings()
	if not Settings.changed.is_connected(_on_setting_changed):
		Settings.changed.connect(_on_setting_changed)

func reset(_state: SimState, _spec: CarSpec) -> void:
	tc_cut = 0.0
	abs_release = 0.0
	stability = 0.0
	_tc_int = 1.0
	_abs_int = 1.0
	_steer_filtered = 0.0
	_steer_norm = 0.0
	_countersteer = 0.0
	_understeer = 0.0
	_pending_shift = 0
	_manual_hold = 0.0
	_shift_cooldown = 0.0
	_limiter_time = 0.0
	_drs_on = false
	_drs_prev = false
	_drs_press_time = 0.0

func _on_setting_changed(section: String, key: String) -> void:
	if section == SECTION and key.begins_with("aid_"):
		_read_settings()

func _read_settings() -> void:
	if not follow_settings:
		return
	traction_control = clampi(int(Settings.get_value(SECTION, "aid_traction_control")), 0, 2)
	anti_lock = int(Settings.get_value(SECTION, "aid_abs")) > 0
	auto_gearbox = bool(Settings.get_value(SECTION, "aid_auto_gearbox"))
	steering_help = int(Settings.get_value(SECTION, "aid_steering_help")) > 0
	stability_help = int(Settings.get_value(SECTION, "aid_stability")) > 0

## Called first every tick.
func step(state: SimState, spec: CarSpec, dt: float) -> void:
	_a_lat_max = _lateral_limit(state, spec)
	_step_steering(state, spec, dt)
	_step_stability(state, spec, dt)
	# Overdrive: the last part of an analog device's travel turns the wheels past the grip
	# limit, and the stability help stands back, so the driver can throw the car into a slide.
	overdrive = 0.0
	if state.in_steer_overdrive:
		overdrive = smoothstep(spec.aid_steer_overdrive_start, 1.0, absf(_steer_norm))
	var lock := steer_lock * (1.0 + spec.aid_steer_overdrive_gain * overdrive)
	state.steer_angle = clampf(-_steer_norm * lock + _countersteer * (1.0 - overdrive), -spec.max_steer_angle, spec.max_steer_angle)
	_step_pedals(state, spec, dt)
	_step_gearbox(state, spec, dt)
	_step_drs(state, spec, dt)

# ================================================================ tyre limits
## Peak slip ratio / slip angle of the tyres. One place to change when the tyre model
## publishes per-axle or load-dependent peaks.
func _peak_slip_ratio(spec: CarSpec) -> float:
	return maxf(spec.tyre_peak_slip_ratio, 0.01)

func _peak_slip_angle(spec: CarSpec) -> float:
	return maxf(spec.tyre_peak_slip_angle, 0.01)

## Lateral acceleration (m/s^2) the four tyres can hold now, from the weight, the downforce,
## the surface under each wheel and the tyres' condition.
func _lateral_limit(state: SimState, spec: CarSpec) -> float:
	var down := maxf(state.downforce_front + state.downforce_rear, 0.0)
	var mass := maxf(state.mass, 1.0)
	var wheel_load := (mass * G + down) * 0.25
	var over := maxf(wheel_load / maxf(spec.tyre_reference_load, 1.0) - 1.0, -0.5)
	var mu := spec.tyre_mu * maxf(1.0 - spec.tyre_load_sensitivity * over, 0.4)
	var grip := 0.0
	for i in 4:
		grip += state.surface_mu[i] * state.grip_factor[i]
	return mu * grip * 0.25 * (G + down / mass)

# ================================================================ steering
func _step_steering(state: SimState, spec: CarSpec, dt: float) -> void:
	if not steering_help:
		# Linear, full mechanical lock at every speed.
		steer_lock = spec.max_steer_angle
		_steer_filtered = state.in_steer
		_steer_norm = state.in_steer
		return
	# Full input asks for the tightest turn the grip allows (wheelbase / radius) plus a margin
	# of slip angle: the fronts work near their peak, not far past it.
	var v := maxf(state.speed, 1.0)
	steer_lock = clampf(Car.WHEELBASE * spec.aid_steer_grip_usage * _a_lat_max / (v * v) + spec.aid_steer_slip_margin * _peak_slip_angle(spec),
			minf(spec.aid_steer_min_lock, spec.max_steer_angle), spec.max_steer_angle)
	var x := state.in_steer
	var rate := spec.aid_steer_rate_digital
	if state.in_steer_digital:
		_steer_filtered = x   # the Car already ramps key steering
	else:
		rate = spec.aid_steer_rate_analog
		# Tilt is noisy and coarse: smooth it, and make the centre less sensitive.
		_steer_filtered += (x - _steer_filtered) * dt / (maxf(spec.aid_steer_smooth_time, 0.0) + dt)
		var c := clampf(spec.aid_steer_center_gain, 0.0, 1.0)
		x = _steer_filtered * (c + (1.0 - c) * absf(_steer_filtered))
	_steer_norm = move_toward(_steer_norm, x, rate * dt)

# ================================================================ stability
func _step_stability(state: SimState, spec: CarSpec, dt: float) -> void:
	var blend := dt / (maxf(spec.aid_stab_response_time, 0.0) + dt)
	var fade := clampf(state.speed / maxf(spec.aid_stab_min_speed, 0.1) - 1.0, 0.0, 1.0)
	if not stability_help or fade <= 0.0 or state.on_ground < 3 or state.v_long < 0.0:
		stability += (0.0 - stability) * blend
		_countersteer += (0.0 - _countersteer) * blend
		_understeer += (0.0 - _understeer) * blend
		return
	var peak := _peak_slip_angle(spec)
	# Rear slide: the rear tyres run past their peak slip angle.
	var rear := 0.5 * (state.slip_angle[2] + state.slip_angle[3])
	var slide := maxf(absf(rear) - spec.aid_stab_slip_deadband * peak, 0.0)
	# Yaw beyond what the steering and the speed call for, in the direction of the rotation.
	var r_limit := _a_lat_max / maxf(state.speed, 1.0)
	var r_ref := clampf(state.v_long * tan(-_steer_norm * steer_lock) / Car.WHEELBASE, -r_limit, r_limit)
	var over_yaw := maxf((state.yaw_rate - r_ref) * signf(state.yaw_rate) - spec.aid_stab_yaw_deadband, 0.0)
	var want := maxf(slide / maxf(spec.aid_stab_slip_range * peak, 1e-3), over_yaw / maxf(spec.aid_stab_yaw_range, 1e-3))
	stability += (clampf(want, 0.0, 1.0) * fade - stability) * blend
	# Opposite lock: steer towards where the rear is going (rear moving right -> steer right).
	var cs := -signf(rear) * minf(slide * spec.aid_stab_countersteer_gain, spec.aid_stab_countersteer_max) * fade
	_countersteer += (cs - _countersteer) * blend
	# Plain understeer: the fronts are well past their peak and the rear is not.
	var front := 0.5 * (absf(state.slip_angle[0]) + absf(state.slip_angle[1]))
	var under := 0.0
	if front > absf(rear):
		under = clampf(front / peak - spec.aid_stab_understeer_slip, 0.0, 1.0) * fade
	_understeer += (under - _understeer) * blend

# ================================================================ pedals
func _step_pedals(state: SimState, spec: CarSpec, dt: float) -> void:
	var throttle := clampf(state.in_throttle, 0.0, 1.0)
	var brake := clampf(state.in_brake, 0.0, 1.0)
	if state.gear < 0:
		# Reverse: the power unit and the brakes read the raw pedals themselves.
		_tc_int = 1.0
		_abs_int = 1.0
		tc_cut = 0.0
		abs_release = 0.0
		state.throttle = throttle
		state.brake = brake
		return
	var peak := _peak_slip_ratio(spec)

	# ---- stability: ease the throttle in a slide; cancel engine braking when the pedal is up
	var stand_back := 1.0 - overdrive   # the driver asked for the slide
	var demand := throttle * (1.0 - spec.aid_stab_throttle_cut * stability * stand_back) * (1.0 - spec.aid_stab_understeer_cut * _understeer * stand_back)
	if brake <= 0.0:
		demand = maxf(demand, minf(spec.aid_stab_drag_throttle * stability, 1.0))

	# ---- traction control
	if traction_control <= 0:
		_tc_int = 1.0
		tc_cut = 0.0
		state.throttle = demand
	else:
		var target := peak * (spec.aid_tc_slip_high if traction_control >= 2 else spec.aid_tc_slip_low)
		if traction_control >= 2:
			# Cornering uses the same grip: allow less wheel slip as the rear slip angle builds.
			var lat := 0.5 * (absf(state.slip_angle[2]) + absf(state.slip_angle[3])) / _peak_slip_angle(spec)
			target *= 1.0 - spec.aid_tc_lateral_trim * clampf(lat, 0.0, 1.0)
		# In the steering overdrive the driver wants the rear to step out: allow much more slip.
		target *= 1.0 + spec.aid_steer_overdrive_tc_slip * overdrive
		var err := maxf(_slip_speed_over(state, 2, 1.0, target), _slip_speed_over(state, 3, 1.0, target))
		var lo := clampf(spec.aid_tc_min_throttle, 0.0, 1.0)
		_tc_int = clampf(_tc_int - spec.aid_tc_ki * err * dt, lo, 1.0)
		var ceiling := clampf(_tc_int - spec.aid_tc_kp * err, lo, 1.0)
		state.throttle = minf(demand, ceiling)
		tc_cut = demand - state.throttle

	# ---- ABS
	if not anti_lock or state.speed < spec.aid_abs_min_speed:
		_abs_int = 1.0
		abs_release = 0.0
		state.brake = brake
	else:
		var b_target := peak * spec.aid_abs_slip
		var b_err := -INF
		for i in 4:
			if state.contact[i]:
				# Locking is slip against the direction of travel, also when rolling backwards.
				b_err = maxf(b_err, _slip_speed_over(state, i, 1.0 if state.wheel_v_long[i] < 0.0 else -1.0, b_target))
		if b_err == -INF:
			b_err = 0.0
		var b_lo := clampf(spec.aid_abs_min_brake, 0.0, 1.0)
		_abs_int = clampf(_abs_int - spec.aid_abs_ki * b_err * dt, b_lo, 1.0)
		var b_ceiling := clampf(_abs_int - spec.aid_abs_kp * b_err, b_lo, 1.0)
		state.brake = minf(brake, b_ceiling)
		abs_release = brake - state.brake

## How far wheel i's slip speed (m/s, in direction `dir`: +1 spinning, -1 locking) is over
## the slip-ratio target. Negative below the target.
func _slip_speed_over(state: SimState, i: int, dir: float, target_ratio: float) -> float:
	var v_ref := maxf(absf(state.wheel_v_long[i]), SimHandling.MIN_SLIP_SPEED_LONG)
	return (state.slip_ratio[i] * dir - target_ratio) * v_ref

# ================================================================ gearbox
func _step_gearbox(state: SimState, spec: CarSpec, dt: float) -> void:
	state.shift_request = 0
	_manual_hold = maxf(0.0, _manual_hold - dt)
	_shift_cooldown = maxf(0.0, _shift_cooldown - dt)
	if state.in_shift_up:
		_pending_shift = 1
	elif state.in_shift_down:
		_pending_shift = -1
	var count := spec.gear_ratios.size()
	if state.gear < 1 or state.gear > count:
		_pending_shift = 0
		_limiter_time = 0.0
		return
	if state.shifting > 0.0:
		return   # a manual request waits for the shift in progress
	# Engine speed the road speed gives in this gear (no wheel slip). With spinning wheels the
	# engine turns faster than that: downshifts are judged on the higher of the two, so a
	# gear the wheelspin just left is not taken again.
	var rpm_road := absf(state.v_long) / Car.REAR_WHEEL_RADIUS * spec.final_drive * 60.0 / TAU * spec.gear_ratios[state.gear - 1]
	var rpm_now := maxf(rpm_road, state.rpm)
	var rpm_lower := rpm_now * spec.gear_ratios[state.gear - 2] / spec.gear_ratios[state.gear - 1] if state.gear > 1 else INF

	if _pending_shift != 0:
		var req := _pending_shift
		_pending_shift = 0
		# The gearbox refuses a downshift that would over-rev the engine, aids or not.
		if (req > 0 and state.gear < count) or (req < 0 and state.gear > 1 and rpm_lower <= spec.rpm_max):
			state.shift_request = req
			_shift_cooldown = spec.aid_shift_cooldown
			_limiter_time = 0.0
			_manual_hold = spec.aid_manual_hold_time   # only a shift that happened takes over
		return
	if not auto_gearbox or _manual_hold > 0.0:
		_limiter_time = 0.0
		return

	_limiter_time = _limiter_time + dt if state.rpm >= spec.rpm_shift_up else 0.0
	if _shift_cooldown > 0.0:
		return
	if state.gear < count and state.rpm >= spec.rpm_shift_up:
		# With spinning wheels the revs say nothing about the road speed: wait a moment.
		if rpm_road >= spec.rpm_shift_up * spec.aid_upshift_grip_rpm or _limiter_time >= spec.aid_upshift_spin_delay:
			_auto_shift(state, spec, 1)
		return
	if state.gear > 1 and rpm_lower < spec.rpm_shift_up * spec.aid_downshift_max_rpm and rpm_lower < spec.rpm_max:
		var low := rpm_now < spec.rpm_shift_down
		var kick := state.in_throttle >= spec.aid_kickdown_throttle and rpm_lower < spec.rpm_shift_up * spec.aid_kickdown_rpm
		if not (low or kick):
			return
		# A downshift while the rear is sliding unsettles it further; wait unless the engine
		# is about to bog down.
		var rear := 0.5 * (absf(state.slip_angle[2]) + absf(state.slip_angle[3]))
		var sliding := state.speed > spec.aid_stab_min_speed and rear > spec.aid_shift_block_slip * _peak_slip_angle(spec)
		if sliding and rpm_now > spec.rpm_idle * spec.aid_shift_block_release_rpm:
			return
		_auto_shift(state, spec, -1)

func _auto_shift(state: SimState, spec: CarSpec, dir: int) -> void:
	state.shift_request = dir
	_shift_cooldown = spec.aid_shift_cooldown
	_limiter_time = 0.0

# ================================================================ DRS
## A short press toggles the flap; a long press holds it open until released. Braking closes it.
func _step_drs(state: SimState, spec: CarSpec, dt: float) -> void:
	var pressed := state.in_drs
	if pressed and not _drs_prev:
		_drs_on = not _drs_on
		_drs_press_time = 0.0
	elif pressed:
		_drs_press_time += dt
	elif _drs_prev and _drs_press_time > spec.aid_drs_hold_time:
		_drs_on = false
	_drs_prev = pressed
	if state.in_brake > spec.aid_drs_brake_close:
		_drs_on = false
	state.drs_request = _drs_on
