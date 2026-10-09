class_name SimBrakes
extends RefCounted
## PLACEHOLDER brakes. Writes state.brake_torque (N m per wheel, >= 0) and state.brake_temp.
## This placeholder: torque proportional to the pedal with a fixed front bias, no temperature.

func setup(_spec: CarSpec) -> void:
	pass

func reset(_state: SimState, _spec: CarSpec) -> void:
	pass

func step(state: SimState, spec: CarSpec, _dt: float) -> void:
	# In reverse gear the brake pedal drives the car backwards (see SimPowertrain).
	var pedal := 0.0 if state.gear == -1 else state.brake
	if state.gear == -1:
		pedal = state.in_throttle
	var total := pedal * spec.brake_torque_max
	state.brake_torque[0] = total * spec.brake_bias_front * 0.5
	state.brake_torque[1] = state.brake_torque[0]
	state.brake_torque[2] = total * (1.0 - spec.brake_bias_front) * 0.5
	state.brake_torque[3] = state.brake_torque[2]
