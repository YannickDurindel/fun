class_name SimAero
extends RefCounted
## PLACEHOLDER aerodynamics. Writes state.downforce_front, downforce_rear, drag (N) and
## state.drs_open. This placeholder: constant coefficients, DRS follows the request directly,
## no ride-height sensitivity, no tow.

func setup(_spec: CarSpec) -> void:
	pass

func reset(state: SimState, _spec: CarSpec) -> void:
	state.drs_open = false

func step(state: SimState, spec: CarSpec, _dt: float) -> void:
	state.drs_open = state.drs_request
	var q := 0.5 * spec.air_density * state.v_long * absf(state.v_long)
	q = maxf(q, 0.0)
	var down := q * spec.cl_a
	state.downforce_front = down * spec.aero_balance_front
	state.downforce_rear = down * (1.0 - spec.aero_balance_front) * (spec.drs_downforce_factor if state.drs_open else 1.0)
	state.drag = 0.5 * spec.air_density * state.speed * state.speed * spec.cd_a * (spec.drs_drag_factor if state.drs_open else 1.0)
