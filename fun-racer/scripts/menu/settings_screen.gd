class_name SettingsScreen
extends UIScreen
## Options screen: GRAPHICS / AUDIO / GAMEPLAY tabs plus a CONTROLS... button.
## Every row edits one `Settings` key; `SettingsApply` makes the change real at once, so there
## is no "apply" step. Leaving the screen saves the file.
##   * Keyboard / gamepad: up/down picks a row, left/right changes it, PageUp/PageDown, Q/E or
##     LB/RB switch tabs, Esc / B goes back. Hovering a row with the mouse focuses it.
##   * Also usable without the menu router (in-race pause menu): instance the scene, listen to
##     `closed`. It runs while the tree is paused and fits itself to its parent's height.
## Dev flag (after `--`): --tab=graphics|audio|gameplay opens on that tab.

## Emitted instead of router.back() when the screen was opened without a router.
signal closed

const REF_HEIGHT: float = 1080.0
const TAB_NAMES: Array[String] = ["graphics", "audio", "gameplay"]
const TAB_HELP: Dictionary = {
	"graphics": "Display, image quality and performance.",
	"audio": "Volume of the engine, effects and menu sounds.",
	"gameplay": "What the in-race display shows.",
}
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i(3840, 2160),
]
const COL_ROW_FOCUS := Color(0.10, 0.14, 0.24, 0.92)
const BOLD_FONT := preload("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")
const LEFT: float = 140.0
const PANEL_WIDTH: float = 1140.0

## Left/right value picker: "<  VALUE  >". `options` is a list of [text, value].
class Stepper extends Control:
	signal picked(value: Variant)

	var options: Array = []
	var index: int = -1
	## Shown when the current value is none of the options (e.g. a custom preset).
	var fallback_text: String = ""
	var enabled: bool = true:
		set(v):
			enabled = v
			queue_redraw()

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		custom_minimum_size = Vector2(520, 52)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	## Shows `value` without emitting `picked`.
	func select_value(value: Variant) -> void:
		index = -1
		for i in options.size():
			var v: Variant = options[i][1]
			if typeof(v) == typeof(value) and v == value:
				index = i
			elif (v is float or v is int) and (value is float or value is int) and is_equal_approx(float(v), float(value)):
				index = i
		queue_redraw()

	func current_value() -> Variant:
		return options[index][1] if index >= 0 and index < options.size() else null

	func text() -> String:
		return str(options[index][0]) if index >= 0 and index < options.size() else fallback_text

	func can_step(dir: int) -> bool:
		if not enabled or options.is_empty():
			return false
		if index < 0:
			return true
		return index + dir >= 0 and index + dir < options.size()

	## Moves by `dir` (-1 / +1). With `wrap` the ends join up (used for accept / click).
	func step(dir: int, wrap: bool = false) -> void:
		if not enabled or options.is_empty():
			return
		var n := options.size()
		var next: int
		if index < 0:
			next = n - 1 if dir < 0 else 0
		elif wrap:
			next = posmod(index + dir, n)
		else:
			next = clampi(index + dir, 0, n - 1)
		if next == index:
			return
		index = next
		queue_redraw()
		picked.emit(options[index][1])

	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed(&"ui_left", true):
			step(-1)
			accept_event()
		elif event.is_action_pressed(&"ui_right", true):
			step(1)
			accept_event()
		elif event.is_action_pressed(&"ui_accept"):
			step(1, true)
			accept_event()
		elif event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
				grab_focus()
				if mb.position.x < size.x * 0.3:
					step(-1)
				else:
					step(1, mb.position.x < size.x * 0.7)
				accept_event()

	func _draw() -> void:
		var font := get_theme_font(&"font", &"Button")
		var fs := 30
		var dim := 1.0 if enabled else 0.35
		var y := (size.y + font.get_ascent(fs) - font.get_descent(fs)) * 0.5
		draw_string(font, Vector2(40, y), text(), HORIZONTAL_ALIGNMENT_CENTER, size.x - 80, fs, Color(1, 1, 1, dim))
		var cy := size.y * 0.5
		var a := 9.0
		var col_l := Color(UIScreen.COL_ACCENT, 1.0) if can_step(-1) else Color(1, 1, 1, 0.15)
		var col_r := Color(UIScreen.COL_ACCENT, 1.0) if can_step(1) else Color(1, 1, 1, 0.15)
		draw_colored_polygon(PackedVector2Array([Vector2(12, cy), Vector2(12 + a * 1.3, cy - a), Vector2(12 + a * 1.3, cy + a)]), col_l)
		var rx := size.x - 12
		draw_colored_polygon(PackedVector2Array([Vector2(rx, cy), Vector2(rx - a * 1.3, cy - a), Vector2(rx - a * 1.3, cy + a)]), col_r)

## One option: name on the left, its widget on the right, highlighted while the widget has focus.
class Row extends HBoxContainer:
	var section: String = ""
	var key: String = ""
	var description: String = ""
	## The control that takes focus (a Stepper or an HSlider).
	var widget: Control
	var stepper: Stepper
	var slider: HSlider
	var value_label: Label
	var title: Label
	## Slider rows: the setting is slider.value * scale.
	var scale_to_setting: float = 1.0

	func _init() -> void:
		custom_minimum_size = Vector2(0, 60)
		mouse_filter = Control.MOUSE_FILTER_PASS
		add_theme_constant_override(&"separation", 0)

	func _draw() -> void:
		if widget == null or not widget.has_focus():
			return
		var k := size.y * 0.06
		draw_colored_polygon(PackedVector2Array([Vector2(k, 0), Vector2(size.x, 0), Vector2(size.x - k, size.y), Vector2(0, size.y)]),
				SettingsScreen.COL_ROW_FOCUS)
		draw_colored_polygon(PackedVector2Array([Vector2(k, 0), Vector2(k + 6, 0), Vector2(6, size.y), Vector2(0, size.y)]),
				UIScreen.COL_HILITE)

## Tab shown right now: "graphics", "audio" or "gameplay".
var current_tab: String = ""
## The quality preset picker (graphics tab).
var preset_stepper: Stepper
var back_button: Button
var reset_button: Button
var controls_button: Button

var _content: Control
var _tab_buttons: Dictionary = {}   # tab -> Button
var _pages: Dictionary = {}         # tab -> VBoxContainer
var _rows: Dictionary = {}          # tab -> Array[Row]
var _by_key: Dictionary = {}        # "section/key" -> Row
var _desc: Label
var _blip: AudioStreamPlayer
var _dirty: bool = false
## Process frame of the last real mouse movement: hovering only moves focus when the mouse
## itself moved, not when a row appears under a resting cursor.
var _mouse_frame: int = -10

func on_enter() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	Settings.changed.connect(_on_setting_changed)
	resized.connect(_fit)
	_fit()
	_refresh()
	var start := TAB_NAMES[0]
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--tab=") and arg.get_slice("=", 1) in TAB_NAMES:
			start = arg.get_slice("=", 1)
	show_tab(start)
	initial_focus = get_path_to(_first_widget())

func on_back() -> void:
	_save_if_dirty()
	if router != null:
		router.back()
	else:
		closed.emit()

func _exit_tree() -> void:
	_save_if_dirty()

func _save_if_dirty() -> void:
	if _dirty:
		_dirty = false
		Settings.save()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_frame = Engine.get_process_frames()

func _hover_focus(c: Control) -> void:
	if Engine.get_process_frames() - _mouse_frame <= 1:
		c.grab_focus()

func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var dir := 0
	if event is InputEventJoypadButton and event.is_pressed():
		var jb := event as InputEventJoypadButton
		if jb.button_index == JOY_BUTTON_LEFT_SHOULDER:
			dir = -1
		elif jb.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			dir = 1
	elif event is InputEventKey and event.is_pressed() and not event.is_echo():
		var kc := (event as InputEventKey).keycode
		if kc == KEY_PAGEUP or kc == KEY_Q:
			dir = -1
		elif kc == KEY_PAGEDOWN or kc == KEY_E:
			dir = 1
	if dir != 0:
		get_viewport().set_input_as_handled()
		var i := clampi(TAB_NAMES.find(current_tab) + dir, 0, TAB_NAMES.size() - 1)
		if TAB_NAMES[i] != current_tab:
			show_tab(TAB_NAMES[i])
			_first_widget().grab_focus()
		return
	super(event)

# --- public helpers (also used by tests) ---

func show_tab(tab: String) -> void:
	if not _pages.has(tab):
		return
	current_tab = tab
	for t: String in _pages:
		(_pages[t] as Control).visible = t == tab
		(_tab_buttons[t] as Button).set_pressed_no_signal(t == tab)
	_wire_focus()
	var owner_of_focus := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if owner_of_focus == null or not is_ancestor_of(owner_of_focus) or not owner_of_focus.is_visible_in_tree():
		_set_description(TAB_HELP[tab])

## The row editing `section/key`, e.g. row("audio", "master").
func row(section: String, key: String) -> Row:
	return _by_key.get(section + "/" + key) as Row

## Restores every option of the current tab to its default.
func reset_current_tab() -> void:
	for r in _tab_rows(current_tab):
		if not r.key.is_empty():
			var d: Variant = Settings.default_value(r.section, r.key)
			Settings.set_value(r.section, r.key, d)

func description_text() -> String:
	return _desc.text

# --- building ---

func _build() -> void:
	_content = Control.new()
	_content.name = "Content"
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_content)

	var title := Label.new()
	title.text = "OPTIONS"
	title.theme_type_variation = &"TitleLabel"
	title.position = Vector2(LEFT, 56)
	_content.add_child(title)

	var tabs := HBoxContainer.new()
	tabs.name = "Tabs"
	tabs.position = Vector2(LEFT, 170)
	tabs.add_theme_constant_override(&"separation", 10)
	_content.add_child(tabs)
	for tab: String in TAB_NAMES:
		var b := _make_button(tab.to_upper(), 250)
		b.toggle_mode = true
		b.pressed.connect(show_tab.bind(tab))
		_describe(b, TAB_HELP[tab])
		tabs.add_child(b)
		_tab_buttons[tab] = b
	controls_button = _make_button("CONTROLS...", 250)
	controls_button.visible = router != null
	controls_button.pressed.connect(_open_controls)
	_describe(controls_button, "Key and gamepad bindings, steering response.")
	tabs.add_child(controls_button)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.position = Vector2(LEFT, 246)
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 608)
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BG
	sb.border_color = COL_ACCENT
	sb.border_width_top = 3
	sb.content_margin_top = 14
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override(&"panel", sb)
	_content.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 0)
	panel.add_child(column)
	var page_holder := Control.new()
	page_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(page_holder)
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.12)
	rule.custom_minimum_size = Vector2(0, 2)
	column.add_child(rule)
	var desc_margin := MarginContainer.new()
	desc_margin.add_theme_constant_override(&"margin_left", 30)
	desc_margin.add_theme_constant_override(&"margin_right", 30)
	desc_margin.add_theme_constant_override(&"margin_top", 12)
	desc_margin.add_theme_constant_override(&"margin_bottom", 4)
	column.add_child(desc_margin)
	_desc = Label.new()
	_desc.theme_type_variation = &"DimLabel"
	_desc.add_theme_font_size_override(&"font_size", 25)
	_desc.custom_minimum_size = Vector2(0, 34)
	_desc.clip_text = true
	desc_margin.add_child(_desc)

	for tab: String in TAB_NAMES:
		var page := VBoxContainer.new()
		page.name = tab.capitalize()
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		page.add_theme_constant_override(&"separation", 4)
		page_holder.add_child(page)
		_pages[tab] = page
		var list: Array[Row] = []
		_rows[tab] = list
	_build_graphics()
	_build_audio()
	_build_gameplay()

	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.position = Vector2(LEFT, 880)
	buttons.add_theme_constant_override(&"separation", 10)
	_content.add_child(buttons)
	back_button = _make_button("BACK", 250)
	back_button.pressed.connect(on_back)
	_describe(back_button, "Save the options and go back.")
	buttons.add_child(back_button)
	reset_button = _make_button("RESET TO DEFAULTS", 380)
	reset_button.pressed.connect(reset_current_tab)
	_describe(reset_button, "Put every option on this tab back to its default.")
	buttons.add_child(reset_button)

	var hint := Label.new()
	hint.theme_type_variation = &"DimLabel"
	hint.text = "LEFT / RIGHT  CHANGE        PAGE UP / DOWN  ·  LB / RB  SWITCH TAB        ESC  ·  B  BACK"
	hint.position = Vector2(LEFT + 6, 968)
	_content.add_child(hint)

	_blip = AudioStreamPlayer.new()
	_blip.stream = _make_blip()
	_blip.volume_db = -8.0
	add_child(_blip)

func _build_graphics() -> void:
	var preset_options: Array = []
	for preset: String in SettingsApply.PRESET_ORDER:
		preset_options.append([preset.to_upper(), preset])
	var preset_row := _add_choice("graphics", "", "", "QUALITY PRESET",
			"Sets anti-aliasing, shadows and render scale together. LOW suits integrated graphics.", preset_options)
	preset_stepper = preset_row.stepper
	preset_stepper.fallback_text = "CUSTOM"
	preset_stepper.picked.connect(func(v: Variant) -> void: SettingsApply.apply_preset(str(v)))
	_add_choice("graphics", "graphics", "fullscreen", "DISPLAY MODE",
			"Fullscreen uses the whole screen at its native resolution.", [["WINDOWED", false], ["FULLSCREEN", true]])
	_add_choice("graphics", "graphics", "resolution", "RESOLUTION",
			"Window size when not in fullscreen.", _resolution_options())
	_add_choice("graphics", "graphics", "vsync", "VSYNC",
			"Syncs frames to the display: no tearing, slightly more input delay.", [["OFF", false], ["ON", true]])
	_add_choice("graphics", "graphics", "fps_cap", "FPS CAP",
			"Limits the frame rate to keep the machine cool and quiet.",
			[["OFF", 0], ["30", 30], ["60", 60], ["120", 120], ["144", 144]])
	_add_choice("graphics", "graphics", "msaa", "ANTI-ALIASING",
			"Smooths jagged edges. Higher levels cost a lot on integrated graphics.",
			[["OFF", 0], ["MSAA 2X", 1], ["MSAA 4X", 2], ["MSAA 8X", 3]])
	_add_choice("graphics", "graphics", "shadows", "SHADOWS",
			"Resolution and softness of the sun shadows. OFF is the fastest.",
			[["OFF", 0], ["LOW", 1], ["MEDIUM", 2], ["HIGH", 3]])
	_add_slider("graphics", "graphics", "render_scale", "RENDER SCALE",
			"Renders the 3D view at a lower resolution, then upscales. The biggest speed-up.", 50, 100, 5)

func _build_audio() -> void:
	_add_slider("audio", "audio", "master", "MASTER", "Overall volume of the game.", 0, 100, 5)
	_add_slider("audio", "audio", "engine", "ENGINE", "Volume of the car's engine.", 0, 100, 5)
	_add_slider("audio", "audio", "fx", "EFFECTS", "Volume of tyre squeal and wind noise.", 0, 100, 5)
	_add_slider("audio", "audio", "ui", "MENU", "Volume of menu and interface sounds.", 0, 100, 5)

func _build_gameplay() -> void:
	_add_choice("gameplay", "gameplay", "speed_unit", "SPEED UNIT",
			"Unit of the speedometer.", [["KM/H", "kmh"], ["MPH", "mph"]])
	_add_choice("gameplay", "gameplay", "show_input_display", "INPUT DISPLAY",
			"Shows your throttle, brake and steering inputs in the corner of the screen.", [["OFF", false], ["ON", true]])

## Common sizes that fit the screen, plus whatever is currently set.
func _resolution_options() -> Array:
	var screen := DisplayServer.screen_get_size()
	var current := SettingsApply.parse_resolution(Settings.get_value("graphics", "resolution"))
	var sizes: Array[Vector2i] = []
	for r in RESOLUTIONS:
		if screen.x <= 0 or screen.y <= 0 or (r.x <= screen.x and r.y <= screen.y):
			sizes.append(r)
	if not sizes.has(current):
		sizes.append(current)
	sizes.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	var out: Array = []
	for r in sizes:
		out.append(["%d x %d" % [r.x, r.y], "%dx%d" % [r.x, r.y]])
	return out

func _new_row(tab: String, section: String, key: String, title: String, description: String) -> Row:
	var r := Row.new()
	r.section = section
	r.key = key
	r.description = description
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(34, 0)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_child(pad)
	r.title = Label.new()
	r.title.text = title
	r.title.add_theme_font_override(&"font", BOLD_FONT)
	r.title.add_theme_font_size_override(&"font_size", 30)
	r.title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(r.title)
	(_pages[tab] as Control).add_child(r)
	_tab_rows(tab).append(r)
	if not key.is_empty():
		_by_key[section + "/" + key] = r
	return r

func _finish_row(r: Row) -> void:
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(26, 0)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_child(pad)
	r.widget.focus_entered.connect(_on_row_focus.bind(r))
	r.widget.focus_exited.connect(r.queue_redraw)
	r.widget.mouse_entered.connect(_hover_focus.bind(r.widget))
	r.mouse_entered.connect(_hover_focus.bind(r.widget))

func _add_choice(tab: String, section: String, key: String, title: String, description: String, options: Array) -> Row:
	var r := _new_row(tab, section, key, title, description)
	r.stepper = Stepper.new()
	r.stepper.options = options
	r.stepper.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.widget = r.stepper
	r.add_child(r.stepper)
	if not key.is_empty():
		r.stepper.picked.connect(func(v: Variant) -> void: Settings.set_value(section, key, v))
	_finish_row(r)
	return r

## Slider in percent; the setting is the value / 100.
func _add_slider(tab: String, section: String, key: String, title: String, description: String,
		lo: int, hi: int, step: int) -> Row:
	var r := _new_row(tab, section, key, title, description)
	r.scale_to_setting = 0.01
	var box := HBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 52)
	box.add_theme_constant_override(&"separation", 18)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.slider = HSlider.new()
	r.slider.min_value = lo
	r.slider.max_value = hi
	r.slider.step = step
	r.slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.slider.size_flags_vertical = Control.SIZE_FILL
	r.slider.focus_mode = Control.FOCUS_ALL
	r.slider.add_theme_stylebox_override(&"focus", StyleBoxEmpty.new())
	box.add_child(r.slider)
	r.value_label = Label.new()
	r.value_label.custom_minimum_size = Vector2(96, 0)
	r.value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	r.value_label.add_theme_font_override(&"font", BOLD_FONT)
	r.value_label.add_theme_font_size_override(&"font_size", 30)
	box.add_child(r.value_label)
	r.widget = r.slider
	r.add_child(box)
	r.slider.value_changed.connect(_on_slider_changed.bind(r))
	_finish_row(r)
	return r

func _make_button(text: String, width: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(width, 60)
	b.mouse_entered.connect(_hover_focus.bind(b))
	return b

func _make_blip() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.09)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var env := minf(1.0, t / 0.004) * exp(-t / 0.025)
		data.encode_s16(i * 2, int(sin(TAU * 880.0 * t) * env * 20000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav

# --- behaviour ---

func _fit() -> void:
	if size.y <= 0.0:
		return
	# 1080-high design. Under the router the screen is already 1080 high (k = 1); instanced
	# straight into a viewport it scales itself.
	var k := size.y / REF_HEIGHT
	_content.scale = Vector2(k, k)
	_content.position = Vector2.ZERO
	_content.size = size / k

func _tab_rows(tab: String) -> Array[Row]:
	var rows: Array[Row] = _rows[tab]
	return rows

func _first_widget() -> Control:
	return _tab_rows(current_tab)[0].widget

func _wire_focus() -> void:
	var rows := _tab_rows(current_tab)
	var tab_button: Button = _tab_buttons[current_tab]
	var tab_like: Array[Button] = [controls_button]
	for t: String in _tab_buttons:
		tab_like.append(_tab_buttons[t])
	for b in tab_like:
		b.focus_neighbor_top = b.get_path_to(b)
		b.focus_neighbor_bottom = b.get_path_to(rows[0].widget)
	for i in rows.size():
		var w := rows[i].widget
		var up: Control = rows[i - 1].widget if i > 0 else tab_button
		var down: Control = rows[i + 1].widget if i < rows.size() - 1 else back_button
		w.focus_neighbor_top = w.get_path_to(up)
		w.focus_neighbor_bottom = w.get_path_to(down)
		w.focus_neighbor_left = w.get_path_to(w)
		w.focus_neighbor_right = w.get_path_to(w)
	var last := rows[rows.size() - 1].widget
	for b: Button in [back_button, reset_button]:
		b.focus_neighbor_top = b.get_path_to(last)
		b.focus_neighbor_bottom = b.get_path_to(b)
	back_button.focus_neighbor_left = back_button.get_path_to(back_button)
	back_button.focus_neighbor_right = back_button.get_path_to(reset_button)
	reset_button.focus_neighbor_left = reset_button.get_path_to(back_button)
	reset_button.focus_neighbor_right = reset_button.get_path_to(reset_button)

func _describe(c: Control, text: String) -> void:
	c.focus_entered.connect(_set_description.bind(text))

func _set_description(text: String) -> void:
	_desc.text = text

func _on_row_focus(r: Row) -> void:
	r.queue_redraw()
	_set_description(r.description)

func _open_controls() -> void:
	_save_if_dirty()
	if router != null:
		router.go("controls")

func _on_slider_changed(v: float, r: Row) -> void:
	r.value_label.text = "%d %%" % roundi(v)
	Settings.set_value(r.section, r.key, v * r.scale_to_setting)
	if r.section == "audio":
		_blip.bus = SettingsApply.BUSES.get(r.key, &"Master")
		_blip.play()

func _on_setting_changed(_section: String, _key: String) -> void:
	_dirty = true
	_refresh()

## Shows the stored settings in every widget (without re-emitting changes).
func _refresh() -> void:
	for id: String in _by_key:
		var r: Row = _by_key[id]
		var v: Variant = Settings.get_value(r.section, r.key)
		if r.stepper != null:
			# A stored value that is not on the list (hand-edited file) is still shown.
			r.stepper.fallback_text = str(v).to_upper()
			r.stepper.select_value(v)
		elif r.slider != null:
			# The slider snaps to its range and step; the label shows where the handle is.
			r.slider.set_value_no_signal(float(v) / r.scale_to_setting)
			r.value_label.text = "%d %%" % roundi(r.slider.value)
	preset_stepper.select_value(SettingsApply.current_preset())
	var res := row("graphics", "resolution")
	var fullscreen: bool = Settings.get_value("graphics", "fullscreen")
	res.stepper.enabled = not fullscreen
	res.title.modulate.a = 0.4 if fullscreen else 1.0
