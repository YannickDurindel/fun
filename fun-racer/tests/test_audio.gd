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

## Power of `buf` at `hz` (Goertzel), normalised by the number of samples.
func _power_at(buf: PackedVector2Array, hz: float, rate: float) -> float:
	var w := TAU * hz / rate
	var c := 2.0 * cos(w)
	var s1 := 0.0
	var s2 := 0.0
	for v in buf:
		var s0 := v.x + c * s1 - s2
		s2 = s1
		s1 = s0
	return (s1 * s1 + s2 * s2 - c * s1 * s2) / (float(buf.size()) * float(buf.size()))

## Brightness: rms of the first difference over rms. A pure sine at hz gives 2 sin(pi hz / rate);
## upper harmonics and noise raise it.
func _brightness(buf: PackedVector2Array) -> float:
	var d := 0.0
	for i in range(1, buf.size()):
		var x := buf[i].x - buf[i - 1].x
		d += x * x
	return sqrt(d / maxf(buf.size() - 1, 1.0)) / maxf(_rms(buf), 1e-9)

func _rms(buf: PackedVector2Array) -> float:
	var sum := 0.0
	for v in buf:
		sum += v.x * v.x
	return sqrt(sum / maxf(buf.size(), 1.0))

func _render(s: EngineSynth, rpm: float, throttle: float, blocks: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in blocks:
		s.update(1.0 / 60.0, rpm, throttle)
		out.append_array(s.render(400))
	return out

## On throttle the engine is louder and brighter (upper orders up against the firing order),
## not a pure tone (orders 2..4 carry real energy), and still pitched (the firing order stands
## well above the gaps between orders).
func test_synth_load_timbre() -> void:
	var s := EngineSynth.new(24000.0, 12)
	s.reset(9000.0, 1.0)
	_render(s, 9000.0, 1.0, 20)
	var on := _render(s, 9000.0, 1.0, 30)
	_render(s, 9000.0, 0.0, 20)
	var off := _render(s, 9000.0, 0.0, 30)
	var f0 := 900.0
	var bright_on := _brightness(on)
	var bright_off := _brightness(off)
	var sine := 2.0 * sin(PI * f0 / 24000.0)
	assert_true(_rms(on) > _rms(off) * 1.4, "louder on load: %.3f vs %.3f" % [_rms(on), _rms(off)])
	assert_true(bright_on > bright_off * 1.3, "brighter on load: %.3f vs %.3f" % [bright_on, bright_off])
	assert_true(bright_on > sine * 1.8, "upper orders on load, not a pure tone: %.3f vs sine %.3f" % [bright_on, sine])
	# Between the order lines (and the 1/12 lines of the cylinder imbalance).
	var gap := maxf(_power_at(on, f0 * 0.79, 24000.0), _power_at(on, f0 * 1.21, 24000.0))
	assert_true(_power_at(on, f0, 24000.0) > gap * 10.0, "firing order stands out of the gaps: %.6f vs %.6f"
			% [_power_at(on, f0, 24000.0), gap])

func test_synth_downshift_blip() -> void:
	var s := EngineSynth.new(24000.0, 12)
	s.reset(8000.0, 0.0)
	var quiet := _rms(_render(s, 8000.0, 0.0, 30))
	s.downshift_blip()
	var bang := _rms(_render(s, 8000.0, 0.0, 2))
	assert_true(bang > quiet * 1.15, "a downshift bangs on the overrun: %.3f vs %.3f" % [bang, quiet])

func test_kerb_rumble() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	var audio := _audio(main)
	car.simulate = false
	car.speed_kmh = 144.0
	for w: WheelState in car.wheels:
		w.contact = true
		w.slip = 0.0
		w.surface = &"asphalt"
	await _seconds(0.3)
	assert_between(audio.kerb_gain, 0.0, 0.01, "no rumble on asphalt")
	car.wheels[1].surface = &"kerb"
	car.wheels[3].surface = &"kerb"
	await _seconds(0.3)
	assert_true(audio.kerb_gain > 0.6, "rumble with two wheels on a kerb (%.2f)" % audio.kerb_gain)
	assert_between(audio.kerb_pitch, 0.95, 1.05, "ridge rate follows speed (40 m/s = pitch 1)")
	car.speed_kmh = 72.0
	await _seconds(0.1)
	assert_between(audio.kerb_pitch, 0.45, 0.55, "slower: lower rumble")
	car.wheels[1].surface = &"asphalt"
	car.wheels[3].surface = &"asphalt"
	await _seconds(0.5)
	assert_between(audio.kerb_gain, 0.0, 0.02, "rumble stops off the kerb")

func test_scrub_rises_with_slip_before_screech() -> void:
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	var audio := _audio(main)
	car.simulate = false
	car.speed_kmh = 120.0
	car.is_drifting = false
	for w: WheelState in car.wheels:
		w.contact = true
		w.slip = 0.0
		w.surface = &"asphalt"
	await _seconds(0.4)
	assert_between(audio.scrub_gain, 0.0, 0.01, "no scrub when rolling straight")
	car.wheels[0].slip = 0.2
	await _seconds(0.6)
	var light: float = audio.scrub_gain
	assert_true(light > 0.2, "scrub at moderate slip (%.2f)" % light)
	assert_between(audio.screech_gain, 0.0, 0.02, "no screech yet at moderate slip")
	car.wheels[0].slip = 0.6
	await _seconds(0.6)
	assert_true(audio.scrub_gain > light, "scrub rises with slip: %.2f -> %.2f" % [light, audio.scrub_gain])
	assert_true(audio.screech_gain > 0.2, "screech joins at high slip")

func test_whoosh_doppler() -> void:
	var ea := preload("res://scripts/audio/engine_audio.gd")
	var far: Vector2 = ea.whoosh(Vector3(0, 0, 30), Vector3(0, 0, -20))
	assert_true(far.x == 0.0, "a far car makes no whoosh")
	var coming: Vector2 = ea.whoosh(Vector3(2, 0, -6), Vector3(0, 0, 15))
	var going: Vector2 = ea.whoosh(Vector3(2, 0, 6), Vector3(0, 0, 15))
	assert_true(coming.x > 0.3 and going.x > 0.3, "a close, fast car whooshes")
	assert_true(coming.y > 1.01 and going.y < 0.99, "doppler: higher closing in, lower going away (%.3f, %.3f)" % [coming.y, going.y])
	var slow: Vector2 = ea.whoosh(Vector3(2, 0, 0), Vector3(0, 0, 1))
	assert_true(slow.x < 0.01, "no whoosh from a car alongside at the same speed")

func _seconds(t: float) -> void:
	var end := Time.get_ticks_msec() + int(t * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
