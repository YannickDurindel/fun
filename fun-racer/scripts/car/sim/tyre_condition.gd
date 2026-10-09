class_name SimTyreCondition
extends RefCounted
## PLACEHOLDER tyre condition and fuel. Writes state.grip_factor, tyre_temp, tyre_wear, fuel
## and compound. Called last every tick. This placeholder: grip never changes, fuel burns with
## throttle, and state.mass follows the fuel.

func setup(_spec: CarSpec) -> void:
	pass

func reset(state: SimState, spec: CarSpec) -> void:
	state.fuel = spec.fuel_start
	state.mass = spec.mass(state.fuel)
	for i in 4:
		state.grip_factor[i] = 1.0
		state.tyre_temp[i] = 90.0
		state.tyre_wear[i] = 0.0

func step(state: SimState, spec: CarSpec, dt: float) -> void:
	state.fuel = maxf(0.0, state.fuel - spec.fuel_burn_full * state.throttle * dt)
	state.mass = spec.mass(state.fuel)
