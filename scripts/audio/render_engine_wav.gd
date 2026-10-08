extends SceneTree
## Offline render of the engine synth (plus the screech / wind loops) for signal checks.
## Usage: godot --headless --path . -s res://scripts/audio/render_engine_wav.gd -- --out=/tmp/engine.wav
## Writes OUT (engine sweep, ~5 s), OUT.csv (time, rpm, throttle, expected firing Hz per block),
## and OUT-screech.wav / OUT-wind.wav. Also prints the average render cost per 60 fps block.

const EngineSynth := preload("res://scripts/audio/engine_synth.gd")
const AudioLoops := preload("res://scripts/audio/audio_loops.gd")
const RATE := 24000.0
const BLOCK := 400  # 1/60 s at 24 kHz

func _initialize() -> void:
	var out_path := "/tmp/unit7_engine.wav"
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_path = a.get_slice("=", 1)
	var synth := EngineSynth.new(RATE, 12)
	var all := PackedVector2Array()
	var csv := "t,rpm,throttle,expected_hz\n"
	var t := 0.0
	var rpm := 4000.0
	var gear := 1
	var dt := BLOCK / RATE
	var total_usec := 0
	var blocks := 0
	synth.reset(rpm, 1.0)
	while t < 5.0:
		var thr := 1.0
		if t < 4.0:
			# Full throttle: each gear revs slower than the last, upshift at 10800 rpm.
			rpm += dt * 9000.0 / float(gear)
			if rpm > 10800.0 and gear < 7:
				gear += 1
				rpm = 10800.0 * float(gear - 1) / float(gear) + 1200.0
		else:
			thr = 0.0  # lift off: coast down
			rpm = maxf(4000.0, rpm - dt * 3000.0)
		synth.update(dt, rpm, thr)
		var t0 := Time.get_ticks_usec()
		all.append_array(synth.render(BLOCK))
		total_usec += Time.get_ticks_usec() - t0
		blocks += 1
		csv += "%.4f,%.1f,%.2f,%.2f\n" % [t, rpm, thr, synth.freq_hz]
		t += dt
	var mono := PackedFloat32Array()
	mono.resize(all.size())
	for i in all.size():
		mono[i] = all[i].x
	AudioLoops.to_wav(mono, 1.0, int(RATE), false).save_to_wav(out_path)
	var f := FileAccess.open(out_path + ".csv", FileAccess.WRITE)
	f.store_string(csv)
	f.close()
	var base := out_path.get_basename()
	AudioLoops.make_screech().save_to_wav(base + "-screech.wav")
	AudioLoops.make_wind().save_to_wav(base + "-wind.wav")
	print("rendered %d frames, avg %.3f ms per %d-frame block" % [all.size(), total_usec / 1000.0 / blocks, BLOCK])
	quit(0)
