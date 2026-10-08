class_name OptionRow
extends Control
## A menu row: "LABEL        < VALUE >". Focusable; ui_left / ui_right change the value,
## ui_accept cycles forward, and the arrows can be clicked.
##   var row := OptionRow.create("LAPS", ["1", "2", "3"], 0, false, "Number of laps.")
##   row.value_changed.connect(func(i: int) -> void: ...)
## `index` can be set from code without emitting value_changed.

signal value_changed(index: int)

const COL_PLATE := Color(0.03, 0.035, 0.05, 0.82)
const COL_PLATE_FOCUS := Color(0.1, 0.14, 0.24, 0.94)
const COL_HILITE := UIScreen.COL_HILITE
const SLANT := 8.0
const ARROW_ZONE := 64.0     ## clickable width around each arrow
const VALUE_WIDTH := 400.0   ## width of the "< value >" block on the right

var title: String = "":
	set(v):
		title = v
		queue_redraw()
var options: PackedStringArray = []:
	set(v):
		options = v
		index = index
		queue_redraw()
## Selected entry of `options`.
var index: int = 0:
	set(v):
		index = clampi(v, 0, maxi(0, options.size() - 1))
		queue_redraw()
## Left on the first entry jumps to the last (and back) instead of stopping.
var wrap: bool = false
## One-line help shown by the screen while this row has focus.
var description: String = ""
## A disabled row is dimmed, cannot be focused and shows `disabled_text` (if set).
var disabled: bool = false:
	set(v):
		disabled = v
		focus_mode = Control.FOCUS_NONE if v else Control.FOCUS_ALL
		mouse_default_cursor_shape = Control.CURSOR_ARROW if v else Control.CURSOR_POINTING_HAND
		queue_redraw()
var disabled_text: String = "":
	set(v):
		disabled_text = v
		queue_redraw()

var _hover: bool = false
var _axis_dir: int = 0   # direction an analog stick is currently held in (-1, 0, 1)

static func create(p_title: String, p_options: PackedStringArray, p_index: int = 0, p_wrap: bool = false,
		p_description: String = "") -> OptionRow:
	var r := OptionRow.new()
	r.title = p_title
	r.options = p_options
	r.index = p_index
	r.wrap = p_wrap
	r.description = p_description
	return r

func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = Vector2(600, 64)
	# Left / right change the value, they never move the focus away.
	focus_neighbor_left = NodePath(".")
	focus_neighbor_right = NodePath(".")

func _ready() -> void:
	focus_entered.connect(queue_redraw)
	focus_exited.connect(_on_focus_exited)
	resized.connect(queue_redraw)
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))

## Text of the selected entry.
func value_text() -> String:
	return options[index] if index < options.size() else ""

## Moves the selection by `dir` entries. Returns true (and emits value_changed) if it changed.
func step(dir: int, force_wrap: bool = false) -> bool:
	if disabled or options.is_empty():
		return false
	var n := options.size()
	var next := posmod(index + dir, n) if (wrap or force_wrap) else clampi(index + dir, 0, n - 1)
	if next == index:
		return false
	index = next
	value_changed.emit(index)
	return true

func can_step(dir: int) -> bool:
	if disabled or options.size() < 2:
		return false
	return wrap or (index + dir >= 0 and index + dir < options.size())

func _on_focus_exited() -> void:
	_axis_dir = 0
	queue_redraw()

func _set_hover(on: bool) -> void:
	_hover = on
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventJoypadMotion:
		# A stick sends a stream of motion events: step once per push, not once per event.
		if event.is_action(&"ui_left") or event.is_action(&"ui_right"):
			accept_event()
			var push := event.get_action_strength(&"ui_right") - event.get_action_strength(&"ui_left")
			var dir := 0 if absf(push) < 0.5 else (1 if push > 0.0 else -1)
			if dir != _axis_dir:
				_axis_dir = dir
				if dir != 0:
					step(dir)
	elif event.is_action_pressed(&"ui_left", true):
		accept_event()
		step(-1)
	elif event.is_action_pressed(&"ui_right", true):
		accept_event()
		step(1)
	elif event.is_action_pressed(&"ui_accept"):
		accept_event()
		step(1, true)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			grab_focus()
			var x0 := size.x - SLANT - VALUE_WIDTH
			if mb.position.x >= x0 and mb.position.x < x0 + ARROW_ZONE:
				step(-1)
			elif mb.position.x >= x0:
				step(1, mb.position.x < size.x - SLANT - ARROW_ZONE)

func _draw() -> void:
	var focused := has_focus() and not disabled
	var dim := 0.35 if disabled else 1.0
	var plate := COL_PLATE_FOCUS if (focused or (_hover and not disabled)) else COL_PLATE
	plate.a *= 0.55 if disabled else 1.0
	draw_colored_polygon(PackedVector2Array([Vector2(SLANT, 0), Vector2(size.x, 0),
			Vector2(size.x - SLANT, size.y), Vector2(0, size.y)]), plate)
	if focused:
		draw_colored_polygon(PackedVector2Array([Vector2(SLANT, 0), Vector2(SLANT + 7, 0),
				Vector2(7, size.y), Vector2(0, size.y)]), COL_HILITE)
	var font := get_theme_font(&"font", &"Button")
	var fs := get_theme_font_size(&"font_size", &"Button")
	var base := (size.y - font.get_height(fs)) * 0.5 + font.get_ascent(fs)
	draw_string(font, Vector2(34, base), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, dim))
	var x0 := size.x - SLANT - VALUE_WIDTH
	var text := disabled_text if (disabled and not disabled_text.is_empty()) else value_text()
	var value_col := Color(1, 1, 1, dim) if not focused else Color(1, 1, 1)
	draw_string(font, Vector2(x0 + ARROW_ZONE, base), text, HORIZONTAL_ALIGNMENT_CENTER,
			VALUE_WIDTH - ARROW_ZONE * 2.0, fs, value_col)
	if not disabled:
		_draw_arrow(Vector2(x0 + ARROW_ZONE * 0.5, size.y * 0.5), -1.0, focused)
		_draw_arrow(Vector2(x0 + VALUE_WIDTH - ARROW_ZONE * 0.5, size.y * 0.5), 1.0, focused)

func _draw_arrow(c: Vector2, dir: float, focused: bool) -> void:
	var col := (COL_HILITE if focused else Color(1, 1, 1, 0.7))
	if not can_step(int(dir)):
		col = Color(1, 1, 1, 0.15)
	var h := 11.0
	draw_colored_polygon(PackedVector2Array([c + Vector2(dir * h * 0.8, 0), c + Vector2(-dir * h * 0.6, -h),
			c + Vector2(-dir * h * 0.6, h)]), col)
