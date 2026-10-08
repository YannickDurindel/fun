extends Control
## Pause overlay of the race scene (UI/PauseMenu). The `pause` action (Esc / pad Start by
## default, rebindable) toggles it; ui_cancel (menu "back") only closes it. It works
## through Game.set_paused() and keeps processing while the tree is paused, so the race, the
## countdown, the car and the engine audio (all pausable) freeze behind it.
##   RESUME / RESTART (back to the grid) / END SESSION (time attack: results with the laps so
##   far) / OPTIONS (the settings screen in an overlay) / TRACK SELECT / MAIN MENU.
## Joins group "pause_menu": the race scene's temporary Esc-quits-to-menu steps aside for it.
## Dev flag: --pause-at=FRAMES opens the menu after that many frames (screenshots).
## Designed at 1080p and scaled to the viewport height, like the menus.

signal opened
signal closed

const SlantedPanel := preload("res://scripts/ui/slanted_panel.gd")
const RaceTimer := preload("res://scripts/ui/race_timer.gd")
const SETTINGS_SCENE := "res://scenes/menu/settings.tscn"
const REF_HEIGHT: float = 1080.0
const LEFT: float = 140.0
const BUTTON_SIZE := Vector2(520, 64)
const HUD_PATHS: Array[NodePath] = [^"../RacePanel", ^"../HUD"]

var race: RaceManager

var _dim: ColorRect
var _root: Control            ## 1080p design space, scaled to the viewport
var _menu: Control            ## title, info and buttons (hidden while the options are open)
var _track_label: Label
var _mode_label: Label
var _info_label: Label
var _buttons: Dictionary = {} ## name -> Button
var _options_layer: Control   ## holds the settings screen while it is open
var _options: Node
var _options_self_closing: bool = false
var _pause_at: int = -1
var _frame: int = 0
var _hidden_hud: Array[CanvasItem] = []
var _resume_pending: bool = false   ## menu closed, waiting for the respawn key to be let go

func _enter_tree() -> void:
	add_to_group(&"pause_menu")

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	register_pause_action()
	_build()
	race = get_tree().get_first_node_in_group(&"race_manager") as RaceManager
	Game.pause_changed.connect(_on_pause_changed)
	resized.connect(_layout)
	_layout()
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--pause-at="):
			_pause_at = int(a.get_slice("=", 1))
	set_process(_pause_at >= 0)
	if _pause_at >= 0:
		# Dev: --screenshot counts frames in Bootstrap, which would stop with the tree.
		Bootstrap.process_mode = Node.PROCESS_MODE_ALWAYS

func _exit_tree() -> void:
	# Leaving the race with the menu open (scene change, test teardown) never leaves the
	# tree paused.
	if visible or _resume_pending:
		visible = false
		_resume_pending = false
		Game.set_paused(false)

## `pause`: Escape / pad Start. Only added when missing: the rebindable controls own it when
## they are there.
static func register_pause_action() -> void:
	if InputMap.has_action(&"pause"):
		return
	InputMap.add_action(&"pause")
	var k := InputEventKey.new()
	k.physical_keycode = KEY_ESCAPE
	InputMap.action_add_event(&"pause", k)
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_START
	InputMap.action_add_event(&"pause", b)

# ---------------------------------------------------------------- construction
func _build() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0.0, 0.01, 0.03, 0.62)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)

	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_menu = Control.new()
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_menu)

	# Darker band behind the column so the text reads over any scenery.
	var band: Control = SlantedPanel.new()
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.position = Vector2(-80, 0)
	band.size = Vector2(880, REF_HEIGHT)
	band.set(&"slant", 110.0)
	band.set(&"color", Color(0.02, 0.025, 0.04, 0.55))
	_menu.add_child(band)
	var bar := ColorRect.new()
	bar.color = UIScreen.COL_HILITE
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.position = Vector2(LEFT, 150)
	bar.size = Vector2(96, 8)
	_menu.add_child(bar)

	var box := VBoxContainer.new()
	box.position = Vector2(LEFT, 166)
	box.add_theme_constant_override(&"separation", 12)
	_menu.add_child(box)
	var title := Label.new()
	title.text = "PAUSED"
	title.theme_type_variation = &"TitleLabel"
	box.add_child(title)
	_track_label = Label.new()
	_track_label.theme_type_variation = &"HeaderLabel"
	box.add_child(_track_label)
	_mode_label = Label.new()
	_mode_label.add_theme_color_override(&"font_color", UIScreen.COL_ACCENT.lightened(0.35))
	box.add_child(_mode_label)
	_info_label = Label.new()
	_info_label.add_theme_color_override(&"font_color", UIScreen.COL_TEXT_DIM)
	box.add_child(_info_label)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 22)
	box.add_child(gap)
	_button(box, "resume", "RESUME", resume)
	_button(box, "restart", "RESTART", _on_restart)
	_button(box, "end_session", "END SESSION", _on_end_session)
	_button(box, "options", "OPTIONS", open_options)
	_button(box, "tracks", "TRACK SELECT", func() -> void: Game.quit_to_menu("tracks"))
	_button(box, "menu", "MAIN MENU", func() -> void: Game.quit_to_menu())

	var hint := Label.new()
	hint.text = "ESC / START   RESUME"
	hint.theme_type_variation = &"DimLabel"
	hint.position = Vector2(LEFT, REF_HEIGHT - 96)
	_menu.add_child(hint)

	_options_layer = Control.new()
	_options_layer.visible = false
	_root.add_child(_options_layer)

func _button(parent: Node, id: String, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.name = id.to_pascal_case()
	b.text = text
	b.custom_minimum_size = BUTTON_SIZE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(action)
	parent.add_child(b)
	_buttons[id] = b
	return b

func button(id: String) -> Button:
	return _buttons.get(id) as Button

func _layout() -> void:
	var k := clampf(size.y / REF_HEIGHT, 0.2, 8.0)
	_root.scale = Vector2(k, k)
	_root.position = Vector2.ZERO
	_root.size = Vector2(size.x / k, REF_HEIGHT)
	_menu.size = _root.size
	_options_layer.size = _root.size
	for c in _options_layer.get_children():
		if c is Control and (c as Control).get_meta(&"fill", false):
			(c as Control).size = _root.size

# ---------------------------------------------------------------- pause state
func is_open() -> bool:
	return visible

func is_options_open() -> bool:
	return _options != null

## No pausing once the run is over (the results screen is the menu then).
func can_pause() -> bool:
	# Not while a scene transition / loading screen runs (it pauses the tree itself).
	var tr := get_node_or_null(^"/root/Transitions")
	if tr != null and tr.has_method(&"is_busy") and bool(tr.call(&"is_busy")):
		return false
	if race != null and is_instance_valid(race) and race.state == RaceManager.State.FINISHED:
		return false
	var results := get_tree().get_first_node_in_group(&"results_screen")
	return not (results != null and results.has_method(&"is_open") and results.call(&"is_open"))

func open() -> void:
	if visible or not can_pause():
		return
	_resume_pending = false
	_refresh_info()
	_set_hud_hidden(true)
	visible = true
	_menu.visible = true
	Game.set_paused(true)
	button("resume").grab_focus()
	opened.emit()

func resume() -> void:
	if not visible:
		return
	_hide()
	# Enter and pad B confirm / close menus but are also "respawn": the race only resumes once
	# they are released, so closing the menu never teleports the car.
	if InputMap.has_action(&"respawn") and Input.is_action_pressed(&"respawn"):
		_resume_pending = true
		set_process(true)
		return
	Game.set_paused(false)

func toggle() -> void:
	if visible:
		resume()
	else:
		open()

func _hide() -> void:
	if not visible:
		return
	close_options()
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		focused.release_focus()
	visible = false
	_set_hud_hidden(false)
	closed.emit()

## The race HUD steps aside while this screen is up (only what was visible comes back).
func _set_hud_hidden(hide: bool) -> void:
	if hide:
		for path: NodePath in HUD_PATHS:
			var n := get_node_or_null(path) as CanvasItem
			if n != null and n.visible:
				n.visible = false
				_hidden_hud.append(n)
	else:
		for n in _hidden_hud:
			if is_instance_valid(n):
				n.visible = true
		_hidden_hud.clear()

func _on_pause_changed(paused: bool) -> void:
	# Something else resumed the game (restart, quit to menu): the overlay goes with it.
	if not paused:
		_resume_pending = false
		_hide()

func _on_restart() -> void:
	resume()
	if race != null and is_instance_valid(race):
		race.restart()
	else:
		Game.restart_race()

func _on_end_session() -> void:
	resume()
	if race != null and is_instance_valid(race):
		race.end_session()

func _refresh_info() -> void:
	var info := Game.current_track()
	var track_name := info.name if info != null else ""
	var endless := true
	var parts: PackedStringArray = []
	if race != null and is_instance_valid(race):
		if race.data != null and track_name.is_empty():
			track_name = race.data.name
		endless = race.target_laps <= 0
		if race.state == RaceManager.State.COUNTDOWN:
			parts.append("ON THE GRID")
		elif race.out_lap:
			parts.append("OUT LAP")
		elif endless:
			parts.append("LAP %d" % (race.laps_completed + 1))
		else:
			parts.append("LAP %d / %d" % [mini(race.laps_completed + 1, race.target_laps), race.target_laps])
		if race.state == RaceManager.State.RACING:
			parts.append("LAP TIME  " + RaceTimer.format_time(race.lap_time()))
		parts.append("BEST  " + (RaceTimer.format_time(race.best_lap) if race.best_lap > 0.0 else "-:--.---"))
		_mode_label.text = "TIME ATTACK" if endless else "RACE  -  %d LAP%s" % [race.target_laps, "" if race.target_laps == 1 else "S"]
	else:
		_mode_label.text = ""
	_track_label.text = track_name.to_upper()
	_info_label.text = "     ".join(parts)
	button("end_session").visible = endless and race != null

func get_info_text() -> String:
	return _info_label.text

func get_track_text() -> String:
	return _track_label.text

# ---------------------------------------------------------------- options overlay
## Shows the settings screen over the pause menu. A screen with a `closed` signal closes
## itself; otherwise (the stub) a CLOSE button and ui_cancel do it.
func open_options() -> void:
	if _options != null or not visible:
		return
	var packed := load(SETTINGS_SCENE) as PackedScene
	if packed == null:
		return
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.03, 0.035, 0.05, 0.9)
	backdrop.set_meta(&"fill", true)
	backdrop.size = _root.size
	_options_layer.add_child(backdrop)
	_options = packed.instantiate()
	_options_self_closing = _options.has_signal(&"closed")
	if _options_self_closing:
		_options.connect(&"closed", close_options)
	_menu.visible = false
	_options_layer.visible = true
	if _options is Control:
		var c := _options as Control
		c.set_meta(&"fill", true)
		_options_layer.add_child(c)
		c.set_anchors_preset(Control.PRESET_TOP_LEFT)
		c.position = Vector2.ZERO
		c.size = _root.size
	else:
		_options_layer.add_child(_options)
	if not _options_self_closing:
		var b := Button.new()
		b.name = "CloseOptions"
		b.text = "CLOSE"
		b.custom_minimum_size = Vector2(320, 64)
		b.position = Vector2(LEFT, REF_HEIGHT - 150)
		b.pressed.connect(close_options)
		_options_layer.add_child(b)
		if get_viewport().gui_get_focus_owner() == null or not _options_layer.is_ancestor_of(get_viewport().gui_get_focus_owner()):
			b.grab_focus.call_deferred()

func close_options() -> void:
	if _options == null:
		return
	_options = null
	for c in _options_layer.get_children():
		c.queue_free()
	_options_layer.visible = false
	_menu.visible = true
	if visible:
		button("options").grab_focus()

# ---------------------------------------------------------------- input
func _input(event: InputEvent) -> void:
	# A settings screen without a `closed` signal (the stub) swallows ui_cancel without
	# closing: take it first. While a key is being captured for a binding, Esc belongs to that.
	if _options != null and not _options_self_closing and not _options_capturing() and _is_press(event, &"ui_cancel"):
		get_viewport().set_input_as_handled()
		close_options()

func _unhandled_input(event: InputEvent) -> void:
	if _options != null:
		return
	# `pause` toggles. ui_cancel is the menus' "back" (and pad B is also "respawn"): it only
	# closes the menu, never opens it.
	if not (_is_press(event, &"pause") or (visible and _is_press(event, &"ui_cancel"))):
		return
	if not visible and not can_pause():
		return
	get_viewport().set_input_as_handled()
	toggle()

## True while the embedded options (controls screen) wait for a key to bind.
func _options_capturing() -> bool:
	return _options != null and is_instance_valid(_options) and _options.has_method(&"is_capturing") \
			and bool(_options.call(&"is_capturing"))

static func _is_press(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action) and not event.is_echo()

func _process(_delta: float) -> void:
	if _resume_pending and not Input.is_action_pressed(&"respawn"):
		_resume_pending = false
		Game.set_paused(false)
	if _pause_at >= 0:
		_frame += 1
		if _frame >= _pause_at:
			_pause_at = -1
			open()
	set_process(_resume_pending or _pause_at >= 0)
