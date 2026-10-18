extends SceneTree
## Offline renders of the car audio for listening and signal checks (no game, no audio device).
## Usage: godot --headless --path . -s res://scripts/audio/render_engine_wav.gd -- --dir=/tmp/audio
## Writes into DIR:
##   engine_v12_sweep.wav  arcade V12: full throttle up through the gears (shift cuts), then a
##                         lift with downshift blips and the overrun; + .csv (t, rpm, throttle,
##                         expected firing Hz per block) for spectrum checks;
##   engine_v6_sweep.wav   the same with the simulation car's turbo V6 (F1 rev range); + .csv;
##   engine_v6_endurance_sweep.wav  the V6 over the endurance car's lower rev range; + .csv;
##   shifts.wav            close-up of upshifts (V6 then V12) and two downshift blips;
##   kerb.wav              V6 at 160 km/h, two wheels then four on a kerb, then off again;
##   scrub.wav             cornering harder and harder: scrub rising, then the screech, then grass;
##   passby.wav            a bot passing 25 km/h faster, 2 m away: whoosh with the doppler drop;
##   screech.wav / wind.wav / kerb_loop.wav / scrub_loop.wav / whoosh_loop.wav: the raw loops.
## The loop voices are mixed the way engine_audio.gd drives them (gain + pitch_scale per frame).
## Prints the average engine render cost per 60 fps block.

const EngineSynth := preload("res://scripts/audio/engine_synth.gd")
const AudioLoops := preload("res://scripts/audio/audio_loops.gd")
const RATE := 24000.0
const BLOCK := 400  # 1/60 s at 24 kHz
const DT := BLOCK / RATE

var _usec: int = 0
var _blocks: int = 0

## A looping AudioStreamWAV played back with a pitch_scale and a gain, like an AudioStreamPlayer.
class Voice:
	var data := PackedFloat32Array()
	var rate: float
	var pos: float = 0.0
	var gain: float = 0.0

	func _init(wav: AudioStreamWAV) -> void:
		rate = wav.mix_rate
		var bytes := wav.data
		data.resize(bytes.size() / 2)
		for i in data.size():
			data[i] = bytes.decode_s16(i * 2) / 32768.0

	## Adds `frames` frames to `out` from `at`, gliding the gain to `target` (dB offset `db`).
	func mix(out: PackedFloat32Array, at: int, frames: int, target: float, pitch: float, db: float) -> void:
		var step := pitch * rate / RATE
		var n := data.size()
		var g0 := gain
		var lin := db_to_linear(db)
		for i in frames:
			var g := lerpf(g0, target, float(i) / frames) * lin
			var k := int(pos)
			var f := pos - k
			out[at + i] += g * lerpf(data[k % n], data[(k + 1) % n], f)
			pos = fmod(pos + step, float(n))
		gain = target

func _initialize() -> void:
	var dir := "/tmp/fun_racer_audio"
	var only := ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--dir="):
			dir = a.get_slice("=", 1)
		elif a.begins_with("--only="):
			only = a.get_slice("=", 1)  # render only the files whose name contains this
	DirAccess.make_dir_recursive_absolute(dir)
	var want := func(n: String) -> bool: return only == "" or n.contains(only)
	if want.call("engine_v12_sweep"):
		_sweep(dir + "/engine_v12_sweep.wav", false, 4000.0, 11500.0)
	if want.call("engine_v6_sweep"):
		_sweep(dir + "/engine_v6_sweep.wav", true, 4000.0, 15000.0)
	if want.call("engine_v6_endurance_sweep"):
		_sweep(dir + "/engine_v6_endurance_sweep.wav", true, 2200.0, 8250.0)
	if want.call("shifts"):
		_shifts(dir + "/shifts.wav")
	if want.call("kerb"):
		_kerb(dir + "/kerb.wav")
	if want.call("scrub"):
		_scrub(dir + "/scrub.wav")
	if want.call("passby"):
		_passby(dir + "/passby.wav")
	AudioLoops.make_screech().save_to_wav(dir + "/screech.wav")
	AudioLoops.make_wind().save_to_wav(dir + "/wind.wav")
	AudioLoops.make_kerb().save_to_wav(dir + "/kerb_loop.wav")
	AudioLoops.make_scrub().save_to_wav(dir + "/scrub_loop.wav")
	AudioLoops.make_whoosh().save_to_wav(dir + "/whoosh_loop.wav")
	print("wrote %s; engine avg %.3f ms per %d-frame block" % [dir, _usec / 1000.0 / maxi(_blocks, 1), BLOCK])
	quit(0)

func _synth(v6: bool, idle: float, limit: float) -> EngineSynth:
	var s := EngineSynth.new(RATE, 12)
	if v6:
		s.use_v6_turbo(idle, limit)
	return s

func _block(s: EngineSynth, out: PackedFloat32Array) -> int:
	var t0 := Time.get_ticks_usec()
	var buf := s.render(BLOCK)
	_usec += Time.get_ticks_usec() - t0
	_blocks += 1
	var at := out.size()
	out.resize(at + BLOCK)
	for i in BLOCK:
		out[at + i] = buf[i].x
	return at

func _save(path: String, mono: PackedFloat32Array) -> void:
	AudioLoops.to_wav(mono, 0.8, int(RATE), false).save_to_wav(path)

## Full throttle through six gears (each revs slower than the last), then lift: three
## downshifts on the overrun as the revs fall.
func _sweep(path: String, v6: bool, idle: float, limit: float) -> void:
	var s := _synth(v6, idle, limit)
	var out := PackedFloat32Array()
	var csv := "t,rpm,throttle,expected_hz\n"
	var top := limit - 300.0
	var drop := (top - idle) * 0.38
	var rpm := idle + 0.15 * (top - idle)
	var gear := 1
	var t := 0.0
	s.reset(rpm, 1.0)
	while t < 7.0:
		var thr := 1.0
		if t < 4.6:
			rpm += DT * (top - idle) * 0.9 / float(gear)
			if rpm > top and gear < 6:
				gear += 1
				rpm -= drop
				s.shift_cut()
		else:
			thr = 0.0
			rpm -= DT * (top - idle) * 0.35
			if rpm < idle + 0.45 * (top - idle) and gear > 2:
				gear -= 1
				rpm += drop * 0.8
				s.downshift_blip()
			rpm = maxf(rpm, idle)
		s.update(DT, rpm, thr)
		_block(s, out)
		csv += "%.4f,%.1f,%.2f,%.2f\n" % [t, rpm, thr, s.freq_hz]
		t += DT
	_save(path, out)
	var f := FileAccess.open(path + ".csv", FileAccess.WRITE)
	f.store_string(csv)
	f.close()

func _shifts(path: String) -> void:
	var out := PackedFloat32Array()
	for v6: bool in [true, false]:
		var s := _synth(v6, 4000.0, 15000.0)
		var rpm := 9000.0
		s.reset(rpm, 1.0)
		var t := 0.0
		while t < 3.2:
			var thr := 1.0
			if t < 2.0:
				rpm += DT * 3500.0
				if rpm > 12000.0:
					rpm = 9500.0
					s.shift_cut()
			else:
				thr = 0.0
				rpm = maxf(rpm - DT * 3000.0, 7000.0)
				if absf(t - 2.4) < DT * 0.5 or absf(t - 2.85) < DT * 0.5:
					rpm += 2200.0
					s.downshift_blip()
			s.update(DT, rpm, thr)
			_block(s, out)
			t += DT
	_save(path, out)

## Engine at a steady 160 km/h with the kerb voice on top: 2 wheels at 1.0-1.9 s, 4 wheels at
## 2.6-3.1 s, at the pitch / gain engine_audio.gd would set.
func _kerb(path: String) -> void:
	var s := _synth(true, 4000.0, 15000.0)
	var kerb := Voice.new(AudioLoops.make_kerb())
	var out := PackedFloat32Array()
	s.reset(10500.0, 0.7)
	var v := 160.0 / 3.6
	var pitch := clampf(v / (AudioLoops.KERB_BUMPS * 1.0), 0.3, 2.5)
	var t := 0.0
	var g := 0.0
	while t < 4.0:
		s.update(DT, 10500.0, 0.7)
		var at := _block(s, out)
		var on := 2 if (t > 1.0 and t < 1.9) else (4 if (t > 2.6 and t < 3.1) else 0)
		var target := minf(1.0, 0.45 + 0.2 * on) if on > 0 else 0.0
		g += (target - g) * (1.0 - exp(-DT / (0.015 if target > g else 0.06)))
		kerb.mix(out, at, BLOCK, g, pitch, 0.0 + 3.0)  # player dB as in engine_audio.gd, relative to the engine player at -3 dB
		t += DT
	_save(path, out)

## Cornering harder and harder (arcade slip 0..1 over 4 s) at 120 km/h: the scrub rises first,
## the screech joins from slip 0.3; then two wheels on grass.
func _scrub(path: String) -> void:
	var s := _synth(false, 4000.0, 11500.0)
	var scrub := Voice.new(AudioLoops.make_scrub())
	var screech := Voice.new(AudioLoops.make_screech())
	var out := PackedFloat32Array()
	s.reset(8500.0, 0.6)
	var t := 0.0
	var gs := 0.0
	var gq := 0.0
	while t < 6.0:
		s.update(DT, 8500.0, 0.5)
		var at := _block(s, out)
		var slip := clampf((t - 0.5) / 3.5, 0.0, 1.0) if t < 4.5 else 0.0
		var off := 0.5 if t > 4.8 and t < 5.8 else 0.0
		var work := smoothstep(0.03, 0.45, slip)
		var ts := maxf(work * 0.8, off * 0.9)
		var tq := smoothstep(0.3, 0.85, slip)
		gs += (ts - gs) * (1.0 - exp(-DT / (0.06 if ts > gs else 0.15)))
		gq += (tq - gq) * (1.0 - exp(-DT / (0.05 if tq > gq else 0.14)))
		var sp := lerpf(0.85 + 0.35 * 0.4 + 0.1 * work, 0.6, clampf(off * 2.0, 0.0, 1.0))
		scrub.mix(out, at, BLOCK, gs, sp, -7.0 + 3.0)
		screech.mix(out, at, BLOCK, gq, 0.92 + 0.14 * slip + 0.04, -7.0 + 3.0)
		t += DT
	_save(path, out)

## A bot 25 km/h faster passing 2 m to the side, over the player's engine at 200 km/h.
func _passby(path: String) -> void:
	var s := _synth(true, 4000.0, 15000.0)
	var wh := Voice.new(AudioLoops.make_whoosh())
	var out := PackedFloat32Array()
	s.reset(11000.0, 1.0)
	var dv := 25.0 / 3.6 * 2.0  # exaggerated a little so the doppler is easy to hear offline
	var t := 0.0
	var g := 0.0
	while t < 4.0:
		s.update(DT, 11000.0, 1.0)
		var at := _block(s, out)
		var x := (t - 2.0) * dv  # bot ahead (+) / behind (-) along the track
		var d := sqrt(x * x + 4.0)
		var closing := dv * x / d  # x < 0: bot behind and closing
		closing = -closing
		var target := smoothstep(16.0, 3.0, d) * smoothstep(3.0, 20.0, dv)
		g += (target - g) * (1.0 - exp(-DT / (0.05 if target > g else 0.25)))
		var pitch := clampf(343.0 / maxf(343.0 - closing, 100.0), 0.75, 1.35)
		wh.mix(out, at, BLOCK, g, pitch, -5.0 + 3.0)
		t += DT
	_save(path, out)
