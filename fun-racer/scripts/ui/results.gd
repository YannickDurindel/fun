extends Control
## End-of-run screen of the race scene (UI/Results). Shown about a second after the
## RaceManager's race_finished (race mode: all laps done; time attack: END SESSION), over the
## still-running scene: title, track, total time, best lap, lap table (time, sectors, gap to
## the best lap), best sectors, a NEW RECORD badge, and RETRY / TRACK SELECT / MAIN MENU.
## Keyboard and gamepad: left / right pick a button (focus starts on RETRY), up / down scroll
## the lap table. Joins group "results_screen".
## Dev flag: --finish-demo shows the screen with sample data (screenshots).
## Designed at 1080p and scaled to the viewport height, like the menus.

signal shown(results: Dictionary)

const SlantedPanel := preload("res://scripts/ui/slanted_panel.gd")
const RaceTimer := preload("res://scripts/ui/race_timer.gd")
const FONT_BOLD := preload("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")

const REF_HEIGHT: float = 1080.0
const SHOW_DELAY: float = 1.0
const DEMO_FRAMES: int = 90
const CARD_POS := Vector2(60, 70)
const CARD_SIZE := Vector2(860, 940)
const HUD_PATHS: Array[NodePath] = [^"../RacePanel", ^"../HUD"]
const PAD: float = 44.0
const ROW_H: float = 44.0
const VISIBLE_ROWS: int = 7
const COL_LAP: float = 76.0
const COL_TIME: float = 180.0
const COL_SECTORS: float = 396.0   ## shared by the track's sector columns
const COL_GAP: float = 120.0
const MAX_SECTOR_COLS: int = 5
const DRIVE_ACTIONS: Array[StringName] = [&"accelerate", &"brake", &"steer_left", &"steer_right", &"respawn"]
const NAV_ACTIONS: Array[StringName] = [&"ui_left", &"ui_right", &"ui_up", &"ui_down", &"ui_accept", &"ui_focus_next", &"ui_focus_prev"]

const COL_CARD := Color(0.03, 0.035, 0.05, 0.9)
const COL_ROW := Color(1, 1, 1, 0.045)
const COL_BEST_ROW := Color(0.16, 0.45, 1.0, 0.3)
const COL_GREEN := Color(0.3, 0.95, 0.4)
const COL_PURPLE := Color(0.78, 0.36, 1.0)
const COL_SLOWER := Color(1.0, 0.42, 0.36)

var race: RaceManager
## The results being shown (empty when closed).
var results: Dictionary = {}

var _num_font: FontVariation
var _dim: ColorRect
var _root: Control
var _card: Control
var _title: Label
var _subtitle: Label
var _badge: Control
var _stats: HBoxContainer
var _table_header: HBoxContainer
var _scroll: ScrollContainer
var _rows: VBoxContainer
var _sector_box: HBoxContainer
var _buttons: Dictionary = {}
var _pending: Dictionary = {}
var _delay: float = 0.0
var _demo_frames: int = -1
var _hidden_hud: Array[CanvasItem] = []
var _input_guard: bool = false   ## ignore menu input until the driving keys are released

func _enter_tree() -> void:
	add_to_group(&"results_screen")

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_num_font = FontVariation.new()
	_num_font.base_font = FONT_BOLD
	_num_font.opentype_features = {"tnum": 1}
	_build()
	race = get_tree().get_first_node_in_group(&"race_manager") as RaceManager
	if race != null:
		race.race_finished.connect(_on_race_finished)
		race.race_restarted.connect(close)
	resized.connect(_layout)
	_layout()
	if OS.get_cmdline_user_args().has("--finish-demo"):
		_demo_frames = DEMO_FRAMES

# ---------------------------------------------------------------- construction
func _build() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0.0, 0.01, 0.03, 0.4)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_dim)

	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_card = Control.new()
	_card.position = CARD_POS
	_card.size = CARD_SIZE
	_root.add_child(_card)
	var bg := ColorRect.new()
	bg.color = COL_CARD
	bg.size = CARD_SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(bg)
	var top_bar := ColorRect.new()
	top_bar.color = UIScreen.COL_HILITE
	top_bar.size = Vector2(CARD_SIZE.x, 8)
	top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(top_bar)

	_title = Label.new()
	_title.theme_type_variation = &"TitleLabel"
	_title.position = Vector2(PAD, 26)
	_card.add_child(_title)
	_subtitle = _text(_card, "", 30, UIScreen.COL_TEXT_DIM)
	_subtitle.position = Vector2(PAD + 2, 112)

	# NEW RECORD badge, top right of the card.
	_badge = SlantedPanel.new()
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.size = Vector2(250, 58)
	_badge.position = Vector2(CARD_SIZE.x - PAD - 250 + 8, 44)
	_badge.set(&"slant", 16.0)
	_badge.set(&"color", COL_PURPLE.darkened(0.15))
	_badge.set(&"accent", Color(1, 1, 1, 0.7))
	_card.add_child(_badge)
	var badge_text := _text(_badge, "NEW RECORD", 34, UIScreen.COL_TEXT)
	badge_text.size = _badge.size
	badge_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	_stats = HBoxContainer.new()
	_stats.position = Vector2(PAD, 176)
	_stats.size = Vector2(CARD_SIZE.x - PAD * 2.0, 104)
	_stats.add_theme_constant_override(&"separation", 12)
	_card.add_child(_stats)

	_table_header = HBoxContainer.new()
	_table_header.position = Vector2(PAD, 304)
	_table_header.add_theme_constant_override(&"separation", 0)
	_card.add_child(_table_header)
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.25)
	rule.position = Vector2(PAD, 338)
	rule.size = Vector2(CARD_SIZE.x - PAD * 2.0, 2)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(rule)

	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(PAD, 346)
	_scroll.size = Vector2(CARD_SIZE.x - PAD * 2.0 + 14.0, (ROW_H + 4.0) * VISIBLE_ROWS)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.focus_mode = Control.FOCUS_NONE
	_card.add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override(&"separation", 4)
	_scroll.add_child(_rows)

	_sector_box = HBoxContainer.new()
	_sector_box.position = Vector2(PAD, 702)
	_sector_box.size = Vector2(CARD_SIZE.x - PAD * 2.0, 84)
	_sector_box.add_theme_constant_override(&"separation", 12)
	_card.add_child(_sector_box)

	var buttons := HBoxContainer.new()
	buttons.position = Vector2(PAD, CARD_SIZE.y - 64 - 40)
	buttons.size = Vector2(CARD_SIZE.x - PAD * 2.0, 64)
	buttons.add_theme_constant_override(&"separation", 14)
	_card.add_child(buttons)
	_button(buttons, "retry", "RETRY", func() -> void: Game.restart_race())
	_button(buttons, "tracks", "TRACK SELECT", func() -> void: Game.quit_to_menu("tracks"))
	_button(buttons, "menu", "MAIN MENU", func() -> void: Game.quit_to_menu())

func _text(parent: Node, text: String, font_size: int, color: Color, numeric: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override(&"font", _num_font if numeric else FONT_BOLD)
	l.add_theme_font_size_override(&"font_size", font_size)
	l.add_theme_color_override(&"font_color", color)
	parent.add_child(l)
	return l

func _cell(parent: Node, text: String, width: float, font_size: int, color: Color, height: float = ROW_H) -> Label:
	var l := _text(parent, text, font_size, color, true)
	l.custom_minimum_size = Vector2(width, height)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return l

func _button(parent: Node, id: String, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.name = id.to_pascal_case()
	b.text = text
	b.custom_minimum_size = Vector2(0, 64)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(action)
	parent.add_child(b)
	_buttons[id] = b
	return b

func button(id: String) -> Button:
	return _buttons.get(id) as Button

## A captioned value on a dark tile (total time, best lap, best sectors...).
func _tile(parent: Node, caption: String, value: String, color: Color, value_size: int = 46) -> void:
	var tile := PanelContainer.new()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.06)
	sb.border_color = color
	sb.border_width_left = 5
	sb.content_margin_left = 20
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 6
	tile.add_theme_stylebox_override(&"panel", sb)
	parent.add_child(tile)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", -6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(v)
	_text(v, caption, 21, UIScreen.COL_TEXT_DIM)
	_text(v, value, value_size, color, true)

func _layout() -> void:
	var k := clampf(size.y / REF_HEIGHT, 0.2, 8.0)
	_root.scale = Vector2(k, k)
	_root.position = Vector2.ZERO
	_root.size = Vector2(size.x / k, REF_HEIGHT)
	# Narrow windows: keep the whole card on screen.
	_card.position.x = clampf(CARD_POS.x, 0.0, maxf(0.0, _root.size.x - CARD_SIZE.x))

# ---------------------------------------------------------------- content
func is_open() -> bool:
	return visible

func _on_race_finished(res: Dictionary) -> void:
	_pending = res
	_delay = SHOW_DELAY

## Fills and shows the screen. `res`: see RaceManager.results().
func show_results(res: Dictionary) -> void:
	_pending = {}
	_delay = 0.0
	results = res
	_fill(res)
	if not visible:
		_set_hud_hidden(true)
	visible = true
	_input_guard = _driving_keys_held()
	_scroll.scroll_vertical = 0
	button("retry").grab_focus()
	_scroll_to_best.call_deferred()
	shown.emit(res)

func close() -> void:
	_pending = {}
	_delay = 0.0
	if not visible:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		focused.release_focus()
	visible = false
	results = {}
	_set_hud_hidden(false)

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

static func _time(t: float) -> String:
	return RaceTimer.format_time(t) if t > 0.0 else "-:--.---"

static func _sector_time(t: float) -> String:
	if t <= 0.0:
		return "--.---"
	var txt := RaceTimer.format_time(t)
	return txt.substr(2) if t < 60.0 else txt

static func _same(a: float, b: float) -> bool:
	return a > 0.0 and b > 0.0 and absf(a - b) < 0.0005

func _fill(res: Dictionary) -> void:
	var laps: Array = res.get("laps", [])
	var lap_sectors: Array = res.get("lap_sectors", [])
	var best := float(res.get("best", -1.0))
	var best_index := int(res.get("best_lap_index", -1))
	var previous := float(res.get("previous_best", -1.0))
	var is_record := bool(res.get("is_record", false))
	var run_best: Array = res.get("sectors_best", [])
	var record: Array = res.get("sectors_record", [])
	var is_race := StringName(res.get("mode", RaceConfig.MODE_RACE)) == RaceConfig.MODE_RACE

	_title.text = "RACE COMPLETE" if is_race else "SESSION COMPLETE"
	var info := TrackCatalog.find(String(res.get("track_id", "")))
	var track_name := info.name if info != null else String(res.get("track_name", ""))
	var lap_word := "%d LAP%s" % [laps.size(), "" if laps.size() == 1 else "S"]
	_subtitle.text = "%s   -   %s   -   %s" % [track_name.to_upper(), "RACE" if is_race else "TIME ATTACK", lap_word]
	_badge.visible = is_record
	var best_color := COL_PURPLE if is_record else COL_GREEN

	for c in _stats.get_children():
		c.free()
	_tile(_stats, "TOTAL TIME", _time(float(res.get("total", 0.0))), UIScreen.COL_TEXT)
	_tile(_stats, "BEST LAP", _time(best), best_color)
	if previous > 0.0 and best > 0.0:
		var d := best - previous
		_tile(_stats, "VS PREVIOUS BEST", RaceManager.format_delta(d), COL_GREEN if d < 0.0 else COL_SLOWER)
	else:
		_tile(_stats, "PREVIOUS BEST", _time(previous), UIScreen.COL_TEXT_DIM)

	# One column per sector of the track (three on every F1 circuit).
	var n_sec := clampi(run_best.size(), 0, MAX_SECTOR_COLS)
	var sec_w := COL_SECTORS / maxf(n_sec, 1.0)
	for c in _table_header.get_children():
		c.free()
	_cell(_table_header, "LAP", COL_LAP, 22, UIScreen.COL_TEXT_DIM, 30.0)
	_cell(_table_header, "TIME", COL_TIME + (COL_SECTORS if n_sec == 0 else 0.0), 22, UIScreen.COL_TEXT_DIM, 30.0)
	for k in n_sec:
		_cell(_table_header, "S%d" % (k + 1), sec_w, 22, UIScreen.COL_TEXT_DIM, 30.0)
	_cell(_table_header, "GAP", COL_GAP, 22, UIScreen.COL_TEXT_DIM, 30.0)

	for c in _rows.get_children():
		c.free()
	_table_header.visible = not laps.is_empty()
	if laps.is_empty():
		var none := _text(_rows, "NO LAPS COMPLETED", 34, UIScreen.COL_TEXT_DIM)
		none.custom_minimum_size = Vector2(CARD_SIZE.x - PAD * 2.0, 120)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		none.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	for i in laps.size():
		var lt := float(laps[i])
		var is_best := i == best_index
		var row := PanelContainer.new()
		row.name = "Lap%d" % (i + 1)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := StyleBoxFlat.new()
		sb.bg_color = COL_BEST_ROW if is_best else COL_ROW
		sb.border_color = best_color
		sb.border_width_left = 5 if is_best else 0
		sb.content_margin_left = 16.0 if is_best else 21.0
		row.add_theme_stylebox_override(&"panel", sb)
		_rows.add_child(row)
		var h := HBoxContainer.new()
		h.add_theme_constant_override(&"separation", 0)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(h)
		_cell(h, str(i + 1), COL_LAP - 21.0, 30, UIScreen.COL_TEXT)
		_cell(h, _time(lt), COL_TIME + (COL_SECTORS if n_sec == 0 else 0.0), 32, best_color if is_best else UIScreen.COL_TEXT)
		var secs: Array = lap_sectors[i] if i < lap_sectors.size() else []
		for k in n_sec:
			var st := float(secs[k]) if k < secs.size() else -1.0
			var col := Color(1, 1, 1, 0.78)
			if k < record.size() and _same(st, float(record[k])):
				col = COL_PURPLE
			elif k < run_best.size() and _same(st, float(run_best[k])):
				col = COL_GREEN
			_cell(h, _sector_time(st), sec_w, 28 if n_sec <= 3 else 24, col)
		if is_best:
			_cell(h, "BEST", COL_GAP, 28, best_color)
		else:
			_cell(h, RaceManager.format_delta(lt - best), COL_GAP, 28, COL_SLOWER)

	for c in _sector_box.get_children():
		c.free()
	var ideal := 0.0
	for k in run_best.size():
		var st := float(run_best[k])
		ideal = ideal + st if st > 0.0 and ideal >= 0.0 else -1.0
		if k >= MAX_SECTOR_COLS:
			continue
		var purple := k < record.size() and _same(st, float(record[k]))
		_tile(_sector_box, "BEST S%d" % (k + 1), _sector_time(st), COL_PURPLE if purple else (COL_GREEN if st > 0.0 else UIScreen.COL_TEXT_DIM), 38)
	if not run_best.is_empty():
		_tile(_sector_box, "IDEAL LAP", _time(ideal), UIScreen.COL_TEXT, 38)

## Lap rows of the table (tests).
func lap_row_count() -> int:
	var laps: Array = results.get("laps", [])
	return laps.size()

func is_record_shown() -> bool:
	return visible and _badge.visible

func _scroll_to_best() -> void:
	if not visible:
		return
	var i := int(results.get("best_lap_index", -1))
	if i >= VISIBLE_ROWS and i < _rows.get_child_count():
		_scroll.scroll_vertical = int((ROW_H + 4.0) * (i - VISIBLE_ROWS + 1))

# ---------------------------------------------------------------- input / timing
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if _input_guard:
		# The player was still driving when the screen came up (arrow keys steer and also
		# navigate): nothing reacts until those keys are let go.
		for a in NAV_ACTIONS:
			if event.is_action(a):
				get_viewport().set_input_as_handled()
				return
		return
	# Left / right move between the buttons; up / down scroll the lap table.
	for dir: int in [-1, 1]:
		var action: StringName = &"ui_up" if dir < 0 else &"ui_down"
		if not event.is_action_pressed(action, true):
			continue
		get_viewport().set_input_as_handled()
		# A stick sends a stream of motion events: one row per push, keys repeat.
		if event is InputEventKey or Input.is_action_just_pressed(action):
			_scroll.scroll_vertical += dir * int(ROW_H + 4.0)
		return

func _driving_keys_held() -> bool:
	for a in DRIVE_ACTIONS:
		if InputMap.has_action(a) and Input.is_action_pressed(a):
			return true
	return false

func _process(delta: float) -> void:
	if _demo_frames >= 0:
		_demo_frames -= 1
		if _demo_frames < 0:
			show_results(demo_results())
	if _input_guard and not _driving_keys_held():
		_input_guard = false
	if _pending.is_empty():
		return
	_delay -= delta
	if _delay <= 0.0:
		show_results(_pending)

## Sample data for --finish-demo and tests: a 5-lap race with a new record on lap 4.
static func demo_results() -> Dictionary:
	var lap_sectors: Array[Array] = [
		[38.412, 16.905, 17.631], [35.120, 15.842, 16.377], [34.981, 15.990, 16.204],
		[34.702, 15.611, 16.118], [34.866, 15.704, 16.390],
	]
	var laps: Array[float] = []
	var total := 0.0
	for secs: Array in lap_sectors:
		var lt := float(secs[0]) + float(secs[1]) + float(secs[2])
		laps.append(lt)
		total += lt
	var info := Game.current_track()
	return {
		"track_id": info.id if info != null else "red_bull_ring",
		"track_name": info.name if info != null else "Red Bull Ring",
		"mode": RaceConfig.MODE_RACE,
		"target_laps": laps.size(),
		"laps": laps,
		"lap_sectors": lap_sectors,
		"total": total,
		"best": laps[3],
		"best_lap_index": 3,
		"sectors_best": [34.702, 15.611, 16.118],
		"sectors_record": [34.702, 15.580, 16.118],
		"previous_best": 66.905,
		"is_record": true,
	}
