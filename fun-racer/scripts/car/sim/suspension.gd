class_name SimSuspension
extends RefCounted
## Suspension: from each wheel's travel (state.contact, compression, compression_vel) computes
## its vertical load (state.load, N, never negative).
##
## compression = 0 is the design ride height, where the springs carry the static weight the
## car was set up with (the mass on board at reset). The loop applies each load to the body at
## the contact point, so pitch, roll and the load transfer under braking and cornering come
## out of the rigid body and these forces; nothing here computes load transfer directly.
##
## Per wheel, the load is the sum of:
##   * the static preload: the set-up weight, split by spec.weight_front;
##   * the corner spring: spring_* x its own travel;
##   * the heave (third) element of the axle: heave_* x the mean travel of the two wheels. It
##     holds the car up under downforce and braking but adds nothing in roll, and only half
##     its rate to a single-wheel bump;
##   * the anti-roll bar of the axle: arb_* x (own travel - other side's travel);
##   * the damper: separate bump and rebound rates, digressive above damper_knee_speed;
##   * the bump stop: progressive beyond travel_bump.
##
## Rates seen at one wheel (N/m): heave = spring + heave; roll = spring + 2 arb;
## one-wheel bump = spring + arb + heave / 2.
## Roll stiffness of an axle (N m/rad) = (spring + 2 arb) x track^2 / 2. The front share of
## the total (roll_split_front) is the share of the lateral load transfer the front axle
## takes: more at the front means more understeer.
##
## A wheel that would need to pull on the road (in the air, or fully extended) carries no
## load. It then hangs where its own spring, the bar and the heave element balance, and the
## other wheel of the axle is computed against that position, so the bar never hands the
## loaded wheel more than the unloaded one gave up.

const G: float = 9.81

## Static preload per wheel (N), FL, FR, RL, RR.
var _static_load: PackedFloat32Array = [0, 0, 0, 0]

func setup(spec: CarSpec) -> void:
	_set_static(spec, spec.mass(spec.fuel_start))

## The ride height is set for the mass on board now; fuel burnt or added later lets the car
## rise or sink on its springs, as on the real car.
func reset(state: SimState, spec: CarSpec) -> void:
	_set_static(spec, state.mass)

func _set_static(spec: CarSpec, mass: float) -> void:
	for i in 4:
		_static_load[i] = static_load(spec, mass, i)

## Load on wheel i (N) of a car of `mass` kg standing level.
static func static_load(spec: CarSpec, mass: float, i: int) -> float:
	var share := spec.weight_front if i < 2 else 1.0 - spec.weight_front
	return mass * G * share * 0.5

## Roll stiffness of each axle (N m/rad) and the front axle's share of the total.
static func roll_stiffness_front(spec: CarSpec) -> float:
	var track := Car.WHEEL_OFFSETS[1].x - Car.WHEEL_OFFSETS[0].x
	return (spec.spring_front + 2.0 * spec.arb_front) * track * track * 0.5

static func roll_stiffness_rear(spec: CarSpec) -> float:
	var track := Car.WHEEL_OFFSETS[3].x - Car.WHEEL_OFFSETS[2].x
	return (spec.spring_rear + 2.0 * spec.arb_rear) * track * track * 0.5

static func roll_split_front(spec: CarSpec) -> float:
	var front := roll_stiffness_front(spec)
	return front / maxf(front + roll_stiffness_rear(spec), 1.0)

## Called every tick after the wheel raycasts.
func step(state: SimState, spec: CarSpec, _dt: float) -> void:
	_axle(state, spec, 0, 1, spec.spring_front, spec.heave_front, spec.arb_front,
			spec.damper_front, spec.damper_rebound_front)
	_axle(state, spec, 2, 3, spec.spring_rear, spec.heave_rear, spec.arb_rear,
			spec.damper_rear, spec.damper_rebound_rear)

func _axle(state: SimState, spec: CarSpec, l: int, r: int, k: float, k_heave: float,
		k_arb: float, c_bump: float, c_rebound: float) -> void:
	var on_l := state.contact[l]
	var on_r := state.contact[r]
	if not on_l and not on_r:
		state.load[l] = 0.0
		state.load[r] = 0.0
		return
	var rest_l := _static_load[l]
	var rest_r := _static_load[r]
	var xl := state.compression[l]
	var xr := state.compression[r]
	# A wheel in the air hangs where its elastic force is zero, given the other wheel.
	if not on_l:
		xl = _free_travel(spec, rest_l, xr, k, k_heave, k_arb)
	elif not on_r:
		xr = _free_travel(spec, rest_r, xl, k, k_heave, k_arb)
	var fl := 0.0
	var fr := 0.0
	if on_l:
		fl = _elastic(spec, rest_l, xl, xr, k, k_heave, k_arb) + _damper(state.compression_vel[l], c_bump, c_rebound, spec)
	if on_r:
		fr = _elastic(spec, rest_r, xr, xl, k, k_heave, k_arb) + _damper(state.compression_vel[r], c_bump, c_rebound, spec)
	# A touching wheel that would have to pull carries nothing. If its springs alone would
	# pull, it has really left the road and sits higher, at its free travel; the other wheel
	# is then worked out against that.
	if on_l and on_r:
		if fl <= 0.0 and fr > 0.0:
			xl = maxf(xl, _free_travel(spec, rest_l, xr, k, k_heave, k_arb))
			fr = _elastic(spec, rest_r, xr, xl, k, k_heave, k_arb) + _damper(state.compression_vel[r], c_bump, c_rebound, spec)
		elif fr <= 0.0 and fl > 0.0:
			xr = maxf(xr, _free_travel(spec, rest_r, xl, k, k_heave, k_arb))
			fl = _elastic(spec, rest_l, xl, xr, k, k_heave, k_arb) + _damper(state.compression_vel[l], c_bump, c_rebound, spec)
	state.load[l] = maxf(fl, 0.0)
	state.load[r] = maxf(fr, 0.0)

## Spring, heave element, anti-roll bar and bump stop force on a wheel at travel x, with the
## other wheel of its axle at x_other (N; negative = the wheel would have to pull).
static func _elastic(spec: CarSpec, rest: float, x: float, x_other: float, k: float,
		k_heave: float, k_arb: float) -> float:
	var f := rest + k * x + k_arb * (x - x_other) + k_heave * 0.5 * (x + x_other)
	var over := x - spec.travel_bump
	if over > 0.0:
		f += spec.bump_stop_rate * over * (1.0 + over / maxf(spec.bump_stop_progression, 1e-4))
	return f

## Travel at which an unloaded wheel hangs (its elastic force is zero), given the other
## wheel's travel; never beyond full droop.
static func _free_travel(spec: CarSpec, rest: float, x_other: float, k: float, k_heave: float,
		k_arb: float) -> float:
	var x := ((k_arb - 0.5 * k_heave) * x_other - rest) / maxf(k + k_arb + 0.5 * k_heave, 1.0)
	return clampf(x, -spec.travel_droop, spec.travel_bump)

## Damper force (N, + = resists compression) at travel speed v (m/s, + = compressing).
## Linear up to the knee speed, then a lower slope (digressive), so a kerb strike is not
## passed to the body at the low-speed rate that controls pitch and roll.
static func _damper(v: float, c_bump: float, c_rebound: float, spec: CarSpec) -> float:
	var c := c_bump if v > 0.0 else c_rebound
	var speed := absf(v)
	var knee := spec.damper_knee_speed
	if speed > knee:
		speed = knee + (speed - knee) * spec.damper_high_speed_ratio
	return c * speed * signf(v)
