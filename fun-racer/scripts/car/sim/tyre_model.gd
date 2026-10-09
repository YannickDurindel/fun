class_name SimTyreModel
extends RefCounted
## Combined-slip tyre model in the "magic formula" style. forces() returns the force the road
## puts on one tyre, in the wheel's own frame: x = along the wheel (+ = pushes the car forward),
## y = to the wheel's right. A positive slip angle (patch moving right) gives a negative y force.
## Inputs come from the state: slip_ratio[i], slip_angle[i], load[i], wheel_v_long[i],
## surface_mu[i], grip_factor[i]. Every number is in the Tyres group of CarSpec.
##
## Pure slip. Per axis F = D * shape(s), with s the slip divided by the slip of the peak and
##     shape(s) = sin(C * atan(u s - E (u s - atan(u s))))
## C comes from the share of grip left when fully sliding (tyre_slide_grip_*), E is the
## curvature (tyre_curvature_*), and u (= B x peak slip) is solved in setup() so the peak sits
## exactly at s = 1, that is at tyre_peak_slip_ratio and tyre_peak_slip_angle (front / rear).
##
## Load sensitivity. D = mu * load with mu = tyre_mu * (load / reference load)^-k: the peak
## force still grows with load, but less than in proportion, so load transfer costs grip.
##
## Combined slip (similarity method). With sx and sy the two normalised slips and
## s = sqrt(sx^2 + sy^2):  Fx = Dx shape_x(s) sx / s,  Fy = -Dy shape_y(s) sy / s.
## Braking or accelerating so takes cornering force away smoothly and the reverse, and the
## result never leaves the friction ellipse (Fx / Dx)^2 + (Fy / Dy)^2 <= 1.
##
## Relaxation length. The slip angle the tyre feels follows the kinematic one by a first-order
## lag over the distance rolled (tyre_relaxation_length). The lag fades out at low speed, where
## it would only make the car weave.
##
## Low speed. The loop computes slip against a minimum speed, which makes the tyre a damper
## (force per sliding speed) near a standstill. Two things keep a stopped car quiet:
##   * the damper is capped in proportion to the load (tyre_low_speed_damping_*), since the
##     body is integrated explicitly and a stiffer one would oscillate. With the F1 values the
##     cap only acts below about 5 m/s, where it moves the peak to a larger slip;
##     long_stiffness() includes it;
##   * a damper alone lets a parked car creep down a slope, so each tyre also has static
##     friction: the tread deflection (m) builds from the patch's sliding, is limited to the
##     deflection of the peak force, is carried away as the wheel rolls and fades out with
##     speed (tyre_stick_*).
##
## The loop does not call forces() for a wheel in the air, so the lag keeps its value through a
## jump; on landing it is rolled out again within one relaxation length (a few milliseconds).
##
## Not modelled: camber (the loop has no camber angle to give).

## Slip angles are clamped to this (rad): a wheel moving almost purely sideways, where the
## tangent is still finite.
const SLIP_ANGLE_MAX: float = 1.56

## Self-aligning moment per wheel (N m about the wheel's up axis, + = turns the wheel to the
## left, like state.steer_angle), from the last forces() call of the wheel; for steering
## feedback. Only meaningful while the wheel is loaded (state.contact).
var aligning_moment: PackedFloat32Array = [0, 0, 0, 0]

var _c_long: float = 1.4
var _u_long: float = 2.0
var _e_long: float = 0.0
var _c_lat: float = 1.3
var _u_lat: float = 2.5
var _e_lat: float = 0.0
var _peak_tan_front: float = 0.14
var _peak_tan_rear: float = 0.12
var _peak_kappa: float = 0.09
## Per wheel: mu without surface and condition, cached against the load it was computed for
## (the load is constant over the sub-steps of a tick, and pow() is not free).
var _mu_load: PackedFloat32Array = [-1, -1, -1, -1]
var _mu_base: PackedFloat32Array = [0, 0, 0, 0]
## Per wheel: lagged tangent of the slip angle, and the tread deflection (m) along and across.
var _lag: PackedFloat32Array = [0, 0, 0, 0]
var _stick_x: PackedFloat32Array = [0, 0, 0, 0]
var _stick_y: PackedFloat32Array = [0, 0, 0, 0]

## Derives the curve constants from the spec. Call again after changing tyre numbers.
func setup(spec: CarSpec) -> void:
	_c_long = _shape_factor(spec.tyre_slide_grip_long)
	_e_long = minf(spec.tyre_curvature_long, 0.95)
	_u_long = _solve_peak(_c_long, _e_long)
	_c_lat = _shape_factor(spec.tyre_slide_grip_lat)
	_e_lat = minf(spec.tyre_curvature_lat, 0.95)
	_u_lat = _solve_peak(_c_lat, _e_lat)
	_peak_tan_front = tan(clampf(spec.tyre_peak_slip_angle, 0.01, 1.0))
	_peak_tan_rear = tan(clampf(spec.tyre_peak_slip_angle_rear, 0.01, 1.0))
	_peak_kappa = maxf(spec.tyre_peak_slip_ratio, 0.005)
	for i in 4:
		_mu_load[i] = -1.0

func reset(_state: SimState, _spec: CarSpec) -> void:
	for i in 4:
		_clear(i)

func _clear(i: int) -> void:
	_lag[i] = 0.0
	_stick_x[i] = 0.0
	_stick_y[i] = 0.0
	aligning_moment[i] = 0.0

## Peak friction coefficient (lateral) for wheel i at its current load, surface and condition.
## The longitudinal peak is tyre_mu_long_scale times this.
func mu(state: SimState, spec: CarSpec, i: int) -> float:
	var fz := state.load[i]
	if fz != _mu_load[i]:
		var ref := spec.tyre_reference_load if i < 2 else spec.tyre_reference_load_rear
		var ratio := maxf(fz / maxf(ref, 1.0), maxf(spec.tyre_min_load_ratio, 0.01))
		_mu_base[i] = spec.tyre_mu * pow(ratio, -spec.tyre_load_sensitivity)
		_mu_load[i] = fz
	return _mu_base[i] * state.surface_mu[i] * state.grip_factor[i]

## Longitudinal stiffness dFx/d(slip ratio) at zero slip (N), used by the wheel integrator
## for a stable step. It is the slope of forces() itself, low-speed cap included.
func long_stiffness(state: SimState, spec: CarSpec, i: int) -> float:
	var fz := state.load[i]
	if fz <= 0.0:
		return 0.0
	var k0 := mu(state, spec, i) * spec.tyre_mu_long_scale * fz * _c_long * _u_long / _peak_kappa
	var vref := maxf(absf(state.wheel_v_long[i]), SimHandling.MIN_SLIP_SPEED_LONG)
	return minf(k0, spec.tyre_low_speed_damping_long * fz * vref)

## Pure-slip curve of one axis, as a share of its peak: slip_norm = slip / slip of the peak.
func shape_long(slip_norm: float) -> float:
	return _shape(slip_norm, _c_long, _u_long, _e_long)

func shape_lat(slip_norm: float) -> float:
	return _shape(slip_norm, _c_lat, _u_lat, _e_lat)

func forces(state: SimState, spec: CarSpec, i: int, dt: float) -> Vector2:
	var fz := state.load[i]
	if fz <= 0.0:
		_clear(i)
		return Vector2.ZERO
	var m := mu(state, spec, i)
	var dx := m * spec.tyre_mu_long_scale * fz
	var dy := m * fz
	if dx <= 0.0 or dy <= 0.0:
		_clear(i)
		return Vector2.ZERO
	var peak_tan := _peak_tan_front if i < 2 else _peak_tan_rear
	var v_roll := state.wheel_v_long[i]
	var vl := absf(v_roll)
	var vref_x := maxf(vl, SimHandling.MIN_SLIP_SPEED_LONG)
	var vref_y := maxf(vl, SimHandling.MIN_SLIP_SPEED_LAT)
	var kappa := state.slip_ratio[i]
	var tan_in := tan(clampf(state.slip_angle[i], -SLIP_ANGLE_MAX, SLIP_ANGLE_MAX))

	# Relaxation: the felt slip angle lags over distance; no lag below the fade speed.
	var w := smoothstep(spec.tyre_relaxation_fade_lo, spec.tyre_relaxation_fade_hi, vl)
	var follow := 1.0 - w * exp(-vl * dt / maxf(spec.tyre_relaxation_length, 0.001))
	var lagged := _lag[i] + (tan_in - _lag[i]) * follow
	_lag[i] = lagged

	# Normalised slips, with the stiffness capped near a standstill.
	var slope_x := _c_long * _u_long
	var slope_y := _c_lat * _u_lat
	var cap_x := minf(1.0, spec.tyre_low_speed_damping_long * fz * vref_x * _peak_kappa / (dx * slope_x))
	var cap_y := minf(1.0, spec.tyre_low_speed_damping_lat * fz * vref_y * peak_tan / (dy * slope_y))
	var sx := kappa / _peak_kappa * cap_x
	var sy := lagged / peak_tan * cap_y

	# Static friction: tread deflection from the patch's sliding, shed as the wheel rolls.
	# It only exists while the patch is nearly still: it fades with rolling and sliding speed.
	var slide_x := kappa * vref_x          # omega r - v
	var slide_y := tan_in * vref_y         # sideways speed of the patch
	var spin := absf(v_roll + slide_x)     # |omega r|
	var hold := 1.0 - maxf(maxf(vl, spin), absf(slide_y)) / maxf(spec.tyre_stick_fade_speed, 0.01)
	if hold > 0.0:
		var reach := maxf(spec.tyre_stick_length, 0.001)
		var shed := 1.0 / (1.0 + spin * dt / reach)
		var ux := clampf((_stick_x[i] + slide_x * dt) * shed, -reach, reach)
		var uy := clampf((_stick_y[i] + slide_y * dt) * shed, -reach, reach)
		_stick_x[i] = ux
		_stick_y[i] = uy
		sx += hold * ux / reach
		sy += hold * uy / reach
	else:
		_stick_x[i] = 0.0
		_stick_y[i] = 0.0

	var s := sqrt(sx * sx + sy * sy)
	if s < 1e-6:
		aligning_moment[i] = 0.0
		return Vector2(dx * slope_x * sx, -dy * slope_y * sy)
	var fx := dx * _shape(s, _c_long, _u_long, _e_long) * sx / s
	var fy := -dy * _shape(s, _c_lat, _u_lat, _e_lat) * sy / s
	# The lateral force acts behind the patch centre by the pneumatic trail, which shrinks to
	# nothing as the tyre reaches its limit.
	aligning_moment[i] = spec.tyre_pneumatic_trail * maxf(1.0 - s, 0.0) * fy
	return Vector2(fx, fy)

func _shape(s: float, c: float, u: float, e: float) -> float:
	var x := u * s
	return sin(c * atan(x - e * (x - atan(x))))

## C from the share of the peak left at endless slip: sin(C pi / 2) = slide_grip, C > 1.
func _shape_factor(slide_grip: float) -> float:
	return 2.0 - asin(clampf(slide_grip, 0.3, 0.995)) * 2.0 / PI

## u such that the curve peaks at normalised slip 1: u - E (u - atan u) = tan(pi / (2 C)).
func _solve_peak(c: float, e: float) -> float:
	var target := tan(PI / (2.0 * c))
	var lo := 0.0
	var hi := 1.0
	while hi - e * (hi - atan(hi)) < target and hi < 1.0e6:
		hi *= 2.0
	for k in 60:
		var mid := 0.5 * (lo + hi)
		if mid - e * (mid - atan(mid)) < target:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)
