extends TestCase
## Options screen, the settings applier (SettingsApply) and the HUD's gameplay options.

const SCREEN := "res://scenes/menu/settings.tscn"

func _restore() -> void:
	for section: String in ["graphics", "audio"]:
		Settings.reset(section)
	Settings.set_value("gameplay", "speed_unit", Settings.default_value("gameplay", "speed_unit"))
	Settings.set_value("gameplay", "show_input_display", Settings.default_value("gameplay", "show_input_display"))

func _open() -> SettingsScreen:
	var screen := spawn(SCREEN) as SettingsScreen
	await get_tree().process_frame
	return screen

func _press(action: StringName) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame
	# Release it again so the action does not stay held for later tests.
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame

func test_widgets_update_settings() -> void:
	var screen := await _open()
	assert_true(screen.current_tab == "graphics", "opens on the graphics tab")
	# Slider (percent) -> linear setting.
	var master := screen.row("audio", "master")
	master.slider.value = 40.0
	assert_between(Settings.get_value("audio", "master"), 0.399, 0.401, "master slider sets audio/master")
	assert_true(master.value_label.text == "40 %", "slider label: " + master.value_label.text)
	var render := screen.row("graphics", "render_scale")
	render.slider.value = 20.0
	assert_between(Settings.get_value("graphics", "render_scale"), 0.499, 0.501, "render scale is limited to 50 %")
	# Option steppers.
	var vsync := screen.row("graphics", "vsync")
	assert_true(vsync.stepper.text() == "ON", "vsync shows the default: " + vsync.stepper.text())
	vsync.stepper.step(-1)
	assert_true(Settings.get_value("graphics", "vsync") == false, "stepping left turns vsync off")
	vsync.stepper.step(-1)
	assert_true(Settings.get_value("graphics", "vsync") == false, "no wrap at the end of the list")
	var unit := screen.row("gameplay", "speed_unit")
	unit.stepper.step(1)
	assert_true(Settings.get_value("gameplay", "speed_unit") == "mph", "speed unit option")
	var shadows := screen.row("graphics", "shadows")
	shadows.stepper.step(1)
	assert_true(Settings.get_value("graphics", "shadows") == 3, "shadows stepped to high")
	# A change made elsewhere shows up in the widgets.
	Settings.set_value("audio", "engine", 0.25)
	assert_between(screen.row("audio", "engine").slider.value, 24.9, 25.1, "slider follows Settings")
	Settings.set_value("graphics", "fullscreen", true)
	assert_true(not screen.row("graphics", "resolution").stepper.enabled, "resolution is locked in fullscreen")
	_restore()

func test_rows_descriptions_and_focus() -> void:
	var screen := await _open()
	await get_tree().process_frame
	var focus := get_viewport().gui_get_focus_owner()
	assert_true(focus == screen.preset_stepper, "the first row has focus on open")
	assert_true(not screen.description_text().is_empty(), "focused row shows its description")
	for tab in SettingsScreen.TAB_NAMES:
		screen.show_tab(tab)
		assert_true(screen.current_tab == tab, "tab " + tab)
		var rows: Array = screen.get("_rows")[tab]
		assert_true(rows.size() >= 2, "%s has rows" % tab)
		for r: SettingsScreen.Row in rows:
			assert_true(not r.description.is_empty(), "%s has a description" % r.title.text)
			assert_true(r.is_visible_in_tree(), "%s is visible on its tab" % r.title.text)
			assert_true(r.widget.focus_mode == Control.FOCUS_ALL, "%s can take focus" % r.title.text)
	# Down from the last row reaches BACK, right of it is RESET.
	var last_rows: Array = screen.get("_rows")["gameplay"]
	var last: Control = (last_rows.back() as SettingsScreen.Row).widget
	assert_true(last.get_node(last.focus_neighbor_bottom) == screen.back_button, "last row leads down to BACK")
	assert_true(screen.back_button.get_node(screen.back_button.focus_neighbor_right) == screen.reset_button, "BACK -> RESET")
	# Left / right on a focused row changes the value (keyboard and gamepad share ui_left/right).
	var unit := screen.row("gameplay", "speed_unit")
	unit.stepper.grab_focus()
	assert_true(screen.description_text() == unit.description, "description follows focus")
	await _press(&"ui_right")
	assert_true(Settings.get_value("gameplay", "speed_unit") == "mph", "ui_right changes the focused option")
	await _press(&"ui_left")
	assert_true(Settings.get_value("gameplay", "speed_unit") == "kmh", "ui_left changes it back")
	screen.show_tab("audio")
	screen.row("audio", "ui").slider.grab_focus()
	await _press(&"ui_left")
	assert_between(Settings.get_value("audio", "ui"), 0.649, 0.651, "ui_left lowers the focused slider by one step")
	_restore()

func test_applier_audio_buses() -> void:
	for bus: StringName in [&"Master", &"Engine", &"FX", &"UI"]:
		assert_true(AudioServer.get_bus_index(bus) >= 0, "bus %s exists" % bus)
	assert_between(SettingsApply.linear_to_bus_db(1.0), -0.001, 0.001, "1.0 -> 0 dB")
	assert_between(SettingsApply.linear_to_bus_db(0.5), -6.03, -6.01, "0.5 -> -6 dB")
	assert_between(SettingsApply.linear_to_bus_db(0.0), -80.01, -79.99, "0 -> floor")
	var engine := AudioServer.get_bus_index(&"Engine")
	assert_between(AudioServer.get_bus_volume_db(engine), linear_to_db(0.8) - 0.01, linear_to_db(0.8) + 0.01, "default engine volume applied at startup")
	Settings.set_value("audio", "engine", 0.5)
	assert_between(AudioServer.get_bus_volume_db(engine), -6.03, -6.01, "engine bus follows the setting")
	assert_true(not AudioServer.is_bus_mute(engine), "audible bus is not muted")
	Settings.set_value("audio", "engine", 0.0)
	assert_true(AudioServer.is_bus_mute(engine), "0 mutes the bus")
	Settings.set_value("audio", "ui", 0.1)
	assert_between(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(&"UI")), -20.01, -19.99, "ui bus")
	Settings.set_value("audio", "engine", 0.3)
	assert_true(not AudioServer.is_bus_mute(engine), "raising the volume unmutes")
	# The car's players are routed to the buses.
	var audio := spawn("res://scenes/audio/engine_audio.tscn")
	await get_tree().process_frame
	assert_true((audio.get_node("EnginePlayer") as AudioStreamPlayer).bus == &"Engine", "engine synth on the Engine bus")
	assert_true((audio.get_node("ScreechPlayer") as AudioStreamPlayer).bus == &"FX", "screech on the FX bus")
	assert_true((audio.get_node("WindPlayer") as AudioStreamPlayer).bus == &"FX", "wind on the FX bus")
	_restore()
	assert_true(not AudioServer.is_bus_mute(engine), "restored")

func test_applier_graphics() -> void:
	var vp := get_tree().root
	var sky := spawn("res://scenes/world/sky_environment.tscn")
	var sun := sky.get_node("Sun") as DirectionalLight3D
	assert_true(sun.is_in_group(&"sun"), "the applier groups directional lights")
	assert_true(sun.shadow_enabled, "shadows on by default")
	assert_true(vp.msaa_3d == Viewport.MSAA_4X, "default MSAA applied")
	Settings.set_value("graphics", "msaa", 0)
	assert_true(vp.msaa_3d == Viewport.MSAA_DISABLED, "MSAA follows the setting")
	Settings.set_value("graphics", "render_scale", 0.7)
	assert_between(vp.scaling_3d_scale, 0.699, 0.701, "render scale applied")
	Settings.set_value("graphics", "shadows", 0)
	assert_true(not sun.shadow_enabled, "shadows off turns the sun's shadows off")
	Settings.set_value("graphics", "shadows", 3)
	assert_true(sun.shadow_enabled, "and back on")
	Settings.set_value("graphics", "fps_cap", 144)
	assert_true(Engine.max_fps == 144, "FPS cap applied")
	# A light added while shadows are off starts without them.
	Settings.set_value("graphics", "shadows", 0)
	var sky2 := spawn("res://scenes/world/sky_environment.tscn")
	assert_true(not (sky2.get_node("Sun") as DirectionalLight3D).shadow_enabled, "new lights get the current setting")
	assert_true(SettingsApply.parse_resolution("1920x1080") == Vector2i(1920, 1080), "resolution parsed")
	assert_true(SettingsApply.parse_resolution("nonsense") == Vector2i(1600, 900), "bad resolution falls back")
	_restore()
	assert_true(Engine.max_fps == 0 and vp.msaa_3d == Viewport.MSAA_4X and is_equal_approx(vp.scaling_3d_scale, 1.0), "defaults restored")
	assert_true(sun.shadow_enabled, "sun shadows restored")
	assert_true((sky2.get_node("Sun") as DirectionalLight3D).shadow_enabled, "the late light gets its shadows back too")

func test_presets() -> void:
	var screen := await _open()
	assert_true(SettingsApply.current_preset() == "medium", "defaults are the medium preset: " + SettingsApply.current_preset())
	assert_true(screen.preset_stepper.text() == "MEDIUM", "preset row shows it: " + screen.preset_stepper.text())
	screen.preset_stepper.step(-1)
	assert_true(SettingsApply.current_preset() == "low", "stepped to low")
	assert_between(Settings.get_value("graphics", "render_scale"), 0.699, 0.701, "low: render scale 70 %")
	assert_true(Settings.get_value("graphics", "msaa") == 0, "low: MSAA off")
	assert_true(Settings.get_value("graphics", "shadows") == 1, "low: low shadows")
	assert_between(screen.row("graphics", "render_scale").slider.value, 69.9, 70.1, "widgets follow the preset")
	assert_true(screen.row("graphics", "msaa").stepper.text() == "OFF", "AA row follows the preset")
	# A manual change makes it custom ...
	screen.row("graphics", "msaa").stepper.step(1)
	assert_true(SettingsApply.current_preset() == "custom", "manual change -> custom")
	assert_true(screen.preset_stepper.text() == "CUSTOM", "preset row shows CUSTOM: " + screen.preset_stepper.text())
	# ... and from custom you can step back onto a preset.
	screen.preset_stepper.step(-1)
	assert_true(SettingsApply.current_preset() == "high", "left of custom is high")
	assert_true(Settings.get_value("graphics", "msaa") == 3 and Settings.get_value("graphics", "shadows") == 3, "high values")
	# Moving the slider by hand also leaves the preset.
	screen.row("graphics", "render_scale").slider.value = 80.0
	assert_true(screen.preset_stepper.text() == "CUSTOM", "slider change -> CUSTOM")
	screen.row("graphics", "render_scale").slider.value = 100.0
	assert_true(screen.preset_stepper.text() == "HIGH", "matching values show the preset again")
	# Presets leave the display options alone.
	Settings.set_value("graphics", "vsync", false)
	assert_true(SettingsApply.current_preset() == "high", "vsync is not part of a preset")
	_restore()

func test_reset_to_defaults() -> void:
	var screen := await _open()
	Settings.set_value("gameplay", "last_race", {"track_id": "red_bull_ring"})
	Settings.set_value("graphics", "shadows", 0)
	Settings.set_value("graphics", "fps_cap", 60)
	Settings.set_value("audio", "master", 0.2)
	Settings.set_value("gameplay", "speed_unit", "mph")
	Settings.set_value("gameplay", "show_input_display", false)
	screen.show_tab("graphics")
	screen.reset_button.pressed.emit()
	assert_true(Settings.get_value("graphics", "shadows") == 2 and Settings.get_value("graphics", "fps_cap") == 0, "graphics reset")
	assert_between(Settings.get_value("audio", "master"), 0.199, 0.201, "reset only touches the current tab")
	screen.show_tab("audio")
	screen.reset_current_tab()
	assert_between(Settings.get_value("audio", "master"), 0.999, 1.001, "audio reset")
	assert_between(screen.row("audio", "master").slider.value, 99.9, 100.1, "slider shows the default again")
	screen.show_tab("gameplay")
	screen.reset_current_tab()
	assert_true(Settings.get_value("gameplay", "speed_unit") == "kmh", "gameplay reset")
	assert_true(Settings.get_value("gameplay", "show_input_display") == true, "input display reset")
	assert_true((Settings.get_value("gameplay", "last_race") as Dictionary).size() == 1, "reset keeps the last race")
	Settings.set_value("gameplay", "last_race", {})
	_restore()

func test_without_router_emits_closed() -> void:
	get_tree().paused = true
	var screen := await _open()
	assert_true(screen.router == null, "no router")
	assert_true(not screen.controls_button.visible, "CONTROLS is hidden without a router")
	assert_true(screen.can_process(), "runs while the tree is paused")
	var closed: Array[int] = []
	screen.closed.connect(func() -> void: closed.append(1))
	screen.back_button.pressed.emit()
	assert_true(closed.size() == 1, "BACK emits closed")
	await _press(&"ui_cancel")
	assert_true(closed.size() == 2, "ui_cancel emits closed (%d)" % closed.size())
	get_tree().paused = false
	# It fits itself to whatever height it is given.
	screen.size = Vector2(1280, 720)
	var content := screen.get_node("Content") as Control
	assert_between(content.scale.y, 0.666, 0.667, "content scaled to the parent's height")
	_restore()

func test_in_router_has_controls_button() -> void:
	Bootstrap.start_screen = "settings"
	var menu := spawn(Game.MENU_SCENE) as MenuRouter
	await get_tree().process_frame
	Bootstrap.start_screen = ""
	assert_true(menu.current_name == "settings" and menu.current is SettingsScreen, "router shows the options screen")
	var screen := menu.current as SettingsScreen
	assert_true(screen.controls_button.visible, "CONTROLS button shown")
	screen.controls_button.pressed.emit()
	assert_true(menu.current_name == "controls", "CONTROLS opens the controls screen")
	menu.back()
	assert_true(menu.current_name == "settings", "and back returns to the options")
	(menu.current as SettingsScreen).back_button.pressed.emit()
	assert_true(menu.current_name == "main", "BACK returns to the main menu")
	_restore()

func test_hud_speed_unit_and_input_display() -> void:
	var main := spawn("res://scenes/main.tscn")
	var hud := main.get_node("UI/HUD")
	var car := main.get_node("Car") as Car
	car.simulate = false
	car.speed_kmh = 200.0
	await physics_frames(240)
	await get_tree().process_frame
	assert_true(hud.get_speed_text() == "200", "km/h by default: " + hud.get_speed_text())
	assert_true(hud.get_speed_unit_text() == "KM/H", "unit label: " + hud.get_speed_unit_text())
	assert_true((hud.get_node("Inputs") as Control).visible, "input display shown by default")
	Settings.set_value("gameplay", "speed_unit", "mph")
	assert_true(hud.get_speed_unit_text() == "MPH", "unit label switches live")
	assert_true(hud.get_speed_text() == "124", "200 km/h = 124 mph at once, got " + hud.get_speed_text())
	await physics_frames(60)
	await get_tree().process_frame
	assert_true(hud.get_speed_text() == "124", "stays at 124 mph, got " + hud.get_speed_text())
	Settings.set_value("gameplay", "show_input_display", false)
	assert_true(not (hud.get_node("Inputs") as Control).visible, "input display hidden live")
	Settings.set_value("gameplay", "speed_unit", "kmh")
	assert_true(hud.get_speed_text() == "200", "back to km/h, got " + hud.get_speed_text())
	_restore()
	assert_true((hud.get_node("Inputs") as Control).visible, "input display back")
