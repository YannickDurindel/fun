class_name SimPowertrain
extends RefCounted
## PLACEHOLDER power unit and gearbox. Writes state.drive_torque (N m at each wheel; rear-wheel
## drive, so indices 2 and 3), state.gear, state.rpm, state.shifting and state.ers_energy.
## Reads state.throttle, state.shift_request and the rear wheels' state.omega.
## This placeholder: constant power below the torque limit, open differential, instant
## clutch, no energy management.

func setup(_spec: CarSpec) -> void:
	pass

func reset(state: SimState, spec: CarSpec) -> void:
	state.gear = 1
	state.rpm = spec.rpm_idle
	state.shifting = 0.0
	state.ers_energy = spec.ers_capacity

func ratio(state: SimState, spec: CarSpec) -> float:
	if state.gear >= 1:
		return spec.gear_ratios[state.gear - 1] * spec.final_drive
	if state.gear == -1:
		return -spec.reverse_ratio * spec.final_drive
	return 0.0

func step(state: SimState, spec: CarSpec, dt: float) -> void:
	# Reverse: brake held at a standstill with no throttle.
	if state.gear >= 1 and state.speed < 0.5 and state.in_brake > 0.5 and state.in_throttle < 0.05 and state.v_long < 0.3:
		state.gear = -1
	elif state.gear == -1 and state.in_throttle > 0.05:
		state.gear = 1
	if state.shift_request != 0 and state.shifting <= 0.0 and state.gear >= 1:
		state.gear = clampi(state.gear + state.shift_request, 1, spec.gear_ratios.size())
		state.shifting = spec.shift_time
	state.shifting = maxf(0.0, state.shifting - dt)
	var r := ratio(state, spec)
	var axle_omega := 0.5 * (state.omega[2] + state.omega[3])
	var engine_omega := absf(axle_omega * r)
	state.rpm = clampf(engine_omega * 60.0 / TAU, spec.rpm_idle, spec.rpm_max)
	var torque := 0.0
	if state.gear == -1:
		# In reverse the brake pedal is the accelerator.
		torque = state.in_brake * spec.engine_torque_max * 0.35 if state.v_long > -22.0 else 0.0
	elif state.shifting <= 0.0:
		var power := spec.engine_power + spec.ers_power
		var w := maxf(state.rpm * TAU / 60.0, 1.0)
		torque = state.throttle * minf(spec.engine_torque_max, power / w)
		if state.rpm >= spec.rpm_max - 1.0:
			torque = 0.0
		# Engine braking only resists a turning engine: none at a standstill.
		torque -= (1.0 - state.throttle) * spec.engine_brake_torque * clampf(axle_omega / 8.0, 0.0, 1.0)
	var wheel_torque := torque * r * spec.driveline_efficiency
	state.drive_torque[0] = 0.0
	state.drive_torque[1] = 0.0
	state.drive_torque[2] = wheel_torque * 0.5
	state.drive_torque[3] = wheel_torque * 0.5
