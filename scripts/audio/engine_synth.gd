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

var mix_rate: float
var cylinders: int = 12

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

func _init(rate: float = 24000.0, cyl: int = 12) -> void:
	mix_rate = rate
	cylinders = cyl
	_pop_decay = exp(-1.0 / (0.022 * rate))  # overrun pop decay, ~22 ms
	_cyc_coef = 1.0 - exp(-1.0 / (0.0013 * rate))  # per-cycle gain glide, ~1.3 ms
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
	for i in TABLE_SIZE:
		var x := float(i) / TABLE_SIZE
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

## Slews rpm/throttle towards the car's values. Call once per frame with the frame delta.
func update(dt: float, rpm: float, throttle: float) -> void:
	var target := maxf(rpm, IDLE_RPM)
	var tau := RPM_TAU_UP if target > smoothed_rpm else RPM_TAU_DOWN
	smoothed_rpm += (target - smoothed_rpm) * (1.0 - exp(-dt / tau))
	smoothed_throttle += (clampf(throttle, 0.0, 1.0) - smoothed_throttle) * (1.0 - exp(-dt / THROTTLE_TAU))

## Snaps the smoothed state (e.g. after a respawn).
func reset(rpm: float, throttle: float) -> void:
	smoothed_rpm = maxf(rpm, IDLE_RPM)
	smoothed_throttle = clampf(throttle, 0.0, 1.0)
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
	var rn := clampf((smoothed_rpm - 3000.0) / 8000.0, 0.0, 1.0)
	var inc_t := freq_hz * ts / mix_rate
	if _inc < 0.0:
		_inc = inc_t
	var amp_t := 0.26 + 0.20 * thr + 0.06 * rn
	var blend_t := 0.12 + 0.88 * thr * (0.6 + 0.4 * rn)
	var sub_t := 0.05 + 0.13 * coast
	var grit_t := 0.035 + 0.05 * thr
	var master_t := clampf(master, 0.0, 1.0)
	var lpc := 0.35 + 0.6 * thr  # filter coefficient: stepping it per block does not click
	var burble := 0.55 * coast * (0.3 + 0.7 * rn)
	var pop_prob := 0.025 * coast * coast * rn
	var pop_amp := 0.22
	var inv := 1.0 / float(frames)
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
				pe = pop_amp
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
		var tone := d1 + bl * (bright[i1] - d1) + 0.6 * dark[int(p2)]
		cg += (ct - cg) * cyc_coef
		lp += lpc * ((tone * amp + sub[int(ps)] * sa + nz * pulse[i1] * gr) * cg + nz * pe - lp)
		pe *= pop_decay
		var y := lp * mg
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
	return out
