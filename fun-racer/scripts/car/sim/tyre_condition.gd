class_name SimTyreCondition
extends RefCounted
## Tyre temperature, wear, flat spots, compounds and fuel. Called last every tick.
## Writes state.grip_factor, tyre_temp, tyre_wear, fuel, mass and compound.
##
## Temperature: two thermal masses per tyre. The SURFACE (tread) is heated by the frictional
## power of the contact patch (sliding force x sliding speed) and cooled by the air (more with
## speed) and by conduction into the road; it reacts in seconds. The CORE (carcass) is heated by
## flexing (load x speed, the rolling resistance) and exchanges heat with the surface; it
## reacts over tens of seconds. state.tyre_temp is a weighted mean of the two and is what the
## grip depends on.
##
## Grip: state.grip_factor = compound grip (at the track wetness) x temperature factor (1 at
## the centre of the compound's window, falling with the square of the distance, never below
## spec.tyre_temp_grip_floor) x wear factor (a slow linear loss, then the cliff) x flat spot.
##
## Wear grows with the sliding energy and faster above the window. A wheel locked while moving
## also wears by the metre and leaves a flat spot: a permanent grip loss on that tyre.
##
## Fuel burns with throttle and rpm up to the flow limit; state.mass follows.
##
## spec.wear_rate_scale and spec.fuel_burn_scale speed both up for short races.
## All numbers are in CarSpec ("Tyre condition", "Fuel") and SimTyreCompounds.

## 0 dry .. 1 standing water. There is no rain in the game yet: whoever adds it sets this.
var track_wetness: float = 0.0

## What reset() does. SimHandling resets its parts on every Car.respawn(), which is both the
## start of a run and a mid-race return to the track. False (default): reset() is a new run,
## with the starting fuel and a new set. The race sets it true once the start is taken, so a
## respawn keeps the fuel, the wear, the flat spots and the temperatures; new_stint() and
## set_compound() still fit new tyres.
var keep_on_reset: bool = false

## Read-only telemetry, per wheel (FL, FR, RL, RR).
var surface_temp: PackedFloat32Array = [70, 70, 70, 70]   ## deg C, tread
var core_temp: PackedFloat32Array = [70, 70, 70, 70]      ## deg C, carcass
var flat_spot: PackedFloat32Array = [0, 0, 0, 0]          ## 0 none .. 1 worst
var vibration: PackedFloat32Array = [0, 0, 0, 0]          ## 0..1 amplitude from the flat spot, for effects
var slide_power: PackedFloat32Array = [0, 0, 0, 0]        ## W dissipated in the contact patch this tick
var slide_energy: PackedFloat64Array = [0, 0, 0, 0]       ## J dissipated since the set was fitted
var fuel_used: float = 0.0                                ## kg burnt since reset

# The active compound's row, copied so step() reads no dictionary.
var _grip_dry: float = 1.0
var _grip_damp: float = 0.68
var _grip_wet: float = 0.4
var _temp_low: float = 88.0
var _temp_high: float = 118.0
var _wear_rate: float = 1.0
var _heat: float = 1.0
var _blanket: float = 70.0
var _compound_grip: float = 1.0   # the compound's grip at the current track wetness
var _fitted: bool = false
# Wear in double precision: one tick adds about 1e-7, which a 32-bit float near 1 would lose.
var _wear: PackedFloat64Array = [0, 0, 0, 0]

func setup(_spec: CarSpec) -> void:
	pass

## A new run (see keep_on_reset): the starting fuel and a new set of the current compound.
func reset(state: SimState, spec: CarSpec) -> void:
	if keep_on_reset and _fitted:
		state.mass = spec.mass(state.fuel)
		return
	new_stint(state, spec)

## Full starting fuel and a new set of the current compound out of the blankets.
func new_stint(state: SimState, spec: CarSpec) -> void:
	state.fuel = clampf(spec.fuel_start, 0.0, spec.fuel_capacity)
	state.mass = spec.mass(state.fuel)
	fuel_used = 0.0
	var compound := state.compound if SimTyreCompounds.has(state.compound) else SimTyreCompounds.DEFAULT
	set_compound(state, spec, compound)

## Fits a new set of `compound` (soft, medium, hard, intermediate, wet): blanket temperature,
## no wear, no flat spots. Returns false and changes nothing for an unknown name.
func set_compound(state: SimState, spec: CarSpec, compound: StringName) -> bool:
	if not SimTyreCompounds.has(compound):
		return false
	var r := SimTyreCompounds.row(compound)
	_grip_dry = r["grip_dry"]
	_grip_damp = r["grip_damp"]
	_grip_wet = r["grip_wet"]
	_temp_low = r["temp_low"]
	_temp_high = r["temp_high"]
	_wear_rate = r["wear"]
	_heat = r["heat"]
	_blanket = r["blanket"]
	state.compound = compound
	_fitted = true
	_compound_grip = SimTyreCompounds.grip_between(_grip_dry, _grip_damp, _grip_wet, track_wetness)
	for i in 4:
		surface_temp[i] = _blanket
		core_temp[i] = _blanket
		flat_spot[i] = 0.0
		vibration[i] = 0.0
		slide_power[i] = 0.0
		slide_energy[i] = 0.0
		_wear[i] = 0.0
		state.tyre_temp[i] = _blanket
		state.tyre_wear[i] = 0.0
		state.grip_factor[i] = _grip(state, spec, i)
	return true

## Sets the fuel on board (kg, clamped to the tank) and the mass with it.
func set_fuel(state: SimState, spec: CarSpec, kg: float) -> void:
	state.fuel = clampf(kg, 0.0, spec.fuel_capacity)
	state.mass = spec.mass(state.fuel)

## Grip multiplier from temperature alone for the active compound: 1 at the centre of the
## window, spec.tyre_temp_grip_floor at worst.
func temp_factor(spec: CarSpec, temp: float) -> float:
	var half := maxf((_temp_high - _temp_low) * 0.5, 1.0)
	var x := (temp - (_temp_low + _temp_high) * 0.5) / half
	var loss := (spec.tyre_cold_grip_loss if x < 0.0 else spec.tyre_hot_grip_loss) * x * x
	return maxf(1.0 - loss, spec.tyre_temp_grip_floor)

## Grip multiplier from wear alone: a slow linear loss up to the cliff, then a steep drop.
func wear_factor(spec: CarSpec, wear: float) -> float:
	var w := clampf(wear, 0.0, 1.0)
	var cliff := clampf(spec.tyre_wear_cliff, 0.05, 0.99)
	if w <= cliff:
		return 1.0 - spec.tyre_wear_grip_loss * w / cliff
	var over := (w - cliff) / (1.0 - cliff)
	return 1.0 - spec.tyre_wear_grip_loss - spec.tyre_cliff_grip_loss * over * over

## Fuel flow (kg/s) at this throttle and rpm, before spec.fuel_burn_scale.
func fuel_flow(spec: CarSpec, throttle: float, rpm: float) -> float:
	var revs := clampf(rpm / maxf(spec.fuel_flow_rpm, 1.0), 0.0, 1.0)
	var demand := clampf(throttle, 0.0, 1.0) * revs
	return spec.fuel_burn_full * (spec.fuel_idle_fraction + (1.0 - spec.fuel_idle_fraction) * demand)

func _grip(state: SimState, spec: CarSpec, i: int) -> float:
	var condition := temp_factor(spec, state.tyre_temp[i]) * wear_factor(spec, state.tyre_wear[i]) \
			* (1.0 - spec.tyre_flat_grip_loss * flat_spot[i])
	return _compound_grip * maxf(condition, spec.tyre_condition_grip_floor)

func step(state: SimState, spec: CarSpec, dt: float) -> void:
	# ---- fuel
	if state.fuel > 0.0:
		# In reverse the brake pedal is the accelerator (see SimPowertrain).
		var demand := state.in_brake if state.gear == -1 else state.throttle
		var burn := minf(fuel_flow(spec, demand, state.rpm) * spec.fuel_burn_scale * dt, state.fuel)
		state.fuel -= burn
		fuel_used += burn
	state.mass = spec.mass(state.fuel)

	# ---- tyres
	var wet := clampf(track_wetness, 0.0, 1.0)
	_compound_grip = SimTyreCompounds.grip_between(_grip_dry, _grip_damp, _grip_wet, wet)
	var half := maxf((_temp_high - _temp_low) * 0.5, 1.0)
	var air_surface := spec.tyre_air_cooling_base + spec.tyre_air_cooling_per_speed * state.speed
	var air_core := spec.tyre_core_cooling_base + spec.tyre_core_cooling_per_speed * state.speed
	var road := spec.tyre_road_conductance * (1.0 + spec.tyre_wet_cooling * wet)
	var road_temp := lerpf(spec.tyre_track_temp, spec.tyre_ambient_temp, wet)
	for i in 4:
		var on_road := state.contact[i] and state.load[i] > 0.0
		var v_long := absf(state.wheel_v_long[i])
		var p_slide := 0.0
		var p_flex := 0.0
		if on_road:
			# Sliding velocity of the patch: along the wheel it is omega R - v, which is the slip
			# ratio times the speed it was computed against; across the wheel it is v_lat.
			var slide_long := state.slip_ratio[i] * maxf(v_long, SimHandling.MIN_SLIP_SPEED_LONG)
			p_slide = absf(state.tyre_fx[i] * slide_long) + absf(state.tyre_fy[i] * state.wheel_v_lat[i])
			if not is_finite(p_slide):
				p_slide = 0.0
			p_slide = minf(p_slide, spec.tyre_slide_power_max)
			p_flex = spec.tyre_flex_heat_coeff * state.load[i] * v_long
		slide_power[i] = p_slide
		slide_energy[i] += p_slide * dt

		# Temperatures (explicit Euler: the rates are a fraction of 1/s, far below the tick rate).
		var ts := surface_temp[i]
		var tc := core_temp[i]
		var q_surface := spec.tyre_friction_heat_share * _heat * p_slide \
				- air_surface * (ts - spec.tyre_ambient_temp) \
				- spec.tyre_surface_core_conductance * (ts - tc)
		if on_road:
			q_surface -= road * (ts - road_temp)
		var q_core := _heat * p_flex + spec.tyre_surface_core_conductance * (ts - tc) \
				- air_core * (tc - spec.tyre_ambient_temp)
		ts = clampf(ts + q_surface / spec.tyre_surface_heat_capacity * dt, spec.tyre_temp_min, spec.tyre_temp_max)
		tc = clampf(tc + q_core / spec.tyre_core_heat_capacity * dt, spec.tyre_temp_min, spec.tyre_temp_max)
		surface_temp[i] = ts
		core_temp[i] = tc
		var temp := lerpf(tc, ts, spec.tyre_temp_surface_weight)
		state.tyre_temp[i] = temp

		# Wear: sliding energy, more above the window; a locked wheel also wears by the metre.
		var hot := maxf(temp - _temp_high, 0.0) / half
		var wear := spec.tyre_wear_per_joule * p_slide * (1.0 + spec.tyre_wear_hot_gain * hot)
		# The patch of a locked wheel slides at its full speed over the road, sideways included.
		var patch_speed := sqrt(v_long * v_long + state.wheel_v_lat[i] * state.wheel_v_lat[i])
		if on_road and state.locked[i] and patch_speed > spec.tyre_lock_min_speed:
			var load_ratio := state.load[i] / spec.tyre_reference_load
			wear += spec.tyre_lock_wear_per_metre * patch_speed * load_ratio
			flat_spot[i] = minf(flat_spot[i] + spec.tyre_flat_per_metre * patch_speed * load_ratio * dt, 1.0)
		_wear[i] = minf(_wear[i] + wear * _wear_rate * spec.wear_rate_scale * dt, 1.0)
		state.tyre_wear[i] = _wear[i]
		vibration[i] = flat_spot[i] * minf(state.speed / spec.tyre_flat_vibration_speed, 1.0)

		state.grip_factor[i] = _grip(state, spec, i)
