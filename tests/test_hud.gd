extends TestCase
## HUD: time formatting, race timer start/reset behaviour, speed readout.

const RaceTimer := preload("res://scripts/ui/race_timer.gd")

func _release_all() -> void:
	for a: StringName in [&"accelerate", &"brake", &"steer_left", &"steer_right"]:
		Input.action_release(a)
	Bootstrap.autodrive = false

func test_format_time() -> void:
	assert_true(RaceTimer.format_time(0.0) == "0:00.000", "0 s -> " + RaceTimer.format_time(0.0))
	assert_true(RaceTimer.format_time(61.234) == "1:01.234", "61.234 s -> " + RaceTimer.format_time(61.234))
	assert_true(RaceTimer.format_time(9.9999) == "0:09.999", "truncates, got " + RaceTimer.format_time(9.9999))
	assert_true(RaceTimer.format_time(600.5) == "10:00.500", "600.5 s -> " + RaceTimer.format_time(600.5))
	assert_true(RaceTimer.format_time(-1.0) == "0:00.000", "negative clamps to 0")

func test_timer_logic() -> void:
	var t := RaceTimer.new()
	t.step(0.5, false)
	assert_true(not t.is_running() and t.elapsed == 0.0, "waits without input")
	t.step(0.25, true)
	t.step(0.25, false)
	assert_true(t.is_running(), "keeps running after input released")
	assert_between(t.elapsed, 0.499, 0.501, "elapsed")
	t.reset()
	assert_true(not t.is_running() and t.elapsed == 0.0, "reset")

func test_timer_waits_runs_and_resets() -> void:
	_release_all()
	var main := spawn("res://scenes/main.tscn")
	var hud := main.get_node("UI/HUD")
	var car := main.get_node("Car") as Car
	await physics_frames(120)
	assert_true(hud.timer.elapsed == 0.0, "timer must stay at 0 before any input")
	assert_true(hud.get_time_text() == "0:00.000", "label before input: " + hud.get_time_text())

	Input.action_press(&"accelerate")
	await physics_frames(240)  # 1 s at 240 Hz
	Input.action_release(&"accelerate")
	assert_true(hud.timer.is_running(), "timer runs after input")
	assert_between(hud.timer.elapsed, 0.98, 1.01, "elapsed after 240 ticks")
	await physics_frames(24)
	assert_between(hud.timer.elapsed, 1.07, 1.11, "keeps counting after release")
	await get_tree().process_frame
	assert_true(hud.get_time_text().begins_with("0:01."), "label shows running time: " + hud.get_time_text())

	car.respawn()
	assert_true(hud.timer.elapsed == 0.0 and not hud.timer.is_running(), "respawn resets timer")
	await physics_frames(60)
	await get_tree().process_frame
	assert_true(hud.timer.elapsed == 0.0, "waiting again after respawn")
	assert_true(hud.get_time_text() == "0:00.000", "label after respawn: " + hud.get_time_text())

	Bootstrap.autodrive = true
	await physics_frames(10)
	assert_true(hud.timer.is_running(), "autodrive counts as driver input")
	_release_all()

	# Respawn while throttle is held: the respawn tick itself is not counted,
	# then the clock restarts immediately (Trackmania behaviour).
	Input.action_press(&"accelerate")
	await physics_frames(5)
	car.respawn()
	await physics_frames(1)
	assert_true(hud.timer.elapsed == 0.0, "respawn tick not counted, got %.4f" % hud.timer.elapsed)
	await physics_frames(24)
	assert_true(hud.timer.is_running(), "restarts with throttle held after respawn")
	assert_between(hud.timer.elapsed, 0.09, 0.101, "elapsed after respawn with throttle held")
	_release_all()

func test_speed_label_tracks_car() -> void:
	_release_all()
	var main := spawn("res://scenes/main.tscn")
	var hud := main.get_node("UI/HUD")
	var car := main.get_node("Car") as Car
	# Freeze the car's own update so speed_kmh is a fixed value we control.
	car.simulate = false
	car.speed_kmh = 187.6
	car.rpm = Car.MAX_RPM * 0.97
	car.gear = 5
	await physics_frames(240)
	await get_tree().process_frame
	assert_true(hud.get_speed_text() == "188", "speed label = %s, expected 188" % hud.get_speed_text())
	var gauge: Control = hud.get_node("Speedo")
	assert_between(gauge.get(&"value"), 0.96, 0.98, "rpm arc fill")
	assert_true((hud.get_node("Speedo/Gear") as Label).text == "5", "gear label")
	car.speed_kmh = 0.0
	await physics_frames(240)
	await get_tree().process_frame
	assert_true(hud.get_speed_text() == "0", "speed label settles to 0, got " + hud.get_speed_text())

	# Live: drive, coast, and compare against the car within rounding.
	car.simulate = true
	Input.action_press(&"accelerate")
	await physics_frames(480)
	Input.action_release(&"accelerate")
	await physics_frames(240)
	await get_tree().process_frame
	var shown := float(hud.get_speed_text())
	assert_true(car.speed_kmh > 5.0, "car should be moving")
	# Label is the rounded smoothed value; the smoothing lags a coasting car slightly.
	assert_between(shown, hud.display_speed - 0.56, hud.display_speed + 0.56, "speed label vs smoothed speed")
	var tol := maxf(3.0, car.speed_kmh * 0.1)
	assert_between(shown, car.speed_kmh - tol, car.speed_kmh + tol, "speed label vs car.speed_kmh (%.2f)" % car.speed_kmh)
	_release_all()
