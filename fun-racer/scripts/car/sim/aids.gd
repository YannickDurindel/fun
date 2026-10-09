class_name SimAids
extends RefCounted
## PLACEHOLDER driving aids. Turns the raw driver input (state.in_*) into demands for the
## parts (state.throttle, brake, steer_angle, shift_request, drs_request).
## This placeholder has a crude traction control and anti-lock, speed-sensitive steering and
## always uses the automatic gearbox. The real unit adds traction control, ABS, stability and steering help, each
## switchable from Settings.

func setup(_spec: CarSpec) -> void:
	pass

func reset(_state: SimState, _spec: CarSpec) -> void:
	pass

## Called first every tick.
func step(state: SimState, spec: CarSpec, _dt: float) -> void:
	# Crude traction control and anti-lock so the placeholder car is drivable: cut the demand
	# as the driven / braked wheels pass the tyres' peak slip.
	var spin := maxf(state.slip_ratio[2], state.slip_ratio[3])
	state.throttle = state.in_throttle * clampf(1.0 - (spin - spec.tyre_peak_slip_ratio) / 0.08, 0.15, 1.0)
	var locking := 0.0
	for i in 4:
		locking = maxf(locking, -state.slip_ratio[i])
	state.brake = state.in_brake * clampf(1.0 - (locking - spec.tyre_peak_slip_ratio * 1.2) / 0.10, 0.2, 1.0)
	# Less lock at speed so full input stays near the tyres' limit (keyboard friendly).
	var lock := spec.max_steer_angle / (1.0 + pow(state.speed / 28.0, 2.0))
	state.steer_angle = -state.in_steer * maxf(lock, 0.03)
	state.shift_request = 0
	if state.shifting <= 0.0 and state.gear >= 1:
		if state.rpm > spec.rpm_shift_up and state.gear < spec.gear_ratios.size():
			state.shift_request = 1
		elif state.rpm < spec.rpm_shift_down and state.gear > 1:
			state.shift_request = -1
	state.drs_request = false
