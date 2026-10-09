class_name SimSuspension
extends RefCounted
## PLACEHOLDER suspension. From each wheel's travel (state.compression, compression_vel,
## contact) computes its vertical load (state.load, N, never negative).
## compression = 0 is the design ride height, where the springs carry the static weight.
## This placeholder is one spring-damper per wheel with a bump stop and no anti-roll bars.

var _static_load: PackedFloat32Array = [0, 0, 0, 0]

func setup(_spec: CarSpec) -> void:
	pass

func reset(_state: SimState, _spec: CarSpec) -> void:
	pass

## Called every tick after the wheel raycasts.
func step(state: SimState, spec: CarSpec, _dt: float) -> void:
	var weight := state.mass * 9.81
	_static_load[0] = weight * spec.weight_front * 0.5
	_static_load[1] = _static_load[0]
	_static_load[2] = weight * (1.0 - spec.weight_front) * 0.5
	_static_load[3] = _static_load[2]
	for i in 4:
		if not state.contact[i]:
			state.load[i] = 0.0
			continue
		var k := spec.spring_front if i < 2 else spec.spring_rear
		var c := spec.damper_front if i < 2 else spec.damper_rear
		var x := state.compression[i]
		var f := _static_load[i] + k * x + c * state.compression_vel[i]
		if x > spec.travel_bump:
			f += spec.bump_stop_rate * (x - spec.travel_bump)
		state.load[i] = maxf(f, 0.0)
