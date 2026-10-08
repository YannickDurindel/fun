class_name RaceOptionsScreen
extends UIScreen
## Race options for the chosen track. Every row edits Game.pending live; START RACE hands it
## to Game.start_race(). Left / right change a value, up / down move between rows.

const MARGIN := 90.0
const TOP := 172.0
const ROW_H := 72.0
const ROW_GAP := 12
const MAX_LAPS := 20
const SIDE_W := 640.0

## Rows by name: mode, laps, bots, difficulty, ghost, countdown, camera.
var rows: Dictionary[StringName, OptionRow] = {}
var start_button: Button
var back_button: Button

var _info: TrackInfo
var _left: VBoxContainer
var _side: PanelContainer
var _desc: Label

func on_enter() -> void:
	_info = TrackCatalog.find(Game.pending.track_id)
	# The menu offers 1..MAX_LAPS; bring anything else (dev flags, old saves) into range.
	Game.pending.laps = clampi(Game.pending.laps, 1, MAX_LAPS)
	_build()
	resized.connect(_layout)
	_layout()
	_refresh()
	initial_focus = get_path_to(start_button if not start_button.disabled else rows[&"mode"])

func _build() -> void:
	var title := Label.new()
	title.text = "RACE OPTIONS"
	title.theme_type_variation = &"TitleLabel"
	title.position = Vector2(MARGIN, 44)
	add_child(title)

	_left = VBoxContainer.new()
	_left.add_theme_constant_override(&"separation", ROW_GAP)
	add_child(_left)

	var p := Game.pending
	var laps := PackedStringArray()
	for i in range(1, MAX_LAPS + 1):
		laps.append(str(i))
	var bots := PackedStringArray(["OFF"])
	for i in range(1, 8):
		bots.append(str(i))
	_row(&"mode", "MODE", ["TIME ATTACK", "RACE"], 1 if p.mode == RaceConfig.MODE_RACE else 0, true,
			"Time attack: endless laps against the clock.  Race: a set number of laps to the flag.")
	_row(&"laps", "LAPS", laps, p.laps - 1, false, "Number of laps in the race.")
	_row(&"bots", "OPPONENTS", bots, p.bots, false, "Number of AI drivers on the grid with you.")
	_row(&"difficulty", "DIFFICULTY", ["EASY", "MEDIUM", "HARD"], p.bot_difficulty, false,
			"How fast the AI drivers are.")
	_row(&"ghost", "GHOST", ["OFF", "ON"], 1 if p.ghost else 0, true,
			"Show a ghost car replaying your best lap.")
	_row(&"countdown", "COUNTDOWN", ["OFF", "ON"], 1 if p.countdown else 0, true,
			"3-2-1-GO before the start.  Off: you can drive away at once.")
	_row(&"camera", "CAMERA", ["LOW CHASE", "HIGH CHASE", "COCKPIT"], p.camera - 1, true,
			"Starting camera.  Keys 1 / 2 / 3 still switch it while driving.")
	rows[&"laps"].disabled_text = "UNLIMITED"
	rows[&"difficulty"].disabled_text = "-"

	var desc_box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(COL_BG, 0.7)
	sb.border_color = COL_ACCENT
	sb.border_width_left = 4
	sb.content_margin_left = 22
	sb.content_margin_right = 16
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	desc_box.add_theme_stylebox_override(&"panel", sb)
	_left.add_child(desc_box)
	_desc = Label.new()
	_desc.theme_type_variation = &"DimLabel"
	_desc.add_theme_font_size_override(&"font_size", 24)
	_desc.clip_text = true
	_desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_desc.custom_minimum_size.y = 32
	desc_box.add_child(_desc)

	var gap := Control.new()
	gap.custom_minimum_size.y = 14
	_left.add_child(gap)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 22)
	_left.add_child(buttons)
	start_button = Button.new()
	start_button.text = "START RACE"
	start_button.custom_minimum_size = Vector2(0, 84)
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.size_flags_stretch_ratio = 2.0
	start_button.add_theme_font_size_override(&"font_size", 42)
	start_button.add_theme_stylebox_override(&"normal", _start_style(Color(COL_ACCENT.darkened(0.25), 0.95)))
	start_button.add_theme_stylebox_override(&"hover", _start_style(COL_ACCENT))
	start_button.add_theme_stylebox_override(&"pressed", _start_style(COL_ACCENT.lightened(0.2)))
	start_button.disabled = _info == null or not _info.available
	start_button.pressed.connect(_on_start)
	start_button.focus_entered.connect(_describe.bind("Load the track and go racing."))
	buttons.add_child(start_button)
	back_button = Button.new()
	back_button.text = "BACK"
	back_button.custom_minimum_size = Vector2(0, 84)
	back_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back_button.pressed.connect(on_back)
	back_button.focus_entered.connect(_describe.bind("Back to the track list."))
	buttons.add_child(back_button)

	_build_side()

func _start_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.skew = Vector2(0.12, 0)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	return sb

func _row(key: StringName, title: String, options: PackedStringArray, index: int, wrap: bool, description: String) -> void:
	var r := OptionRow.create(title, options, index, wrap, description)
	r.custom_minimum_size = Vector2(600, ROW_H)
	r.value_changed.connect(_on_row_changed.bind(key))
	r.focus_entered.connect(_describe.bind(description))
	r.mouse_entered.connect(_hover_focus.bind(r))
	rows[key] = r
	_left.add_child(r)

func _hover_focus(r: OptionRow) -> void:
	if not r.disabled:
		r.grab_focus()

## The chosen track: name, small map, key facts, best lap.
func _build_side() -> void:
	_side = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(COL_BG, 0.86)
	sb.border_color = COL_ACCENT
	sb.border_width_top = 4
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 18
	sb.content_margin_bottom = 22
	_side.add_theme_stylebox_override(&"panel", sb)
	add_child(_side)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 0)
	_side.add_child(col)
	var gp := Label.new()
	gp.text = _info.grand_prix.to_upper() if _info != null else "TRACK"
	gp.add_theme_color_override(&"font_color", COL_ACCENT.lightened(0.25))
	gp.add_theme_font_size_override(&"font_size", 24)
	col.add_child(gp)
	var name_label := Label.new()
	name_label.text = _info.name.to_upper() if _info != null else "NO TRACK SELECTED"
	name_label.theme_type_variation = &"HeaderLabel"
	name_label.add_theme_font_size_override(&"font_size", 48)
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(name_label)
	var map := TrackMap.new()
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.set_track(_info)
	col.add_child(map)
	if _info == null:
		return
	var facts := Label.new()
	facts.theme_type_variation = &"DimLabel"
	facts.add_theme_font_size_override(&"font_size", 24)
	facts.text = "%s   ·   %s   ·   %d TURNS" % [_info.country.to_upper(), TrackSelectScreen.format_length(_info.length_m), _info.turns]
	col.add_child(facts)
	var best := TrackSelectScreen.read_best(_info)
	var best_label := Label.new()
	best_label.theme_type_variation = &"HeaderLabel"
	best_label.add_theme_font_size_override(&"font_size", 36)
	if not _info.available:
		best_label.text = "COMING SOON"
	elif best.is_empty():
		best_label.text = "NO TIME SET"
		best_label.add_theme_color_override(&"font_color", COL_TEXT_DIM)
	else:
		best_label.text = "BEST  %s" % TrackSelectScreen.format_lap(best["lap"])
	col.add_child(best_label)

func _layout() -> void:
	var w := maxf(size.x, 1100.0) if size.x > 1.0 else 1920.0
	var side_x := w - MARGIN - SIDE_W
	var left_w := clampf(side_x - 70.0 - MARGIN, 600.0, 1020.0)
	side_x = maxf(side_x, MARGIN + left_w + 40.0)
	_left.position = Vector2(MARGIN, TOP)
	_left.size = Vector2(left_w, 0)
	_side.position = Vector2(side_x, TOP)
	_side.size = Vector2(SIDE_W, maxf(_left.get_combined_minimum_size().y, 400.0))

func _describe(text: String) -> void:
	_desc.text = text

func _on_row_changed(index: int, key: StringName) -> void:
	var p := Game.pending
	match key:
		&"mode": p.mode = RaceConfig.MODE_RACE if index == 1 else RaceConfig.MODE_TIME_ATTACK
		&"laps": p.laps = index + 1
		&"bots": p.bots = index
		&"difficulty": p.bot_difficulty = index
		&"ghost": p.ghost = index == 1
		&"countdown": p.countdown = index == 1
		&"camera": p.camera = index + 1
	_refresh()

## Greys out the rows that do not apply and rebuilds the up / down focus chain.
func _refresh() -> void:
	rows[&"laps"].disabled = Game.pending.mode != RaceConfig.MODE_RACE
	rows[&"difficulty"].disabled = Game.pending.bots <= 0
	var chain: Array[Control] = []
	for r: OptionRow in rows.values():
		if not r.disabled:
			chain.append(r)
	var bottom: Control = back_button if start_button.disabled else start_button
	for i in chain.size():
		var c := chain[i]
		c.focus_neighbor_top = c.get_path_to(chain[i - 1]) if i > 0 else NodePath(".")
		c.focus_neighbor_bottom = c.get_path_to(chain[i + 1] if i + 1 < chain.size() else bottom)
		c.focus_previous = c.focus_neighbor_top
		c.focus_next = c.focus_neighbor_bottom
	var last := chain.back() as Control
	for b: Button in [start_button, back_button]:
		b.focus_neighbor_top = b.get_path_to(last)
		b.focus_neighbor_bottom = NodePath(".")
	start_button.focus_neighbor_left = NodePath(".")
	start_button.focus_neighbor_right = start_button.get_path_to(back_button)
	back_button.focus_neighbor_right = NodePath(".")
	back_button.focus_neighbor_left = NodePath(".") if start_button.disabled else back_button.get_path_to(start_button)

func _on_start() -> void:
	if _info == null or not _info.available:
		return
	Game.start_race()
