extends RefCounted
## What a simulation tyre is doing, read from the Car contract (WheelState.slip_ratio,
## slip_angle, locked, load, contact) and reduced to what the effects and the screech need.
## Three causes, each 0..1:
##   spin  - a driven wheel turning faster than the road (slip_ratio well above the tyre's peak);
##   lock  - a braked wheel stopped or nearly stopped (locked, or slip_ratio towards -1);
##   slide - the tyre moving sideways (slip_angle well beyond the peak).
## The thresholds are multiples of the tyre's own peak slip (from the car's spec), clear of
## where traction control and ABS hold the tyre: a car driven on its aids at the limit leaves
## nothing, an overshoot leaves a light mark, and a real mistake leaves a black one and smoke.
## Arcade cars publish none of these fields; callers keep their own arcade path.

## Wheelspin and lock-up thresholds as multiples of the tyre's peak slip ratio.
const SPIN_FROM_PEAKS: float = 1.7
const SPIN_FULL_PEAKS: float = 5.0
const LOCK_FROM_PEAKS: float = 2.8
const LOCK_FULL_PEAKS: float = 7.8
## Slide thresholds as multiples of the tyre's peak slip angle.
const SLIDE_FROM_PEAKS: float = 1.4
const SLIDE_FULL_PEAKS: float = 3.0
const DEFAULT_PEAK_RATIO: float = 0.09
const DEFAULT_PEAK_ANGLE: float = 0.14
## Load (N) at which a tyre marks at full strength; lighter tyres mark less.
const FULL_LOAD: float = 3000.0
## Slip ratio is published against at least this road speed (m/s).
const MIN_ROAD_SPEED: float = SimHandling.MIN_SLIP_SPEED_LONG
## Rolling backwards faster than this (m/s), or in reverse gear, the slip ratio's sign flips.
const REVERSE_SPEED: float = 1.0
## Patch sliding speed (m/s) where marks start / reach full strength.
const MARK_SPEED_FROM: float = 0.5
const MARK_SPEED_FULL: float = 2.0

static func peak_angle(car: Car) -> float:
	if car.sim != null and car.sim.spec != null:
		return maxf(car.sim.spec.tyre_peak_slip_angle, 0.02)
	return DEFAULT_PEAK_ANGLE

static func peak_ratio(car: Car) -> float:
	if car.sim != null and car.sim.spec != null:
		return maxf(car.sim.spec.tyre_peak_slip_ratio, 0.02)
	return DEFAULT_PEAK_RATIO

static func is_driven(i: int) -> bool:
	return i >= 2

## Slip ratio of wheel i in the car's direction of travel: + = the wheel drives harder than the
## road moves (wheelspin), - = it turns slower (towards a lock-up), also when reversing, where
## the published ratio has the opposite sign.
static func travel_ratio(car: Car, i: int) -> float:
	var reversing := car.gear < 0 or car.forward_speed < -REVERSE_SPEED
	return -car.wheels[i].slip_ratio if reversing else car.wheels[i].slip_ratio

static func spin(car: Car, i: int) -> float:
	if not is_driven(i):
		return 0.0
	var peak := peak_ratio(car)
	return smoothstep(peak * SPIN_FROM_PEAKS, peak * SPIN_FULL_PEAKS, travel_ratio(car, i))

static func lock(car: Car, i: int) -> float:
	if car.wheels[i].locked:
		return 1.0
	var peak := peak_ratio(car)
	return smoothstep(peak * LOCK_FROM_PEAKS, peak * LOCK_FULL_PEAKS, -travel_ratio(car, i))

static func slide(w: WheelState, peak: float) -> float:
	return smoothstep(peak * SLIDE_FROM_PEAKS, peak * SLIDE_FULL_PEAKS, absf(w.slip_angle))

## Speed (m/s) at which the contact patch rubs over the road.
static func sliding_speed(car: Car, i: int) -> float:
	var w := car.wheels[i]
	var v := absf(car.speed_kmh) / Car.KMH
	var along := v if w.locked else minf(absf(w.slip_ratio), 8.0) * maxf(v, MIN_ROAD_SPEED)
	var across := absf(sin(w.slip_angle)) * v
	return sqrt(along * along + across * across)

## True when the lock-up is the main reason wheel i is sliding.
static func lock_dominant(car: Car, i: int) -> bool:
	var w := car.wheels[i]
	var l := lock(car, i)
	return l > 0.0 and l >= slide(w, peak_angle(car))

## 0..1: how hard wheel i is marking the road (0 in the air, unloaded, or gripping).
static func strength(car: Car, i: int) -> float:
	var w := car.wheels[i]
	if not w.contact or w.load <= 0.0:
		return 0.0
	var k := maxf(maxf(spin(car, i), lock(car, i)), slide(w, peak_angle(car)))
	if k <= 0.0:
		return 0.0
	var loaded := sqrt(clampf(w.load / FULL_LOAD, 0.0, 1.0))
	return k * loaded * smoothstep(MARK_SPEED_FROM, MARK_SPEED_FULL, sliding_speed(car, i))
