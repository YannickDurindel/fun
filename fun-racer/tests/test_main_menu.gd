extends TestCase
## Title screen (scenes/menu/main_menu.tscn) and the shared 3D backdrop.

var _changes: Array[String] = []

func _open_menu() -> MenuRouter:
	_changes.clear()
	Game.scene_changer = func(path: String) -> void: _changes.append(path)
	Bootstrap.start_screen = ""
	Game.menu_start_screen = ""
	var menu := spawn(Game.MENU_SCENE) as MenuRouter
	await get_tree().process_frame
	await get_tree().process_frame
	return menu

func _close_menu(menu: MenuRouter) -> void:
	menu.queue_free()
	await get_tree().process_frame
	Game.scene_changer = Callable()
	Game.pending = RaceConfig.new()
	Game.config = RaceConfig.new()
	Game.menu_start_screen = ""
	Settings.set_value("gameplay", "last_race", {})

func _press(action: StringName) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await get_tree().process_frame

func test_opens_on_main_with_focus() -> void:
	var menu := await _open_menu()
	assert_true(menu.current_name == "main", "menu opens on main (%s)" % menu.current_name)
	var main := menu.current as MainMenu
	assert_true(main != null, "main screen is the MainMenu")
	if main != null:
		var focused := menu.get_viewport().gui_get_focus_owner()
		assert_true(focused is Button and main.buttons.has(focused), "a menu button has focus: %s" % str(focused))
		assert_true(focused == main.buttons[0], "the first button is focused")
		var texts: Array[String] = []
		for b in [main.play_button, main.records_button, main.options_button, main.quit_button]:
			assert_true(b != null and b.focus_mode == Control.FOCUS_ALL, "button exists and is focusable")
			if b != null:
				texts.append(b.text)
		assert_true(texts == ["PLAY", "RECORDS", "OPTIONS", "QUIT"], "button captions: %s" % str(texts))
		assert_true(main.version_label.text.begins_with("v") and main.version_label.text.length() > 1, "version label")
		assert_true(not main.hint_label.text.is_empty(), "hint footer")
	await _close_menu(menu)

func test_buttons_navigate() -> void:
	var menu := await _open_menu()
	var targets := {"play_button": "tracks", "records_button": "records", "options_button": "settings"}
	for prop: String in targets:
		var main := menu.current as MainMenu
		assert_true(main != null, "back on the main screen before pressing %s" % prop)
		if main == null:
			break
		(main.get(prop) as Button).pressed.emit()
		assert_true(menu.current_name == targets[prop], "%s opens %s (got %s)" % [prop, targets[prop], menu.current_name])
		menu.back()
		assert_true(menu.current_name == "main", "back returns to main")
		await get_tree().process_frame
		await get_tree().process_frame
		main = menu.current as MainMenu
		assert_true(menu.get_viewport().gui_get_focus_owner() == main.get(prop), "focus returns to %s" % prop)
	assert_true(_changes.is_empty(), "navigation does not change scene")
	await _close_menu(menu)

func test_keyboard_navigation() -> void:
	var menu := await _open_menu()
	var main := menu.current as MainMenu
	var vp := menu.get_viewport()
	var n := main.buttons.size()
	main.buttons[0].grab_focus()
	await _press(&"ui_down")
	assert_true(vp.gui_get_focus_owner() == main.buttons[1], "down moves to the next button")
	await _press(&"ui_up")
	await _press(&"ui_up")
	assert_true(vp.gui_get_focus_owner() == main.buttons[n - 1], "up from the top wraps to QUIT")
	await _press(&"ui_right")
	assert_true(vp.gui_get_focus_owner() == main.buttons[n - 1], "left/right keep the focus in the column")
	await _press(&"ui_down")
	assert_true(vp.gui_get_focus_owner() == main.buttons[0], "down from the bottom wraps to the top")
	# Esc on the title screen neither leaves it nor quits.
	await _press(&"ui_cancel")
	assert_true(menu.current_name == "main" and is_instance_valid(main) and main.is_inside_tree(), "Esc stays on main")
	# Enter activates the focused button.
	main.play_button.grab_focus()
	await _press(&"ui_accept")
	assert_true(menu.current_name == "tracks", "Enter on PLAY opens tracks (%s)" % menu.current_name)
	await _close_menu(menu)

func test_hint_follows_input_device() -> void:
	var menu := await _open_menu()
	var main := menu.current as MainMenu
	var keyboard_hint := main.hint_label.text
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_DPAD_DOWN
	pad.pressed = true
	main._input(pad)
	assert_true(main.using_gamepad and main.hint_label.text != keyboard_hint, "hint switches to gamepad glyphs")
	assert_true(main.hint_label.text == MainMenu.hint_text(true), "gamepad hint text")
	var key := InputEventKey.new()
	key.keycode = KEY_DOWN
	key.pressed = true
	main._input(key)
	assert_true(not main.using_gamepad and main.hint_label.text == keyboard_hint, "hint switches back to keyboard")
	await _close_menu(menu)

func test_continue_starts_last_race() -> void:
	Game.pending = RaceConfig.new()
	Game.pending.track_id = "red_bull_ring"
	Game.pending.mode = RaceConfig.MODE_RACE
	Game.pending.laps = 4
	Game.pending.bots = 2
	Settings.set_value("gameplay", "last_race", Game.pending.to_dict())
	# Options edited in the menus afterwards (but never raced) do not change CONTINUE.
	Game.pending.laps = 9
	Game.pending.mode = RaceConfig.MODE_TIME_ATTACK
	var menu := await _open_menu()
	var main := menu.current as MainMenu
	assert_true(main.continue_button != null, "continue button shown after a race")
	if main.continue_button != null:
		assert_true(main.buttons[0] == main.continue_button, "continue is the first button")
		assert_true(menu.get_viewport().gui_get_focus_owner() == main.continue_button, "continue has the initial focus")
		var caption := main.continue_button.get_node("Caption") as Label
		assert_true(caption.text == "CONTINUE: RED BULL RING", "caption: %s" % caption.text)
		var details := (main.continue_button.get_node("Details") as Label).text
		assert_true(details.contains("RACE") and details.contains("4 LAPS") and details.contains("2 BOTS"), "details: %s" % details)
		main.continue_button.pressed.emit()
		assert_true(_changes == [Game.RACE_SCENE], "continue loads the race scene: %s" % str(_changes))
		assert_true(Game.config.track_id == "red_bull_ring" and Game.config.laps == 4, "pending config handed over")
	await _close_menu(menu)

func test_continue_hidden_and_best_lap() -> void:
	Game.pending = RaceConfig.new()
	Game.pending.track_id = "monza"   # listed but not playable
	Settings.set_value("gameplay", "last_race", {"track_id": "monza"})
	assert_true(MainMenu.last_race() == null, "no continue for an unavailable track")
	var menu := await _open_menu()
	var main := menu.current as MainMenu
	assert_true(main.continue_button == null and main.buttons[0] == main.play_button, "PLAY is first without a continue")
	await _close_menu(menu)
	# Best lap parsing, on a throw-away TrackInfo so the player's real file is left alone.
	var fake := TrackInfo.new()
	fake.id = "m1_test_track"
	assert_true(MainMenu.best_lap(fake) < 0.0, "no file: no best lap")
	var f := FileAccess.open(fake.best_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify({"best_lap": 65.432}))
	f.close()
	assert_between(MainMenu.best_lap(fake), 65.431, 65.433, "best lap read from the file")
	var cfg := RaceConfig.new()
	assert_true(MainMenu.continue_details(fake, cfg).contains("BEST 1:05.432"), "best lap shown: %s" % MainMenu.continue_details(fake, cfg))
	f = FileAccess.open(fake.best_path(), FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	assert_true(MainMenu.best_lap(fake) < 0.0, "corrupt file: no best lap")
	DirAccess.remove_absolute(fake.best_path())

func test_backdrop() -> void:
	var menu := await _open_menu()
	var backdrop := menu.get_node_or_null("Backdrop") as MenuBackdrop
	assert_true(backdrop != null and backdrop.get_index() == 0, "Backdrop is the first child of the menu")
	if backdrop != null:
		assert_true(backdrop.viewport != null and backdrop.camera != null and backdrop.camera.current, "3D view built")
		assert_true(backdrop.car_root.get_child_count() == 5, "car body + 4 wheels")
		assert_between(backdrop.car_root.get_node("Wheel0").position.y, -0.04, -0.02, "front wheel rests on the floor")
		assert_true(backdrop.mouse_filter == Control.MOUSE_FILTER_IGNORE, "backdrop does not eat mouse input")
		var before := backdrop.camera.global_position
		await physics_frames(20)
		await get_tree().process_frame
		assert_true(backdrop.camera.global_position.distance_to(before) > 0.0001, "camera orbits")
		assert_between(backdrop.dim, -0.001, 0.001, "full view on main")
		# The router's screen_changed drives the dim (animated).
		menu.go("records")
		for i in 600:
			if backdrop.dim >= MenuBackdrop.DIM_SUB - 0.01:
				break
			await get_tree().process_frame
		assert_between(backdrop.dim, MenuBackdrop.DIM_SUB - 0.01, MenuBackdrop.DIM_SUB + 0.01, "router dims the backdrop on records")
		menu.back()
		for i in 600:
			if backdrop.dim <= 0.01:
				break
			await get_tree().process_frame
		assert_between(backdrop.dim, -0.001, 0.01, "full view again back on main")
		Settings.set_value("graphics", "render_scale", 0.5)
		assert_between(backdrop.viewport.scaling_3d_scale, 0.37, 0.38, "render scale setting applied")
		Settings.reset("graphics")
		backdrop.set_dim(1.0, true)
		assert_true(backdrop.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "fully dimmed: stops rendering")
		backdrop.set_dim(0.0, true)
		assert_true(backdrop.viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "rendering resumes")
	await _close_menu(menu)
