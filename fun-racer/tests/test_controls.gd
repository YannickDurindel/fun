extends TestCase
## Controls: InputBindings (table, serialization, InputMap), Bootstrap / car hooks and the
## controls screen. Every test restores the defaults before returning.

const SCREEN := "res://scenes/menu/controls.tscn"

func _key(code: Key, pressed: bool = true) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.pressed = pressed
	return ev

func _button(index: JoyButton, pressed: bool = true) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = index
	ev.pressed = pressed
	return ev

func _axis(axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	return ev

func _restore() -> void:
	InputBindings.reset_all()
	Settings.reset("controls")

func _map_has(action: String, event: InputEvent) -> bool:
	for ev: InputEvent in InputMap.action_get_events(action):
		if InputBindings.same_event(ev, event):
			return true
	return false

## Presses the key for one frame and reports whether the action was down meanwhile.
func _tap_presses(code: Key, action: String) -> bool:
	Input.parse_input_event(_key(code, true))
	await get_tree().process_frame
	var down := Input.is_action_pressed(action)
	Input.parse_input_event(_key(code, false))
	await get_tree().process_frame
	return down

func test_serialize_round_trip() -> void:
	var k := InputBindings.deserialize(InputBindings.serialize(_key(KEY_F))) as InputEventKey
	assert_true(k != null and k.physical_keycode == KEY_F, "key survives the round trip")
	var b := InputBindings.deserialize(InputBindings.serialize(_button(JOY_BUTTON_X))) as InputEventJoypadButton
	assert_true(b != null and b.button_index == JOY_BUTTON_X, "button survives the round trip")
	var m := InputBindings.deserialize(InputBindings.serialize(_axis(JOY_AXIS_RIGHT_Y, -0.7))) as InputEventJoypadMotion
	assert_true(m != null and m.axis == JOY_AXIS_RIGHT_Y and m.axis_value == -1.0, "axis and sign survive the round trip")
	var p := InputBindings.deserialize(InputBindings.serialize(_axis(JOY_AXIS_TRIGGER_LEFT, 0.9))) as InputEventJoypadMotion
	assert_true(p != null and p.axis == JOY_AXIS_TRIGGER_LEFT and p.axis_value == 1.0, "positive axis")
	# Through text, like the settings file (ints may come back as floats from other sources).
	var text := var_to_str(InputBindings.serialize(_key(KEY_F)))
	assert_true(InputBindings.same_event(InputBindings.deserialize(str_to_var(text)), _key(KEY_F)), "text round trip")
	assert_true(InputBindings.same_event(InputBindings.deserialize({"t": "axis", "a": 2.0, "s": -1.0}),
			_axis(JOY_AXIS_RIGHT_X, -1.0)), "float fields are accepted")
	assert_true(InputBindings.serialize(null).is_empty() and InputBindings.serialize(InputEventMouseButton.new()).is_empty(),
			"unsupported events serialize to {}")
	assert_true(InputBindings.same_event(InputBindings.deserialize({"t": "btn", "b": 24}), _button(24 as JoyButton)),
			"buttons of unmapped pads / wheels are kept")
	for bad: Variant in [{}, {"t": "key"}, {"t": "key", "k": "x"}, {"t": "btn", "b": 999}, {"t": "axis", "a": -3}, 12, "key"]:
		assert_true(InputBindings.deserialize(bad) == null, "malformed data is rejected: %s" % str(bad))

func test_event_labels() -> void:
	assert_true(InputBindings.event_label(_key(KEY_UP)) == "↑", "arrow key label")
	assert_true(InputBindings.event_label(_key(KEY_1)) == "1", "number row label")
	assert_true(InputBindings.event_label(_key(KEY_ESCAPE)) == "ESC", "escape label")
	assert_true(InputBindings.event_label(_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)) == "RT", "trigger label")
	assert_true(InputBindings.event_label(_axis(JOY_AXIS_LEFT_X, -1.0)) == "L-Stick ←", "stick label")
	assert_true(InputBindings.event_label(_button(JOY_BUTTON_B)) == "Ⓑ", "button label")
	assert_true(InputBindings.event_label(null) == "—", "unbound label")
	assert_true(not InputBindings.event_label(_key(KEY_F)).is_empty(), "letter keys have a label")

func test_apply_default_map() -> void:
	_restore()
	InputBindings.apply()
	assert_true(InputBindings.is_default(), "no overrides")
	for action: String in InputBindings.actions():
		assert_true(InputMap.has_action(action), "%s registered" % action)
	assert_true(_map_has("accelerate", _key(KEY_UP)) and _map_has("accelerate", _key(KEY_W)), "accelerate keys")
	assert_true(_map_has("accelerate", _axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)), "accelerate trigger")
	assert_true(_map_has("brake", _key(KEY_DOWN)) and _map_has("brake", _axis(JOY_AXIS_TRIGGER_LEFT, 1.0)), "brake")
	assert_true(_map_has("steer_left", _axis(JOY_AXIS_LEFT_X, -1.0)) and not _map_has("steer_left", _axis(JOY_AXIS_LEFT_X, 1.0)),
			"steer_left uses the negative stick direction only")
	assert_true(_map_has("steer_right", _key(KEY_D)) and _map_has("steer_right", _axis(JOY_AXIS_LEFT_X, 1.0)), "steer_right")
	assert_true(_map_has("respawn", _key(KEY_BACKSPACE)) and _map_has("respawn", _button(JOY_BUTTON_B)), "respawn")
	assert_true(_map_has("restart", _key(KEY_DELETE)) and _map_has("restart", _button(JOY_BUTTON_BACK)), "restart")
	assert_true(_map_has("pause", _key(KEY_ESCAPE)) and _map_has("pause", _button(JOY_BUTTON_START)), "pause")
	assert_true(_map_has("camera_2", _key(KEY_2)), "camera keys")
	assert_true(InputMap.action_get_events("accelerate").size() == 3, "no duplicated events after re-applying")
	# The race manager's own registration must stay a no-op.
	RaceManager._register_restart_action()
	assert_true(InputMap.action_get_events("restart").size() == 2, "restart not registered twice")
	assert_true(await _tap_presses(KEY_W, "accelerate"), "default key drives the action")
	_restore()

func test_rebind_changes_input() -> void:
	_restore()
	assert_true(InputBindings.rebind("accelerate", InputBindings.SLOT_KEY_1, _key(KEY_K)), "rebind accepted")
	assert_true(InputBindings.same_event(InputBindings.get_event("accelerate", InputBindings.SLOT_KEY_1), _key(KEY_K)), "slot updated")
	Input.parse_input_event(_key(KEY_K, true))
	await get_tree().process_frame
	assert_true(Input.is_action_pressed("accelerate"), "new key presses accelerate")
	assert_between(Bootstrap.get_throttle(), 0.99, 1.01, "Bootstrap throttle follows the new key")
	Input.parse_input_event(_key(KEY_K, false))
	await get_tree().process_frame
	assert_true(not Input.is_action_pressed("accelerate"), "released")
	assert_true(not await _tap_presses(KEY_UP, "accelerate"), "old key no longer accelerates")
	assert_true(await _tap_presses(KEY_W, "accelerate"), "the other keyboard slot is untouched")
	# Wrong device for the slot, unknown action, bad slot.
	assert_true(not InputBindings.rebind("accelerate", InputBindings.SLOT_PAD, _key(KEY_K)), "keys do not go in the pad slot")
	assert_true(not InputBindings.rebind("accelerate", InputBindings.SLOT_KEY_1, _button(JOY_BUTTON_A)), "pad inputs do not go in a key slot")
	assert_true(not InputBindings.rebind("ui_accept", 0, _key(KEY_K)) and not InputBindings.rebind("brake", 7, _key(KEY_K)), "invalid targets rejected")
	# Same key in the other slot of the same action moves instead of duplicating.
	InputBindings.rebind("accelerate", InputBindings.SLOT_KEY_2, _key(KEY_K))
	assert_true(InputBindings.get_event("accelerate", InputBindings.SLOT_KEY_1) == null, "duplicate inside an action is removed")
	# Gamepad: a button on an analog action, an axis on a digital one.
	InputBindings.rebind("accelerate", InputBindings.SLOT_PAD, _button(JOY_BUTTON_A))
	InputBindings.rebind("respawn", InputBindings.SLOT_PAD, _axis(JOY_AXIS_RIGHT_Y, -1.0))
	assert_true(_map_has("accelerate", _button(JOY_BUTTON_A)) and not _map_has("accelerate", _axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)), "pad slot rebound")
	assert_true(_map_has("respawn", _axis(JOY_AXIS_RIGHT_Y, -1.0)), "axis bound to a digital action")
	InputBindings.clear("respawn", InputBindings.SLOT_PAD)
	assert_true(InputBindings.get_event("respawn", InputBindings.SLOT_PAD) == null and InputMap.action_get_events("respawn").size() == 2, "clear unbinds")
	_restore()

func test_conflicts_and_swap() -> void:
	_restore()
	assert_true(InputBindings.find_conflict(_key(KEY_S), "accelerate") == "brake", "S belongs to brake")
	assert_true(InputBindings.find_conflict(_key(KEY_S), "brake") == "", "no conflict with itself")
	assert_true(InputBindings.find_conflict(_key(KEY_K), "accelerate") == "", "free key")
	assert_true(InputBindings.find_conflict(_axis(JOY_AXIS_LEFT_X, -0.8), "steer_right") == "steer_left", "axis direction conflict")
	assert_true(InputBindings.find_conflict(_axis(JOY_AXIS_RIGHT_X, -0.8), "steer_right") == "", "other stick is free")
	assert_true(InputBindings.find_conflict(_button(JOY_BUTTON_START), "respawn") == "pause", "button conflict")
	assert_true(InputBindings.find_conflict(_key(KEY_ENTER)) == "respawn", "ui_* actions are not reported, game ones are")
	assert_true(InputBindings.swap("accelerate", InputBindings.SLOT_KEY_1, _key(KEY_DOWN)), "swap accepted")
	assert_true(InputBindings.same_event(InputBindings.get_event("accelerate", InputBindings.SLOT_KEY_1), _key(KEY_DOWN)), "accelerate got the key")
	assert_true(InputBindings.same_event(InputBindings.get_event("brake", InputBindings.SLOT_KEY_1), _key(KEY_UP)), "brake got the old one")
	assert_true(InputBindings.find_conflict(_key(KEY_DOWN), "accelerate") == "", "no input is bound twice after a swap")
	# Swapping into an empty slot leaves the other side unbound.
	InputBindings.swap("camera_1", InputBindings.SLOT_KEY_2, _key(KEY_2))
	assert_true(InputBindings.get_event("camera_2", InputBindings.SLOT_KEY_1) == null, "nothing to give back")
	_restore()

func test_reset_all() -> void:
	_restore()
	InputBindings.rebind("brake", InputBindings.SLOT_KEY_1, _key(KEY_K))
	InputBindings.clear("steer_left", InputBindings.SLOT_PAD)
	assert_true(not InputBindings.is_default() and not (Settings.get_value("controls", "bindings") as Dictionary).is_empty(), "overrides stored")
	InputBindings.reset_all()
	assert_true(InputBindings.is_default() and (Settings.get_value("controls", "bindings") as Dictionary).is_empty(), "overrides gone")
	assert_true(_map_has("brake", _key(KEY_DOWN)) and not _map_has("brake", _key(KEY_K)), "InputMap back to defaults")
	assert_true(_map_has("steer_left", _axis(JOY_AXIS_LEFT_X, -1.0)), "cleared slot restored")
	# Rebinding back to the default leaves no override behind.
	InputBindings.rebind("brake", InputBindings.SLOT_KEY_1, _key(KEY_K))
	InputBindings.rebind("brake", InputBindings.SLOT_KEY_1, _key(KEY_DOWN))
	assert_true((Settings.get_value("controls", "bindings") as Dictionary).is_empty(), "default bindings are not stored")
	_restore()

func _snapshot(prefix: String) -> Dictionary:
	var out := {}
	for action: StringName in InputMap.get_actions():
		if String(action).begins_with(prefix):
			var list: Array = []
			for ev: InputEvent in InputMap.action_get_events(action):
				list.append(ev.as_text())
			out[action] = list
	return out

func test_other_actions_untouched() -> void:
	_restore()
	InputMap.add_action(&"m4_foreign")
	InputMap.action_add_event(&"m4_foreign", _key(KEY_F9))
	var before := _snapshot("ui_")
	assert_true(before.size() > 10, "ui actions exist (%d)" % before.size())
	InputBindings.rebind("accelerate", InputBindings.SLOT_KEY_1, _key(KEY_ENTER))
	InputBindings.rebind("respawn", InputBindings.SLOT_PAD, _button(JOY_BUTTON_A))
	InputBindings.clear("steer_left", InputBindings.SLOT_KEY_1)
	InputBindings.apply()
	InputBindings.reset_all()
	assert_true(_snapshot("ui_") == before, "ui_* actions are never modified")
	assert_true(InputMap.has_action(&"m4_foreign") and _map_has("m4_foreign", _key(KEY_F9))
			and InputMap.action_get_events(&"m4_foreign").size() == 1, "unknown actions are left alone")
	InputMap.erase_action(&"m4_foreign")
	_restore()

func test_bindings_survive_reload() -> void:
	_restore()
	InputBindings.rebind("accelerate", InputBindings.SLOT_KEY_1, _key(KEY_K))
	InputBindings.rebind("brake", InputBindings.SLOT_PAD, _button(JOY_BUTTON_X))
	InputBindings.clear("respawn", InputBindings.SLOT_KEY_2)
	# What the settings file would hold, as text.
	var saved := var_to_str(Settings.get_value("controls", "bindings"))
	# "Quit": the InputMap is rebuilt from scratch on the next start.
	Settings.set_value("controls", "bindings", {})
	InputBindings.apply_overrides({})
	assert_true(_map_has("accelerate", _key(KEY_UP)) and not _map_has("accelerate", _key(KEY_K)), "fresh start has the defaults")
	# "Start": Settings loads the file; Bootstrap re-applies on the change.
	Settings.set_value("controls", "bindings", str_to_var(saved))
	assert_true(_map_has("accelerate", _key(KEY_K)) and not _map_has("accelerate", _key(KEY_UP)), "key rebind restored")
	assert_true(_map_has("accelerate", _key(KEY_W)), "untouched slot kept")
	assert_true(_map_has("brake", _button(JOY_BUTTON_X)) and not _map_has("brake", _axis(JOY_AXIS_TRIGGER_LEFT, 1.0)), "pad rebind restored")
	assert_true(not _map_has("respawn", _key(KEY_ENTER)) and _map_has("respawn", _key(KEY_BACKSPACE)), "cleared slot stays cleared")
	assert_true(await _tap_presses(KEY_K, "accelerate"), "restored key works")
	# Garbage in the file falls back to the defaults for that action instead of breaking input.
	Settings.set_value("controls", "bindings", {"brake": "nonsense", "steer_left": [1, 2], "nope": [{}, {}, {}],
			"accelerate": [{"t": "btn", "b": 0}, {"t": "key", "k": KEY_K}, {"t": "key", "k": KEY_K}]})
	assert_true(_map_has("brake", _key(KEY_DOWN)) and _map_has("steer_left", _key(KEY_LEFT)), "malformed entries use the defaults")
	assert_true(not InputMap.has_action("nope"), "unknown actions in the file are ignored")
	assert_true(InputMap.action_get_events("accelerate").size() == 1 and _map_has("accelerate", _key(KEY_K)),
			"events on the wrong device slot are dropped")
	_restore()

func test_gamepad_deadzone_applied() -> void:
	_restore()
	assert_between(InputMap.action_get_deadzone("steer_left"), 0.149, 0.151, "default dead zone")
	Settings.set_value("controls", "gamepad_deadzone", 0.3)
	for action: String in ["accelerate", "brake", "steer_left", "steer_right"]:
		assert_between(InputMap.action_get_deadzone(action), 0.299, 0.301, "%s dead zone" % action)
	assert_between(InputMap.action_get_deadzone("respawn"), 0.49, 0.51, "digital actions keep a 0.5 threshold")
	# A stick inside the dead zone does not steer; outside it does, rescaled from the edge.
	Input.parse_input_event(_axis(JOY_AXIS_LEFT_X, 0.25))
	await get_tree().process_frame
	assert_between(Bootstrap.get_steer(), -0.001, 0.001, "inside the dead zone")
	Input.parse_input_event(_axis(JOY_AXIS_LEFT_X, 0.65))
	await get_tree().process_frame
	assert_between(Bootstrap.get_steer(), 0.45, 0.55, "outside the dead zone")
	assert_true(not Bootstrap.is_steer_digital(), "a half-deflected stick is analog")
	Input.parse_input_event(_axis(JOY_AXIS_LEFT_X, 0.0))
	await get_tree().process_frame
	assert_between(Bootstrap.get_steer(), -0.001, 0.001, "stick released")
	Settings.set_value("controls", "gamepad_deadzone", 0.0)
	assert_true(InputMap.action_get_deadzone("steer_left") > 0.0, "a zero dead zone is kept slightly positive")
	_restore()
	assert_between(InputMap.action_get_deadzone("steer_left"), 0.149, 0.151, "dead zone restored")

func test_car_follows_steer_settings() -> void:
	_restore()
	Settings.set_value("controls", "key_steer_in_time", 0.25)
	Settings.set_value("controls", "key_steer_out_time", 0.2)
	var car := spawn("res://scenes/car/car.tscn") as Car
	await physics_frames(2)
	assert_between(car.key_steer_in_time, 0.249, 0.251, "car reads key_steer_in_time at start")
	assert_between(car.key_steer_out_time, 0.199, 0.201, "car reads key_steer_out_time at start")
	Settings.set_value("controls", "key_steer_in_time", 0.6)
	assert_between(car.key_steer_in_time, 0.599, 0.601, "car follows live changes")
	Settings.reset("controls")
	assert_between(car.key_steer_in_time, 0.399, 0.401, "car follows a reset")
	assert_between(car.key_steer_out_time, 0.119, 0.121, "release time reset")
	car.queue_free()
	await get_tree().process_frame
	Settings.set_value("controls", "key_steer_in_time", 0.3)   # must not reach the freed car
	_restore()

func test_screen_without_router() -> void:
	_restore()
	var screen := spawn(SCREEN) as ControlsScreen
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(screen != null and screen.router == null, "screen instanced stand-alone")
	assert_true(screen.process_mode == Node.PROCESS_MODE_ALWAYS, "runs while the tree is paused")
	var closed_count: Array[int] = [0]
	screen.closed.connect(func() -> void: closed_count[0] += 1)
	for action: String in InputBindings.actions():
		for slot in InputBindings.SLOT_COUNT:
			var b := screen.cell(action, slot)
			assert_true(b != null and b.focus_mode == Control.FOCUS_ALL, "cell %s/%d is focusable" % [action, slot])
	assert_true(screen.cell("accelerate", 0).text == "↑" and screen.cell("accelerate", 2).text == "RT", "cells show the bindings")
	assert_true(screen.cell("camera_1", 2).text == "—", "unbound cells show a dash")

	# Capture a free key.
	screen.cell("brake", 0).pressed.emit()
	assert_true(screen.is_capturing() and screen.cell("brake", 0).text.begins_with("PRESS A KEY"), "capture prompt")
	screen.handle_capture_event(_key(KEY_K, false))
	screen.handle_capture_event(_axis(JOY_AXIS_LEFT_X, 1.0))
	assert_true(screen.is_capturing(), "key releases and sticks are ignored in a keyboard cell")
	screen.handle_capture_event(_key(KEY_K))
	assert_true(not screen.is_capturing() and _map_has("brake", _key(KEY_K)), "key captured and applied")
	assert_true(screen.cell("brake", 0).text == InputBindings.event_label(_key(KEY_K)), "cell shows the new key")

	# Esc cancels, back during a capture only cancels, Delete clears.
	screen.begin_capture("brake", 1)
	screen.handle_capture_event(_key(KEY_ESCAPE))
	assert_true(not screen.is_capturing() and _map_has("brake", _key(KEY_S)), "Esc cancels the capture")
	screen.begin_capture("brake", 1)
	screen.on_back()
	assert_true(not screen.is_capturing() and closed_count[0] == 0, "back cancels the capture first")
	screen.begin_capture("brake", 1)
	screen.handle_capture_event(_key(KEY_DELETE))
	assert_true(not screen.is_capturing() and not _map_has("brake", _key(KEY_S)) and screen.cell("brake", 1).text == "—", "Delete unbinds")

	# On the now empty cell, Delete is an ordinary key again (it is a default binding).
	screen.begin_capture("brake", 1)
	screen.handle_capture_event(_key(KEY_DELETE))
	assert_true(screen.is_dialog_open() and screen.dialog_text().contains("RESTART"), "Delete on an empty cell is captured (conflict with restart)")
	screen._close_dialog()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	screen.begin_capture("brake", 1)
	screen._input(wheel)
	assert_true(screen.is_capturing(), "mouse wheel does not cancel a capture")
	screen.cancel_capture()

	# Conflict -> dialog -> cancel, then swap.
	screen.begin_capture("accelerate", 0)
	screen.handle_capture_event(_key(KEY_LEFT))
	assert_true(screen.is_dialog_open() and screen.dialog_text().contains("STEER LEFT"), "conflict warning names the other action: %s" % screen.dialog_text())
	assert_true(_map_has("steer_left", _key(KEY_LEFT)) and _map_has("accelerate", _key(KEY_UP)), "nothing changes before the answer")
	screen.on_back()
	assert_true(not screen.is_dialog_open() and closed_count[0] == 0 and _map_has("accelerate", _key(KEY_UP)), "cancel keeps the bindings")
	screen.begin_capture("accelerate", 0)
	screen.handle_capture_event(_key(KEY_LEFT))
	screen._on_dialog_ok()
	assert_true(_map_has("accelerate", _key(KEY_LEFT)) and _map_has("steer_left", _key(KEY_UP)) and not _map_has("steer_left", _key(KEY_LEFT)), "swap exchanges the two keys")
	assert_true(screen.cell("steer_left", 0).text == "↑", "cells refreshed after the swap")

	# Gamepad cell: threshold on sticks / triggers, buttons, and a stick held from before.
	screen.begin_capture("respawn", InputBindings.SLOT_PAD)
	assert_true(screen.cell("respawn", 2).text.begins_with("PRESS A BUTTON"), "gamepad prompt")
	screen.handle_capture_event(_key(KEY_K))
	screen.handle_capture_event(_axis(JOY_AXIS_RIGHT_Y, 0.4))
	assert_true(screen.is_capturing(), "keys and small stick moves are ignored in a gamepad cell")
	screen.handle_capture_event(_axis(JOY_AXIS_RIGHT_Y, 0.9))
	assert_true(not screen.is_capturing() and _map_has("respawn", _axis(JOY_AXIS_RIGHT_Y, 1.0)), "stick direction captured")
	assert_true(screen.cell("respawn", 2).text == "R-Stick ↓", "stick label: %s" % screen.cell("respawn", 2).text)
	screen.begin_capture("camera_1", InputBindings.SLOT_PAD)
	screen.handle_capture_event(_axis(JOY_AXIS_TRIGGER_RIGHT, 0.8))
	assert_true(screen.is_dialog_open() and screen.dialog_text().contains("ACCELERATE"), "trigger captured, conflict with accelerate")
	screen._close_dialog()
	screen.begin_capture("camera_1", InputBindings.SLOT_PAD)
	screen.handle_capture_event(_button(JOY_BUTTON_Y))
	assert_true(_map_has("camera_1", _button(JOY_BUTTON_Y)), "button captured")
	screen.begin_capture("camera_2", InputBindings.SLOT_PAD)
	screen._cap_blocked["0:%d" % JOY_AXIS_RIGHT_X] = true   # stick was already pushed
	screen.handle_capture_event(_axis(JOY_AXIS_RIGHT_X, 1.0))
	assert_true(screen.is_capturing(), "a stick held since before the capture is not taken")
	screen.handle_capture_event(_axis(JOY_AXIS_RIGHT_X, 0.1))
	screen.handle_capture_event(_axis(JOY_AXIS_RIGHT_X, -1.0))
	assert_true(_map_has("camera_2", _axis(JOY_AXIS_RIGHT_X, -1.0)), "after recentring it is")

	# The capture gives up on its own (gamepad-only players are never stuck).
	screen.begin_capture("camera_3", 0)
	screen._cap_time_left = 0.01
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(not screen.is_capturing(), "capture times out")

	# Sliders write to Settings and show the value.
	var slider := screen._sliders["key_steer_in_time"] as HSlider
	assert_between(slider.min_value, 0.049, 0.051, "build-up slider min")
	assert_between(slider.max_value, 0.79, 0.81, "build-up slider max")
	slider.value = 0.55
	assert_between(Settings.get_value("controls", "key_steer_in_time"), 0.549, 0.551, "slider stored in Settings")
	(screen._sliders["gamepad_deadzone"] as HSlider).value = 0.25
	assert_between(InputMap.action_get_deadzone("steer_right"), 0.249, 0.251, "dead zone slider applied")
	assert_true((screen._slider_values["gamepad_deadzone"] as Label).text == "25 %", "dead zone shown in percent")

	# Reset with confirmation.
	screen._reset_button.pressed.emit()
	assert_true(screen.is_dialog_open() and not InputBindings.is_default(), "reset asks first")
	screen._on_dialog_ok()
	assert_true(InputBindings.is_default() and _map_has("accelerate", _key(KEY_UP)), "bindings reset")
	assert_between(Settings.get_value("controls", "key_steer_in_time"), 0.399, 0.401, "sliders reset")
	assert_between(slider.value, 0.399, 0.401, "slider shows the default again")
	assert_true(screen.cell("accelerate", 0).text == "↑", "cells show the defaults again")

	# Works while paused, and leaving emits `closed`.
	get_tree().paused = true
	assert_true(screen.can_process(), "screen processes while paused")
	get_tree().paused = false
	var cancel := InputEventAction.new()
	cancel.action = &"ui_cancel"
	cancel.pressed = true
	screen._unhandled_input(cancel)
	assert_true(closed_count[0] == 1, "ui_cancel emits closed without a router")
	screen._back_button.pressed.emit()
	assert_true(closed_count[0] == 2, "BACK emits closed")
	screen.queue_free()
	await get_tree().process_frame
	_restore()

func test_preview_matches_key_steering() -> void:
	_restore()
	# 0.40 s to full lock, 0.12 s back: the preview uses the same ramp as the car.
	var v := 0.0
	for i in 20:
		v = ControlsScreen.smooth_steer(v, 1.0, 0.01, 0.40, 0.12)
	assert_between(v, 0.49, 0.51, "half lock after half the build-up time")
	for i in 20:
		v = ControlsScreen.smooth_steer(v, 1.0, 0.01, 0.40, 0.12)
	assert_between(v, 0.999, 1.0, "full lock")
	for i in 6:
		v = ControlsScreen.smooth_steer(v, 0.0, 0.01, 0.40, 0.12)
	assert_between(v, 0.49, 0.51, "half way back after half the release time")
	v = ControlsScreen.smooth_steer(0.5, -1.0, 0.01, 0.40, 0.12)
	assert_true(v < 0.5 and v > 0.0, "reversing first recentres at the release rate")
	# In the screen the bar follows the steer action.
	var screen := spawn(SCREEN) as ControlsScreen
	await get_tree().process_frame
	Input.parse_input_event(_key(KEY_D, true))
	for i in 5:
		await get_tree().process_frame
	assert_true(screen.preview_steer > 0.0, "preview moves right while the key is held (%.3f)" % screen.preview_steer)
	Input.parse_input_event(_key(KEY_D, false))
	screen.queue_free()
	await get_tree().process_frame
	_restore()
