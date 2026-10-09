extends RefCounted
## Procedural racing-engine synthesiser (a V12 "screamer" in the spirit of the Stadium car).
##
## Wavetable based so the per-sample GDScript loop stays cheap:
##   * main oscillator at the firing frequency f = rpm/60 * cylinders/2, crossfading between a
##     dark table (steep harmonic roll-off) and a bright table (flat roll-off): throttle acts like
##     opening a filter;
##   * a slightly detuned second oscillator (beating / chorus, gives the synthetic whine);
##   * a half-order sub oscillator that is louder when coasting (burble);
##   * pulse-gated noise synchronised to the firing phase (grit);
##   * on the overrun, per-firing-cycle random gain and occasional crackle pops;
##   * one-pole tone filter + cubic soft clip.
## Call update(dt, rpm, throttle) once per frame (parameter slew), then render(frames). render()
## ramps every parameter linearly across the block and keeps oscillator phase between blocks, so
## there are no clicks or zipper noise. Used by engine_audio.gd and by render_engine_wav.gd.
## Designed for mix rates of 22050..48000 Hz (BRIGHT_HARMONICS keeps the bright table below
## Nyquist at 22.05 kHz for f <= 1.1 kHz); time constants are derived from the rate.
##
## Two characters share the render loop; the numbers below the "character" heading pick one:
##   * use_v12(): the arcade car's screamer, exactly as before (the defaults);
##   * use_v6_turbo(idle, limit): the simulation car's turbo-hybrid V6. Six cylinders, so the
##     firing frequency is rpm/60 * 3: an octave lower. Darker (the turbine muffles the
##     exhaust), more half-order rumble and grit, and on top of the engine:
##       - a turbo whistle whose pitch and level follow the boost (throttle x revs, with lag),
##         and a short hiss as the boost is dumped on lift-off;
##       - shift_cut(): the ignition cut of an upshift, a short hole then a crack;
##       - a burst of overrun crackle right after the throttle closes;
##       - a stutter on the rev limiter (firing cycles dropped in groups).

const TABLE_SIZE: int = 4096
const NOISE_SIZE: int = 16384
const NOISE_MASK: int = NOISE_SIZE - 1
const DETUNE: float = 1.0065          ## second oscillator ratio (~6 Hz beat at 1 kHz)
const BRIGHT_HARMONICS: int = 9       ## 9 * 1.15 kHz < 11.03 kHz Nyquist at 22.05 kHz
const DARK_HARMONICS: int = 6
const IDLE_RPM: float = 2500.0
const RPM_TAU_UP: float = 0.035       ## s; quick but not instant rev-up
const RPM_TAU_DOWN: float = 0.022     ## s; upshift drop is fast (~60 ms to settle)
const THROTTLE_TAU: float = 0.05

const SHIFT_CUT_TIME: float = 0.045   ## s of ignition cut on an upshift
const SHIFT_CUT_GAIN: float = 0.22    ## engine level during the cut
const SHIFT_CRACK_AMP: float = 0.42   ## noise burst as the ignition comes back
const BOOST_TAU_UP: float = 0.28      ## s, turbo spooling up
const BOOST_TAU_DOWN: float = 0.10    ## s, boost dumped
const WHISTLE_HZ_LOW: float = 2600.0  ## whistle pitch with no boost...
const WHISTLE_HZ_HIGH: float = 6400.0 ## ...and at full boost
const LIFT_TAU: float = 0.45          ## s, how long the lift-off crackle lasts
const LIMITER_BAND_RPM: float = 150.0 ## the limiter cuts within this of the limit
const LIMITER_PERIOD: int = 20        ## firing cycles per stutter (about 30 Hz at 13000 rpm)
const LIMITER_CUT_CYCLES: int = 9     ## ...of which this many are cut

var mix_rate: float
var cylinders: int = 12

# ---- character (defaults = the V12; see use_v6_turbo)
var rpm_floor: float = IDLE_RPM       ## the engine never sounds slower than this
var rpm_norm_low: float = 3000.0      ## rev range mapped to 0..1 for level and brightness
var rpm_norm_span: float = 8000.0
var limiter_rpm: float = INF          ## rev limit; INF = no limiter stutter
var amp_base: float = 0.26
var amp_throttle: float = 0.20
var amp_rpm: float = 0.06
var blend_base: float = 0.12          ## dark-to-bright morph: at rest...
var blend_throttle: float = 0.88      ## ...and what full throttle adds
var detune_mix: float = 0.6           ## level of the detuned partner (the whine)
var sub_base: float = 0.05            ## half-order rumble...
var sub_coast: float = 0.13           ## ...and what coasting adds
var grit_base: float = 0.035
var grit_throttle: float = 0.05
var filter_base: float = 0.35         ## one-pole tone filter coefficient at rest...
var filter_throttle: float = 0.6      ## ...and what full throttle adds
var burble_depth: float = 0.55        ## per-cycle gain wobble on the overrun
var pop_rate: float = 0.025           ## chance of a pop per firing cycle on the overrun
var pop_amp: float = 0.22
var lift_pop_boost: float = 0.0       ## extra pops right after lifting off (x pop_rate)
var whistle_amp: float = 0.0          ## turbo whistle level at full boost; 0 = no turbo
var blowoff_amp: float = 0.0          ## hiss as the boost is dumped

## Smoothed state (read-only for callers).
var smoothed_rpm: float = IDLE_RPM
var smoothed_throttle: float = 0.0
var freq_hz: float:
	get:
		return smoothed_rpm / 60.0 * float(cylinders) * 0.5
## Master gain target (0..1); ramped per block.
var master: float = 1.0

# Shared, immutable tables (built once per process, not per instance).
static var _bright := PackedFloat32Array()
static var _dark := PackedFloat32Array()
static var _pulse := PackedFloat32Array()
static var _sub := PackedFloat32Array()
static var _noise := PackedFloat32Array()
static var _sine := PackedFloat32Array()

# Per-sample coefficients derived from mix_rate.
var _pop_decay: float
var _cyc_coef: float

# Oscillator and per-block ramp state.
var _p1: float = 0.0
var _p2: float = 0.0
var _ps: float = 0.0
var _ni: int = 0
var _inc: float = -1.0
var _amp: float = 0.0
var _blend: float = 0.0
var _master_ramp: float = 1.0
var _sub_amp: float = 0.0
var _grit: float = 0.0
var _cyc_gain: float = 1.0
var _cyc_target: float = 1.0
var _pop_env: float = 0.0
var _lp: float = 0.0
# Turbo, shift cut, lift-off and limiter state (idle for the V12).
var _boost: float = 0.0
var _pw: float = 0.0
var _winc: float = 0.0
var _wamp: float = 0.0
var _blow: float = 0.0
var _blow_decay: float
var _cut_frames: int = 0   ## samples of ignition cut left (timed by the audio, not by frames)
var _smoothed_pedal: float = 0.0
var _crack_pending: bool = false
var _lift: float = 0.0
var _cycle: int = 0

func _init(rate: float = 24000.0, cyl: int = 12) -> void:
	mix_rate = rate
	cylinders = cyl
	_pop_decay = exp(-1.0 / (0.022 * rate))  # overrun pop decay, ~22 ms
	_cyc_coef = 1.0 - exp(-1.0 / (0.0013 * rate))  # per-cycle gain glide, ~1.3 ms
	_blow_decay = exp(-1.0 / (0.09 * rate))  # blow-off hiss, ~90 ms
	if _noise.is_empty():
		_build_tables()

static func _build_tables() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var phases: Array[float] = []
	for k in BRIGHT_HARMONICS + 1:
		phases.append(rng.randf() * TAU)
	_bright = _additive(BRIGHT_HARMONICS, 0.8, phases, true)
	_dark = _additive(DARK_HARMONICS, 2.1, phases, false)
	_pulse.resize(TABLE_SIZE)
	_sub.resize(TABLE_SIZE)
	_sine.resize(TABLE_SIZE)
	for i in TABLE_SIZE:
		var x := float(i) / TABLE_SIZE
		_sine[i] = sin(TAU * x)
		# Narrow pulse near the start of each firing cycle (exhaust "bark").
		var d := minf(absf(x - 0.08), 1.0 - absf(x - 0.08))
		_pulse[i] = exp(-(d * d) / (2.0 * 0.06 * 0.06))
		_sub[i] = (sin(TAU * x) + 0.35 * sin(3.0 * TAU * x + 0.6)) / 1.25
	_noise.resize(NOISE_SIZE)
	for i in NOISE_SIZE:
		_noise[i] = rng.randf_range(-1.0, 1.0)

## Sum of harmonics k^-rolloff with fixed pseudo-random phases, normalised to peak 1.
## `formant` adds a bump on harmonics 3..6 for the nasal racing-engine scream.
static func _additive(count: int, rolloff: float, phases: Array[float], formant: bool) -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(TABLE_SIZE)
	var amps: Array[float] = []
	for k in range(1, count + 1):
		var a := pow(float(k), -rolloff)
		if formant and k >= 3 and k <= 6:
			a *= 1.6
		amps.append(a)
	var peak := 0.0
	for i in TABLE_SIZE:
		var x := TAU * float(i) / TABLE_SIZE
		var s := 0.0
		for k in range(1, count + 1):
			s += amps[k - 1] * sin(float(k) * x + phases[k])
		t[i] = s
		peak = maxf(peak, absf(s))
	for i in TABLE_SIZE:
		t[i] /= peak
	return t

## The arcade car's V12 (the defaults).
func use_v12() -> void:
	cylinders = 12
	rpm_floor = IDLE_RPM
	rpm_norm_low = 3000.0
	rpm_norm_span = 8000.0
	limiter_rpm = INF
	amp_base = 0.26
	amp_throttle = 0.20
	amp_rpm = 0.06
	blend_base = 0.12
	blend_throttle = 0.88
	detune_mix = 0.6
	sub_base = 0.05
	sub_coast = 0.13
	grit_base = 0.035
	grit_throttle = 0.05
	filter_base = 0.35
	filter_throttle = 0.6
	burble_depth = 0.55
	pop_rate = 0.025
	pop_amp = 0.22
	lift_pop_boost = 0.0
	whistle_amp = 0.0
	blowoff_amp = 0.0
	_boost = 0.0
	_blow = 0.0
	_lift = 0.0
	_cut_frames = 0
	_crack_pending = false
	_inc = -1.0

## The simulation car's turbo-hybrid V6, revving from `idle_rpm` to the limiter at `limit_rpm`.
func use_v6_turbo(idle_rpm: float, limit_rpm: float) -> void:
	cylinders = 6
	set_rev_range(idle_rpm, limit_rpm)
	amp_base = 0.27
	amp_throttle = 0.20
	amp_rpm = 0.05
	blend_base = 0.08
	blend_throttle = 0.58
	detune_mix = 0.3
	sub_base = 0.12
	sub_coast = 0.10
	grit_base = 0.06
	grit_throttle = 0.09
	filter_base = 0.22
	filter_throttle = 0.42
	burble_depth = 0.6
	pop_rate = 0.03
	pop_amp = 0.26
	lift_pop_boost = 7.0
	whistle_amp = 0.045
	blowoff_amp = 0.11
	_inc = -1.0

## Rev range of the current engine: level and brightness follow it, and the limiter stutters
## at `limit_rpm`. Only for the V6 (use_v12 switches the limiter off again).
func set_rev_range(idle_rpm: float, limit_rpm: float) -> void:
	rpm_floor = minf(idle_rpm, IDLE_RPM)
	rpm_norm_low = idle_rpm
	rpm_norm_span = maxf(limit_rpm - idle_rpm, 1000.0)
	limiter_rpm = limit_rpm

## An upshift: cuts the engine for SHIFT_CUT_TIME of audio (at least one rendered block,
## whatever the frame rate), then a crack as it fires again.
func shift_cut() -> void:
	_cut_frames = int(SHIFT_CUT_TIME * mix_rate)

## Turbo boost 0..1 (read-only; 0 for the V12).
func boost() -> float:
	return _boost

## True while the engine is being held on the rev limiter.
func on_limiter() -> bool:
	return smoothed_rpm >= limiter_rpm - LIMITER_BAND_RPM and smoothed_throttle > 0.4

## True during the ignition cut of an upshift.
func is_shift_cut() -> bool:
	return _cut_frames > 0

## Slews rpm/throttle towards the car's values. Call once per frame with the frame delta.
## `throttle` is what reaches the engine. `pedal` is the driver's foot when that differs
## (traction control); a lift-off is judged on it. Leave it out when they are the same.
func update(dt: float, rpm: float, throttle: float, pedal: float = -1.0) -> void:
	var target := maxf(rpm, rpm_floor)
	var tau := RPM_TAU_UP if target > smoothed_rpm else RPM_TAU_DOWN
	smoothed_rpm += (target - smoothed_rpm) * (1.0 - exp(-dt / tau))
	var thr := clampf(throttle, 0.0, 1.0)
	if whistle_amp > 0.0 or lift_pop_boost > 0.0:
		_update_turbo(dt, thr, clampf(pedal, 0.0, 1.0) if pedal >= 0.0 else thr)
	smoothed_throttle += (thr - smoothed_throttle) * (1.0 - exp(-dt / THROTTLE_TAU))

## Boost follows throttle x revs with turbo lag; the driver closing the throttle under boost
## dumps it (a hiss) and starts the lift-off crackle. A traction-control cut is not a lift.
func _update_turbo(dt: float, thr: float, pedal: float) -> void:
	if pedal < _smoothed_pedal - 0.25 and _lift < 0.5:
		_lift = 1.0
		_blow = maxf(_blow, blowoff_amp * _boost)
	_smoothed_pedal += (pedal - _smoothed_pedal) * (1.0 - exp(-dt / THROTTLE_TAU))
	_lift *= exp(-dt / LIFT_TAU)
	var rn := clampf((smoothed_rpm - rpm_norm_low) / rpm_norm_span, 0.0, 1.0)
	var boost_t := thr * (0.25 + 0.75 * rn)
	_boost += (boost_t - _boost) * (1.0 - exp(-dt / (BOOST_TAU_UP if boost_t > _boost else BOOST_TAU_DOWN)))

## Snaps the smoothed state (e.g. after a respawn).
func reset(rpm: float, throttle: float) -> void:
	smoothed_rpm = maxf(rpm, rpm_floor)
	smoothed_throttle = clampf(throttle, 0.0, 1.0)
	_boost = 0.0
	_blow = 0.0
	_lift = 0.0
	_smoothed_pedal = smoothed_throttle
	_cut_frames = 0
	_crack_pending = false
	_pop_env = 0.0
	_cyc_gain = 1.0
	_cyc_target = 1.0
	_inc = -1.0  # next block starts at the new pitch instead of gliding from the old one

## Renders `frames` stereo frames (identical channels), ramping from the previous block's
## parameters to the current smoothed state.
func render(frames: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if frames <= 0:
		return out
	out.resize(frames)
	var ts := float(TABLE_SIZE)
	var thr := smoothed_throttle
	var coast := 1.0 - thr
	var rn := clampf((smoothed_rpm - rpm_norm_low) / rpm_norm_span, 0.0, 1.0)
	var inc_t := freq_hz * ts / mix_rate
	if _inc < 0.0:
		_inc = inc_t
	var amp_t := amp_base + amp_throttle * thr + amp_rpm * rn
	var blend_t := blend_base + blend_throttle * thr * (0.6 + 0.4 * rn)
	var sub_t := sub_base + sub_coast * coast
	var grit_t := grit_base + grit_throttle * thr
	var master_t := clampf(master, 0.0, 1.0)
	var lpc := filter_base + filter_throttle * thr  # filter coefficient: stepping it per block does not click
	var burble := burble_depth * coast * (0.3 + 0.7 * rn)
	var pop_prob := pop_rate * coast * coast * rn * (1.0 + lift_pop_boost * _lift)
	var pop_level := pop_amp
	var mix2 := detune_mix
	# Upshift: the ignition cut drops the engine for a few blocks, then it cracks back in.
	if _crack_pending:
		_crack_pending = false
		_pop_env = maxf(_pop_env, SHIFT_CRACK_AMP)
	if _cut_frames > 0:
		amp_t *= SHIFT_CUT_GAIN
		blend_t *= 0.5
		_cut_frames -= frames
		_crack_pending = _cut_frames <= 0
	# Rev limiter: groups of firing cycles are cut.
	var limiting := on_limiter()
	var cycle := _cycle
	# Turbo whistle (added after the tone filter: it lives above it) and blow-off hiss.
	var turbo := whistle_amp > 0.0
	var winc_t := lerpf(WHISTLE_HZ_LOW, WHISTLE_HZ_HIGH, _boost) * ts / mix_rate
	var wamp_t := whistle_amp * _boost * _boost
	if _winc <= 0.0:
		_winc = winc_t
	var inv := 1.0 / float(frames)
	var d_winc := (winc_t - _winc) * inv
	var d_wamp := (wamp_t - _wamp) * inv
	var sine := _sine
	var pw := _pw
	var winc := _winc
	var wamp := _wamp
	var blow := _blow
	var blow_decay := _blow_decay
	var d_inc := (inc_t - _inc) * inv
	var d_amp := (amp_t - _amp) * inv
	var d_blend := (blend_t - _blend) * inv
	var d_sub := (sub_t - _sub_amp) * inv
	var d_grit := (grit_t - _grit) * inv
	var d_master := (master_t - _master_ramp) * inv
	var pop_decay := _pop_decay
	var cyc_coef := _cyc_coef

	# Locals are much faster than member access in GDScript. Every gain is ramped per sample.
	var bright := _bright
	var dark := _dark
	var pulse := _pulse
	var sub := _sub
	var noise := _noise
	var p1 := _p1
	var p2 := _p2
	var ps := _ps
	var ni := _ni
	var inc := _inc
	var amp := _amp
	var bl := _blend
	var sa := _sub_amp
	var gr := _grit
	var mg := _master_ramp
	var cg := _cyc_gain
	var ct := _cyc_target
	var pe := _pop_env
	var lp := _lp
	for i in frames:
		inc += d_inc
		amp += d_amp
		bl += d_blend
		sa += d_sub
		gr += d_grit
		mg += d_master
		p1 += inc
		if p1 >= ts:
			p1 -= ts
			# New firing cycle: pick this cycle's gain and maybe an overrun pop.
			var r := noise[(ni + 5003) & NOISE_MASK]
			ct = 1.0 - burble * (r if r > 0.0 else -r)
			if (noise[(ni + 911) & NOISE_MASK] + 1.0) * 0.5 < pop_prob:
				pe = pop_level
			if limiting:
				cycle += 1
				if cycle % LIMITER_PERIOD < LIMITER_CUT_CYCLES:
					ct *= 0.12
		p2 += inc * DETUNE
		if p2 >= ts:
			p2 -= ts
		ps += inc * 0.5
		if ps >= ts:
			ps -= ts
		var i1 := int(p1)
		var d1 := dark[i1]
		var nz := noise[ni]
		ni = (ni + 1) & NOISE_MASK
		# Main osc morphs dark->bright; detuned partner stays dark (beating in the low partials).
		var tone := d1 + bl * (bright[i1] - d1) + mix2 * dark[int(p2)]
		cg += (ct - cg) * cyc_coef
		lp += lpc * ((tone * amp + sub[int(ps)] * sa + nz * pulse[i1] * gr) * cg + nz * pe - lp)
		pe *= pop_decay
		var y := lp * mg
		if turbo:
			winc += d_winc
			wamp += d_wamp
			pw += winc
			if pw >= ts:
				pw -= ts
			y += (sine[int(pw)] * wamp + nz * blow) * mg
			blow *= blow_decay
		if y > 1.4:
			y = 1.4
		elif y < -1.4:
			y = -1.4
		y -= 0.15 * y * y * y
		out[i] = Vector2(y, y)
	_p1 = p1
	_p2 = p2
	_ps = ps
	_ni = ni
	_inc = inc_t
	_amp = amp_t
	_blend = blend_t
	_sub_amp = sub_t
	_grit = grit_t
	_master_ramp = master_t
	_cyc_gain = cg
	_cyc_target = ct
	_pop_env = pe
	_lp = lp
	_pw = pw
	_winc = winc_t
	_wamp = wamp_t
	_blow = blow
	_cycle = cycle % LIMITER_PERIOD
	return out
