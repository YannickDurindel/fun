extends RefCounted
## Builds seamless looping AudioStreamWAVs in code (no samples on disk) for the tyre screech,
## the tyre scrub, the kerb rumble, the wind and the whoosh of a car going by. They are rendered once at startup; at runtime only volume_db / pitch_scale change,
## which costs nothing. pitch_scale on the noise loops moves their spectrum, which is how the
## wind "cutoff" rises with speed. Loops are cached, so they are built once per process.

const RATE: int = 22050
const LOOP_SECONDS: float = 1.0
const FADE_SECONDS: float = 0.15

static var _screech: AudioStreamWAV
static var _wind: AudioStreamWAV
static var _kerb: AudioStreamWAV
static var _scrub: AudioStreamWAV
static var _whoosh: AudioStreamWAV

## Kerb rumble: KERB_BUMPS ridges per loop, so at pitch_scale 1 the car crosses KERB_BUMPS
## ridges a second (pitch_scale = speed / (KERB_BUMPS * ridge spacing)).
const KERB_BUMPS: int = 40

static func make_screech() -> AudioStreamWAV:
	if _screech == null:
		_screech = _build_screech()
	return _screech

static func make_wind() -> AudioStreamWAV:
	if _wind == null:
		_wind = _build_wind()
	return _wind

static func make_kerb() -> AudioStreamWAV:
	if _kerb == null:
		_kerb = _build_kerb()
	return _kerb

static func make_scrub() -> AudioStreamWAV:
	if _scrub == null:
		_scrub = _build_scrub()
	return _scrub

static func make_whoosh() -> AudioStreamWAV:
	if _whoosh == null:
		_whoosh = _build_whoosh()
	return _whoosh

## Kerb rumble: every ridge is a thud (a damped low resonance: tyre and chassis) plus a short
## rattle of band-passed noise, with a little random level per ridge. The tails are added
## circularly, so the loop is seamless by construction.
static func _build_kerb() -> AudioStreamWAV:
	var n := int(RATE * LOOP_SECONDS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2468
	var rattle := _bandpass_noise(n, 1200.0, 0.8, rng)
	var data := PackedFloat32Array()
	data.resize(n)
	var tail := int(0.03 * RATE)
	var peak := 0.0
	for b in KERB_BUMPS:
		var start := b * n / KERB_BUMPS
		var level := rng.randf_range(0.75, 1.0)
		for j in tail:
			var t := float(j) / RATE
			var thud := sin(TAU * 95.0 * t) * exp(-t / 0.009) + 0.5 * sin(TAU * 190.0 * t + 0.4) * exp(-t / 0.005)
			var rat := rattle[(start + j) % n] * exp(-t / 0.006) * 3.5
			var k := (start + j) % n
			data[k] += level * (thud + rat)
	for i in n:
		peak = maxf(peak, absf(data[i]))
	return to_wav(data, 0.85 / peak, RATE, true)

## Tyre scrub: the rough, grainy rubbing of a tyre working near its limit, below the squeal.
## Mid band-passed noise, a low rumble under it, and a random grain envelope (the "chhrr").
static func _build_scrub() -> AudioStreamWAV:
	var n := int(RATE * LOOP_SECONDS)
	var m := int(RATE * FADE_SECONDS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 97531
	var mid := _bandpass_noise(n + m, 950.0, 0.8, rng)
	var high := _bandpass_noise(n + m, 2400.0, 1.2, rng)
	var low := _bandpass_noise(n + m, 220.0, 0.9, rng)
	var raw := PackedFloat32Array()
	raw.resize(n + m)
	var grain := 0.0
	var target := 1.0
	var gc := 1.0 - exp(-1.0 / (0.004 * RATE))
	for i in n + m:
		if i % int(0.012 * RATE) == 0:
			target = rng.randf_range(0.35, 1.0)
		grain += (target - grain) * gc
		raw[i] = grain * (1.0 * mid[i] + 0.45 * high[i]) + 0.6 * low[i]
	var data := _seamless(raw, n, m)
	var peak := 0.0
	for i in n:
		peak = maxf(peak, absf(data[i]))
	return to_wav(data, 0.85 / peak, RATE, true)

## Whoosh of a car going by: broad band-passed noise, a body of low rumble and a slow swell.
## Its pitch_scale carries the doppler shift.
static func _build_whoosh() -> AudioStreamWAV:
	var n := int(RATE * LOOP_SECONDS)
	var m := int(RATE * FADE_SECONDS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8642
	var body := _bandpass_noise(n + m, 520.0, 0.6, rng)
	var air := _bandpass_noise(n + m, 1600.0, 0.8, rng)
	var raw := PackedFloat32Array()
	raw.resize(n + m)
	for i in n + m:
		raw[i] = body[i] + 0.4 * air[i]
	var data := _seamless(raw, n, m)
	var peak := 0.0
	for i in n:
		var t := float(i) / RATE
		data[i] *= 0.85 + 0.15 * sin(TAU * 2.0 * t)
		peak = maxf(peak, absf(data[i]))
	return to_wav(data, 0.85 / peak, RATE, true)

## Tyre screech: band-passed noise (rubber hiss) + a resonant squeal tone with harmonics,
## gentle vibrato and amplitude wobble. All periodic parts have integer cycles per loop.
static func _build_screech() -> AudioStreamWAV:
	var n := int(RATE * LOOP_SECONDS)
	var m := int(RATE * FADE_SECONDS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var hiss := _bandpass_noise(n + m, 2600.0, 1.4, rng)
	var hiss2 := _bandpass_noise(n + m, 5200.0, 2.0, rng)
	var noise := _seamless(hiss, n, m)
	var noise2 := _seamless(hiss2, n, m)
	var data := PackedFloat32Array()
	data.resize(n)
	var f := 1180.0       # squeal fundamental, integer cycles per 1 s loop
	var fv := 6.0         # vibrato rate (Hz, integer)
	var depth := 0.025    # vibrato depth (fraction of f)
	var peak := 0.0
	for i in n:
		var t := float(i) / RATE
		# FM vibrato: phase = 2*pi*f*t + (f*depth/fv)*sin(2*pi*fv*t); returns to 2*pi*f at t=1.
		var ph := TAU * f * t + (f * depth / fv) * sin(TAU * fv * t)
		var wob := 0.75 + 0.25 * sin(TAU * 9.0 * t) * sin(TAU * 2.0 * t + 0.7)
		var tone := (sin(ph) + 0.45 * sin(2.0 * ph + 0.3) + 0.2 * sin(3.0 * ph + 1.1)) * wob
		var s := 0.55 * tone + 1.6 * noise[i] + 0.8 * noise2[i]
		data[i] = s
		peak = maxf(peak, absf(s))
	return to_wav(data, 0.85 / peak, RATE, true)

## Wind: white noise through two one-pole low-passes, with slow gusts.
static func _build_wind() -> AudioStreamWAV:
	var n := int(RATE * LOOP_SECONDS)
	var m := int(RATE * FADE_SECONDS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4321
	var raw := PackedFloat32Array()
	raw.resize(n + m)
	var a := 1.0 - exp(-TAU * 700.0 / RATE)
	var y1 := 0.0
	var y2 := 0.0
	for i in n + m:
		y1 += a * (rng.randf_range(-1.0, 1.0) - y1)
		y2 += a * (y1 - y2)
		raw[i] = y2
	var data := _seamless(raw, n, m)
	var peak := 0.0
	for i in n:
		var t := float(i) / RATE
		data[i] *= 0.8 + 0.2 * sin(TAU * 1.0 * t) * sin(TAU * 3.0 * t + 0.4)
		peak = maxf(peak, absf(data[i]))
	return to_wav(data, 0.85 / peak, RATE, true)

## Resonant two-pole band-pass (RBJ biquad, constant 0 dB peak gain) over white noise.
static func _bandpass_noise(count: int, fc: float, q: float, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var w0 := TAU * fc / RATE
	var alpha := sin(w0) / (2.0 * q)
	var a0 := 1.0 + alpha
	var b0 := alpha / a0
	var b2 := -alpha / a0
	var a1 := -2.0 * cos(w0) / a0
	var a2 := (1.0 - alpha) / a0
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	var out := PackedFloat32Array()
	out.resize(count)
	for i in count:
		var x := rng.randf_range(-1.0, 1.0)
		var y := b0 * x + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		out[i] = y
	return out

## Returns the first n samples of src (length n + m) with the tail [n, n+m) crossfaded
## (equal power) into the head, so sample n-1 flows into sample 0 seamlessly.
static func _seamless(src: PackedFloat32Array, n: int, m: int) -> PackedFloat32Array:
	var out := src.slice(0, n)
	for i in m:
		var x := float(i) / m
		out[i] = src[i] * sin(x * PI * 0.5) + src[n + i] * cos(x * PI * 0.5)
	return out

## Encodes mono float samples as a 16-bit AudioStreamWAV (optionally looping forward).
static func to_wav(data: PackedFloat32Array, gain: float, rate: int, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		bytes.encode_s16(i * 2, int(clampf(data[i] * gain, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = data.size()
	return wav
