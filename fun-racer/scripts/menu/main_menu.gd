class_name MainMenu
extends UIScreen
## Title screen: FUN RACER logo, CONTINUE (last race, when there is one) / PLAY / RECORDS /
## OPTIONS / QUIT, an input hint footer and a version label. Laid out at 1920x1080 on the left,
## over the shared 3D backdrop. Keyboard, gamepad and mouse all drive the same focus highlight.

const VERSION := "0.1"
const SLANTED_PANEL := preload("res://scripts/ui/slanted_panel.gd")
const RaceTimer := preload("res://scripts/ui/race_timer.gd")
const BOLD_FONT := preload("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")
## Font of the hint footer (the theme default), to check which glyphs it can draw.
const HINT_FONT := preload("res://assets/ui/fonts/BarlowCondensed-SemiBoldItalic.ttf")

const LEFT: float = 140.0
const TITLE_Y: float = 120.0
const BUTTON_W: float = 560.0
const BUTTON_H: float = 76.0
const CONTINUE_H: float = 104.0
const BUTTON_GAP: float = 12.0
## The button column is centred around this height, whatever the number of buttons.
const COLUMN_CENTRE_Y: float = 670.0
## The focused button grows to the right by this much (its left edge and hit area stay put).
const FOCUS_GROW: float = 34.0
const INTRO_SLIDE: float = 70.0
## Stick deflection that counts as "the player is using the gamepad".
const PAD_AXIS_THRESHOLD: float = 0.5

var continue_button: Button     ## null when there is no race to continue
var play_button: Button
var records_button: Button
var options_button: Button
var quit_button: Button
var buttons: Array[Button] = []
var hint_label: Label
var version_label: Label
var using_gamepad: bool = false

## Button to focus when the player comes back from a sub-screen (the one they left through).
static var _return_focus: StringName = &""

var _column: Control
var _focus_tweens: Dictionary = {}
var _continue_config: RaceConfig
## Hovering only moves the focus once the entrance animation has settled, so a resting mouse
## cannot steal the initial focus while the buttons slide under it.
var _hover_enabled: bool = false

func on_enter() -> void:
	_build_title()
	_build_buttons()
	_build_footer()
	_play_intro()

## The title screen is the root of the menu: Esc / pad B does nothing here (QUIT is a button).
func on_back() -> void:
	pass

func _input(event: InputEvent) -> void:
	var pad := using_gamepad
	if event is InputEventJoypadButton:
		pad = true
	elif event is InputEventJoypadMotion:
		if absf((event as InputEventJoypadMotion).axis_value) > PAD_AXIS_THRESHOLD:
			pad = true
	elif event is InputEventKey or event is InputEventMouseButton:
		pad = false
	if pad != using_gamepad:
		using_gamepad = pad
		_refresh_hint()

# --- actions --------------------------------------------------------------------------------

func _on_continue() -> void:
	Game.start_race(_continue_config)

func _on_play() -> void:
	_go(play_button, "tracks")

func _on_records() -> void:
	_go(records_button, "records")

func _on_options() -> void:
	_go(options_button, "settings")

func _go(from: Button, screen: String) -> void:
	_return_focus = from.name
	router.go(screen)

func _on_quit() -> void:
	get_tree().quit()

# --- continue info --------------------------------------------------------------------------

## The race CONTINUE restarts: the last started race (Settings gameplay/last_race), not
## Game.pending, which the track / options screens may have edited without starting anything.
## Falls back to Game.pending when only a best lap file tells us the player has raced there.
## Null if the player never raced or that track is not playable any more.
static func last_race() -> RaceConfig:
	var cfg: RaceConfig = null
	var last: Variant = Settings.get_value("gameplay", "last_race")
	if last is Dictionary and not (last as Dictionary).is_empty():
		cfg = RaceConfig.new()
		cfg.apply_dict(last as Dictionary)
	else:
		var pending_info := TrackCatalog.find(Game.pending.track_id)
		if pending_info != null and FileAccess.file_exists(pending_info.best_path()):
			cfg = Game.pending.copy()
	if cfg == null:
		return null
	var info := TrackCatalog.find(cfg.track_id)
	if info == null or not info.available:
		return null
	return cfg

## Player's best lap on `info` in seconds (from user://best_<id>.json), or -1 if none.
static func best_lap(info: TrackInfo) -> float:
	if info == null or not FileAccess.file_exists(info.best_path()):
		return -1.0
	# JSON.parse (not parse_string) so a corrupt file is not reported as an engine error.
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(info.best_path())) != OK or not (json.data is Dictionary):
		return -1.0
	var lap: Variant = (json.data as Dictionary).get("best_lap", -1.0)
	if not (lap is float or lap is int) or float(lap) <= 0.0:
		return -1.0
	return float(lap)

static func continue_details(info: TrackInfo, cfg: RaceConfig) -> String:
	var parts: PackedStringArray = []
	if cfg.mode == RaceConfig.MODE_RACE:
		parts.append("RACE")
		parts.append("%d LAP%s" % [cfg.laps, "" if cfg.laps == 1 else "S"])
		if cfg.bots > 0:
			parts.append("%d BOT%s" % [cfg.bots, "" if cfg.bots == 1 else "S"])
	else:
		parts.append("TIME ATTACK")
	var best := best_lap(info)
	if best > 0.0:
		parts.append("BEST %s" % RaceTimer.format_time(best))
	return "  ·  ".join(parts)

# --- layout ---------------------------------------------------------------------------------

func _build_title() -> void:
	var title := Label.new()
	title.name = "Title"
	title.text = "FUN RACER"
	title.theme_type_variation = &"TitleLabel"
	title.add_theme_font_size_override(&"font_size", 176)
	title.add_theme_color_override(&"font_shadow_color", Color(0, 0, 0, 0.55))
	title.add_theme_constant_override(&"shadow_offset_x", 6)
	title.add_theme_constant_override(&"shadow_offset_y", 6)
	title.position = Vector2(LEFT - 6.0, TITLE_Y)
	add_child(title)
	_stripe("StripeBlue", Rect2(LEFT, TITLE_Y + 204.0, 430.0, 14.0), COL_ACCENT)
	_stripe("StripeRed", Rect2(LEFT + 438.0, TITLE_Y + 204.0, 130.0, 14.0), COL_HILITE)
	var tagline := Label.new()
	tagline.name = "Tagline"
	tagline.text = "A R C A D E   F O R M U L A   R A C I N G"
	tagline.theme_type_variation = &"DimLabel"
	tagline.add_theme_font_size_override(&"font_size", 26)
	tagline.position = Vector2(LEFT + 2.0, TITLE_Y + 232.0)
	add_child(tagline)

func _stripe(node_name: String, rect: Rect2, color: Color) -> void:
	var stripe := Control.new()
	stripe.set_script(SLANTED_PANEL)
	stripe.name = node_name
	stripe.set(&"color", color)
	stripe.set(&"slant", 8.0)
	stripe.position = rect.position
	stripe.size = rect.size
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(stripe)

func _build_buttons() -> void:
	_column = Control.new()
	_column.name = "Buttons"
	add_child(_column)
	buttons.clear()
	continue_button = null
	_continue_config = last_race()
	if _continue_config != null:
		var info := TrackCatalog.find(_continue_config.track_id)
		var caption := "CONTINUE: %s" % info.name.to_upper()
		continue_button = _button("Continue", caption, _on_continue, CONTINUE_H)
		_add_continue_details(continue_button, caption, continue_details(info, _continue_config))
	play_button = _button("Play", "PLAY", _on_play)
	records_button = _button("Records", "RECORDS", _on_records)
	options_button = _button("Options", "OPTIONS", _on_options)
	quit_button = _button("Quit", "QUIT", _on_quit)
	var total := -BUTTON_GAP
	for b in buttons:
		total += b.size.y + BUTTON_GAP
	var y := 0.0
	for i in buttons.size():
		var b := buttons[i]
		b.position = Vector2(0.0, y)
		y += b.size.y + BUTTON_GAP
		# Explicit neighbours: up/down wrap around, left/right stay put.
		var me := b.get_path()
		b.focus_neighbor_top = buttons[(i - 1 + buttons.size()) % buttons.size()].get_path()
		b.focus_neighbor_bottom = buttons[(i + 1) % buttons.size()].get_path()
		b.focus_previous = b.focus_neighbor_top
		b.focus_next = b.focus_neighbor_bottom
		b.focus_neighbor_left = me
		b.focus_neighbor_right = me
	_column.position = Vector2(LEFT, COLUMN_CENTRE_Y - total * 0.5)
	_column.size = Vector2(BUTTON_W + FOCUS_GROW, total)
	var first := buttons[0]
	for b in buttons:
		if b.name == _return_focus:
			first = b
	_return_focus = &""
	initial_focus = get_path_to(first)

func _button(node_name: String, text: String, action: Callable, height: float = BUTTON_H) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.size = Vector2(BUTTON_W, height)
	b.add_theme_font_size_override(&"font_size", 40)
	b.add_theme_stylebox_override(&"focus", _focus_style())
	b.pressed.connect(action)
	b.focus_entered.connect(_on_focus_changed.bind(b, true))
	b.focus_exited.connect(_on_focus_changed.bind(b, false))
	# One highlight only: hovering with the mouse moves the focus.
	b.mouse_entered.connect(_on_hover.bind(b))
	_column.add_child(b)
	buttons.append(b)
	return b

## The continue button is two lines tall: its caption moves up and the mode / best lap go below.
func _add_continue_details(b: Button, caption: String, text: String) -> void:
	var left := b.get_theme_stylebox(&"normal").get_margin(SIDE_LEFT)
	b.text = ""
	b.tooltip_text = caption
	var title := Label.new()
	title.name = "Caption"
	title.text = caption
	title.add_theme_font_override(&"font", BOLD_FONT)
	title.add_theme_font_size_override(&"font_size", 40)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.position = Vector2(left, 8.0)
	title.size = Vector2(BUTTON_W - 2.0 * left, 50.0)
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.add_child(title)
	var details := Label.new()
	details.name = "Details"
	details.text = text
	details.add_theme_font_size_override(&"font_size", 24)
	details.add_theme_color_override(&"font_color", Color(0.72, 0.84, 1.0))
	details.mouse_filter = Control.MOUSE_FILTER_IGNORE
	details.position = Vector2(left - 5.0, 58.0)
	details.size = Vector2(BUTTON_W - 2.0 * left, 30.0)
	details.clip_text = true
	details.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.add_child(details)

## Focused button: filled blue plate with the theme's red bar, so it reads from across the room.
func _focus_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(COL_ACCENT.r * 0.75, COL_ACCENT.g * 0.75, COL_ACCENT.b * 0.9, 0.92)
	sb.border_color = COL_HILITE
	sb.border_width_left = 10
	sb.set_corner_radius_all(2)
	sb.skew = Vector2(0.12, 0.0)
	sb.content_margin_left = 26.0
	sb.content_margin_right = 26.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb

func _on_hover(b: Button) -> void:
	if _hover_enabled:
		b.grab_focus()

func _on_focus_changed(b: Button, focused: bool) -> void:
	var old := _focus_tweens.get(b) as Tween
	if old != null:
		old.kill()
	var t := b.create_tween()
	t.tween_property(b, ^"size:x", BUTTON_W + (FOCUS_GROW if focused else 0.0), 0.12) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_focus_tweens[b] = t

func _build_footer() -> void:
	hint_label = Label.new()
	hint_label.name = "Hint"
	hint_label.theme_type_variation = &"DimLabel"
	hint_label.add_theme_font_size_override(&"font_size", 24)
	hint_label.anchor_top = 1.0
	hint_label.anchor_bottom = 1.0
	hint_label.offset_left = LEFT
	hint_label.offset_right = LEFT + 900.0
	hint_label.offset_top = -84.0
	hint_label.offset_bottom = -50.0
	add_child(hint_label)
	_refresh_hint()
	version_label = Label.new()
	version_label.name = "Version"
	version_label.theme_type_variation = &"DimLabel"
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	version_label.text = "v%s" % (VERSION if version.is_empty() else version)
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version_label.anchor_left = 1.0
	version_label.anchor_right = 1.0
	version_label.anchor_top = 1.0
	version_label.anchor_bottom = 1.0
	version_label.offset_left = -360.0
	version_label.offset_right = -60.0
	version_label.offset_top = -84.0
	version_label.offset_bottom = -50.0
	add_child(version_label)

static func hint_text(gamepad: bool) -> String:
	if gamepad:
		return "D-PAD  SELECT   ·   A  CONFIRM"
	var arrows := "↑↓" if HINT_FONT.has_char(0x2191) and HINT_FONT.has_char(0x2193) else "UP / DOWN"
	return "%s  SELECT   ·   ENTER  CONFIRM" % arrows

func _refresh_hint() -> void:
	if hint_label != null:
		hint_label.text = hint_text(using_gamepad)

func _play_intro() -> void:
	# Buttons slide in from the left, one after the other.
	var t := create_tween().set_parallel(true)
	for i in buttons.size():
		var b := buttons[i]
		b.modulate.a = 0.0
		t.tween_property(b, ^"modulate:a", 1.0, 0.22).set_delay(0.08 + 0.05 * i)
	var x := _column.position.x
	_column.position.x = x - INTRO_SLIDE
	t.tween_property(_column, ^"position:x", x, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.chain().tween_callback(func() -> void: _hover_enabled = true)
