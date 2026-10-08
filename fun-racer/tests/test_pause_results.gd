extends TestCase
## Pause menu, race mode (finish after N laps), the results screen and time attack staying endless.

const SCENE := "res://scenes/race_red_bull_ring.tscn"

var _scene: Node
var race: RaceManager
var car: Car
var data: TrackData
var pause: Control
var results: Control
var _changes: Array[String] = []

func _setup(target_laps: int = 0, countdown: bool = false) -> void:
	Bootstrap.autodrive = false
	Bootstrap.skip_countdown = not countdown
	Game.set_paused(false)
	Game.config = RaceConfig.new()
	Game.config.mode = RaceConfig.MODE_RACE if target_laps > 0 else RaceConfig.MODE_TIME_ATTACK
	Game.config.laps = maxi(target_laps, 1)
	_changes.clear()
	Game.scene_changer = func(path: String) -> void: _changes.append(path)
	_scene = spawn(SCENE)
	race = _scene.get_node("Track/Race") as RaceManager
	car = _scene.get_node("Car") as Car
	pause = _scene.get_node("UI/PauseMenu") as Control
	results = _scene.get_node("UI/Results") as Control
	data = race.data
	race.persist_best = false
	race.clear_best()
	race.previous_best = -1.0

func _teardown() -> void:
	Game.set_paused(false)
	Game.scene_changer = Callable()
	Game.config = RaceConfig.new()
	Game.menu_start_screen = ""
	Bootstrap.skip_countdown = true
	if car != null and is_instance_valid(car):
		car.clear_input_override()

func _press(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	get_viewport().push_input(ev)

## Teleports the frozen car along the centreline (see test_race.gd).
func _drive(s_from: float, s_to: float, step: float = 25.0) -> int:
	car.simulate = false
	car.linear_velocity = Vector3.ZERO
	var ticks := 0
	var x := s_from
	while x < s_to:
		x = minf(x + step, s_to)
		car.global_transform = race.track.spawn_transform(x)
		await get_tree().physics_frame
		ticks += 1
	return ticks

func test_pause_action_pauses_and_resumes() -> void:
	_setup()
	await physics_frames(5)
	assert_true(InputMap.has_action(&"pause"), "pause action registered")
	assert_true(pause.is_in_group(&"pause_menu"), "joins the pause_menu group")
	assert_true(not pause.visible and not get_tree().paused, "running at first")
	_press(&"pause")
	assert_true(get_tree().paused, "pause action pauses the tree")
	assert_true(pause.visible, "overlay shown")
	assert_true(pause.call(&"get_track_text") == "RED BULL RING", "track name: " + String(pause.call(&"get_track_text")))
	assert_true(String(pause.call(&"get_info_text")).contains("LAP 1"), "lap info: " + String(pause.call(&"get_info_text")))
	var resume := pause.call(&"button", "resume") as Button
	assert_true(get_viewport().gui_get_focus_owner() == resume, "focus on RESUME")
	assert_true((pause.call(&"button", "end_session") as Button).visible, "time attack offers END SESSION")
	var engine := _scene.get_node("EngineAudio/EnginePlayer") as AudioStreamPlayer
	assert_true(not engine.can_process(), "engine audio stops processing while paused")
	_press(&"pause")
	assert_true(not get_tree().paused and not pause.visible, "pause again resumes")
	_press(&"ui_cancel")
	assert_true(not get_tree().paused and not pause.visible, "ui_cancel (menu back) never opens the pause menu")
	_press(&"pause")
	assert_true(get_tree().paused and pause.visible, "paused again")
	_press(&"ui_cancel")
	assert_true(not get_tree().paused and not pause.visible, "ui_cancel closes the pause menu")
	pause.call(&"open")
	resume.pressed.emit()
	assert_true(not get_tree().paused and not pause.visible, "RESUME unpauses")
	assert_true(_changes.is_empty(), "no scene change: %s" % str(_changes))
	_teardown()

func test_paused_car_and_clock_freeze() -> void:
	_setup()
	car.set_input_override(1.0, 0.0, 0.0)
	await physics_frames(240)
	assert_true(car.linear_velocity.length() > 3.0, "car is driving")
	pause.call(&"open")
	await physics_frames(2)
	var p0 := car.global_position
	var t0 := race.race_time
	var lt0 := race.lap_time()
	await physics_frames(240)
	assert_true(get_tree().paused, "still paused")
	assert_true(car.global_position.distance_to(p0) < 0.001, "car frozen while paused (moved %.3f m)" % car.global_position.distance_to(p0))
	assert_true(race.race_time == t0 and race.lap_time() == lt0, "race clock frozen while paused")
	pause.call(&"resume")
	await physics_frames(120)
	assert_true(car.global_position.distance_to(p0) > 1.0, "car moves again after resume")
	assert_between(race.race_time - t0, 0.45, 0.55, "clock resumed where it stopped")
	_teardown()

func test_countdown_freezes_while_paused() -> void:
	_setup(0, true)
	await physics_frames(60)
	assert_true(race.state == RaceManager.State.COUNTDOWN, "counting down")
	pause.call(&"open")
	await physics_frames(2)
	var left := race.countdown_left
	await physics_frames(720)   # longer than the whole countdown
	assert_true(race.state == RaceManager.State.COUNTDOWN and race.countdown_left == left, "countdown frozen while paused")
	assert_true(String(pause.call(&"get_info_text")).contains("ON THE GRID"), "info: " + String(pause.call(&"get_info_text")))
	pause.call(&"resume")
	await physics_frames(int(left * 240.0) + 10)
	assert_true(race.state == RaceManager.State.RACING, "GO after resuming")
	_teardown()

func test_restart_from_pause() -> void:
	_setup(0, true)
	race.start_now()
	await _drive(race.s, race.checkpoints[1] + 10.0)
	assert_true(race.next_checkpoint == 2, "two checkpoints passed")
	pause.call(&"open")
	assert_true(get_tree().paused, "paused")
	(pause.call(&"button", "restart") as Button).pressed.emit()
	assert_true(not get_tree().paused and not pause.visible, "restart unpauses")
	assert_true(race.state == RaceManager.State.COUNTDOWN or race.state == RaceManager.State.RACING, "countdown / racing after restart")
	assert_true(race.state == RaceManager.State.COUNTDOWN, "full restart: new countdown")
	assert_true(race.next_checkpoint == 0 and race.laps_completed == 0 and race.race_time == 0.0, "lap reset")
	assert_true(car.global_position.distance_to(race._grid.origin) < 0.1, "back on the grid")
	assert_true(_changes.is_empty(), "restart keeps the scene: %s" % str(_changes))
	_teardown()

func test_pause_menu_quits() -> void:
	_setup()
	await physics_frames(3)
	pause.call(&"open")
	(pause.call(&"button", "tracks") as Button).pressed.emit()
	assert_true(_changes == [Game.MENU_SCENE] and Game.menu_start_screen == "tracks", "TRACK SELECT -> track list: %s" % str(_changes))
	assert_true(not get_tree().paused and not pause.visible, "quitting unpauses")
	pause.call(&"open")
	(pause.call(&"button", "menu") as Button).pressed.emit()
	assert_true(_changes.size() == 2 and Game.menu_start_screen == "", "MAIN MENU -> main screen")
	assert_true(not get_tree().paused, "unpaused")
	_teardown()

func test_options_overlay() -> void:
	_setup()
	await physics_frames(3)
	pause.call(&"open")
	(pause.call(&"button", "options") as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(bool(pause.call(&"is_options_open")), "options overlay open")
	assert_true(get_tree().paused, "still paused in the options")
	_press(&"pause")
	assert_true(get_tree().paused and bool(pause.call(&"is_options_open")), "pause key ignored while the options are open")
	pause.call(&"close_options")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(not bool(pause.call(&"is_options_open")) and pause.visible and get_tree().paused, "back on the pause menu")
	assert_true(get_viewport().gui_get_focus_owner() == pause.call(&"button", "options"), "focus returns to OPTIONS")
	pause.call(&"resume")
	_teardown()

func test_race_mode_finishes_after_target_laps() -> void:
	_setup(2)
	assert_true(race.target_laps == 2, "target laps from the config (%d)" % race.target_laps)
	assert_true(not (pause.call(&"button", "end_session") as Button).visible or not pause.visible, "pause menu closed")
	var got: Array[Dictionary] = []
	race.race_finished.connect(func(res: Dictionary) -> void: got.append(res))
	await get_tree().process_frame
	await get_tree().process_frame
	var panel := _scene.get_node("UI/RacePanel")
	assert_true(panel.call(&"get_lap_text") == "LAP 1 / 2", "lap counter: " + String(panel.call(&"get_lap_text")))
	var s0 := race.s
	await _drive(s0, data.length + 20.0, 25.0)
	assert_true(race.laps_completed == 1 and got.is_empty(), "one lap: not finished yet")
	assert_true(race.state == RaceManager.State.RACING, "still racing")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(panel.call(&"get_lap_text") == "LAP 2 / 2", "lap counter: " + String(panel.call(&"get_lap_text")))
	await _drive(data.length + 20.0, data.length * 2.0 + 20.0, 40.0)
	assert_true(got.size() == 1, "race_finished emitted once (%d)" % got.size())
	assert_true(race.state == RaceManager.State.FINISHED and race.is_finished(), "state FINISHED")
	if got.size() == 1:
		var res := got[0]
		var laps: Array = res["laps"]
		assert_true(laps.size() == 2, "two lap times (%d)" % laps.size())
		assert_true(res["track_id"] == "red_bull_ring" and res["mode"] == RaceConfig.MODE_RACE, "track and mode")
		if laps.size() == 2:
			assert_true(float(laps[1]) < float(laps[0]), "lap 2 was the faster one")
			assert_between(float(res["best"]), float(laps[1]) - 1e-5, float(laps[1]) + 1e-5, "best lap")
			assert_true(int(res["best_lap_index"]) == 1, "best lap index")
			assert_between(float(res["total"]), float(laps[0]) + float(laps[1]) - 1e-4, float(laps[0]) + float(laps[1]) + 1e-4, "total")
			assert_between(float(laps[0]), race.lap_times[0] - 1e-5, race.lap_times[0] + 1e-5, "lap 1 matches lap_times")
		assert_true(bool(res["is_record"]) and float(res["previous_best"]) < 0.0, "first best lap is a record")
		var sectors: Array = res["sectors_best"]
		assert_true(sectors.size() == 3 and float(sectors[0]) > 0.0 and float(sectors[2]) > 0.0, "sector bests: %s" % str(sectors))
		var lap_sectors: Array = res["lap_sectors"]
		assert_true(lap_sectors.size() == 2 and (lap_sectors[1] as Array).size() == 3, "sectors per lap")
	var time_at_finish := race.lap_time()
	# Further line crossings do not count.
	await _drive(data.length * 2.0 + 20.0, data.length * 3.0 + 20.0, 40.0)
	assert_true(race.laps_completed == 2 and race.lap_times.size() == 2, "no lap counted after the finish (%d)" % race.laps_completed)
	assert_true(got.size() == 1, "race_finished not emitted again")
	assert_true(race.lap_time() == time_at_finish, "clock stopped at the finish")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(panel.call(&"get_lap_text") == "FINISHED", "panel shows FINISHED: " + String(panel.call(&"get_lap_text")))
	# No pausing once the run is over.
	_press(&"pause")
	assert_true(not get_tree().paused and not pause.visible, "no pause after the finish")
	# A restart starts a fresh run.
	race.restart()
	assert_true(race.state == RaceManager.State.RACING and race.laps_completed == 0 and race.lap_times.is_empty(), "restart resets the run")
	assert_true(race.previous_best > 0.0, "the record to beat is now the best lap")
	_teardown()

func test_finished_car_coasts_to_a_stop() -> void:
	_setup(1)
	await physics_frames(2)
	await _drive(race.s, data.length - 30.0, 25.0)
	assert_true(race.next_checkpoint == race.checkpoints.size(), "all checkpoints passed")
	# Cross the line driving at 30 m/s with the throttle held.
	car.global_transform = race.track.spawn_transform(data.length - 20.0)
	await get_tree().physics_frame
	car.simulate = true
	car.linear_velocity = -car.global_transform.basis.z * 30.0
	Bootstrap.autodrive = true     # no provider: full throttle
	for i in 600:
		await get_tree().physics_frame
		if race.state == RaceManager.State.FINISHED:
			break
	assert_true(race.state == RaceManager.State.FINISHED, "finished after one lap")
	var v0 := car.linear_velocity.length()
	await physics_frames(240)
	assert_true(car.throttle == 0.0, "inputs neutralised after the finish")
	var v1 := car.linear_velocity.length()
	assert_true(v1 < v0 - 2.0, "slowing down (%.1f -> %.1f m/s)" % [v0, v1])
	await physics_frames(2400)
	assert_true(car.linear_velocity.length() < 0.5, "stopped (%.2f m/s)" % car.linear_velocity.length())
	assert_true(car.gear != -1, "never reverses")
	assert_true(absf(data.lateral_offset(car.global_position)) < 8.0, "stayed on the road (%.1f m)" % data.lateral_offset(car.global_position))
	Bootstrap.autodrive = false
	race.restart()
	await physics_frames(5)
	assert_true(car.simulate and race.state == RaceManager.State.RACING, "restart gives the car back")
	_teardown()

func test_results_overlay() -> void:
	_setup(1)
	await physics_frames(2)
	assert_true(not results.visible, "hidden during the race")
	await _drive(race.s, data.length + 20.0, 25.0)
	assert_true(race.state == RaceManager.State.FINISHED, "finished")
	assert_true(not results.visible, "not shown immediately")
	await physics_frames(360)
	assert_true(results.visible and bool(results.call(&"is_open")), "results shown about a second later")
	assert_true(not get_tree().paused, "the scene keeps running behind the results")
	assert_true(int(results.call(&"lap_row_count")) == 1, "one lap row")
	assert_true(bool(results.call(&"is_record_shown")), "NEW RECORD badge")
	var retry := results.call(&"button", "retry") as Button
	assert_true(get_viewport().gui_get_focus_owner() == retry, "focus on RETRY")
	assert_true(not _scene.get_node("UI/RacePanel").visible, "race panel hidden behind the results")
	_press(&"pause")
	assert_true(not get_tree().paused and not pause.visible, "no pause on the results screen")
	retry.pressed.emit()
	assert_true(_changes == [Game.RACE_SCENE], "RETRY reloads the race: %s" % str(_changes))
	(results.call(&"button", "tracks") as Button).pressed.emit()
	assert_true(_changes.back() == Game.MENU_SCENE and Game.menu_start_screen == "tracks", "TRACK SELECT")
	(results.call(&"button", "menu") as Button).pressed.emit()
	assert_true(_changes.size() == 3 and _changes.back() == Game.MENU_SCENE and Game.menu_start_screen == "", "MAIN MENU")
	# A restart (Del) closes the screen.
	race.restart()
	assert_true(not results.visible and _scene.get_node("UI/RacePanel").visible, "restart closes the results")
	_teardown()

func test_results_content_and_record_badge() -> void:
	_setup(1)
	await physics_frames(2)
	var demo: Dictionary = results.call(&"demo_results")
	results.call(&"show_results", demo)
	assert_true(results.visible and int(results.call(&"lap_row_count")) == 5, "five lap rows")
	assert_true(bool(results.call(&"is_record_shown")), "record badge for a new record")
	demo["is_record"] = false
	demo["previous_best"] = 60.0
	results.call(&"show_results", demo)
	assert_true(not bool(results.call(&"is_record_shown")), "no badge when the record stands")
	results.call(&"close")
	assert_true(not results.visible, "closed")
	_teardown()

func test_record_needs_to_beat_previous_best() -> void:
	_setup(1)
	await physics_frames(2)
	race.best_lap = 0.1          # an unbeatable saved record
	race.restart()
	var got: Array[Dictionary] = []
	race.race_finished.connect(func(res: Dictionary) -> void: got.append(res))
	await _drive(race.s, data.length + 20.0, 25.0)
	assert_true(got.size() == 1, "finished")
	if got.size() == 1:
		assert_true(not bool(got[0]["is_record"]), "slower than the saved best: no record")
		assert_between(float(got[0]["previous_best"]), 0.099, 0.101, "previous best reported")
	_teardown()

func test_time_attack_never_finishes() -> void:
	_setup(0)
	assert_true(race.target_laps == 0, "time attack: no lap target")
	var got: Array[Dictionary] = []
	race.race_finished.connect(func(res: Dictionary) -> void: got.append(res))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(_scene.get_node("UI/RacePanel").call(&"get_lap_text") == "LAP 1", "plain lap counter")
	await _drive(race.s, data.length * 3.0 + 20.0, 45.0)
	assert_true(race.laps_completed == 3, "three laps (%d)" % race.laps_completed)
	assert_true(got.is_empty() and race.state == RaceManager.State.RACING, "time attack never finishes")
	await physics_frames(300)
	assert_true(not results.visible, "no results screen")
	# END SESSION from the pause menu shows the results with the laps so far.
	pause.call(&"open")
	var end := pause.call(&"button", "end_session") as Button
	assert_true(end.visible, "END SESSION offered in time attack")
	end.pressed.emit()
	assert_true(not get_tree().paused, "unpaused")
	assert_true(got.size() == 1 and race.state == RaceManager.State.FINISHED, "session ended")
	if got.size() == 1:
		assert_true((got[0]["laps"] as Array).size() == 3 and got[0]["mode"] == RaceConfig.MODE_TIME_ATTACK, "three laps reported")
	await physics_frames(360)
	assert_true(results.visible and int(results.call(&"lap_row_count")) == 3, "results list the three laps")
	_teardown()
