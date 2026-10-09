extends TestCase
## HUD, sound and effects of the simulation car. Most tests freeze the car
## (`car.simulate = false`) and set the contract fields by hand, so they check the presentation
## and not the physics; the last ones drive the real simulation car to see the body and the
## wheels move. Every test also checks, or is paired with one that checks, that an arcade car
## gets none of it.

const EngineSynth := preload("res://scripts/audio/engine_synth.gd")
const SimWidgets := preload("res://scripts/ui/sim_widgets.gd")
const RpmGauge := preload("res://scripts/ui/rpm_gauge.gd")
const TyreSlip := preload("res://scripts/fx/tyre_slip.gd")

## Carries the frozen car's contact patches down the road, so the effects see a moving car.
## Runs after the car and before DrivingFX (priority 100).
class RoadMover extends Node:
	var car: Car
	var speed: float = 40.0   ## m/s
	var base: Array[Vector3] = []
	var travelled: float = 0.0
	func _ready() -> void:
		process_physics_priority = 10
		for w in car.wheels:
			base.append(w.contact_point)
	func _physics_process(delta: float) -> void:
		travelled += speed * delta
		var fwd := -car.global_transform.basis.z
		car.speed_kmh = speed * 3.6
		for i in 4:
			var w := car.wheels[i]
			w.contact = true
			w.contact_point = base[i] + fwd * travelled
			w.contact_normal = Vector3.UP

## The main scene with the car in the given handling model.
func _main(handling: StringName) -> Node:
	var prev := Bootstrap.handling_override
	Bootstrap.handling_override = handling
	var main := spawn("res://scenes/main.tscn")
	Bootstrap.handling_override = prev
	return main

## A frozen simulation car in the main scene, settled on the road, every wheel loaded and
## gripping. Returns [main, car, fx, hud, audio].
func _frozen(handling: StringName = Car.HANDLING_SIMULATION) -> Array:
	var main := _main(handling)
	var car := main.get_node("Car") as Car
	await physics_frames(60)
	car.simulate = false
	car.speed_kmh = 0.0
	car.is_drifting = false
	for w in car.wheels:
		w.contact = true
		w.load = 4000.0
		w.slip = 0.0
		w.slip_ratio = 0.0
		w.slip_angle = 0.0
		w.locked = false
	return [main, car, main.get_node("FX/DrivingFX"), main.get_node("UI/HUD"), main.get_node("EngineAudio")]

func _move(main: Node, car: Car, speed: float) -> RoadMover:
	var mover := RoadMover.new()
	mover.car = car
	mover.speed = speed
	main.add_child(mover)
	return mover

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _seconds(t: float) -> void:
	var end := Time.get_ticks_msec() + int(t * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame

# ================================================================ HUD
func test_hud_shows_the_simulation_car() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var hud: Control = r[3]
	var widgets := hud.get_node("SimWidgets") as SimWidgets
	var gauge := hud.get_node("Speedo") as RpmGauge
	var gear := hud.get_node("Speedo/Gear") as Label
	var spec := car.sim.spec
	car.gear = 8
	car.rpm = spec.rpm_max
	car.ers_charge = 0.4
	car.drs_open = true
	car.fuel_kg = 42.5
	car.tyre_compound = &"soft"
	var temps: Array[float] = [60.0, 95.0, 130.0, 95.0]
	var wears: Array[float] = [0.12, 0.5, 0.0, 1.0]
	for i in 4:
		car.wheels[i].temperature = temps[i]
		car.wheels[i].wear = wears[i]
	car.wheels[1].locked = true
	car.sim.state.in_throttle = 1.0
	car.sim.state.throttle = 0.4
	car.sim.state.in_brake = 0.0
	car.sim.state.brake = 0.0
	await _frames(4)
	assert_true(widgets.visible, "simulation widgets are shown")
	assert_true(gear.text == "8", "gear label shows 8, got " + gear.text)
	assert_between(gauge.value, 0.999, 1.0, "rpm arc at the car's rpm_max")
	assert_true(gauge.leds_lit() == RpmGauge.LED_COUNT, "all shift lights lit at the limit (%d)" % gauge.leds_lit())
	assert_between(widgets.ers_fraction, 0.399, 0.401, "ERS bar")
	assert_true(widgets.ers_text() == "40%", "ERS text, got " + widgets.ers_text())
	assert_true(widgets.drs_lit, "DRS light lit while open")
	var cold := widgets.tyre_color(0)
	var ok := widgets.tyre_color(1)
	var hot := widgets.tyre_color(2)
	assert_true(cold.b > cold.r + 0.3 and cold.b > cold.g + 0.2, "60 C tyre is blue: %s" % cold)
	assert_true(ok.g > ok.r + 0.3 and ok.g > ok.b + 0.3, "95 C tyre is green: %s" % ok)
	assert_true(hot.r > hot.g + 0.3 and hot.r > hot.b + 0.3, "130 C tyre is red: %s" % hot)
	assert_true(widgets.wear_text(0) == "12%" and widgets.wear_text(1) == "50%"
			and widgets.wear_text(2) == "0%" and widgets.wear_text(3) == "100%",
			"wear texts: %s %s %s %s" % [widgets.wear_text(0), widgets.wear_text(1), widgets.wear_text(2), widgets.wear_text(3)])
	assert_true(widgets.is_lock_flashing(1) and not widgets.is_lock_flashing(0), "the locked wheel flashes")
	assert_true(widgets.fuel_text == "42.5", "fuel text, got " + widgets.fuel_text)
	assert_true(widgets.compound_letter == "S" and widgets.compound_color.r > 0.8 and widgets.compound_color.g < 0.4,
			"soft compound badge: %s %s" % [widgets.compound_letter, widgets.compound_color])
	assert_true(widgets.tc_active and not widgets.abs_active, "TC light while the aid cuts the throttle")

	# Neutral, reverse, DRS shut, ABS working, a mid-range rev count, the other compounds.
	car.gear = 0
	car.drs_open = false
	car.rpm = spec.rpm_max * 0.5
	car.sim.state.throttle = 1.0
	car.sim.state.in_brake = 1.0
	car.sim.state.brake = 0.5
	car.tyre_compound = &"wet"
	await _seconds(0.3)   # longer than the aid lights' hold time
	assert_true(gear.text == "N", "neutral shows N, got " + gear.text)
	assert_true(not widgets.drs_lit, "DRS light off while shut")
	assert_between(gauge.value, 0.49, 0.51, "rpm arc at half the rev limit")
	assert_true(gauge.leds_lit() == 0, "no shift lights at half revs (%d)" % gauge.leds_lit())
	assert_true(widgets.abs_active and not widgets.tc_active, "ABS light while the aid releases the brake")
	assert_true(widgets.compound_letter == "W" and widgets.compound_color.b > 0.8, "wet compound badge")
	car.gear = -1
	car.rpm = lerpf(spec.rpm_idle, spec.rpm_shift_up, 0.9)
	await _frames(3)
	assert_true(gear.text == "R", "reverse shows R, got " + gear.text)
	var lit := gauge.leds_lit()
	assert_true(lit > 2 and lit < RpmGauge.LED_COUNT, "some shift lights just below the shift point (%d)" % lit)

func test_ers_bar_tints_with_deploy_and_harvest() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var widgets := (r[3] as Control).get_node("SimWidgets") as SimWidgets
	car.ers_charge = 0.8
	await _frames(3)
	assert_true(widgets.ers_mode == 0, "steady battery: no tint")
	var end := Time.get_ticks_msec() + 500
	while Time.get_ticks_msec() < end:
		car.ers_charge = maxf(car.ers_charge - 0.03 * get_process_delta_time(), 0.0)
		await get_tree().process_frame
	assert_true(widgets.ers_mode == 1, "falling charge reads as deploying")
	end = Time.get_ticks_msec() + 800
	while Time.get_ticks_msec() < end:
		car.ers_charge = minf(car.ers_charge + 0.03 * get_process_delta_time(), 1.0)
		await get_tree().process_frame
	assert_true(widgets.ers_mode == -1, "rising charge reads as harvesting")

func test_arcade_hud_is_unchanged() -> void:
	var r: Array = await _frozen(Car.HANDLING_ARCADE)
	var car: Car = r[1]
	var hud: Control = r[3]
	assert_true(car.sim == null, "arcade car")
	var widgets := hud.get_node("SimWidgets") as SimWidgets
	var gauge := hud.get_node("Speedo") as RpmGauge
	car.rpm = Car.MAX_RPM
	car.gear = 7
	await _frames(4)
	assert_true(not widgets.visible, "simulation widgets hidden for an arcade car")
	assert_true(gauge.leds_lit() == -1, "no shift lights for an arcade car")
	assert_between(gauge.value, 0.999, 1.0, "arcade arc is full at Car.MAX_RPM")
	assert_true(gauge.flash_from == RpmGauge.SHIFT_FLASH_FROM and gauge.red_from == RpmGauge.RED_FROM
			and gauge.warm_from == RpmGauge.WARM_FROM, "arcade gauge keeps its red zone")
	assert_true((hud.get_node("Speedo/Gear") as Label).text == "7", "arcade gear label")

func test_widgets_clear_of_the_other_hud_parts() -> void:
	var r: Array = await _frozen()
	var hud: Control = r[3]
	await _frames(2)
	for res: Vector2 in [Vector2(1280, 720), Vector2(1920, 1080), Vector2(960, 720)]:
		hud.size = res
		await _frames(1)
		var widgets := (hud.get_node("SimWidgets") as Control).get_global_rect()
		var speedo := (hud.get_node("Speedo") as Control).get_global_rect()
		var inputs := (hud.get_node("Inputs") as Control).get_global_rect()
		var timer := (hud.get_node("TimerGroup") as Control).get_global_rect()
		assert_true(widgets.size.x > 100.0 and Rect2(Vector2.ZERO, res).encloses(widgets),
				"widgets on screen at %s: %s" % [res, widgets])
		for other: Rect2 in [speedo, inputs, timer]:
			assert_true(not widgets.intersects(other), "widgets %s overlap %s at %s" % [widgets, other, res])
		# The race panel's sector plate and the standings tower hang from the top-left corner
		# (see race_panel.gd, standings.gd); the widgets stay right of and below them.
		var s := res.y / 1080.0
		assert_true(widgets.position.x > (44.0 + 300.0) * s, "widgets right of the standings at %s" % res)
		# Shift lights: above the gauge, clear of the timer.
		var gauge := hud.get_node("Speedo") as RpmGauge
		var led_top := speedo.position.y + RpmGauge.LED_Y * gauge.size.y * 0.5 * s - 10.0 * s
		assert_true(led_top > timer.end.y + 100.0 * s, "shift lights below the timer at %s" % res)

# ================================================================ engine sound
func test_engine_is_a_v6_in_simulation_and_the_v12_in_arcade() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var audio: Node = r[4]
	car.rpm = 12000.0
	car.throttle = 1.0
	car.sim.state.throttle = 1.0
	await _seconds(0.4)
	assert_true(audio.engine_cylinders == 6, "simulation engine has 6 cylinders (%d)" % audio.engine_cylinders)
	assert_between(audio.engine_freq_hz, 595.0, 605.0, "firing frequency at 12000 rpm, V6 (rpm/60 x 3)")
	# Upshifts cut the engine; downshifts and the first gear after a respawn do not.
	car.gear = 3
	await _frames(2)
	var cuts: int = audio.shift_cuts
	car.gear = 4
	await _frames(2)
	assert_true(audio.shift_cuts == cuts + 1, "an upshift cuts the engine")
	car.gear = 3
	await _frames(2)
	assert_true(audio.shift_cuts == cuts + 1, "a downshift does not")

	var r2: Array = await _frozen(Car.HANDLING_ARCADE)
	var car2: Car = r2[1]
	var audio2: Node = r2[4]
	car2.rpm = 12000.0
	car2.throttle = 1.0
	await _seconds(0.4)
	assert_true(audio2.engine_cylinders == 12, "arcade engine keeps 12 cylinders (%d)" % audio2.engine_cylinders)
	assert_between(audio2.engine_freq_hz, 1190.0, 1210.0, "firing frequency at 12000 rpm, V12 (rpm/60 x 6)")
	car2.gear = 2
	await _frames(2)
	car2.gear = 3
	await _frames(2)
	assert_true(audio2.shift_cuts == 0, "no shift cut in arcade")

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

func test_v6_synth_signal() -> void:
	var s := EngineSynth.new(24000.0, 12)
	s.use_v6_turbo(4000.0, 13000.0)
	assert_true(s.cylinders == 6, "V6")
	s.reset(12000.0, 1.0)
	assert_between(s.freq_hz, 599.9, 600.1, "fundamental at 12000 rpm")
	_render(s, 12000.0, 1.0, 90)   # spool the turbo
	var buf := _render(s, 12000.0, 1.0, 30)
	# The firing frequency carries the sound; frequencies between its orders do not.
	var fundamental := _power_at(buf, 600.0, 24000.0)
	var between := maxf(_power_at(buf, 450.0, 24000.0), _power_at(buf, 750.0, 24000.0))
	assert_true(fundamental > between * 20.0, "600 Hz stands out: %.6f vs %.6f" % [fundamental, between])
	# Turbo whistle near the top of its range at full boost, and none on the V12.
	assert_true(s.boost() > 0.8, "boost at full throttle and high revs (%.2f)" % s.boost())
	var whistle_hz := lerpf(EngineSynth.WHISTLE_HZ_LOW, EngineSynth.WHISTLE_HZ_HIGH, s.boost())
	var whistle := _power_at(buf, whistle_hz, 24000.0)
	var beside := _power_at(buf, whistle_hz * 1.07, 24000.0)
	assert_true(whistle > beside * 8.0, "turbo whistle at %.0f Hz: %.7f vs %.7f" % [whistle_hz, whistle, beside])
	var peak := 0.0
	for v in buf:
		peak = maxf(peak, absf(v.x))
	assert_between(peak, 0.05, 0.98, "rendered peak (audible, not clipping)")
	var loud := _rms(buf)

	# Upshift: a hole, then the engine is back.
	s.shift_cut()
	assert_true(s.is_shift_cut(), "cut starts")
	var cut := _render(s, 12000.0, 1.0, 2)
	var hole := _rms(cut.slice(400, 800))
	assert_true(hole < loud * 0.6, "the shift cut drops the level: %.3f vs %.3f" % [hole, loud])
	_render(s, 12000.0, 1.0, 12)
	assert_true(not s.is_shift_cut(), "cut over")
	assert_true(_rms(_render(s, 12000.0, 1.0, 10)) > loud * 0.85, "level back after the shift")

	# Limiter: held at the limit the engine stutters (quieter than just below it).
	_render(s, 12500.0, 1.0, 30)
	assert_true(not s.on_limiter(), "below the limiter")
	var below := _rms(_render(s, 12500.0, 1.0, 30))
	_render(s, 13000.0, 1.0, 30)
	assert_true(s.on_limiter(), "on the limiter at rpm_max")
	var limited := _rms(_render(s, 13000.0, 1.0, 30))
	assert_true(limited < below * 0.92, "limiter stutter lowers the level: %.3f vs %.3f" % [limited, below])
	# The power unit may raise the limit: no stutter at 13000 with the limit at 15000.
	s.set_rev_range(4000.0, 15000.0)
	_render(s, 13000.0, 1.0, 5)
	assert_true(not s.on_limiter(), "limit follows the car")

	# A traction-control cut (engine throttle down, pedal still flat) is not a lift-off...
	_render(s, 11000.0, 1.0, 60)
	for k in 20:
		s.update(1.0 / 60.0, 11000.0, 0.15, 1.0)
		s.render(400)
	assert_true(s._lift < 0.01, "no lift-off crackle from a traction-control cut (%.2f)" % s._lift)
	# ...the driver's foot coming off is.
	s.update(1.0 / 60.0, 11000.0, 0.0, 0.0)
	assert_true(s._lift > 0.5, "lift-off crackle when the pedal closes (%.2f)" % s._lift)
	# The cut lasts as long at 20 fps as at 60: one long block is still a hole.
	_render(s, 12000.0, 1.0, 60)
	s.shift_cut()
	s.update(1.0 / 20.0, 12000.0, 1.0)
	assert_true(s.is_shift_cut(), "the cut survives a long frame")
	assert_true(_rms(s.render(1200)) < loud * 0.75, "a hole at 20 fps too")

	# Lift-off dumps the boost.
	_render(s, 11000.0, 1.0, 60)
	_render(s, 11000.0, 0.0, 30)
	assert_true(s.boost() < 0.1, "boost gone after lifting (%.2f)" % s.boost())

	# Cost of one 60 fps block, turbo and all.
	var best := 1e9
	for rep in 20:
		s.update(1.0 / 60.0, 11000.0, 1.0)
		var t0 := Time.get_ticks_usec()
		s.render(400)
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
	assert_true(best < 4.0, "V6 render of 400 frames took %.3f ms" % best)
	var v12 := EngineSynth.new(24000.0, 12)
	v12.reset(9000.0, 1.0)
	var best12 := 1e9
	for rep in 20:
		v12.update(1.0 / 60.0, 9000.0, 1.0)
		var t0 := Time.get_ticks_usec()
		v12.render(400)
		best12 = minf(best12, (Time.get_ticks_usec() - t0) / 1000.0)
	print("    synth cost per 400-frame block: V6 turbo %.3f ms, V12 %.3f ms" % [best, best12])

	# The V12 has no turbo and no limiter, whatever happened before.
	s.use_v12()
	s.reset(10000.0, 1.0)
	_render(s, 10000.0, 1.0, 30)
	assert_true(s.cylinders == 12 and s.boost() == 0.0 and not s.on_limiter(), "V12 restored")
	assert_between(s.freq_hz, 999.0, 1001.0, "V12 fundamental at 10000 rpm")

# ================================================================ tyre effects
func _emitted(fx: Node) -> PackedInt32Array:
	return fx.tyre_smoke.emitted

func test_locked_front_wheel_smokes_and_marks() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var fx: Node = r[2]
	var audio: Node = r[4]
	_move(r[0], car, 40.0)
	car.wheels[0].locked = true
	car.wheels[0].slip_ratio = -1.0
	await physics_frames(120)
	await _seconds(0.4)
	var e := _emitted(fx)
	assert_true(e[0] > 0, "smoke at the locked front-left wheel")
	assert_true(e[1] == 0 and e[2] == 0 and e[3] == 0, "no smoke at the rolling wheels: %s" % e)
	assert_true(fx.skid_marks.is_strip_active(0), "a mark under the locked wheel")
	assert_true(fx.skid_marks.total_segments_written > 0, "skid segments laid")
	for i in [1, 2, 3]:
		assert_true(not fx.skid_marks.is_strip_active(i), "no mark under rolling wheel %d" % i)
	assert_true(TyreSlip.lock_dominant(car, 0), "it is a lock-up")
	assert_true(audio.screech_gain > 0.3, "the locked tyre screeches (%.2f)" % audio.screech_gain)
	var lock_pitch: float = audio.screech_pitch
	# Released: the mark ends and the screech fades.
	car.wheels[0].locked = false
	car.wheels[0].slip_ratio = 0.0
	await physics_frames(10)
	await _seconds(1.0)
	assert_true(not fx.skid_marks.is_strip_active(0), "the mark ends when the wheel rolls again")
	assert_between(audio.screech_gain, 0.0, 0.05, "screech fades once the tyre grips")
	# A spinning tyre sings higher than a locked one howls.
	car.wheels[3].slip_ratio = 1.5
	await _seconds(0.4)
	assert_true(audio.screech_pitch > lock_pitch + 0.1,
			"wheelspin pitch %.2f above lock-up pitch %.2f" % [audio.screech_pitch, lock_pitch])

func test_wheelspin_smokes_at_the_driven_wheel() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var fx: Node = r[2]
	_move(r[0], car, 10.0)
	car.wheels[2].slip_ratio = 1.5   # rear left spinning
	car.wheels[1].slip_ratio = 1.5   # a front wheel is not driven: nothing
	await physics_frames(240)
	await _seconds(0.3)
	var e := _emitted(fx)
	assert_true(e[2] > 0, "smoke at the spinning rear-left wheel")
	assert_true(e[0] == 0 and e[1] == 0 and e[3] == 0, "no smoke elsewhere: %s" % e)
	assert_true(fx.skid_marks.is_strip_active(2) and fx.skid_marks.total_segments_written > 0, "a mark from wheelspin")
	assert_true(not fx.skid_marks.is_strip_active(1), "no mark from an undriven wheel")
	# Reversing, the published ratio changes sign: spinning backwards is still wheelspin.
	car.wheels[2].slip_ratio = -1.5
	car.gear = -1
	assert_true(TyreSlip.spin(car, 2) > 0.9 and TyreSlip.lock(car, 2) == 0.0 and not TyreSlip.lock_dominant(car, 2),
			"wheelspin in reverse is not a lock-up")
	car.sim.state.in_brake = 1.0
	car.sim.state.brake = 0.3
	await _frames(3)
	assert_true(not ((r[3] as Control).get_node("SimWidgets") as SimWidgets).abs_active, "no ABS light while reversing on the brake pedal")

func test_sliding_smokes_at_every_loaded_wheel() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var fx: Node = r[2]
	_move(r[0], car, 30.0)
	for w in car.wheels:
		w.slip_angle = 0.5
	car.wheels[1].load = 0.0   # an unloaded tyre does not mark
	await physics_frames(120)
	await _seconds(0.3)
	var e := _emitted(fx)
	assert_true(e[0] > 0 and e[2] > 0 and e[3] > 0, "smoke at the sliding wheels: %s" % e)
	assert_true(e[1] == 0, "none at the unloaded wheel")

func test_nothing_without_slip() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var fx: Node = r[2]
	var audio: Node = r[4]
	_move(r[0], car, 60.0)
	await physics_frames(120)
	await _seconds(0.3)
	# Then with the tyres working at their peak, where the aids hold them: still nothing.
	var peak_angle := car.sim.spec.tyre_peak_slip_angle
	var peak_ratio := car.sim.spec.tyre_peak_slip_ratio
	for i in 4:
		car.wheels[i].slip_angle = peak_angle
		car.wheels[i].slip_ratio = peak_ratio * (1.3 if i >= 2 else -1.5)
	await physics_frames(120)
	await _seconds(0.3)
	var e := _emitted(fx)
	assert_true(e[0] + e[1] + e[2] + e[3] == 0, "smoke without slip: %s" % e)
	assert_true(fx.tyre_smoke.alive_count() == 0, "no puffs alive")
	assert_true(fx.skid_marks.total_segments_written == 0, "marks without slip: %d" % fx.skid_marks.total_segments_written)
	assert_true(fx.floor_sparks == null or fx.floor_sparks.alive_count() == 0, "no sparks at ride height")
	assert_between(audio.screech_gain, 0.0, 0.01, "no screech without slip")

func test_floor_sparks_when_bottoming_at_speed() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var fx: Node = r[2]
	_move(r[0], car, 70.0)
	var st := car.sim.state
	for i in 4:
		st.contact[i] = true
		st.load[i] = 9000.0
		st.compression[i] = 0.0
	await physics_frames(30)
	await _frames(5)
	assert_true(fx.floor_sparks == null or fx.floor_sparks.alive_count() == 0, "no sparks at ride height")
	st.compression[0] = car.sim.spec.travel_bump
	st.compression[1] = car.sim.spec.travel_bump
	for w in car.wheels:
		w.surface = &"grass"
	await _seconds(0.2)
	assert_true(fx.floor_sparks == null or fx.floor_sparks.alive_count() == 0, "no sparks off grass")
	for w in car.wheels:
		w.surface = &"asphalt"
	await _seconds(0.2)
	assert_true(fx.floor_sparks != null and fx.floor_sparks.alive_count() > 0, "sparks with the front on its bump stops")
	st.compression[0] = 0.0
	st.compression[1] = 0.0
	await _seconds(0.7)
	assert_true(fx.floor_sparks.alive_count() == 0, "sparks die out once the floor lifts")

func test_arcade_effects_ignore_the_simulation_fields() -> void:
	var r: Array = await _frozen(Car.HANDLING_ARCADE)
	var car: Car = r[1]
	var fx: Node = r[2]
	_move(r[0], car, 40.0)
	for w in car.wheels:
		w.locked = true
		w.slip_ratio = -1.0
		w.slip_angle = 0.6
	await physics_frames(120)
	await _seconds(0.3)
	var e := _emitted(fx)
	assert_true(e[0] + e[1] + e[2] + e[3] == 0 and fx.skid_marks.total_segments_written == 0,
			"arcade effects come from WheelState.slip only")
	assert_true(fx.floor_sparks == null, "no sparks node for an arcade car")

# ================================================================ wheels and body
func test_brake_discs_glow_and_stripes_take_the_compound() -> void:
	var r: Array = await _frozen()
	var car: Car = r[1]
	var fl := car.get_node("WheelFL")
	var rr := car.get_node("WheelRR")
	car.sim.state.brake_temp[0] = 950.0
	car.sim.state.brake_temp[3] = 300.0
	car.tyre_compound = &"hard"
	await _frames(3)
	assert_true(fl.brake_glow > 0.7, "hot front disc glows (%.2f)" % fl.brake_glow)
	assert_true(rr.brake_glow == 0.0, "cool rear disc does not (%.2f)" % rr.brake_glow)
	var disc: StandardMaterial3D = fl._disc_mat
	assert_true(disc != null and disc.emission_enabled and disc.emission_energy_multiplier > 1.0, "disc material is emissive")
	assert_true(rr._disc_mat != null and not rr._disc_mat.emission_enabled, "each wheel has its own disc material")
	var stripe: StandardMaterial3D = fl._stripe_mat
	assert_true(stripe != null and stripe.albedo_color.r > 0.8 and stripe.albedo_color.b > 0.8, "hard tyres carry a white stripe")

	var r2: Array = await _frozen(Car.HANDLING_ARCADE)
	var car2: Car = r2[1]
	await _frames(3)
	var fl2 := car2.get_node("WheelFL")
	assert_true(fl2._disc_mat == null and fl2._stripe_mat == null and fl2.brake_glow == 0.0,
			"an arcade car's wheel materials are left alone")
	var body2 := car2.get_node("BodyVisual")
	assert_true(not body2.is_processing(), "body motion is off for an arcade car")
	assert_true((body2.get_node("Body/Helmet") as Node3D).transform.is_equal_approx(Transform3D.IDENTITY), "arcade helmet untouched")

func test_body_and_wheels_move_by_real_amounts() -> void:
	var car := await SimRig.spawn(self)
	var body := car.get_node("BodyVisual")
	var visuals: Array[Node3D] = []
	for wheel_name: String in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		visuals.append(car.get_node(wheel_name) as Node3D)
	await _frames(2)
	# At rest every tyre stands on the pad (y = 0) and the body is level.
	var rest: Array[float] = []
	for i in 4:
		var bottom := visuals[i].global_position.y - car.wheel_radius(i)
		assert_between(bottom, -0.012, 0.012, "wheel %d tyre bottom above the road at rest (m)" % i)
		rest.append(visuals[i].position.y)

	# Braking from 250 km/h: the nose dips, the front wheels rise in their arches, the helmet nods.
	SimRig.set_speed(car, 250.0)
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(60)
	car.set_input_override(0.0, 1.0, 0.0)
	var dive := 0.0
	var front_travel := 0.0
	var pitch_travel := 0.0
	var nod := 0.0
	var worst_gap := 0.0
	for k in 240:
		await get_tree().physics_frame
		dive = minf(dive, rad_to_deg(asin(clampf(-car.global_transform.basis.z.y, -1.0, 1.0))))
		front_travel = maxf(front_travel, visuals[0].position.y - rest[0])
		# Front against rear at the same instant: the weight moving forward.
		pitch_travel = maxf(pitch_travel, (visuals[0].position.y - rest[0]) - (visuals[2].position.y - rest[2]))
		nod = minf(nod, body.head_nod)
		for i in 4:
			if car.wheels[i].contact:
				worst_gap = maxf(worst_gap, absf(visuals[i].global_position.y - car.wheel_radius(i)))
	print("    sim braking 250 km/h: dive %.2f deg, front wheels +%.1f mm in the arches (%.1f mm more than the rears), helmet nod %.1f deg" % [
			dive, front_travel * 1000.0, pitch_travel * 1000.0, rad_to_deg(nod)])
	assert_between(dive, -2.0, -0.05, "nose dive under braking (deg, small as on the real car)")
	assert_true(front_travel > 0.002, "front wheels travel up in the arches (%.1f mm)" % (front_travel * 1000.0))
	# Downforce presses the whole car down at this speed, so the rears are above their rest
	# position too; the weight moving forward shows as the fronts travelling further.
	assert_true(pitch_travel > 0.002, "fronts travel further than the rears under braking (%.1f mm)" % (pitch_travel * 1000.0))
	assert_between(rad_to_deg(nod), -5.01, -1.0, "helmet nods forward under braking (deg)")
	assert_between(worst_gap, 0.0, 0.02, "tyres stay on the road while the body pitches (m)")

	# Cornering to the right at 180 km/h: the body rolls a little to the left, the helmet leans out.
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(120)
	SimRig.set_speed(car, 180.0)
	var roll := 0.0
	var lean := 0.0
	var outer_travel := 0.0
	for k in 360:
		var err := 50.0 - car.linear_velocity.length()
		car.set_input_override(clampf(0.4 + err * 0.5, 0.0, 1.0), 0.0, minf(k / 240.0, 0.6))
		await get_tree().physics_frame
		# basis.x.y > 0: the right side is up, the body leans left (out of a right-hander).
		roll = maxf(roll, rad_to_deg(asin(clampf(car.global_transform.basis.x.y, -1.0, 1.0))))
		lean = maxf(lean, body.head_lean)
		outer_travel = maxf(outer_travel, visuals[0].position.y - rest[0])
	print("    sim cornering 180 km/h: roll %.2f deg, outer front wheel +%.1f mm, helmet lean %.1f deg" % [
			roll, outer_travel * 1000.0, rad_to_deg(lean)])
	assert_between(roll, 0.03, 2.5, "body roll out of the corner (deg, small as on the real car)")
	assert_true(outer_travel > 0.001, "outer front wheel travels up (%.1f mm)" % (outer_travel * 1000.0))
	assert_between(rad_to_deg(lean), 1.0, 7.01, "helmet leans out of the corner (deg)")
	car.set_input_override(0.0, 0.0, 0.0)
