class_name SimBrakes
extends RefCounted
## Carbon disc brakes. Writes state.brake_torque (N m per wheel, >= 0: the torque the caliper
## can put on the wheel) and state.brake_temp (deg C per disc).
## Reads state.brake (pedal after the aids), state.omega, state.speed, and state.gear with the
## raw pedals for the reverse rule.
##
## Pedal -> torque. The pedal goes through a slightly progressive map (CarSpec.brake_pedal_gamma)
## so an analog input has fine control near the limit. Full pedal asks for
## CarSpec.brake_torque_max in total, split front / rear by CarSpec.brake_bias_front (the share
## of the torque on the front axle, what the driver's balance dial shows). Each circuit turns
## that into a line pressure through its caliper (piston area, effective disc radius, pad
## friction), capped at CarSpec.brake_line_pressure_max, and the pressure makes the torque:
##     torque = pressure * 2 faces * piston area * disc radius * pad friction * friction(temp)
## The loop applies the torque against the wheel's rotation and stops the wheel when it exceeds
## what the tyre transmits, so a lock-up is not decided here: it happens when the pedal asks for
## more than the grip at that wheel. The system is sized for the grip a car has near 300 km/h
## with its downforce (about 5 g); at low speed full pedal is far more than the tyres hold, and
## the driver (or the anti-lock aid) must come off the pedal as the downforce bleeds away.
##
## Temperature. Each disc is one thermal mass: it heats with the power it dissipates (torque x
## wheel speed; a locked wheel dissipates nothing in the disc) and cools by forced convection
## (growing with the car's speed) and radiation. Pad friction is full in the working window,
## lower on cold discs and fades on overheated ones (see friction_factor).
##
## Hybrid harvesting. CarSpec.brake_rear_regen_share is the share of the rear axle's demand that
## the friction brakes leave to the electric motor (brake-by-wire). It only removes friction
## torque here; the power unit is expected to supply the same amount as negative drive torque.
## Nothing is read from the power unit. The default 0 means friction brakes do all the work.
##
## Reverse rule (shared with SimPowertrain): in reverse gear the brake pedal drives the car
## backwards, so the throttle pedal (raw input) is the brake.

const STEFAN_BOLTZMANN: float = 5.670374e-8   ## W / (m^2 K^4), physical constant
const KELVIN: float = 273.15
const FACES: float = 2.0                      ## a disc is clamped on both sides

## Test hook: when >= 0 this replaces state.brake (bypasses the anti-lock aid).
var pedal_override: float = -1.0
## Line pressure in each circuit this tick (Pa), for telemetry and tests. Index 0 front, 1 rear.
var line_pressure: PackedFloat32Array = [0.0, 0.0]

func setup(_spec: CarSpec) -> void:
	pass

func reset(state: SimState, spec: CarSpec) -> void:
	pedal_override = -1.0
	line_pressure[0] = 0.0
	line_pressure[1] = 0.0
	for i in 4:
		state.brake_torque[i] = 0.0
		state.brake_temp[i] = spec.brake_temp_start

## Share of full braking demand (0..1) for a pedal position (0..1). Monotonic, 0 -> 0, 1 -> 1.
static func pedal_map(spec: CarSpec, pedal: float) -> float:
	return pow(clampf(pedal, 0.0, 1.0), maxf(spec.brake_pedal_gamma, 0.1))

## Share of the brake torque on the front axle at this pedal position. With brake migration
## (CarSpec.brake_bias_migration) the balance moves forward as the pedal is released: less pedal
## goes with less downforce and a larger part of the rear grip used by engine braking.
static func front_share(spec: CarSpec, pedal: float) -> float:
	return clampf(spec.brake_bias_front + spec.brake_bias_migration * (1.0 - clampf(pedal, 0.0, 1.0)), 0.0, 1.0)

## Pad friction relative to its best, from the disc temperature (deg C): reduced below the
## working window (cold carbon), 1 inside it, fading above it.
static func friction_factor(spec: CarSpec, temp: float) -> float:
	if temp < spec.brake_temp_work_low:
		return lerpf(spec.brake_friction_cold, 1.0, smoothstep(spec.brake_temp_cold, spec.brake_temp_work_low, temp))
	if temp > spec.brake_temp_work_high:
		return lerpf(1.0, spec.brake_friction_fade, smoothstep(spec.brake_temp_work_high, spec.brake_temp_fade, temp))
	return 1.0

## Torque at one wheel per Pa of line pressure at the reference pad friction (N m / Pa).
static func wheel_gain(spec: CarSpec, front: bool) -> float:
	var area := spec.brake_piston_area_front if front else spec.brake_piston_area_rear
	var radius := spec.brake_disc_radius_front if front else spec.brake_disc_radius_rear
	return maxf(FACES * area * radius * spec.brake_pad_mu, 1e-9)

## Heat a disc loses at `temp` (deg C) with the car at `speed` (m/s), in W: forced convection
## through the ducts (smaller at the rear, which does less work) plus radiation.
static func cooling_power(spec: CarSpec, temp: float, speed: float, front: bool) -> float:
	var conv := (spec.brake_cooling_base + spec.brake_cooling_per_speed * speed) * (temp - spec.brake_temp_ambient)
	if not front:
		conv *= spec.brake_cooling_rear_factor
	var tk := temp + KELVIN
	var ak := spec.brake_temp_ambient + KELVIN
	var rad := spec.brake_emissivity * STEFAN_BOLTZMANN * spec.brake_radiation_area * (tk * tk * tk * tk - ak * ak * ak * ak)
	return conv + rad

func step(state: SimState, spec: CarSpec, dt: float) -> void:
	# In reverse gear the brake pedal drives the car backwards (see SimPowertrain), so the
	# throttle pedal is the brake.
	var pedal := state.brake
	if state.gear == -1:
		pedal = state.in_throttle
	if pedal_override >= 0.0:
		pedal = pedal_override
	pedal = clampf(pedal, 0.0, 1.0)
	var demand := pedal_map(spec, pedal) * spec.brake_torque_max
	# The balance migrates with the pressure actually applied (after the aids), as a real
	# system does. Measured on the rig this also gives the shorter aided stops: when the
	# anti-lock backs the pedal off, the rears are the wheels that need the relief.
	var share := front_share(spec, pedal)
	var gain_front := wheel_gain(spec, true)
	var gain_rear := wheel_gain(spec, false)
	# Torque asked of one wheel of each axle, then the line pressure that makes it.
	var ask_front := demand * share * 0.5
	var ask_rear := demand * (1.0 - share) * 0.5 * (1.0 - clampf(spec.brake_rear_regen_share, 0.0, 1.0))
	line_pressure[0] = minf(ask_front / gain_front, spec.brake_line_pressure_max)
	line_pressure[1] = minf(ask_rear / gain_rear, spec.brake_line_pressure_max)
	for i in 4:
		var front := i < 2
		var temp := state.brake_temp[i]
		var torque := line_pressure[0 if front else 1] * (gain_front if front else gain_rear) * friction_factor(spec, temp)
		state.brake_torque[i] = torque
		# The disc heats with what it dissipates and sheds heat to the air.
		var heat := torque * absf(state.omega[i])
		var capacity := spec.brake_heat_capacity_front if front else spec.brake_heat_capacity_rear
		temp += (heat - cooling_power(spec, temp, state.speed, front)) * dt / maxf(capacity, 1.0)
		state.brake_temp[i] = maxf(temp, spec.brake_temp_ambient)
