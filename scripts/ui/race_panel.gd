extends Control
## Race panel (Trackmania style), shown next to the HUD in race scenes. Reads a RaceManager:
##   top centre: lap time, lap counter, best lap; centre: 3-2-1-GO countdown, checkpoint /
##   lap split popups (blue = faster, red = slower); top left: S1/S2/S3 sector times
##   (purple = all-time best, green = session best, yellow = slower); WRONG WAY banner.
## Authored at 1080p and scaled to the viewport height, like the HUD.

const RaceTimer := preload("res://scripts/ui/race_timer.gd")
const SlantedPanel := preload("res://scripts/ui/slanted_panel.gd")
const FONT_BOLD := preload("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")
const FONT_SEMI := preload("res://assets/ui/fonts/BarlowCondensed-SemiBoldItalic.ttf")

const REF_HEIGHT: float = 1080.0
const MARGIN := Vector2(44.0, 34.0)
const SPLIT_SHOW_TIME: float = 2.0
const LAP_SHOW_TIME: float = 3.0
const GO_SHOW_TIME: float = 0.8
const WRONG_WAY_BLINK_HZ: float = 2.5

const COL_WAITING := Color(1, 1, 1, 0.55)
const COL_WHITE := Color(1, 1, 1, 1)
const COL_DIM := Color(1, 1, 1, 0.5)
const COL_SHADOW := Color(0, 0, 0, 0.5)
const COL_GO := Color(0.35, 1.0, 0.45)
const COL_SECTOR: Array[Color] = [Color(1.0, 0.84, 0.2), Color(0.3, 0.95, 0.4), Color(0.78, 0.36, 1.0)]
const COL_PLATE := Color(0.03, 0.035, 0.05, 0.62)

@export var race_path: NodePath
@export var hud_path: NodePath = ^"../HUD"

var race: RaceManager

var _num_font: FontVariation
var _small_font: FontVariation
var _top: Control
var _time_label: Label
var _lap_label: Label
var _best_label: Label
var _hint: Label
var _countdown: Label
var _split: Control
var _split_title: Label
var _split_time: Label
var _split_time_box: Control   ## time plate; centred when no delta is shown
var _split_delta_plate: Control
var _split_delta: Label
var _sectors: Control
var _sector_labels: Array[Label] = []
var _wrong_way: Control

var _split_timer: float = 0.0
var _go_timer: float = 0.0
var _blink: float = 0.0
var _shown_ms: int = -1
var _shown_running: bool = true
var _shown_lap: int = -2
var _shown_best: float = -2.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_num_font = FontVariation.new()
	_num_font.base_font = FONT_BOLD
	_num_font.opentype_features = {"tnum": 1}
	_small_font = FontVariation.new()
	_small_font.base_font = FONT_SEMI
	_small_font.spacing_glyph = 2
	_build()
	var hud := get_node_or_null(hud_path)
	if hud and hud.has_method(&"set_free_timer_visible"):
		hud.call(&"set_free_timer_visible", false)
	race = get_node_or_null(race_path) as RaceManager if not race_path.is_empty() else null
	if race == null:
		race = get_tree().get_first_node_in_group(&"race_manager") as RaceManager
	if race:
		race.countdown_changed.connect(_on_countdown)
		race.race_restarted.connect(_on_restarted)
		race.checkpoint_passed.connect(_on_checkpoint)
		race.sector_completed.connect(_on_sector)
		race.lap_completed.connect(_on_lap)
		race.lap_invalidated.connect(_on_lap_invalidated)
		race.wrong_way_changed.connect(_on_wrong_way)
	resized.connect(_layout)
	_layout()
	_refresh()

# ---------------------------------------------------------------- construction
func _plate(parent: Control, rect: Rect2, slant: float, color: Color = COL_PLATE, accent: Color = Color(1, 1, 1, 0)) -> Control:
	var p: Control = SlantedPanel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.position = rect.position
	p.size = rect.size
	p.set(&"slant", slant)
	p.set(&"color", color)
	p.set(&"accent", accent)
	parent.add_child(p)
	return p

func _label(parent: Control, rect: Rect2, font: Font, font_size: int, color: Color, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = rect.position
	l.size = rect.size
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override(&"font", font)
	l.add_theme_font_size_override(&"font_size", font_size)
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_color_override(&"font_shadow_color", COL_SHADOW)
	l.add_theme_constant_override(&"shadow_offset_x", 2)
	l.add_theme_constant_override(&"shadow_offset_y", 2)
	parent.add_child(l)
	return l

func _group(group_size: Vector2) -> Control:
	var g := Control.new()
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.size = group_size
	add_child(g)
	return g

func _build() -> void:
	# Top centre: lap time, lap counter + best lap, hint.
	_top = _group(Vector2(360, 156))
	_plate(_top, Rect2(0, 0, 360, 78), 20.0, COL_PLATE, Color(1, 1, 1, 0.35))
	_time_label = _label(_top, Rect2(0, -4, 360, 82), _num_font, 64, COL_WAITING)
	_time_label.text = "0:00.000"
	_plate(_top, Rect2(14, 84, 332, 36), 12.0)
	_lap_label = _label(_top, Rect2(34, 84, 110, 36), _small_font, 24, COL_WHITE, HORIZONTAL_ALIGNMENT_LEFT)
	_best_label = _label(_top, Rect2(130, 84, 196, 36), _small_font, 24, COL_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	_hint = _label(_top, Rect2(-60, 124, 480, 30), _small_font, 21, COL_DIM)
	_hint.text = "RESPAWN: BACKSPACE   RESTART: DEL"

	# Centre: countdown.
	_countdown = _label(self, Rect2(0, 0, 600, 300), _num_font, 230, COL_WHITE)
	_countdown.add_theme_constant_override(&"shadow_offset_x", 5)
	_countdown.add_theme_constant_override(&"shadow_offset_y", 5)
	_countdown.visible = false

	# Centre: split popup.
	_split = _group(Vector2(440, 112))
	_split_title = _label(_split, Rect2(0, 0, 440, 34), _small_font, 25, COL_WHITE)
	_split_time_box = Control.new()
	_split_time_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_split.add_child(_split_time_box)
	_plate(_split_time_box, Rect2(0, 36, 250, 72), 18.0)
	_split_time = _label(_split_time_box, Rect2(0, 32, 250, 78), _num_font, 54, COL_WHITE)
	_split_delta_plate = _plate(_split, Rect2(240, 36, 200, 72), 18.0, Color(0.2, 0.45, 1.0, 0.85))
	_split_delta = _label(_split, Rect2(240, 32, 200, 78), _num_font, 50, COL_WHITE)
	_split.visible = false

	# Top left: sector times.
	_sectors = _group(Vector2(250, 140))
	_plate(_sectors, Rect2(0, 0, 250, 140), 16.0)
	for i in 3:
		var l := _label(_sectors, Rect2(26, 10 + i * 40, 200, 40), _num_font, 32, COL_DIM, HORIZONTAL_ALIGNMENT_LEFT)
		_sector_labels.append(l)
	_clear_sectors()

	# Wrong-way banner.
	_wrong_way = _group(Vector2(460, 92))
	_plate(_wrong_way, Rect2(0, 0, 460, 92), 24.0, Color(0.85, 0.08, 0.06, 0.85), Color(1, 1, 1, 0.6))
	_label(_wrong_way, Rect2(0, -4, 460, 96), _num_font, 64, COL_WHITE).text = "WRONG WAY"
	_wrong_way.visible = false

func _layout() -> void:
	var sc := clampf(size.y / REF_HEIGHT, 0.4, 4.0)
	var sv := Vector2(sc, sc)
	var m := MARGIN * sc
	_top.scale = sv
	_top.position = Vector2((size.x - _top.size.x * sc) * 0.5, m.y * 0.8)
	_sectors.scale = sv
	_sectors.position = m
	_countdown.scale = sv
	_countdown.position = Vector2((size.x - _countdown.size.x * sc) * 0.5, size.y * 0.36 - _countdown.size.y * sc * 0.5)
	_split.scale = sv
	_split.position = Vector2((size.x - _split.size.x * sc) * 0.5, size.y * 0.27)
	_wrong_way.scale = sv
	_wrong_way.position = Vector2((size.x - _wrong_way.size.x * sc) * 0.5, size.y * 0.42)

# ---------------------------------------------------------------- race events
func _on_restarted() -> void:
	_split.visible = false
	_split_timer = 0.0
	_clear_sectors()

func _on_countdown(step: int) -> void:
	_countdown.visible = true
	if step > 0:
		_countdown.text = str(step)
		_countdown.add_theme_color_override(&"font_color", COL_WHITE)
		_go_timer = 0.0
	else:
		_countdown.text = "GO!"
		_countdown.add_theme_color_override(&"font_color", COL_GO)
		_go_timer = GO_SHOW_TIME

func _on_checkpoint(index: int, time: float, delta: float, has_delta: bool) -> void:
	var total := race.checkpoints.size() if race else 0
	_show_split("CHECKPOINT %d / %d" % [index + 1, total], time, delta, has_delta, SPLIT_SHOW_TIME)

func _on_lap(lap: int, time: float, delta: float, has_delta: bool, is_best: bool) -> void:
	var title := "LAP %d" % lap + ("   NEW BEST" if is_best else "")
	_show_split(title, time, delta, has_delta, LAP_SHOW_TIME)

func _on_lap_invalidated() -> void:
	_split_title.text = "CHECKPOINT MISSED - LAP NOT COUNTED"
	_split_time.text = "--:--.---"
	_split_delta_plate.visible = false
	_split_delta.visible = false
	_split_time_box.position.x = 95.0
	_split.visible = true
	_split_timer = SPLIT_SHOW_TIME

func _show_split(title: String, time: float, delta: float, has_delta: bool, show_time: float) -> void:
	_split_title.text = title
	_split_time.text = RaceTimer.format_time(time)
	_split_delta_plate.visible = has_delta
	_split_delta.visible = has_delta
	_split_time_box.position.x = 0.0 if has_delta else 95.0
	if has_delta:
		_split_delta.text = RaceManager.format_delta(delta)
		var c := RaceManager.delta_color(delta)
		_split_delta_plate.set(&"color", Color(c, 0.85))
	_split.visible = true
	_split_timer = show_time

func _on_sector(sector: int, time: float, grade: int) -> void:
	if sector == 0:
		_clear_sectors()
	if sector < _sector_labels.size():
		var l := _sector_labels[sector]
		l.text = "S%d   %s" % [sector + 1, _short_time(time)]
		l.add_theme_color_override(&"font_color", COL_SECTOR[clampi(grade, 0, 2)])

func _on_wrong_way(active: bool) -> void:
	_wrong_way.visible = active
	_blink = 0.0

func _clear_sectors() -> void:
	for i in _sector_labels.size():
		_sector_labels[i].text = "S%d   --.---" % (i + 1)
		_sector_labels[i].add_theme_color_override(&"font_color", COL_DIM)

static func _short_time(t: float) -> String:
	var txt := RaceTimer.format_time(t)
	return txt.substr(2) if t < 60.0 else txt

# ---------------------------------------------------------------- per frame
func _process(delta: float) -> void:
	if _split_timer > 0.0:
		_split_timer -= delta
		if _split_timer <= 0.0:
			_split.visible = false
	if _go_timer > 0.0:
		_go_timer -= delta
		var k := 1.0 - _go_timer / GO_SHOW_TIME
		_countdown.modulate.a = 1.0 - k * k
		if _go_timer <= 0.0:
			_countdown.visible = false
			_countdown.modulate.a = 1.0
	elif race and race.state != RaceManager.State.COUNTDOWN and _countdown.visible:
		_countdown.visible = false
	if _wrong_way.visible:
		_blink = fmod(_blink + delta * WRONG_WAY_BLINK_HZ, 1.0)
		_wrong_way.modulate.a = 1.0 if _blink < 0.65 else 0.35
	_refresh()

func _refresh() -> void:
	if race == null:
		return
	var running := race.state == RaceManager.State.RACING
	var t := race.lap_time()
	var ms := RaceTimer.to_ms(t)
	if ms != _shown_ms or running != _shown_running:
		_shown_ms = ms
		if running != _shown_running:
			_shown_running = running
			_time_label.add_theme_color_override(&"font_color", COL_WHITE if running else COL_WAITING)
		_time_label.text = RaceTimer.format_time(t)
	var lap_key := -1 if race.out_lap else race.laps_completed
	if lap_key != _shown_lap or race.best_lap != _shown_best:
		_shown_lap = lap_key
		_shown_best = race.best_lap
		_lap_label.text = "OUT LAP" if race.out_lap else "LAP %d" % (race.laps_completed + 1)
		_best_label.text = "BEST  " + (RaceTimer.format_time(race.best_lap) if race.best_lap > 0.0 else "-:--.---")

func get_time_text() -> String:
	return _time_label.text

func get_split_text() -> String:
	return _split_delta.text if _split.visible and _split_delta.visible else ""

func is_wrong_way_shown() -> bool:
	return _wrong_way.visible
