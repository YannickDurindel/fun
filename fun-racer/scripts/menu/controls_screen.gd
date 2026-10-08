class_name ControlsScreen
extends UIScreen
## Controls screen: rebind every game action (two keys + one gamepad input each), tune the
## keyboard steering feel and the gamepad dead zone. Everything is stored in Settings
## (`controls/*`) and saved when the screen is left.
##
## Works in the menu (router set) and stand-alone, e.g. inside the in-race pause menu:
## instance the scene, add it anywhere, and listen to `closed` (BACK / ui_cancel). It runs
## while the tree is paused and scales its 1920x1080 layout to its own height.
##
## Capturing: activate a cell, then press the new key / button / stick direction.
## Esc cancels, Delete or Backspace unbinds the cell (on an empty cell those three keys are
## bound like any other), and it gives up after CAPTURE_TIMEOUT s
## (so a gamepad-only player is never stuck). Dev flags: --capture-demo, --conflict-demo.

## Emitted when the player leaves the screen and there is no router to go back with.
signal closed

const DESIGN_HEIGHT := 1080.0
const MARGIN_X := 140.0
const CONTENT_WIDTH := 1640.0
const CAPTURE_TIMEOUT := 5.0
## A stick / trigger must travel past CAPTURE_AXIS_ON to be captured, and an axis that was
## already deflected when the capture started must first come back under CAPTURE_AXIS_OFF.
const CAPTURE_AXIS_ON := 0.6
const CAPTURE_AXIS_OFF := 0.3
## Analog (stick) steering response used by the preview: same as the car's steer_in/out_time.
const ANALOG_IN_TIME := 0.065
const ANALOG_OUT_TIME := 0.035

const COL_CAPTURE := Color(1.0, 0.82, 0.25)
const COL_FOCUS_TEXT := Color(0.5, 0.72, 1.0)
const HINT_IDLE := "Select a binding and press ENTER / Ⓐ to change it."
const SLIDERS: Array[Dictionary] = [
	{"key": "key_steer_in_time", "name": "STEERING BUILD-UP", "min": 0.05, "max": 0.8,
			"hint": "how long holding a key takes to reach full lock"},
	{"key": "key_steer_out_time", "name": "STEERING RELEASE", "min": 0.03, "max": 0.4,
			"hint": "how long the wheel takes to recentre when you let go"},
	{"key": "gamepad_deadzone", "name": "GAMEPAD DEAD ZONE", "min": 0.0, "max": 0.4,
			"hint": "stick / trigger travel ignored around the rest position"},
]

## Smoothed steering shown by the preview bar: -1 full left .. +1 full right.
var preview_steer: float = 0.0

var _content: Control
var _hint: Label
var _cells: Dictionary = {}          # "action:slot" -> Button
var _sliders: Dictionary = {}        # settings key -> HSlider
var _slider_values: Dictionary = {}  # settings key -> Label
var _steer_bar: SteerBar
var _steer_value: Label
var _back_button: Button
var _reset_button: Button

var _dialog: Control
var _dialog_text: Label
var _dialog_ok: Button
var _dialog_cancel: Button
var _dialog_action: Callable
var _dialog_return_focus: Control

var _capturing: bool = false
var _cap_action: String = ""
var _cap_slot: int = 0
var _cap_time_left: float = 0.0
var _cap_frame: int = -1
var _cap_frozen: bool = false         # dev screenshots: no timeout
var _cap_blocked: Dictionary = {}     # "device:axis" deflected when the capture started
var _dirty: bool = false
var _cell_styles: Dictionary = {}     # state name -> StyleBoxFlat (normal, hover, focus, capture)

func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func on_enter() -> void:
	_build()
	resized.connect(_fit)
	_fit()
	_refresh()
	Settings.changed.connect(_on_setting_changed)
	var args := OS.get_cmdline_user_args()
	if args.has("--capture-demo"):
		_cap_frozen = true
		begin_capture.call_deferred("accelerate", InputBindings.SLOT_KEY_1)
	elif args.has("--conflict-demo"):
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_DOWN
		_on_captured.call_deferred("accelerate", InputBindings.SLOT_KEY_1, ev)

func _exit_tree() -> void:
	_save()

## Leaves the screen (saving). During a capture or a dialog it only closes that.
func on_back() -> void:
	if _capturing:
		cancel_capture()
		return
	if is_dialog_open():
		_close_dialog()
		return
	_save()
	if router != null:
		router.back()
	else:
		closed.emit()

func _save() -> void:
	if _dirty:
		_dirty = false
		Settings.save()

# ---------------------------------------------------------------------------- layout

## The layout is designed 1080 px tall and scaled to this control's height, so it fits both
## the router's scaled holder and a plain full-rect parent (pause menu).
func _fit() -> void:
	if _content == null or size.y <= 0.0:
		return
	var k := size.y / DESIGN_HEIGHT
	_content.scale = Vector2(k, k)
	_content.position = Vector2.ZERO
	_content.size = Vector2(size.x / k, DESIGN_HEIGHT)

func _build() -> void:
	_make_cell_styles()
	_content = Control.new()
	_content.name = "Content"
	add_child(_content)

	var col := VBoxContainer.new()
	col.position = Vector2(MARGIN_X, 22.0)
	col.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	col.add_theme_constant_override(&"separation", 10)
	_content.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 40)
	col.add_child(head)
	var title := Label.new()
	title.text = "CONTROLS"
	title.theme_type_variation = &"TitleLabel"
	head.add_child(title)
	_hint = Label.new()
	_hint.theme_type_variation = &"DimLabel"
	_hint.add_theme_font_size_override(&"font_size", 26)
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.size_flags_vertical = Control.SIZE_SHRINK_END
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_hint)

	col.add_child(_build_bindings())
	col.add_child(_build_feel())

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 16)
	col.add_child(buttons)
	_back_button = _make_button("BACK", Vector2(300, 56))
	_back_button.name = "Back"
	_back_button.pressed.connect(on_back)
	buttons.add_child(_back_button)
	_reset_button = _make_button("RESET ALL TO DEFAULTS", Vector2(460, 56))
	_reset_button.name = "Reset"
	_reset_button.pressed.connect(_ask_reset)
	buttons.add_child(_reset_button)

	_build_dialog()

func _build_bindings() -> Control:
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 3)
	panel.add_child(box)
	var header := HBoxContainer.new()
	header.add_theme_constant_override(&"separation", 10)
	box.add_child(header)
	header.add_child(_column_label("ACTION", 380.0, false))
	header.add_child(_column_label("KEYBOARD", 0.0, true, 2.0))
	header.add_child(_column_label("GAMEPAD", 0.0, true))
	for action: String in InputBindings.actions():
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 10)
		box.add_child(row)
		var name_label := Label.new()
		name_label.text = InputBindings.display_name(action)
		name_label.custom_minimum_size = Vector2(380.0, 0.0)
		name_label.add_theme_font_size_override(&"font_size", 28)
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(name_label)
		for slot in InputBindings.SLOT_COUNT:
			var b := _make_button("", Vector2(300, 50))
			_style_cell(b)
			b.name = "%s_%d" % [action, slot]
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.alignment = HORIZONTAL_ALIGNMENT_CENTER
			b.clip_text = true
			b.add_theme_font_size_override(&"font_size", 26)
			b.pressed.connect(begin_capture.bind(action, slot))
			row.add_child(b)
			_cells[_cell_key(action, slot)] = b
	return panel

func _build_feel() -> Control:
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 4)
	panel.add_child(box)
	for def: Dictionary in SLIDERS:
		var key: String = def["key"]
		var slider := HSlider.new()
		slider.name = key
		slider.min_value = def["min"]
		slider.max_value = def["max"]
		slider.step = 0.01
		slider.custom_minimum_size = Vector2(460, 36)
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.value_changed.connect(_on_slider_changed.bind(key))
		_sliders[key] = slider
		_slider_values[key] = _feel_row(box, def["name"], slider, def["hint"])
	_steer_bar = SteerBar.new()
	_steer_bar.name = "SteerBar"
	_steer_bar.custom_minimum_size = Vector2(460, 30)
	_steer_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_steer_value = _feel_row(box, "STEERING PREVIEW", _steer_bar,
			"hold your steer keys or move the stick (select the bar to try ← →)")
	return panel

## Adds a row  [name][control][value][hint]  and returns its value label.
func _feel_row(parent: Control, title: String, control: Control, hint: String) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 20)
	row.custom_minimum_size = Vector2(0.0, 46.0)
	parent.add_child(row)
	var name_label := Label.new()
	name_label.text = title
	name_label.custom_minimum_size = Vector2(370.0, 0.0)
	name_label.add_theme_font_size_override(&"font_size", 28)
	row.add_child(name_label)
	row.add_child(control)
	# The row's name lights up while its slider / bar has the focus.
	control.focus_entered.connect(name_label.add_theme_color_override.bind(&"font_color", COL_FOCUS_TEXT))
	control.focus_exited.connect(name_label.remove_theme_color_override.bind(&"font_color"))
	var value := Label.new()
	value.custom_minimum_size = Vector2(100.0, 0.0)
	value.add_theme_font_size_override(&"font_size", 28)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	var hint_label := Label.new()
	hint_label.text = hint
	hint_label.theme_type_variation = &"DimLabel"
	hint_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint_label.clip_text = true
	row.add_child(hint_label)
	return value

func _column_label(text: String, min_width: float, expand: bool, ratio: float = 1.0) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"DimLabel"
	l.custom_minimum_size = Vector2(min_width, 0.0)
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_stretch_ratio = ratio
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l

## Binding cells sit on a dark panel, so they get a lighter face than the theme's buttons,
## a clear focus state, and a yellow frame while capturing.
func _make_cell_styles() -> void:
	var base := get_theme_stylebox(&"normal", &"Button").duplicate() as StyleBoxFlat
	if base == null:
		base = StyleBoxFlat.new()
	base.set_border_width_all(0)
	base.content_margin_top = 4.0
	base.content_margin_bottom = 4.0
	var normal := base.duplicate() as StyleBoxFlat
	normal.bg_color = Color(1, 1, 1, 0.07)
	var hover := base.duplicate() as StyleBoxFlat
	hover.bg_color = Color(1, 1, 1, 0.16)
	var focus := base.duplicate() as StyleBoxFlat
	focus.bg_color = Color(COL_ACCENT, 0.45)
	focus.border_color = COL_HILITE
	focus.border_width_left = 6
	var capture := base.duplicate() as StyleBoxFlat
	capture.bg_color = Color(COL_CAPTURE, 0.16)
	capture.border_color = COL_CAPTURE
	capture.set_border_width_all(2)
	_cell_styles = {"normal": normal, "hover": hover, "focus": focus, "capture": capture}

func _style_cell(b: Button, capturing: bool = false) -> void:
	for state: String in ["normal", "hover", "focus", "pressed"]:
		var style: StyleBox = _cell_styles["capture"] if capturing else _cell_styles.get(state, _cell_styles["hover"])
		b.add_theme_stylebox_override(state, style)

func _make_button(text: String, min_size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	return b

func _build_dialog() -> void:
	_dialog = Control.new()
	_dialog.name = "Dialog"
	_dialog.visible = false
	_dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.add_child(_dialog)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dialog.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dialog.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(COL_BG, 0.97)
	style.border_color = COL_HILITE
	style.border_width_left = 8
	style.set_content_margin_all(36.0)
	style.content_margin_left = 48.0
	panel.add_theme_stylebox_override(&"panel", style)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 28)
	panel.add_child(box)
	_dialog_text = Label.new()
	_dialog_text.theme_type_variation = &"HeaderLabel"
	_dialog_text.custom_minimum_size = Vector2(760.0, 0.0)
	_dialog_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_dialog_text)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 16)
	box.add_child(buttons)
	_dialog_ok = _make_button("OK", Vector2(300, 58))
	_style_cell(_dialog_ok)
	_dialog_ok.name = "DialogOk"
	_dialog_ok.pressed.connect(_on_dialog_ok)
	buttons.add_child(_dialog_ok)
	_dialog_cancel = _make_button("CANCEL", Vector2(300, 58))
	_style_cell(_dialog_cancel)
	_dialog_cancel.name = "DialogCancel"
	_dialog_cancel.pressed.connect(_close_dialog)
	buttons.add_child(_dialog_cancel)
	# Keep keyboard / gamepad focus inside the dialog while it is open.
	for b: Button in [_dialog_ok, _dialog_cancel]:
		var other: Button = _dialog_cancel if b == _dialog_ok else _dialog_ok
		for side: Side in [SIDE_LEFT, SIDE_RIGHT]:
			b.set_focus_neighbor(side, b.get_path_to(other))
		for side: Side in [SIDE_TOP, SIDE_BOTTOM]:
			b.set_focus_neighbor(side, b.get_path_to(b))
		b.focus_next = b.get_path_to(other)
		b.focus_previous = b.get_path_to(other)

# ---------------------------------------------------------------------------- refresh

func _cell_key(action: String, slot: int) -> String:
	return "%s:%d" % [action, slot]

## The button of a binding cell (tests, pause menu).
func cell(action: String, slot: int) -> Button:
	return _cells.get(_cell_key(action, slot)) as Button

func _refresh() -> void:
	for action: String in InputBindings.actions():
		for slot in InputBindings.SLOT_COUNT:
			var b := cell(action, slot)
			var pad := InputBindings.is_pad_slot(slot)
			var is_cap := _capturing and action == _cap_action and slot == _cap_slot
			if is_cap:
				b.text = "PRESS A BUTTON / MOVE A STICK…" if pad else "PRESS A KEY…"
			else:
				b.text = InputBindings.slot_label(action, slot)
			for c: StringName in [&"font_color", &"font_focus_color", &"font_hover_color"]:
				if is_cap:
					b.add_theme_color_override(c, COL_CAPTURE)
				else:
					b.remove_theme_color_override(c)
			b.add_theme_font_size_override(&"font_size", 22 if is_cap and pad else 26)
			_style_cell(b, is_cap)
	for key: String in _sliders:
		var v := float(Settings.get_value("controls", key))
		(_sliders[key] as HSlider).set_value_no_signal(v)
		(_slider_values[key] as Label).text = ("%d %%" % roundi(v * 100.0)) if key == "gamepad_deadzone" else ("%.2f s" % v)
	_update_hint()

func _update_hint() -> void:
	if _capturing:
		var what := "Press a button or move a stick" if InputBindings.is_pad_slot(_cap_slot) else "Press a key"
		_hint.text = "%s for %s   ·   ESC cancel   ·   DEL / BACKSPACE unbind   ·   %d" % [
				what, InputBindings.display_name(_cap_action), ceili(_cap_time_left)]
		_hint.add_theme_color_override(&"font_color", COL_CAPTURE)
	else:
		_hint.text = HINT_IDLE
		_hint.remove_theme_color_override(&"font_color")

func _on_setting_changed(section: String, _key: String) -> void:
	if section == "controls":
		_dirty = true
		_refresh()

func _on_slider_changed(value: float, key: String) -> void:
	Settings.set_value("controls", key, snappedf(value, 0.01))

## UIScreen hook (deferred after _ready): start on the first binding cell.
func _grab_initial_focus() -> void:
	if not is_inside_tree() or _capturing:
		return
	if is_dialog_open():
		_dialog_cancel.grab_focus()
	else:
		cell(InputBindings.actions()[0], InputBindings.SLOT_KEY_1).grab_focus()

# ---------------------------------------------------------------------------- capture

func is_capturing() -> bool:
	return _capturing

## Starts listening for the new input of a cell.
func begin_capture(action: String, slot: int) -> void:
	if _capturing or is_dialog_open() or cell(action, slot) == null:
		return
	_capturing = true
	_cap_action = action
	_cap_slot = slot
	_cap_time_left = CAPTURE_TIMEOUT
	_cap_frame = Engine.get_process_frames()
	_cap_blocked.clear()
	for device: int in Input.get_connected_joypads():
		for axis in JOY_AXIS_MAX:
			if absf(Input.get_joy_axis(device, axis as JoyAxis)) >= CAPTURE_AXIS_OFF:
				_cap_blocked["%d:%d" % [device, axis]] = true
	cell(action, slot).grab_focus()
	_refresh()

func cancel_capture() -> void:
	if not _capturing:
		return
	_capturing = false
	_refresh()

func _input(event: InputEvent) -> void:
	if not _capturing:
		return
	if event is InputEventMouseButton:
		if (event as InputEventMouseButton).button_index > MOUSE_BUTTON_MIDDLE:
			return   # wheel scrolling neither cancels nor is swallowed
	elif not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	# Nothing else (focus navigation, ui_cancel, the pause action...) sees input meanwhile.
	get_viewport().set_input_as_handled()
	handle_capture_event(event)

## Feeds one input event to the running capture (also the test entry point).
func handle_capture_event(event: InputEvent) -> void:
	if not _capturing:
		return
	var pad_slot := InputBindings.is_pad_slot(_cap_slot)
	if event is InputEventMouseButton:
		if (event as InputEventMouseButton).pressed and Engine.get_process_frames() != _cap_frame:
			cancel_capture()
	elif event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return
		var code: Key = k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		# Esc / Delete / Backspace are capture commands, but they are also default bindings
		# (pause, restart, respawn): on a cell that is already empty they bind like any key,
		# so "unbind, then press it" puts them back without resetting everything.
		var reserved := code == KEY_ESCAPE or code == KEY_DELETE or code == KEY_BACKSPACE
		if reserved and not pad_slot and InputBindings.get_event(_cap_action, _cap_slot) == null:
			_finish_capture(event)
		elif code == KEY_ESCAPE:
			cancel_capture()
		elif code == KEY_DELETE or code == KEY_BACKSPACE:
			var action := _cap_action
			var slot := _cap_slot
			cancel_capture()
			InputBindings.clear(action, slot)
			_refresh()
		elif not pad_slot and code != KEY_NONE:
			_finish_capture(event)
	elif event is InputEventJoypadButton:
		if not (event as InputEventJoypadButton).pressed:
			return
		if pad_slot:
			_finish_capture(event)
		else:
			cancel_capture()   # gamepad-only players can back out of a keyboard cell
	elif event is InputEventJoypadMotion and pad_slot:
		var m := event as InputEventJoypadMotion
		var id := "%d:%d" % [m.device, m.axis]
		if absf(m.axis_value) < CAPTURE_AXIS_OFF:
			_cap_blocked.erase(id)
		elif absf(m.axis_value) >= CAPTURE_AXIS_ON and not _cap_blocked.has(id):
			_finish_capture(event)

func _finish_capture(event: InputEvent) -> void:
	var action := _cap_action
	var slot := _cap_slot
	cancel_capture()
	_on_captured(action, slot, event)

func _on_captured(action: String, slot: int, event: InputEvent) -> void:
	var other := InputBindings.find_conflict(event, action)
	if other.is_empty():
		InputBindings.rebind(action, slot, event)
		_refresh()
		return
	var text := "%s is already used by %s — swap?" % [InputBindings.event_label(event), InputBindings.display_name(other)]
	var do_swap := func() -> void:
		InputBindings.swap(action, slot, event)
		_refresh()
	_open_dialog(text, "SWAP", do_swap, cell(action, slot))

# ---------------------------------------------------------------------------- dialog

func is_dialog_open() -> bool:
	return _dialog != null and _dialog.visible

func dialog_text() -> String:
	return _dialog_text.text

func _ask_reset() -> void:
	var do_reset := func() -> void:
		Settings.reset("controls")   # bindings, steering feel, dead zone
		InputBindings.apply()
		_dirty = true
		_refresh()
	_open_dialog("Reset all controls to their defaults?", "RESET", do_reset, _reset_button)

func _open_dialog(text: String, ok_text: String, on_ok: Callable, return_focus: Control) -> void:
	_dialog_text.text = text
	_dialog_ok.text = ok_text
	_dialog_action = on_ok
	_dialog_return_focus = return_focus
	_dialog.visible = true
	_dialog.move_to_front()
	_dialog_cancel.grab_focus()

## Confirms the open dialog (SWAP / RESET).
func _on_dialog_ok() -> void:
	var action := _dialog_action
	_close_dialog()
	if action.is_valid():
		action.call()

func _close_dialog() -> void:
	_dialog.visible = false
	_dialog_action = Callable()
	if is_instance_valid(_dialog_return_focus) and _dialog_return_focus.is_inside_tree():
		_dialog_return_focus.grab_focus()
	_dialog_return_focus = null

# ---------------------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if _capturing and not _cap_frozen:
		var before := ceili(_cap_time_left)
		_cap_time_left -= delta
		if _cap_time_left <= 0.0:
			cancel_capture()
		elif ceili(_cap_time_left) != before:
			_update_hint()
	_update_preview(delta)

## Same smoothing as the car (Car._update_steer_smoothing), fed by the live bindings.
func _update_preview(delta: float) -> void:
	var l := Input.get_action_strength(&"steer_left")
	var r := Input.get_action_strength(&"steer_right")
	var target := 0.0 if (_capturing or is_dialog_open()) else clampf(r - l, -1.0, 1.0)
	var digital := (l == 0.0 or l == 1.0) and (r == 0.0 or r == 1.0)
	preview_steer = smooth_steer(preview_steer, target, delta,
			float(Settings.get_value("controls", "key_steer_in_time")) if digital else ANALOG_IN_TIME,
			float(Settings.get_value("controls", "key_steer_out_time")) if digital else ANALOG_OUT_TIME)
	if _steer_bar != null:
		_steer_bar.value = preview_steer
		_steer_value.text = "%+.2f" % preview_steer if absf(preview_steer) > 0.005 else "0.00"

static func smooth_steer(current: float, target: float, dt: float, t_in: float, t_out: float) -> float:
	if current != 0.0 and signf(target) != signf(current):
		return move_toward(current, 0.0, dt / maxf(t_out, 0.001))
	if absf(target) < absf(current):
		return move_toward(current, target, dt / maxf(t_out, 0.001))
	return move_toward(current, target, dt / maxf(t_in, 0.001))

## Live steering bar: centre tick, blue fill towards the current lock. Focusable so that the
## arrow keys / stick can be held on it without moving the menu focus.
class SteerBar extends Control:
	var value: float = 0.0:
		set(v):
			if not is_equal_approx(v, value):
				value = v
				queue_redraw()

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		focus_entered.connect(queue_redraw)
		focus_exited.connect(queue_redraw)

	func _gui_input(event: InputEvent) -> void:
		if event.is_action(&"ui_left") or event.is_action(&"ui_right"):
			accept_event()

	func _draw() -> void:
		var bar := Rect2(0.0, size.y * 0.5 - 7.0, size.x, 14.0)
		draw_rect(bar, Color(1, 1, 1, 0.18))
		var mid := size.x * 0.5
		var x := mid + clampf(value, -1.0, 1.0) * mid
		draw_rect(Rect2(minf(mid, x), bar.position.y, absf(x - mid), bar.size.y), UIScreen.COL_ACCENT)
		draw_rect(Rect2(mid - 1.0, 0.0, 2.0, size.y), Color(1, 1, 1, 0.7))
		draw_rect(Rect2(clampf(x - 3.0, 0.0, size.x - 6.0), 2.0, 6.0, size.y - 4.0), UIScreen.COL_TEXT)
		if has_focus():
			draw_rect(Rect2(-8.0, -2.0, size.x + 16.0, size.y + 4.0), UIScreen.COL_HILITE, false, 2.0)
