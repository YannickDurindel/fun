extends TestCase
## Loading screen, scene transitions (autoload Transitions) and UI sounds (autoload UISounds).

const LOADING_SCENE := "res://scenes/ui/loading.tscn"
const Loading := preload("res://scripts/ui/loading.gd")

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _current_path() -> String:
	var s := get_tree().current_scene
	return s.scene_file_path if s != null else ""

func test_headless_change_is_instant() -> void:
	assert_true(Transitions.is_instant(), "headless runs use the instant path")
	# Game.scene_changer still captures every change; Transitions is not involved.
	var changes: Array[String] = []
	Game.scene_changer = func(path: String) -> void: changes.append(path)
	Game.pending.track_id = "red_bull_ring"
	Game.start_race()
	Game.restart_race()
	Game.quit_to_menu()
	assert_true(changes == [Game.RACE_SCENE, Game.RACE_SCENE, Game.MENU_SCENE], "scene_changer honoured: %s" % str(changes))
	assert_true(not Transitions.busy and Transitions.loading == null, "no transition started")
	Game.scene_changer = Callable()
	Game.pending = RaceConfig.new()
	Game.config = RaceConfig.new()
	Game.menu_start_screen = ""
	# The instant path: a plain deferred scene change, done by the next frame, no cover left.
	var info := TrackCatalog.find("red_bull_ring")
	assert_true(Transitions.change_scene(Game.MENU_SCENE), "request accepted")
	assert_true(Transitions.change_scene(LOADING_SCENE, info), "no lock when instant: the last request of a frame wins")
	await _frames(2)
	assert_true(_current_path() == LOADING_SCENE, "scene changed at once (%s)" % _current_path())
	assert_true(not Transitions.busy, "lock released")
	assert_true(Transitions.loading == null, "no loading screen on the instant path")
	assert_true(not (Transitions.get_node("Fade") as CanvasItem).visible, "no fade left")
	await Transitions.fade_out(0.5)
	assert_true((Transitions.get_node("Fade") as CanvasItem).visible, "fade_out is immediate when instant")
	await Transitions.fade_in(0.5)
	assert_true(not (Transitions.get_node("Fade") as CanvasItem).visible, "fade_in is immediate when instant")
	get_tree().unload_current_scene()
	await _frames(1)

func test_loading_screen_content() -> void:
	var info := TrackCatalog.find("red_bull_ring")
	var scr := spawn(LOADING_SCENE) as Loading
	scr.setup(info, 0)
	await _frames(1)
	assert_true(scr.name_label.text == "RED BULL RING", "track name: %s" % scr.name_label.text)
	assert_true(scr.grand_prix_label.text == "AUSTRIAN GRAND PRIX", "grand prix: %s" % scr.grand_prix_label.text)
	assert_true(scr.place_label.text == "Spielberg, Austria", "place: %s" % scr.place_label.text)
	assert_true(scr.length_label.text == "4.318 KM", "length: %s" % scr.length_label.text)
	assert_true(scr.turns_label.text == "10", "turns: %s" % scr.turns_label.text)
	assert_true(scr.tip_label.text == Loading.TIPS[0], "tip shown")
	assert_true(scr.map_points.size() >= 100, "map polyline has points (%d)" % scr.map_points.size())
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in scr.map_points:
		lo = lo.min(p)
		hi = hi.max(p)
	assert_between(maxf(hi.x - lo.x, hi.y - lo.y), 0.99, 1.01, "map normalised to a unit box")
	assert_between(minf(hi.x - lo.x, hi.y - lo.y), 0.2, 1.01, "map is a 2D outline")
	# Progress: snapped, clamped, then gliding.
	scr.set_progress(0.5, true)
	assert_between(scr.bar_ratio, 0.499, 0.501, "bar snapped to 50%")
	assert_between(scr.bar_fill.anchor_right, 0.499, 0.501, "bar fill follows")
	assert_true(scr.percent_label.text == "50%", "percent text: %s" % scr.percent_label.text)
	await _frames(1)
	assert_between(scr.bar_fill.size.x / scr.bar.size.x, 0.49, 0.51, "fill is half the bar wide")
	scr.set_progress(7.0)
	assert_between(scr.progress, 1.0, 1.0, "progress clamped")
	assert_between(scr.bar_ratio, 0.499, 0.501, "bar glides, it does not jump")
	await get_tree().create_timer(0.6).timeout
	await _frames(2)
	assert_between(scr.bar_ratio, 0.95, 1.0, "bar reached the target")
	scr.set_progress(0.0, true)
	assert_true(scr.bar_ratio == 0.0 and scr.percent_label.text == "0%", "bar back to zero")
	scr.set_phase("BUILDING TRACK")
	assert_true(scr.phase_label.text == "BUILDING TRACK", "phase caption")
	# A track without data still shows its texts.
	var bare := TrackInfo.new()
	bare.name = "Autodromo Internazionale Enzo e Dino Ferrari"
	bare.length_m = 4909.0
	bare.turns = 19
	scr.setup(bare)
	assert_true(scr.map_points.is_empty() and scr.turns_label.text == "19", "bare track handled")
	assert_true(scr.name_label.get_theme_font_size(&"font_size") < Loading.TITLE_SIZE, "long names shrink")

func test_best_lap_record() -> void:
	var path := "user://m10_test_best.json"
	assert_between(Loading.read_best_lap(path + ".missing"), -1.0, -1.0, "no file, no record")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"track": "x", "best_lap": 71.234, "best_splits": []}))
	f.close()
	assert_between(Loading.read_best_lap(path), 71.233, 71.235, "best lap read")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	assert_between(Loading.read_best_lap(path), -1.0, -1.0, "broken file ignored")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_animated_change_and_reentrancy() -> void:
	var saved := [Transitions.fade_out_time, Transitions.fade_in_time, Transitions.cross_time, Transitions.min_loading_time]
	Transitions.instant_override = 0
	Transitions.fade_out_time = 0.03
	Transitions.fade_in_time = 0.03
	Transitions.cross_time = 0.02
	Transitions.min_loading_time = 0.1
	var done: Array[String] = []
	var on_done := func(path: String) -> void: done.append(path)
	Transitions.finished.connect(on_done)
	var info := TrackInfo.new()   # no scene of its own: only the target scene is loaded
	info.name = "Test Ring"
	assert_true(Transitions.change_scene(LOADING_SCENE, info), "first request accepted")
	assert_true(Transitions.busy, "busy at once")
	assert_true(not Transitions.change_scene(Game.MENU_SCENE), "second request ignored while busy")
	# Fade out, loading screen, threaded load, swap: then it waits for Game.race_ready.
	var saw_loading := false
	var deadline := Time.get_ticks_msec() + 8000
	while _current_path() != LOADING_SCENE and Time.get_ticks_msec() < deadline:
		saw_loading = saw_loading or Transitions.loading != null
		await _frames(1)
	assert_true(_current_path() == LOADING_SCENE, "first request won (%s)" % _current_path())
	assert_true(saw_loading, "loading screen was shown")
	await _frames(10)
	assert_true(Transitions.busy and Transitions.loading != null, "loading screen held until the race is ready")
	assert_true(get_tree().paused, "the scene is frozen under the cover")
	assert_true(Transitions.loading.name_label.text == "TEST RING", "loading screen shows the track")
	assert_true(not Transitions.change_scene(Game.MENU_SCENE), "still ignoring requests")
	Game.notify_race_ready()
	deadline = Time.get_ticks_msec() + 8000
	while Transitions.busy and Time.get_ticks_msec() < deadline:
		await _frames(1)
	assert_true(not Transitions.busy, "transition finished")
	assert_true(not get_tree().paused, "the scene runs again")
	assert_true(done == [LOADING_SCENE], "finished emitted once for the first request: %s" % str(done))
	assert_true(Transitions.loading == null, "loading screen removed")
	assert_true(not (Transitions.get_node("Fade") as CanvasItem).visible, "fade lifted")
	assert_true(_current_path() == LOADING_SCENE, "scene unchanged by the ignored requests")
	assert_true(Transitions.last_change_msec >= 100, "minimum display time respected (%d ms)" % Transitions.last_change_msec)
	Transitions.finished.disconnect(on_done)
	Transitions.instant_override = -1
	Transitions.fade_out_time = saved[0]
	Transitions.fade_in_time = saved[1]
	Transitions.cross_time = saved[2]
	Transitions.min_loading_time = saved[3]
	get_tree().unload_current_scene()
	await _frames(1)

func test_ui_sound_streams() -> void:
	assert_true(UISounds.SOUNDS.size() == 5, "five sounds")
	for sound in UISounds.SOUNDS:
		var wav := UISounds.stream(sound)
		assert_true(wav != null and wav.format == AudioStreamWAV.FORMAT_16_BITS and not wav.stereo, "%s is a mono 16-bit stream" % sound)
		if wav == null:
			continue
		var n := wav.data.size() / 2
		var peak := 0.0
		var sum := 0.0
		for i in n:
			var v := wav.data.decode_s16(i * 2) / 32768.0
			peak = maxf(peak, absf(v))
			sum += v * v
		var rms := sqrt(sum / maxi(n, 1))
		var seconds := float(n) / wav.mix_rate
		assert_between(peak, 0.3, 0.9, "%s peak (no clipping)" % sound)
		assert_between(rms, 0.03, 0.6, "%s rms (not silent)" % sound)
		assert_between(seconds, 0.02, 1.0, "%s is short" % sound)
		assert_between(absf(wav.data.decode_s16(0) / 32768.0), 0.0, 0.02, "%s starts at zero (no click)" % sound)
		assert_between(absf(wav.data.decode_s16((n - 1) * 2) / 32768.0), 0.0, 0.02, "%s ends at zero (no click)" % sound)
	assert_true(UISounds.stream(&"focus").data.size() < UISounds.stream(&"start_race").data.size(), "the tick is shorter than the whoosh")
	# play() works with the dummy driver and reports what it started.
	var heard: Array[StringName] = []
	var on_played := func(sound: StringName) -> void: heard.append(sound)
	UISounds.played.connect(on_played)
	for sound in UISounds.SOUNDS:
		UISounds.play(sound)
		await _frames(1)
	assert_true(heard == UISounds.SOUNDS, "every sound played: %s" % str(heard))
	# The race-start whoosh replaces the click of the same frame.
	heard.clear()
	UISounds.play(&"start_race")
	UISounds.play(&"accept")
	assert_true(heard == [&"start_race"], "accept is dropped under start_race: %s" % str(heard))
	assert_true(UISounds.stream(&"nope") == null, "unknown sound has no stream")
	# Without a UI bus, Settings audio/ui scales the sound; 0 mutes it.
	if AudioServer.get_bus_index(&"UI") < 0:
		await _frames(1)
		heard.clear()
		Settings.set_value("audio", "ui", 0.0)
		UISounds.play(&"accept")
		assert_true(heard.is_empty(), "muted by Settings audio/ui")
		Settings.reset("audio")
	UISounds.played.disconnect(on_played)

func test_ui_sound_hooks() -> void:
	await get_tree().create_timer(0.1).timeout   # clear of the previous test's sounds
	var heard: Array[StringName] = []
	var on_played := func(sound: StringName) -> void: heard.append(sound)
	UISounds.played.connect(on_played)
	var box := VBoxContainer.new()
	add_child(box)
	var buttons: Array[Button] = []
	for text: String in ["PLAY", "OPTIONS", "BACK"]:
		var b := Button.new()
		b.text = text
		box.add_child(b)
		buttons.append(b)
	await _frames(1)
	buttons[0].grab_focus()
	assert_true(heard.is_empty(), "the first focus of a screen is silent: %s" % str(heard))
	await get_tree().create_timer(0.06).timeout
	buttons[1].grab_focus()
	assert_true(heard == [&"focus"], "moving the focus ticks: %s" % str(heard))
	await _frames(1)
	buttons[1].pressed.emit()
	assert_true(heard == [&"focus", &"accept"], "a press confirms: %s" % str(heard))
	await _frames(1)
	buttons[2].pressed.emit()
	assert_true(heard == [&"focus", &"accept", &"back"], "a BACK button plays back: %s" % str(heard))
	# A screen change silences the next focus.
	await get_tree().create_timer(0.06).timeout
	UISounds.screen_changed()
	buttons[0].grab_focus()
	assert_true(heard.size() == 3, "focus after a screen change is silent: %s" % str(heard))
	# Hidden UI (a HUD under a race, a closed overlay) makes no focus sound.
	await get_tree().create_timer(0.3).timeout
	box.visible = false
	buttons[1].grab_focus()
	assert_true(heard.size() == 3, "hidden controls are silent: %s" % str(heard))
	box.visible = true
	# Hooks can be switched off.
	UISounds.hooks_enabled = false
	buttons[0].pressed.emit()
	assert_true(heard.size() == 3, "hooks disabled: %s" % str(heard))
	UISounds.hooks_enabled = true
	# Re-entering the tree does not connect twice.
	box.remove_child(buttons[0])
	box.add_child(buttons[0])
	await _frames(1)
	buttons[0].pressed.emit()
	assert_true(heard.size() == 4 and heard[3] == &"accept", "one sound per press after re-adding: %s" % str(heard))
	UISounds.played.disconnect(on_played)
