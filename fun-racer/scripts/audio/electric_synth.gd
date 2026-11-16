extends RefCounted
## Procedural electric-drivetrain synthesiser (the Formula E car: CarKit "sound": "electric").
##
## Same interface as engine_synth.gd (update / render / reset / master / smoothed_rpm /
## freq_hz) so engine_audio.gd can drive either one. No combustion: no firing pulses, pops,
## shift cracks or limiter stutter. What is heard instead:
##   * motor whine: the rotor's electrical order, a near-pure tone rising and falling with the
##     motor speed (with its 2nd and 3rd harmonics and a slow-beating partner for some life);
##   * inverter whine: the switching carrier of the power electronics, a high tone that steps
##     up through a few fixed pitches over the low speed range (like real traction inverters)
##     and fades as the motor whine takes over; louder under load and under regen;
##   * transmission whine: the gear-mesh order, a higher tone tied to the motor speed, loudest
##     when the drivetrain carries torque (throttle or regen braking);
##   * a little band-limited hum (rotor / casing), so it is not a pure synth.
## Tyre, wind, scrub and kerb sounds stay in engine_audio.gd's loops, as for every car.
## update() slews the state per frame, render() ramps every gain and pitch across the block.

const TABLE_SIZE: int = 4096
const NOISE_SIZE: int = 16384
const NOISE_MASK: int = NOISE_SIZE - 1
const RPM_TAU: float = 0.03           ## s; a motor has no flywheel lag to speak of
const THROTTLE_TAU: float = 0.06
const MOTOR_HZ_IDLE: float = 90.0     ## motor whine at a standstill (barely turning)...
const MOTOR_HZ_MAX: float = 1500.0    ## ...and at the top motor speed
const GEAR_RATIO: float = 2.6         ## gear-mesh order against the motor order
## Inverter carrier steps (Hz) over the bottom of the speed range, then fixed.
const CARRIER_STEPS: Array[float] = [2000.0, 2600.0, 3300.0, 4100.0]
const CARRIER_FADE_END: float = 0.45  ## normalised motor speed where the carrier has faded

var mix_rate: float
## Combustion engines report cylinders; an electric motor has none.
var cylinders: int = 0
var rpm_low: float = 0.0              ## motor speed range mapped to 0..1
var rpm_high: float = 11000.0

var smoothed_rpm: float = 0.0
var smoothed_throttle: float = 0.0
## Regen braking 0..1 (lifted off at speed): the drivetrain still carries torque.
var regen: float = 0.0
## Motor whine fundamental (Hz).
var freq_hz: float:
	get:
		return lerpf(MOTOR_HZ_IDLE, MOTOR_HZ_MAX, motor_norm())
var master: float = 1.0

static var _sine := PackedFloat32Array()
static var _noise := PackedFloat32Array()

var _pm: float = 0.0       # phases (table index units)
var _pm2: float = 0.0
var _pg: float = 0.0
var _pc: float = 0.0
var _ni: int = 0
var _inc: float = -1.0
var _cinc: float = -1.0
var _a_motor: float = 0.0
var _a_gear: float = 0.0
var _a_carrier: float = 0.0
var _a_hum: float = 0.0
var _mg: float = 1.0
var _lp: float = 0.0
var _hp: float = 0.0

func _init(rate: float = 24000.0) -> void:
	mix_rate = rate
	if _sine.is_empty():
		_sine.resize(TABLE_SIZE)
		for i in TABLE_SIZE:
			_sine[i] = sin(TAU * float(i) / TABLE_SIZE)
		var rng := RandomNumberGenerator.new()
		rng.seed = 11
		_noise.resize(NOISE_SIZE)
		for i in NOISE_SIZE:
			_noise[i] = rng.randf_range(-1.0, 1.0)

## Motor speed range (the car's idle .. top rpm) mapped onto the whine's pitch range.
func set_rev_range(low_rpm: float, high_rpm: float) -> void:
	rpm_low = 0.0 if low_rpm < 0.0 else low_rpm
	rpm_high = maxf(high_rpm, rpm_low + 1000.0)

func motor_norm() -> float:
	return clampf(smoothed_rpm / rpm_high, 0.0, 1.0)

## Inverter carrier (Hz) at normalised motor speed `m`: steps up, then holds.
static func carrier_hz(m: float) -> float:
	var n := CARRIER_STEPS.size()
	var idx := clampi(int(m / CARRIER_FADE_END * n), 0, n - 1)
	return CARRIER_STEPS[idx]

## No gearbox to cut: an electric car does not crack on shifts.
func shift_cut() -> void:
	pass

func downshift_blip() -> void:
	pass

func is_shift_cut() -> bool:
	return false

func update(dt: float, rpm: float, throttle: float, _pedal: float = -1.0) -> void:
	smoothed_rpm += (maxf(rpm, 0.0) - smoothed_rpm) * (1.0 - exp(-dt / RPM_TAU))
	var thr := clampf(throttle, 0.0, 1.0)
	smoothed_throttle += (thr - smoothed_throttle) * (1.0 - exp(-dt / THROTTLE_TAU))
	var m := motor_norm()
	var regen_t := (1.0 - smoothed_throttle) * smoothstep(0.08, 0.3, m)
	regen += (regen_t - regen) * (1.0 - exp(-dt / 0.12))

func reset(rpm: float, throttle: float) -> void:
	smoothed_rpm = maxf(rpm, 0.0)
	smoothed_throttle = clampf(throttle, 0.0, 1.0)
	regen = 0.0
	_inc = -1.0
	_cinc = -1.0

func render(frames: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if frames <= 0:
		return out
	out.resize(frames)
	var ts := float(TABLE_SIZE)
	var m := motor_norm()
	var thr := smoothed_throttle
	var torque := maxf(thr, 0.7 * regen)       # drive or regen: the gears and the inverter work
	var inc_t := freq_hz * ts / mix_rate
	var cinc_t := carrier_hz(m) * ts / mix_rate
	if _inc < 0.0:
		_inc = inc_t
	if _cinc < 0.0:
		_cinc = cinc_t
	var turning := smoothstep(0.0, 0.06, m)
	var a_motor_t := (0.10 + 0.16 * torque + 0.06 * m) * turning
	var a_gear_t := (0.015 + 0.075 * torque) * smoothstep(0.03, 0.25, m)
	var a_carrier_t := (0.02 + 0.07 * torque) * (1.0 - smoothstep(CARRIER_FADE_END * 0.6, CARRIER_FADE_END, m)) * turning
	var a_hum_t := (0.03 + 0.04 * torque) * turning
	var master_t := clampf(master, 0.0, 1.0)
	var inv := 1.0 / float(frames)
	var d_inc := (inc_t - _inc) * inv
	var d_cinc := (cinc_t - _cinc) * inv
	var d_am := (a_motor_t - _a_motor) * inv
	var d_ag := (a_gear_t - _a_gear) * inv
	var d_ac := (a_carrier_t - _a_carrier) * inv
	var d_ah := (a_hum_t - _a_hum) * inv
	var d_mg := (master_t - _mg) * inv
	var sine := _sine
	var noise := _noise
	var pm := _pm
	var pm2 := _pm2
	var pg := _pg
	var pc := _pc
	var ni := _ni
	var inc := _inc
	var cinc := _cinc
	var am := _a_motor
	var ag := _a_gear
	var ac := _a_carrier
	var ah := _a_hum
	var mg := _mg
	var lp := _lp
	var hp := _hp
	var mask := TABLE_SIZE - 1
	for i in frames:
		inc += d_inc
		cinc += d_cinc
		am += d_am
		ag += d_ag
		ac += d_ac
		ah += d_ah
		mg += d_mg
		pm = fmod(pm + inc, ts)
		pm2 = fmod(pm2 + inc * 1.004, ts)          # slow beat against the main whine
		pg = fmod(pg + inc * GEAR_RATIO, ts)
		pc = fmod(pc + cinc, ts)
		var im := int(pm)
		var motor := sine[im] + 0.35 * sine[(im * 2) & mask] + 0.15 * sine[(im * 3) & mask] \
				+ 0.3 * sine[int(pm2)]
		var gear := sine[int(pg)] + 0.25 * sine[(int(pg) * 2) & mask]
		# The carrier is PWM: a tone with a little jitter in its level.
		var nz := noise[ni]
		ni = (ni + 1) & NOISE_MASK
		var carrier := sine[int(pc)] * (1.0 + 0.25 * nz)
		lp += 0.08 * (nz - lp)                       # low hum: low-passed noise
		hp += 0.5 * (lp - hp)
		var y := (motor * am / 1.8 + gear * ag + carrier * ac + hp * ah * 6.0) * mg
		if y > 1.2:
			y = 1.2
		elif y < -1.2:
			y = -1.2
		y -= 0.15 * y * y * y
		out[i] = Vector2(y, y)
	_pm = pm
	_pm2 = pm2
	_pg = pg
	_pc = pc
	_ni = ni
	_inc = inc_t
	_cinc = cinc_t
	_a_motor = a_motor_t
	_a_gear = a_gear_t
	_a_carrier = a_carrier_t
	_a_hum = a_hum_t
	_mg = master_t
	_lp = lp
	_hp = hp
	return out
