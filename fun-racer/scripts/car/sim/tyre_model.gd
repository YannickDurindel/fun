class_name SimTyreModel
extends RefCounted
## PLACEHOLDER tyre. forces() returns the force the road puts on one tyre, in the wheel's own
## frame: x = along the wheel (+ = pushes the car forward), y = to the wheel's right.
## Inputs come from the state: slip_ratio[i], slip_angle[i], load[i], surface_mu[i],
## grip_factor[i]. A positive slip angle (patch moving right) gives a negative y force.
## This placeholder: linear up to the peak slip then flat, a friction circle for combined slip,
## linear load sensitivity. No relaxation, no camber, no shape after the peak.

func setup(_spec: CarSpec) -> void:
	pass

func reset(_state: SimState, _spec: CarSpec) -> void:
	pass

## Peak friction coefficient for wheel i at its current load, surface and condition.
func mu(state: SimState, spec: CarSpec, i: int) -> float:
	var over := maxf(state.load[i] / spec.tyre_reference_load - 1.0, -0.5)
	return spec.tyre_mu * maxf(1.0 - spec.tyre_load_sensitivity * over, 0.4) * state.surface_mu[i] * state.grip_factor[i]

## Longitudinal stiffness dFx/d(slip ratio) at zero slip (N), used by the wheel integrator
## for a stable step. Must be consistent with forces().
func long_stiffness(state: SimState, spec: CarSpec, i: int) -> float:
	return mu(state, spec, i) * state.load[i] / spec.tyre_peak_slip_ratio

func forces(state: SimState, spec: CarSpec, i: int, _dt: float) -> Vector2:
	var fz := state.load[i]
	if fz <= 0.0:
		return Vector2.ZERO
	var m := mu(state, spec, i)
	var sx := state.slip_ratio[i] / spec.tyre_peak_slip_ratio
	var sy := tan(state.slip_angle[i]) / tan(spec.tyre_peak_slip_angle)
	var s := sqrt(sx * sx + sy * sy)
	if s < 1e-6:
		return Vector2.ZERO
	var f := m * fz * minf(s, 1.0)
	return Vector2(f * sx / s, -f * sy / s)
