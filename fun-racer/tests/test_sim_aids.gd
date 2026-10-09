extends TestCase
## Driving aids of the simulation car (scripts/car/sim/aids.gd): each aid on and off changes
## the measured behaviour, the Settings keys act live, and Options -> Gameplay edits them.

const KEYS: Array[String] = ["aid_traction_control", "aid_abs", "aid_auto_gearbox", "aid_steering_help", "aid_stability"]

## A tyre that loses grip once it slides, as real tyres do (the placeholder tyre keeps its
## peak force at any slip, which hides what a locked wheel costs).
class SlidingTyre extends SimTyreModel:
	func forces(state: SimState, spec: CarSpec, i: int, dt: float) -> Vector2:
		var f := super(state, spec, i, dt)
		var sx := state.slip_ratio[i] / spec.tyre_peak_slip_ratio
		var sy := tan(state.slip_angle[i]) / tan(spec.tyre_peak_slip_angle)
		var s := sqrt(sx * sx + sy * sy)
		return f * lerpf(1.0, 0.75, clampf((s - 1.0) / 3.0, 0.0, 1.0))

func _aid(key: String, value: Variant) -> void:
	Settings.set_value("gameplay", key, value)

func _restore() -> void:
	for key in KEYS:
		_aid(key, Settings.default_value("gameplay", key))
	_aid("handling", Settings.default_value("gameplay", "handling"))

## Back to the spawn point at a standstill, inputs neutral.
func _restart(car: Car) -> void:
	car.set_input_override(0.0, 0.0, 0.0)
	car.respawn()
	await physics_frames(SimRig.HZ / 2)

func _rear_slip(car: Car) -> float:
	return maxf(car.sim.state.slip_ratio[2], car.sim.state.slip_ratio[3])

## Full-throttle standing start to 100 km/h: time, mean and peak rear slip ratio.
func _launch(car: Car) -> Dictionary:
	await _restart(car)
	car.set_input_override(1.0, 0.0, 0.0)
	var t := 0.0
	var total := 0.0
	var peak := 0.0
	var n := 0
	while car.linear_velocity.length() * 3.6 < 100.0 and t < 8.0:
		await get_tree().physics_frame
		t += SimRig.TICK
		var s := _rear_slip(car)
		total += s
		peak = maxf(peak, s)
		n += 1
	car.set_input_override(0.0, 0.0, 0.0)
	return {"t_100": t, "mean_slip": total / maxf(n, 1), "peak_slip": peak, "gear": car.gear}

## Full-pedal stop from `kmh`: distance, longest run of ticks any one wheel stayed locked
## (above 10 km/h) and the share of ticks with a locked wheel.
func _stop(car: Car, kmh: float) -> Dictionary:
	await _restart(car)
	SimRig.set_speed(car, kmh)
	await physics_frames(SimRig.HZ / 4)
	var start := car.global_position
	var run: Array[int] = [0, 0, 0, 0]
	var longest := 0
	var locked_ticks := 0
	var ticks := 0
	var t := 0.0
	car.set_input_override(0.0, 1.0, 0.0)
	while car.linear_velocity.length() * 3.6 > 1.0 and t < 15.0:
		await get_tree().physics_frame
		t += SimRig.TICK
		if car.linear_velocity.length() * 3.6 < 10.0:
			continue
		ticks += 1
		var any := false
		for i in 4:
			run[i] = run[i] + 1 if car.sim.state.locked[i] else 0
			longest = maxi(longest, run[i])
			any = any or car.sim.state.locked[i]
		if any:
			locked_ticks += 1
	car.set_input_override(0.0, 0.0, 0.0)
	return {"distance": car.global_position.distance_to(start), "longest_lock": longest,
			"locked_share": float(locked_ticks) / maxf(ticks, 1), "time": t}

func test_traction_control_launch() -> void:
	var car := await SimRig.spawn(self)
	var res: Array[Dictionary] = []
	for level in 3:
		_aid("aid_traction_control", level)
		res.append(await _launch(car))
		print("    launch, traction control %s: 0-100 %.2f s, rear slip mean %.3f, peak %.2f" % [
				["off", "low", "high"][level], res[level]["t_100"], res[level]["mean_slip"], res[level]["peak_slip"]])
	var peak := car.sim.spec.tyre_peak_slip_ratio
	assert_true(res[0]["mean_slip"] > peak * 4.0, "without traction control full throttle spins the rears (mean slip %.2f)" % res[0]["mean_slip"])
	assert_true(res[2]["mean_slip"] < res[0]["mean_slip"] * 0.4, "HIGH has much less rear slip than OFF")
	assert_between(res[2]["mean_slip"], peak * 0.7, peak * 1.8, "HIGH holds the rears near the tyre's peak slip")
	assert_true(res[1]["mean_slip"] > res[2]["mean_slip"] * 1.3, "LOW allows more slip than HIGH")
	assert_true(res[1]["mean_slip"] < res[0]["mean_slip"], "LOW still has less slip than OFF")
	assert_true(res[2]["t_100"] <= res[0]["t_100"] + 0.15, "HIGH is no slower to 100 km/h (%.2f s vs %.2f s)" % [res[2]["t_100"], res[0]["t_100"]])
	assert_between(res[2]["t_100"], 1.5, 3.5, "0-100 km/h with traction control (s)")
	_restore()

func test_abs_stop() -> void:
	var car := await SimRig.spawn(self)
	var on := await _stop(car, 150.0)
	_aid("aid_abs", 0)
	var off := await _stop(car, 150.0)
	print("    150-0, placeholder tyre: ABS on %.1f m (longest lock %d ticks), off %.1f m (locked %.0f %% of the stop)" % [
			on["distance"], on["longest_lock"], off["distance"], off["locked_share"] * 100.0])
	assert_true(on["longest_lock"] <= 6, "ABS: no wheel stays locked (longest run %d ticks)" % on["longest_lock"])
	assert_true(off["locked_share"] > 0.3, "without ABS the full pedal locks wheels (%.0f %% of the stop)" % (off["locked_share"] * 100.0))
	# The placeholder tyre grips as hard locked as at its peak, and one pedal for four wheels
	# means the axle nearest to locking sets the pressure: here ABS costs some distance.
	assert_true(on["distance"] <= off["distance"] * 1.25, "ABS on the placeholder tyre stays close (%.1f m vs %.1f m)" % [on["distance"], off["distance"]])
	# On a tyre that loses grip when it slides, as real ones do, ABS is clearly shorter.
	car.sim.tyres = SlidingTyre.new()
	var off2 := await _stop(car, 150.0)
	_aid("aid_abs", 1)
	var on2 := await _stop(car, 150.0)
	print("    150-0, sliding tyre: ABS on %.1f m (longest lock %d ticks), off %.1f m" % [on2["distance"], on2["longest_lock"], off2["distance"]])
	assert_true(on2["longest_lock"] <= 6, "ABS on the sliding tyre: no wheel stays locked (%d ticks)" % on2["longest_lock"])
	assert_true(on2["distance"] < off2["distance"] * 0.95, "ABS stops shorter than locked wheels (%.1f m vs %.1f m)" % [on2["distance"], off2["distance"]])
	_restore()

func test_manual_and_automatic_gearbox() -> void:
	var car := await SimRig.spawn(self)
	_aid("aid_auto_gearbox", false)
	await SimRig.drive(self, car, 4.0, 1.0, 0.0, 0.0)
	assert_true(car.gear == 1, "manual: stays in 1st at full throttle (gear %d)" % car.gear)
	assert_true(car.rpm > car.sim.spec.rpm_shift_up, "manual: on the limiter (%.0f rpm)" % car.rpm)
	car.sim.request_shift(1)
	await physics_frames(30)
	assert_true(car.gear == 2, "manual: shift_up gives 2nd (gear %d)" % car.gear)
	# A downshift that would over-rev is refused.
	await SimRig.drive(self, car, 3.0, 1.0, 0.0, 0.0)
	assert_true(car.gear == 2, "manual: still 2nd")
	car.sim.request_shift(-1)
	await physics_frames(30)
	assert_true(car.gear == 2, "manual: no downshift into an over-rev (gear %d, %.0f km/h)" % [car.gear, car.speed_kmh])
	# Automatic: shifts up by itself, back down when slowing, and a manual shift holds.
	_aid("aid_auto_gearbox", true)
	await _restart(car)
	await SimRig.drive(self, car, 6.0, 1.0, 0.0, 0.0)
	var top := car.gear
	assert_true(top >= 4, "automatic: shifted up (gear %d)" % top)
	var peak_rpm := 0.0
	car.set_input_override(0.0, 0.6, 0.0)
	while car.linear_velocity.length() > 8.0:
		await get_tree().physics_frame
		peak_rpm = maxf(peak_rpm, car.rpm)
	assert_true(car.gear <= 2, "automatic: shifted down while braking (gear %d)" % car.gear)
	assert_true(peak_rpm < car.sim.spec.rpm_max - 100.0, "automatic: downshifts never over-rev (%.0f rpm)" % peak_rpm)
	SimRig.set_speed(car, 150.0)
	await SimRig.drive(self, car, 0.5, 0.3, 0.0, 0.0)
	var g := car.gear
	car.sim.request_shift(1)
	await SimRig.drive(self, car, 1.5, 0.3, 0.0, 0.0)
	assert_true(car.gear == g + 1, "automatic: a manual upshift is kept for a while (gear %d -> %d)" % [g, car.gear])
	# Kick-down: full throttle from a high gear picks a lower one.
	await _restart(car)
	SimRig.set_speed(car, 120.0)
	car.sim.state.gear = 6
	await SimRig.drive(self, car, 0.6, 1.0, 0.0, 0.0)
	assert_true(car.gear < 6, "automatic: kicks down on full throttle (gear %d)" % car.gear)
	_restore()

## Full steering input at `kmh` for 1.5 s: peak of the mean front slip angle (rad) and the
## steering angle reached.
func _turn_in(car: Car, kmh: float) -> Dictionary:
	await _restart(car)
	SimRig.set_speed(car, kmh)
	await physics_frames(SimRig.HZ / 4)
	var peak := 0.0
	var angle := 0.0
	car.set_input_override(0.5, 0.0, 1.0)
	for k in int(1.5 * SimRig.HZ):
		await get_tree().physics_frame
		var st := car.sim.state
		peak = maxf(peak, 0.5 * (absf(st.slip_angle[0]) + absf(st.slip_angle[1])))
		angle = maxf(angle, absf(st.steer_angle))
	car.set_input_override(0.0, 0.0, 0.0)
	return {"front_slip": peak, "angle": angle}

func test_steering_help_limits_front_slip() -> void:
	var car := await SimRig.spawn(self)
	_aid("aid_stability", 0)
	var on := await _turn_in(car, 250.0)
	_aid("aid_steering_help", 0)
	var off := await _turn_in(car, 250.0)
	var peak := car.sim.spec.tyre_peak_slip_angle
	print("    full steer at 250 km/h: front slip %.1f deg (lock %.1f deg) with help, %.1f deg (lock %.1f deg) without; tyre peak %.1f deg" % [
			rad_to_deg(on["front_slip"]), rad_to_deg(on["angle"]), rad_to_deg(off["front_slip"]), rad_to_deg(off["angle"]), rad_to_deg(peak)])
	assert_true(on["front_slip"] < peak * 1.4, "help keeps the fronts near their peak (%.3f rad)" % on["front_slip"])
	assert_true(on["front_slip"] > peak * 0.5, "help still uses the front tyres (%.3f rad)" % on["front_slip"])
	assert_true(off["front_slip"] > peak * 2.0, "without help full lock at 250 km/h is far past the peak (%.3f rad)" % off["front_slip"])
	assert_between(off["angle"], car.sim.spec.max_steer_angle - 0.001, car.sim.spec.max_steer_angle + 0.001, "without help: full mechanical lock")
	# At parking speed the help gives the full lock too, and the response is softer at the centre.
	await _restart(car)
	_aid("aid_steering_help", 1)
	await SimRig.drive(self, car, 0.5, 0.0, 0.0, 1.0)
	assert_between(absf(car.sim.state.steer_angle), car.sim.spec.max_steer_angle - 0.001, car.sim.spec.max_steer_angle + 0.001, "help: full lock at a standstill")
	assert_true(car.sim.state.steer_angle < 0.0, "steering right is a negative angle")
	await SimRig.drive(self, car, 0.5, 0.0, 0.0, 0.3)
	assert_true(absf(car.sim.state.steer_angle) < 0.3 * car.sim.spec.max_steer_angle * 0.9, "help: finer control near the centre")
	_restore()

## Corner at the limit at `kmh` on the throttle, then lift suddenly: peak body slip (rad)
## in the 2.5 s after the lift.
func _lift_mid_corner(car: Car, kmh: float) -> float:
	await _restart(car)
	SimRig.set_speed(car, kmh)
	var target := kmh / 3.6
	for k in int(2.0 * SimRig.HZ):
		var err := target - car.linear_velocity.length()
		car.set_input_override(clampf(0.4 + err * 0.5, 0.0, 1.0), 0.0, minf(1.0, k / (0.8 * SimRig.HZ)))
		await get_tree().physics_frame
	var peak := 0.0
	car.set_input_override(0.0, 0.0, 1.0)
	for k in int(2.5 * SimRig.HZ):
		await get_tree().physics_frame
		peak = maxf(peak, absf(car.sim.state.body_slip))
	car.set_input_override(0.0, 0.0, 0.0)
	return peak

func test_stability_help_calms_a_lift() -> void:
	var car := await SimRig.spawn(self)
	for kmh: float in [120.0, 160.0, 200.0]:
		_aid("aid_stability", 1)
		var on := await _lift_mid_corner(car, kmh)
		_aid("aid_stability", 0)
		var off := await _lift_mid_corner(car, kmh)
		print("    lift mid-corner at %.0f km/h: peak body slip %.1f deg with stability help, %.1f deg without" % [kmh, rad_to_deg(on), rad_to_deg(off)])
		# A car that barely slides gives the help nothing to do.
		assert_true(on < off * 0.75 or off < deg_to_rad(4.0), "stability help reduces the slide after a lift at %.0f km/h (%.2f rad vs %.2f rad)" % [kmh, on, off])
		assert_true(on < deg_to_rad(35.0), "with stability help the car does not spin at %.0f km/h (%.2f rad)" % [kmh, on])
	_restore()

func test_settings_switch_the_aids_live() -> void:
	var car := await SimRig.spawn(self)
	var aids := car.sim.aids
	assert_true(aids.traction_control == 2 and aids.anti_lock and aids.auto_gearbox and aids.steering_help and aids.stability_help,
			"every aid is on by default, traction control on high")
	_aid("aid_traction_control", 1)
	_aid("aid_abs", 0)
	_aid("aid_auto_gearbox", false)
	_aid("aid_steering_help", 0)
	_aid("aid_stability", 0)
	assert_true(aids.traction_control == 1 and not aids.anti_lock and not aids.auto_gearbox and not aids.steering_help and not aids.stability_help,
			"the settings reach a running car")
	# The same car, mid-run: full steering at 250 km/h follows the steering help setting.
	_aid("aid_stability", 1)
	SimRig.set_speed(car, 250.0)
	await SimRig.drive(self, car, 0.3, 0.3, 0.0, 1.0)
	assert_true(absf(car.sim.state.steer_angle) > 0.25, "help off: about the full lock at 250 km/h (%.3f rad)" % car.sim.state.steer_angle)
	_aid("aid_steering_help", 1)
	await SimRig.drive(self, car, 0.3, 0.3, 0.0, 1.0)
	assert_true(absf(car.sim.state.steer_angle) < 0.15, "help switched on mid-run: the lock drops (%.3f rad)" % car.sim.state.steer_angle)
	assert_between(aids.steer_lock, car.sim.spec.aid_steer_min_lock, 0.15, "published lock at speed (rad)")
	# With every aid off the pedals pass straight through.
	await _restart(car)
	_aid("aid_traction_control", 0)
	_aid("aid_steering_help", 0)
	_aid("aid_stability", 0)
	await SimRig.drive(self, car, 0.2, 0.7, 0.0, -0.5)
	assert_between(car.sim.state.throttle, 0.699, 0.701, "no aids: the throttle is the pedal")
	assert_between(car.sim.state.steer_angle, 0.5 * car.sim.spec.max_steer_angle - 0.01, 0.5 * car.sim.spec.max_steer_angle + 0.01, "no aids: linear steering, left is positive")
	# An aid set by hand ignores the player's settings.
	aids.follow_settings = false
	aids.traction_control = 2
	_aid("aid_abs", 1)
	assert_true(aids.traction_control == 2 and not aids.anti_lock, "follow_settings = false keeps the aids as set")
	_restore()

## The part alone, on a hand-built state: gearbox rules and the DRS button.
func test_gearbox_rules_and_drs_button() -> void:
	var spec := load(Car.SIM_SPEC_PATH) as CarSpec
	var st := SimState.new()
	st.reset(spec)
	var aids := SimAids.new()
	aids.follow_settings = false
	aids.setup(spec)
	aids.reset(st, spec)
	var dt := SimRig.TICK
	st.on_ground = 4
	for i in 4:
		st.contact[i] = true
	# 4th gear at the shift rpm: the automatic asks for 5th.
	var per_ratio := spec.final_drive * 60.0 / TAU / Car.REAR_WHEEL_RADIUS
	st.gear = 4
	st.v_long = spec.rpm_shift_up * 1.01 / (per_ratio * spec.gear_ratios[3])
	st.speed = st.v_long
	st.rpm = spec.rpm_shift_up * 1.01
	st.in_throttle = 1.0
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 1, "upshift at the shift rpm")
	# Wheels spinning (revs high, road speed low): no upshift at once, only after a moment.
	aids.reset(st, spec)
	st.v_long = 10.0
	st.speed = 10.0
	st.gear = 1
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 0, "no upshift on wheelspin alone")
	var asked := false
	for k in int(spec.aid_upshift_spin_delay / dt) + 5:
		aids.step(st, spec, dt)
		asked = asked or st.shift_request == 1
	assert_true(asked, "... but it does shift up when the spin lasts")
	# Slowing down in 5th: downshift once the revs are low, and not twice within the cooldown.
	aids.reset(st, spec)
	st.in_throttle = 0.0
	st.gear = 5
	st.v_long = spec.rpm_shift_down * 0.95 / (per_ratio * spec.gear_ratios[4])
	st.speed = st.v_long
	st.rpm = spec.rpm_shift_down * 0.95
	aids.step(st, spec, dt)
	assert_true(st.shift_request == -1, "downshift below the downshift rpm")
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 0, "one shift at a time")
	# Not while the rear is sliding.
	aids.reset(st, spec)
	st.slip_angle[2] = spec.tyre_peak_slip_angle * 1.5
	st.slip_angle[3] = spec.tyre_peak_slip_angle * 1.5
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 0, "no automatic downshift while the rear slides")
	st.slip_angle[2] = 0.0
	st.slip_angle[3] = 0.0
	# Just above the downshift rpm: nothing (hysteresis), unless the driver floors it.
	aids.reset(st, spec)
	st.v_long = spec.rpm_shift_down * 1.03 / (per_ratio * spec.gear_ratios[4])
	st.speed = st.v_long
	st.rpm = spec.rpm_shift_down * 1.03
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 0, "no downshift above the downshift rpm")
	st.in_throttle = 1.0
	aids.step(st, spec, dt)
	assert_true(st.shift_request == -1, "kick-down on full throttle")
	# Never into an over-rev: automatic or by hand.
	aids.reset(st, spec)
	st.v_long = spec.rpm_shift_up * 0.97 / (per_ratio * spec.gear_ratios[4])
	st.speed = st.v_long
	st.rpm = spec.rpm_shift_up * 0.97
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 0, "no kick-down into the limiter")
	# By hand: refused only when the lower gear would pass the rev limit.
	st.v_long = spec.rpm_max * 0.97 / (per_ratio * spec.gear_ratios[4])
	st.speed = st.v_long
	st.rpm = spec.rpm_max * 0.97
	st.in_shift_down = true
	aids.step(st, spec, dt)
	st.in_shift_down = false
	assert_true(st.shift_request == 0, "a manual downshift that would over-rev is refused")
	# A manual upshift is passed on, even while another shift is finishing, and the
	# automatic then stays out for a while.
	aids.reset(st, spec)
	st.in_throttle = 0.0
	st.v_long = spec.rpm_shift_down * 0.9 / (per_ratio * spec.gear_ratios[4])
	st.speed = st.v_long
	st.rpm = spec.rpm_shift_down * 0.9
	st.shifting = 0.02
	st.in_shift_up = true
	aids.step(st, spec, dt)
	st.in_shift_up = false
	assert_true(st.shift_request == 0, "waits for the shift in progress")
	st.shifting = 0.0
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 1, "then passes the manual upshift on")
	var auto_shifts := 0
	for k in int(spec.aid_manual_hold_time / dt) - 5:
		aids.step(st, spec, dt)
		auto_shifts += absi(st.shift_request)
	assert_true(auto_shifts == 0, "the automatic stays out after a manual shift")
	for k in 20:
		aids.step(st, spec, dt)
		auto_shifts += absi(st.shift_request)
	assert_true(auto_shifts == 1, "and comes back afterwards")
	# Manual gearbox: nothing by itself.
	aids.reset(st, spec)
	aids.auto_gearbox = false
	aids.step(st, spec, dt)
	assert_true(st.shift_request == 0, "manual gearbox: no automatic shift")
	# DRS: a tap toggles, a long press holds, braking closes.
	aids.reset(st, spec)
	st.in_drs = true
	aids.step(st, spec, dt)
	st.in_drs = false
	aids.step(st, spec, dt)
	assert_true(st.drs_request, "tap: DRS opens and stays open")
	st.in_drs = true
	aids.step(st, spec, dt)
	st.in_drs = false
	aids.step(st, spec, dt)
	assert_true(not st.drs_request, "second tap closes it")
	st.in_drs = true
	for k in int(spec.aid_drs_hold_time / dt) + 10:
		aids.step(st, spec, dt)
	assert_true(st.drs_request, "held: open")
	st.in_drs = false
	aids.step(st, spec, dt)
	assert_true(not st.drs_request, "released after a long press: closed")
	st.in_drs = true
	aids.step(st, spec, dt)
	st.in_drs = false
	st.in_brake = 0.5
	aids.step(st, spec, dt)
	assert_true(not st.drs_request, "braking closes the DRS")
	st.in_brake = 0.0
	aids.step(st, spec, dt)
	assert_true(not st.drs_request, "and it stays closed afterwards")

func test_gameplay_tab_rows() -> void:
	var screen := spawn("res://scenes/menu/settings.tscn") as SettingsScreen
	await get_tree().process_frame
	screen.show_tab("gameplay")
	await get_tree().process_frame
	var handling := screen.row("gameplay", "handling")
	assert_true(handling != null and handling.stepper.text() == "ARCADE", "HANDLING row shows the default")
	assert_true(handling.description.contains("next race"), "HANDLING says when it applies")
	assert_true(screen.aids_heading.is_visible_in_tree() and screen.aids_heading.text.begins_with("DRIVING AIDS"), "DRIVING AIDS heading")
	var page_bottom := (screen.aids_heading.get_parent().get_parent() as Control).get_global_rect().end.y
	var last_y := 0.0
	for key in KEYS:
		var r := screen.row("gameplay", key)
		assert_true(r != null and r.is_visible_in_tree(), "%s has a row" % key)
		assert_true(not r.description.is_empty() and r.description.length() < 100, "%s has a one-line description" % key)
		assert_true(not r.stepper.enabled and r.title.modulate.a < 0.9, "%s is greyed out with arcade handling" % key)
		assert_true(r.get_global_rect().position.y > last_y and r.get_global_rect().position.y > screen.aids_heading.get_global_rect().position.y,
				"%s is below the heading, in order" % key)
		last_y = r.get_global_rect().position.y
		assert_true(r.get_global_rect().end.y <= page_bottom + 0.5, "%s fits in the panel" % key)
		# A greyed-out row does not change its setting.
		var before: Variant = Settings.get_value("gameplay", key)
		r.stepper.step(-1)
		assert_true(Settings.get_value("gameplay", key) == before, "%s is locked with arcade handling" % key)
	# Choosing simulation unlocks them.
	handling.stepper.step(1)
	assert_true(Settings.get_value("gameplay", "handling") == "simulation", "HANDLING writes gameplay/handling")
	assert_true(screen.row("gameplay", "aid_abs").stepper.enabled, "aids unlocked with simulation handling")
	assert_true(screen.row("gameplay", "aid_traction_control").stepper.text() == "HIGH", "traction control shows HIGH")
	assert_true(screen.row("gameplay", "aid_auto_gearbox").stepper.text() == "AUTOMATIC", "gearbox shows AUTOMATIC")
	screen.row("gameplay", "aid_traction_control").stepper.step(-1)
	assert_true(Settings.get_value("gameplay", "aid_traction_control") == 1, "traction control row writes LOW")
	screen.row("gameplay", "aid_traction_control").stepper.step(-1)
	assert_true(Settings.get_value("gameplay", "aid_traction_control") == 0, "... and OFF")
	screen.row("gameplay", "aid_abs").stepper.step(-1)
	assert_true(Settings.get_value("gameplay", "aid_abs") == 0, "ABS row writes the setting")
	screen.row("gameplay", "aid_auto_gearbox").stepper.step(-1)
	assert_true(Settings.get_value("gameplay", "aid_auto_gearbox") == false, "gearbox row writes the setting")
	screen.row("gameplay", "aid_steering_help").stepper.step(-1)
	assert_true(Settings.get_value("gameplay", "aid_steering_help") == 0, "steering help row writes the setting")
	screen.row("gameplay", "aid_stability").stepper.step(-1)
	assert_true(Settings.get_value("gameplay", "aid_stability") == 0, "stability row writes the setting")
	# Keyboard / gamepad: the rows chain from HANDLING down to BACK, and left / right edits.
	var chain: Control = handling.widget
	for key in KEYS:
		chain = chain.get_node(chain.focus_neighbor_bottom) as Control
		assert_true(chain == screen.row("gameplay", key).widget, "down reaches %s" % key)
	assert_true(chain.get_node(chain.focus_neighbor_bottom) == screen.back_button, "the last aid leads down to BACK")
	var stab := screen.row("gameplay", "aid_stability")
	stab.stepper.grab_focus()
	assert_true(screen.description_text() == stab.description, "the description strip follows focus")
	var ev := InputEventAction.new()
	ev.action = &"ui_right"
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame
	var up := InputEventAction.new()
	up.action = &"ui_right"
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame
	assert_true(Settings.get_value("gameplay", "aid_stability") == 1, "ui_right changes the focused aid")
	# RESET TO DEFAULTS puts the aids back on and the handling back to arcade.
	screen.reset_current_tab()
	assert_true(Settings.get_value("gameplay", "aid_traction_control") == 2 and Settings.get_value("gameplay", "aid_auto_gearbox") == true,
			"reset restores the aids")
	assert_true(Settings.get_value("gameplay", "handling") == "arcade", "reset restores the handling")
	_restore()
