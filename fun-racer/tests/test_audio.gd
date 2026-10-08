extends TestCase
## Engine / screech / wind audio: runs headless (Dummy driver) without errors, engine pitch
## follows rpm, screech only while drifting / sliding, render cost stays within budget.
## Scene-level waits are wall-clock based (the smoothing is time based, not frame based).

const EngineSynth := preload("res://scripts/audio/engine_synth.gd")

func _audio(main: Node) -> Node:
	return main.get_node("EngineAudio")

func test_autodrive_runs() -> void:
	Bootstrap.autodrive = true
	var main := spawn("res://scenes/main.tscn")
	await physics_frames(300)
	Bootstrap.autodrive = false
	var audio := _audio(main)
	var car := main.get_node("Car") as Car
	var expected: float = maxf(car.rpm, EngineSynth.IDLE_RPM) / 60.0 * 6.0
	assert_between(audio.engine_freq_hz, expected * 0.6, expected * 1.4, "engine_freq_hz vs rpm")
	if car.speed_kmh > 20.0:
		assert_true(audio.wind_gain > 0.0, "wind should rise with speed (speed=%.1f)" % car.speed_kmh)

func test_freq_follows_rpm() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	var audio := _audio(main)
	car.simulate = false
	car.rpm = 5000.0
	car.throttle = 1.0
	await _seconds(0.4)
	var f_low: float = audio.engine_freq_hz
	car.rpm = 10000.0
	await _seconds(0.4)
	var f_high: float = audio.engine_freq_hz
	assert_true(f_high > f_low * 1.6, "freq should rise with rpm: %.1f -> %.1f" % [f_low, f_high])
	assert_between(f_high, 950.0, 1050.0, "freq at 10000 rpm (12 cyl)")

func test_synth_shift_is_slewed() -> void:
	var s := EngineSynth.new(24000.0, 12)
	s.reset(10800.0, 1.0)
	var f0 := s.freq_hz
	s.update(1.0 / 60.0, 7000.0, 1.0)
	var f1 := s.freq_hz
	assert_true(f1 < f0 and f1 > 700.0 + 5.0, "one frame after shift: %.1f (from %.1f)" % [f1, f0])
	for i in 12:
		s.update(1.0 / 60.0, 7000.0, 1.0)
	assert_between(s.freq_hz, 699.0, 705.0, "settled freq ~0.2 s after shift")

func test_synth_render_output_and_cost() -> void:
	var s := EngineSynth.new(24000.0, 12)
	s.reset(9000.0, 1.0)
	var best := 1e9
	var peak := 0.0
	for rep in 20:
		s.update(1.0 / 60.0, 9000.0, 1.0 if rep < 10 else 0.0)
		var t0 := Time.get_ticks_usec()
		var buf := s.render(400)  # one 60 fps frame at 24 kHz
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
		for v in buf:
			peak = maxf(peak, absf(v.x))
	assert_between(peak, 0.05, 0.98, "rendered peak (audible, not clipping)")
	# Uncontended cost is ~0.4 ms; loose bound so shared CI machines don't flake.
	assert_true(best < 4.0, "render of 400 frames took %.3f ms" % best)

func test_screech_gain() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	var audio := _audio(main)
	car.simulate = false
	car.speed_kmh = 120.0
	car.is_drifting = false
	for w: WheelState in car.wheels:
		w.contact = true
		w.slip = 0.0
	await _seconds(0.3)
	assert_between(audio.screech_gain, 0.0, 0.01, "screech gain when gripping")
	car.is_drifting = true
	await _seconds(0.4)
	assert_true(audio.screech_gain > 0.3, "screech gain when drifting = %.3f" % audio.screech_gain)
	car.is_drifting = false
	await _seconds(1.0)
	assert_between(audio.screech_gain, 0.0, 0.05, "screech fades out after drift")
	car.wheels[2].slip = 0.95
	await _seconds(0.4)
	assert_true(audio.screech_gain > 0.3, "screech on high wheel slip = %.3f" % audio.screech_gain)

func test_respawn_mutes() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	var audio := _audio(main)
	await _seconds(0.3)
	car.respawn()
	await _seconds(0.15)  # inside the 0.3 s mute window
	assert_true(audio.engine_gain < 0.5, "engine should duck after respawn (%.2f)" % audio.engine_gain)
	assert_between(audio.screech_gain, 0.0, 0.01, "screech reset on respawn")

func _seconds(t: float) -> void:
	var end := Time.get_ticks_msec() + int(t * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
