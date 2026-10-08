class_name TrackSelectScreen
extends UIScreen
## Track selection: a scrollable grid of cards (one per TrackCatalog entry) and a detail panel
## for the focused track (map, location, length, turns, elevation, the player's best lap).
## Accepting a playable track sets Game.pending.track_id and opens the race options;
## "coming soon" circuits can be browsed but not selected.

const RaceTimer := preload("res://scripts/ui/race_timer.gd")
const MARGIN := 90.0
const TOP := 172.0
const PANEL_H := 780.0
const DETAIL_W := 740.0
const CARD_SIZE := Vector2(290, 150)
const GAP := 16

var cards: Array[TrackCard] = []
## Track shown in the detail panel (the last focused card).
var focused_info: TrackInfo
var back_button: Button

var _scroll: ScrollContainer
var _grid: GridContainer
var _detail: PanelContainer
var _map: TrackMap
var _gp: Label
var _name: Label
var _place: Label
var _length: Label
var _turns: Label
var _elevation: Label
var _best_box: HBoxContainer
var _hint: Label
var _last_card: TrackCard

func on_enter() -> void:
	_build()
	resized.connect(_layout)
	_layout()
	var start := card_for(Game.pending.track_id)
	if start == null and not cards.is_empty():
		start = cards[0]
	if start != null:
		initial_focus = get_path_to(start)
		_last_card = start
		_show_detail(start)

## The card of a track id, or null.
func card_for(id: String) -> TrackCard:
	for c in cards:
		if c.info.id == id:
			return c
	return null

## Chooses a track: playable tracks open the race options. Returns false for locked tracks.
func select(info: TrackInfo) -> bool:
	if info == null or not info.available:
		return false
	Game.pending.track_id = info.id
	if router != null:
		router.go("race_options")
	return true

## The player's saved best on a track: {"lap": float, "sectors": Array[float]}, or {} if none.
static func read_best(info: TrackInfo) -> Dictionary:
	if info == null or not FileAccess.file_exists(info.best_path()):
		return {}
	var f := FileAccess.open(info.best_path(), FileAccess.READ)
	var json := JSON.new()   # parse() (unlike parse_string) stays quiet on a corrupt file
	if f == null or json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return {}
	var dict: Dictionary = json.data
	var lap: Variant = dict.get("best_lap", -1.0)
	if not (lap is float or lap is int) or float(lap) <= 0.0:
		return {}
	var sectors: Array[float] = []
	var raw: Variant = dict.get("best_sectors", [])
	if raw is Array:
		for v: Variant in raw:
			sectors.append(float(v) if (v is float or v is int) else -1.0)
	return {"lap": float(lap), "sectors": sectors}

## Lap / sector time as M:SS.mmm.
static func format_lap(seconds: float) -> String:
	return RaceTimer.format_time(seconds)

## "4.318 KM", or miles when the speed unit setting is mph.
static func format_length(metres: float) -> String:
	if _imperial():
		return "%.3f MI" % (metres / 1609.344)
	return "%.3f KM" % (metres / 1000.0)

static func format_height(metres: float) -> String:
	if _imperial():
		return "%d FT" % roundi(metres * 3.28084)
	return "%d M" % roundi(metres)

static func _imperial() -> bool:
	return String(Settings.get_value("gameplay", "speed_unit")) == "mph"

# ------------------------------------------------------------------------------------ build

func _build() -> void:
	var title := Label.new()
	title.text = "SELECT TRACK"
	title.theme_type_variation = &"TitleLabel"
	title.position = Vector2(MARGIN, 44)
	add_child(title)

	_scroll = ScrollContainer.new()
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	var pad := MarginContainer.new()
	# Room for the slanted card edges, the focus frame and the scroll bar.
	pad.add_theme_constant_override(&"margin_left", 12)
	pad.add_theme_constant_override(&"margin_right", 22)
	pad.add_theme_constant_override(&"margin_top", 6)
	pad.add_theme_constant_override(&"margin_bottom", 6)
	_scroll.add_child(pad)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override(&"h_separation", GAP)
	_grid.add_theme_constant_override(&"v_separation", GAP)
	pad.add_child(_grid)
	for info in TrackCatalog.all():
		var card := TrackCard.new()
		card.setup(info, read_best(info))
		card.focus_entered.connect(_on_card_focused.bind(card))
		card.mouse_entered.connect(_on_card_hovered.bind(card))
		card.pressed.connect(select.bind(info))
		_grid.add_child(card)
		cards.append(card)

	_build_detail()

	back_button = Button.new()
	back_button.text = "BACK"
	back_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back_button.position = Vector2(MARGIN, TOP + PANEL_H + 22)
	back_button.size = Vector2(260, 58)
	back_button.pressed.connect(on_back)
	add_child(back_button)

	_hint = Label.new()
	_hint.theme_type_variation = &"DimLabel"
	_hint.text = "ARROWS / D-PAD  BROWSE        ENTER / A  SELECT        ESC / B  BACK"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_hint)

func _build_detail() -> void:
	_detail = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(COL_BG, 0.86)
	sb.border_color = COL_ACCENT
	sb.border_width_top = 4
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 16
	sb.content_margin_bottom = 22
	_detail.add_theme_stylebox_override(&"panel", sb)
	add_child(_detail)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 0)
	_detail.add_child(col)

	_map = TrackMap.new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map.line_width = 6.0
	col.add_child(_map)

	_gp = Label.new()
	_gp.add_theme_color_override(&"font_color", COL_ACCENT.lightened(0.25))
	_gp.add_theme_font_size_override(&"font_size", 24)
	col.add_child(_gp)
	_name = Label.new()
	_name.theme_type_variation = &"HeaderLabel"
	_name.add_theme_font_size_override(&"font_size", 50)
	_name.clip_text = true
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_name)
	_place = Label.new()
	_place.theme_type_variation = &"DimLabel"
	_place.add_theme_font_size_override(&"font_size", 24)
	col.add_child(_place)

	col.add_child(_rule())
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override(&"separation", 24)
	col.add_child(stats)
	_length = _stat(stats, "LENGTH")
	_turns = _stat(stats, "TURNS")
	_elevation = _stat(stats, "ELEVATION CHANGE")

	col.add_child(_rule())
	_best_box = HBoxContainer.new()
	_best_box.add_theme_constant_override(&"separation", 24)
	_best_box.custom_minimum_size.y = 84
	col.add_child(_best_box)

func _rule() -> Control:
	var holder := MarginContainer.new()
	holder.add_theme_constant_override(&"margin_top", 12)
	holder.add_theme_constant_override(&"margin_bottom", 10)
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.14)
	line.custom_minimum_size.y = 2
	holder.add_child(line)
	return holder

## Adds a "caption over value" block to `parent` and returns the value label.
func _stat(parent: Control, caption: String, value_size: int = 40, color: Color = COL_TEXT_DIM) -> Label:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", -4)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_size_override(&"font_size", 20)
	cap.add_theme_color_override(&"font_color", color)
	box.add_child(cap)
	var val := Label.new()
	val.theme_type_variation = &"HeaderLabel"
	val.add_theme_font_size_override(&"font_size", value_size)
	box.add_child(val)
	return val

# ----------------------------------------------------------------------------------- layout

func _layout() -> void:
	var w := maxf(size.x, 1100.0) if size.x > 1.0 else 1920.0
	var detail_x := maxf(w - MARGIN - DETAIL_W, MARGIN + CARD_SIZE.x + 70.0)
	_detail.position = Vector2(detail_x, TOP)
	_detail.size = Vector2(DETAIL_W, PANEL_H)
	var grid_w := detail_x - 30.0 - MARGIN
	var cols := maxi(1, int((grid_w - 34.0 + GAP) / (CARD_SIZE.x + GAP)))
	_grid.columns = cols
	_scroll.position = Vector2(MARGIN - 12.0, TOP - 6.0)
	_scroll.size = Vector2(grid_w + 12.0, PANEL_H + 12.0)
	_hint.position = Vector2(detail_x, TOP + PANEL_H + 36)
	_hint.size = Vector2(DETAIL_W, 30)
	_wire_focus(cols)

## Explicit focus neighbours: the grid wraps nowhere, and the last row leads to BACK.
func _wire_focus(cols: int) -> void:
	var n := cards.size()
	for i in n:
		var c := cards[i]
		@warning_ignore("integer_division")
		var same_row_left := i % cols > 0
		var same_row_right := i % cols < cols - 1 and i + 1 < n
		c.focus_neighbor_left = c.get_path_to(cards[i - 1]) if same_row_left else NodePath(".")
		c.focus_neighbor_right = c.get_path_to(cards[i + 1]) if same_row_right else NodePath(".")
		c.focus_neighbor_top = c.get_path_to(cards[i - cols]) if i - cols >= 0 else NodePath(".")
		@warning_ignore("integer_division")
		var has_row_below := (i / cols) < ((n - 1) / cols)
		var below: Control = cards[mini(i + cols, n - 1)] if has_row_below else back_button
		c.focus_neighbor_bottom = c.get_path_to(below)
	back_button.focus_neighbor_left = NodePath(".")
	back_button.focus_neighbor_right = NodePath(".")
	back_button.focus_neighbor_bottom = NodePath(".")
	_wire_back()

func _wire_back() -> void:
	var up: Control = _last_card if _last_card != null else (cards.back() if not cards.is_empty() else null)
	back_button.focus_neighbor_top = back_button.get_path_to(up) if up != null else NodePath(".")

# ----------------------------------------------------------------------------------- detail

## Hovering focuses a card, but must not scroll the grid under the mouse (follow_focus would).
func _on_card_hovered(card: TrackCard) -> void:
	if card.has_focus():
		return
	_scroll.follow_focus = false
	card.grab_focus()
	_scroll.follow_focus = true

func _on_card_focused(card: TrackCard) -> void:
	_last_card = card
	_wire_back()
	_show_detail(card)

func _show_detail(card: TrackCard) -> void:
	var info := card.info
	focused_info = info
	_map.set_track(info)
	_gp.text = info.grand_prix.to_upper()
	_name.text = info.name.to_upper()
	var place := info.city
	if not info.country.is_empty() and info.country != info.city:
		place = info.country if place.is_empty() else "%s, %s" % [place, info.country]
	_place.text = place.to_upper()
	_length.text = format_length(info.length_m) if info.length_m > 0.0 else "-"
	_turns.text = str(info.turns) if info.turns > 0 else "-"
	var data := TrackMap.load_data(info)
	_elevation.text = format_height(TrackMap.elevation_change(data)) if data != null else "-"

	for c in _best_box.get_children():
		_best_box.remove_child(c)
		c.queue_free()
	if not info.available:
		_stat(_best_box, "NOT PLAYABLE YET", 46).text = "COMING SOON"
		return
	var best := card.best
	if best.is_empty():
		var none := _stat(_best_box, "YOUR BEST LAP", 46)
		none.text = "NO TIME SET"
		none.add_theme_color_override(&"font_color", COL_TEXT_DIM)
		return
	var lap := _stat(_best_box, "YOUR BEST LAP", 46)
	lap.text = TrackSelectScreen.format_lap(best["lap"])
	(lap.get_parent() as Control).size_flags_stretch_ratio = 1.5
	var sectors: Array[float] = best["sectors"]
	for i in sectors.size():
		var s := _stat(_best_box, "BEST S%d" % (i + 1), 32, TrackMap.SECTOR_COLORS[i % TrackMap.SECTOR_COLORS.size()].lightened(0.2))
		s.text = TrackSelectScreen.format_lap(sectors[i]) if sectors[i] > 0.0 else "-:--.---"

# ------------------------------------------------------------------------------------- card

## One track in the grid. Locked ("coming soon") tracks are dimmed but still focusable.
class TrackCard extends Button:
	var info: TrackInfo
	var best: Dictionary = {}   ## TrackSelectScreen.read_best(info), read once when the card is built

	func setup(track: TrackInfo, track_best: Dictionary) -> void:
		info = track
		best = track_best
		custom_minimum_size = CARD_SIZE
		mouse_filter = Control.MOUSE_FILTER_PASS   # let the wheel scroll the grid
		var locked := not info.available
		add_theme_stylebox_override(&"normal", _box(Color(0.03, 0.035, 0.05, 0.55) if locked else Color(0.05, 0.08, 0.15, 0.9), not locked))
		add_theme_stylebox_override(&"hover", _box(Color(0.1, 0.14, 0.24, 0.8 if locked else 0.95), not locked))
		add_theme_stylebox_override(&"pressed", _box(Color(0.11, 0.3, 0.66, 0.5 if locked else 1.0), not locked))
		var focus := _box(Color(0, 0, 0, 0), false)
		focus.set_border_width_all(3)
		focus.border_width_left = 9
		focus.border_color = UIScreen.COL_HILITE
		add_theme_stylebox_override(&"focus", focus)
		var dim := 0.5 if locked else 1.0

		var code := Label.new()
		code.text = info.country_code.to_upper()
		code.add_theme_font_size_override(&"font_size", 20)
		code.add_theme_color_override(&"font_color", Color(1, 1, 1, dim))
		var badge := StyleBoxFlat.new()
		badge.bg_color = Color(1, 1, 1, 0.1 * dim)
		badge.border_color = Color(1, 1, 1, 0.55 * dim)
		badge.set_border_width_all(2)
		badge.content_margin_left = 8
		badge.content_margin_right = 9
		code.add_theme_stylebox_override(&"normal", badge)
		code.position = Vector2(26, 14)
		_add(code)

		var tag := Label.new()
		tag.add_theme_font_size_override(&"font_size", 20)
		if locked:
			tag.text = "COMING SOON"
			tag.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.45))
		elif best.is_empty():
			tag.text = "NO TIME SET"
			tag.add_theme_color_override(&"font_color", UIScreen.COL_ACCENT.lightened(0.35))
		else:
			tag.text = TrackSelectScreen.format_lap(best["lap"])
			tag.add_theme_color_override(&"font_color", UIScreen.COL_ACCENT.lightened(0.35))
		tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		tag.position = Vector2(90, 15)
		tag.size = Vector2(CARD_SIZE.x - 90 - 22, 26)
		_add(tag)

		var title := Label.new()
		title.text = info.name.to_upper()
		title.theme_type_variation = &"HeaderLabel"
		title.add_theme_font_size_override(&"font_size", 27)
		title.add_theme_constant_override(&"line_spacing", -6)
		title.add_theme_color_override(&"font_color", Color(1, 1, 1, dim + 0.1))
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		title.max_lines_visible = 2
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		title.position = Vector2(24, 46)
		title.size = Vector2(CARD_SIZE.x - 46, 62)
		_add(title)

		var country := Label.new()
		country.text = info.country.to_upper()
		country.add_theme_font_size_override(&"font_size", 20)
		country.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.65 * dim))
		country.clip_text = true
		country.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		country.position = Vector2(22, 112)
		country.size = Vector2(CARD_SIZE.x - 150, 26)
		_add(country)

		var length := Label.new()
		length.text = TrackSelectScreen.format_length(info.length_m)
		length.add_theme_font_size_override(&"font_size", 20)
		length.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.65 * dim))
		length.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		length.position = Vector2(CARD_SIZE.x - 130, 112)
		length.size = Vector2(104, 26)
		_add(length)

	func _add(l: Label) -> void:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)

	func _box(bg: Color, playable: bool) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.skew = Vector2(0.06, 0)
		sb.set_corner_radius_all(2)
		if playable:
			sb.border_color = UIScreen.COL_ACCENT
			sb.border_width_bottom = 4
		return sb
