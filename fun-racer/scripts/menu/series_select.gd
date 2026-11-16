class_name SeriesSelectScreen
extends UIScreen
## Series selection, opened by PLAY: one big card per SeriesCatalog entry (F1, Endurance, ...).
## A series with events opens the track list for that series (TrackSelectScreen.series);
## the others are "coming soon": they can be browsed but not opened. The grid scrolls once
## there are more rows than fit (cards keep MIN_CARD_H); focus scrolls it into view.

const MARGIN := 90.0
const TOP := 172.0
const AREA_H := 780.0
const COLUMNS := 4
const GAP := 24.0
const MIN_CARD_H := 236.0

var cards: Array[SeriesCard] = []
var back_button: Button

var _scroll: ScrollContainer
var _grid: GridContainer
var _hint: Label
var _last_card: SeriesCard

func on_enter() -> void:
	_build()
	resized.connect(_layout)
	_layout()
	var start := card_for(TrackSelectScreen.series)
	if start == null and not cards.is_empty():
		start = cards[0]
	if start != null:
		initial_focus = get_path_to(start)
		_last_card = start

## The card of a series id, or null.
func card_for(id: String) -> SeriesCard:
	for c in cards:
		if c.series_id == id:
			return c
	return null

## Opens the track list of a series. Returns false for a series without events yet.
func select(id: String) -> bool:
	if not SeriesCatalog.has_events(id):
		return false
	TrackSelectScreen.series = id
	if router != null:
		router.go("tracks")
	return true

func _build() -> void:
	var title := Label.new()
	title.text = "SELECT SERIES"
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
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override(&"h_separation", int(GAP))
	_grid.add_theme_constant_override(&"v_separation", int(GAP))
	pad.add_child(_grid)
	for s in SeriesCatalog.all():
		var card := SeriesCard.new()
		card.setup(s)
		card.focus_entered.connect(_on_card_focused.bind(card))
		card.mouse_entered.connect(_on_card_hovered.bind(card))
		card.pressed.connect(select.bind(card.series_id))
		_grid.add_child(card)
		cards.append(card)

	back_button = Button.new()
	back_button.text = "BACK"
	back_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	back_button.position = Vector2(MARGIN, TOP + AREA_H + 22)
	back_button.size = Vector2(260, 58)
	back_button.pressed.connect(on_back)
	add_child(back_button)

	_hint = Label.new()
	_hint.theme_type_variation = &"DimLabel"
	_hint.text = "ARROWS / D-PAD  BROWSE        ENTER / A  SELECT        ESC / B  BACK"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_hint)

func _layout() -> void:
	var w := maxf(size.x, 1100.0) if size.x > 1.0 else 1920.0
	var rows := ceili(float(cards.size()) / COLUMNS)
	var card_w := floorf((w - 2.0 * MARGIN - 34.0 - GAP * (COLUMNS - 1)) / COLUMNS)
	var card_h := maxf(floorf((AREA_H - 12.0 - GAP * (rows - 1)) / maxi(rows, 1)), MIN_CARD_H)
	for c in cards:
		c.set_card_size(Vector2(card_w, card_h))
	_scroll.position = Vector2(MARGIN - 12.0, TOP - 6.0)
	_scroll.size = Vector2(w - 2.0 * MARGIN + 12.0, AREA_H + 12.0)
	_hint.position = Vector2(w - MARGIN - 1000.0, TOP + AREA_H + 36)
	_hint.size = Vector2(1000.0, 30)
	_wire_focus()

## Explicit focus neighbours: the grid wraps nowhere, and the last row leads to BACK.
func _wire_focus() -> void:
	var n := cards.size()
	for i in n:
		var c := cards[i]
		var same_row_left := i % COLUMNS > 0
		var same_row_right := i % COLUMNS < COLUMNS - 1 and i + 1 < n
		c.focus_neighbor_left = c.get_path_to(cards[i - 1]) if same_row_left else NodePath(".")
		c.focus_neighbor_right = c.get_path_to(cards[i + 1]) if same_row_right else NodePath(".")
		c.focus_neighbor_top = c.get_path_to(cards[i - COLUMNS]) if i - COLUMNS >= 0 else NodePath(".")
		@warning_ignore("integer_division")
		var has_row_below := (i / COLUMNS) < ((n - 1) / COLUMNS)
		var below: Control = cards[mini(i + COLUMNS, n - 1)] if has_row_below else back_button
		c.focus_neighbor_bottom = c.get_path_to(below)
	back_button.focus_neighbor_left = NodePath(".")
	back_button.focus_neighbor_right = NodePath(".")
	back_button.focus_neighbor_bottom = NodePath(".")
	_wire_back()

func _wire_back() -> void:
	var up: Control = _last_card if _last_card != null else (cards.back() if not cards.is_empty() else null)
	back_button.focus_neighbor_top = back_button.get_path_to(up) if up != null else NodePath(".")

## Hovering focuses a card, but must not scroll the grid under the mouse (follow_focus would).
func _on_card_hovered(card: SeriesCard) -> void:
	if card.has_focus():
		return
	_scroll.follow_focus = false
	card.grab_focus()
	_scroll.follow_focus = true

func _on_card_focused(card: SeriesCard) -> void:
	_last_card = card
	_wire_back()

## One series. Series without events are dimmed but still focusable.
class SeriesCard extends Button:
	var series_id: String = ""
	var _code: Label
	var _status: Label
	var _title: Label
	var _tagline: Label

	func setup(s: Dictionary) -> void:
		series_id = s["id"]
		mouse_filter = Control.MOUSE_FILTER_PASS   # let the wheel scroll the grid
		var open := SeriesCatalog.has_events(series_id)
		var playable := SeriesCatalog.is_playable(series_id)
		add_theme_stylebox_override(&"normal", _box(Color(0.05, 0.08, 0.15, 0.9) if open else Color(0.03, 0.035, 0.05, 0.55), playable))
		add_theme_stylebox_override(&"hover", _box(Color(0.1, 0.14, 0.24, 0.95 if open else 0.8), playable))
		add_theme_stylebox_override(&"pressed", _box(Color(0.11, 0.3, 0.66, 1.0 if open else 0.5), playable))
		var focus := _box(Color(0, 0, 0, 0), false)
		focus.set_border_width_all(3)
		focus.border_width_left = 10
		focus.border_color = UIScreen.COL_HILITE
		add_theme_stylebox_override(&"focus", focus)
		var dim := 1.0 if open else 0.5

		_code = Label.new()
		_code.text = String(s.get("code", "")).to_upper()
		_code.add_theme_font_size_override(&"font_size", 24)
		_code.add_theme_color_override(&"font_color", Color(1, 1, 1, dim))
		var badge := StyleBoxFlat.new()
		badge.bg_color = Color(1, 1, 1, 0.1 * dim)
		badge.border_color = Color(1, 1, 1, 0.55 * dim)
		badge.set_border_width_all(2)
		badge.content_margin_left = 10
		badge.content_margin_right = 11
		_code.add_theme_stylebox_override(&"normal", badge)
		_add(_code)

		_status = Label.new()
		_status.add_theme_font_size_override(&"font_size", 24)
		_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		var n := SeriesCatalog.tracks(series_id).size()
		if playable:
			var count := 0
			for t in SeriesCatalog.tracks(series_id):
				if t.available:
					count += 1
			_status.text = "%d TRACK%s" % [count, "" if count == 1 else "S"]
			_status.add_theme_color_override(&"font_color", UIScreen.COL_ACCENT.lightened(0.35))
		elif open:
			_status.text = "%d EVENTS  ·  COMING SOON" % n
			_status.add_theme_color_override(&"font_color", Color(1, 0.8, 0.12))
		else:
			_status.text = "COMING SOON"
			_status.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.45))
		_add(_status)

		_title = Label.new()
		_title.text = String(s["name"]).to_upper()
		_title.theme_type_variation = &"HeaderLabel"
		_title.add_theme_font_size_override(&"font_size", 58)
		_title.add_theme_constant_override(&"line_spacing", -10)
		_title.add_theme_color_override(&"font_color", Color(1, 1, 1, dim + 0.1))
		_title.clip_text = true
		_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_add(_title)

		_tagline = Label.new()
		_tagline.text = String(s.get("tagline", "")).to_upper()
		_tagline.add_theme_font_size_override(&"font_size", 24)
		_tagline.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.65 * dim))
		_tagline.clip_text = true
		_tagline.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_add(_tagline)

	func set_card_size(sz: Vector2) -> void:
		custom_minimum_size = sz
		size = sz
		_code.position = Vector2(30, 22)
		_status.position = Vector2(110, 24)
		_status.size = Vector2(sz.x - 110 - 30, 30)
		_title.position = Vector2(28, sz.y - 150)
		_title.size = Vector2(sz.x - 56, 74)
		_fit_title(sz.x - 56)
		_tagline.position = Vector2(30, sz.y - 70)
		_tagline.size = Vector2(sz.x - 60, 32)

	## Long names ("Motorcycle Grand Prix") shrink the title font until they fit on one line.
	func _fit_title(width: float) -> void:
		var font := _title.get_theme_font(&"font")
		var fs := 58
		while fs > 30 and font.get_string_size(_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width - 8.0:
			fs -= 2
		_title.add_theme_font_size_override(&"font_size", fs)
		_title.position.y += (58 - fs) * 0.6   # keep the baseline where full-size titles sit

	func _add(l: Label) -> void:
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)

	func _box(bg: Color, playable: bool) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.skew = Vector2(0.04, 0)
		sb.set_corner_radius_all(2)
		if playable:
			sb.border_color = UIScreen.COL_ACCENT
			sb.border_width_bottom = 5
		return sb
