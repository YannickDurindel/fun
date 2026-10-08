extends Control
## Live standings tower (scenes/ui/standings.tscn), on the left under the sector panel:
## position, livery chip, name and gap to the leader for every car, the player highlighted.
## Reads BotManager.get_standings() (group "bot_manager"); hidden when there are no bots.
## Authored at 1080p and scaled to the viewport height, like the HUD and the race panel.

const SlantedPanel := preload("res://scripts/ui/slanted_panel.gd")
const FONT_BOLD := preload("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")
const FONT_SEMI := preload("res://assets/ui/fonts/BarlowCondensed-SemiBoldItalic.ttf")

const REF_HEIGHT: float = 1080.0
## Top-left corner at 1080p: under the race panel's sector plate (44, 34, 250 x 140).
const ORIGIN := Vector2(44.0, 190.0)
const ROW_SIZE := Vector2(300.0, 34.0)
const ROW_STEP: float = 38.0
const REFRESH_INTERVAL: float = 0.2    ## s between text updates
const SLIDE_RATE: float = 12.0         ## 1/s, rows slide to their new position

const COL_PLATE := Color(0.03, 0.035, 0.05, 0.62)
const COL_PLAYER_PLATE := Color(0.16, 0.45, 1.0, 0.8)
const COL_WHITE := Color(1, 1, 1, 1)
const COL_DIM := Color(1, 1, 1, 0.65)
const COL_SHADOW := Color(0, 0, 0, 0.5)

@export var manager_path: NodePath

var manager: BotManager

var _group: Control
var _rows: Dictionary = {}       ## name -> row Dictionary {root, pos, name, gap, y}
var _refresh_in: float = 0.0
var _num_font: FontVariation
var _lap_length: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_num_font = FontVariation.new()
	_num_font.base_font = FONT_BOLD
	_num_font.opentype_features = {"tnum": 1}
	_group = Control.new()
	_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_group)
	resized.connect(_layout)
	_layout()

func _layout() -> void:
	var sc := clampf(size.y / REF_HEIGHT, 0.4, 4.0)
	_group.scale = Vector2(sc, sc)
	_group.position = ORIGIN * sc

## The Bots node may become ready after this panel: look it up until it is there.
func _find_manager() -> void:
	manager = get_node_or_null(manager_path) as BotManager if not manager_path.is_empty() else null
	if manager == null:
		manager = get_tree().get_first_node_in_group(&"bot_manager") as BotManager
	if manager != null and manager.track != null and manager.track.data != null:
		_lap_length = manager.track.data.length

func _process(delta: float) -> void:
	if manager == null or not is_instance_valid(manager):
		_find_manager()
		if manager == null:
			return
	_refresh_in -= delta
	if _refresh_in <= 0.0:
		_refresh_in = REFRESH_INTERVAL
		refresh()
	if not visible:
		return
	var k := 1.0 - exp(-SLIDE_RATE * delta)
	for row: Dictionary in _rows.values():
		var root := row["root"] as Control
		root.position.y = lerpf(root.position.y, row["y"], k)

## Rebuilds the texts and the row order from the manager's standings.
func refresh() -> void:
	var rows: Array[Dictionary] = []
	if manager != null:
		rows = manager.get_standings()
	visible = not rows.is_empty()
	if rows.is_empty():
		return
	var leader_progress := float(rows[0]["progress"])
	for st in rows:
		var key := String(st["name"])
		var place := int(st["position"])
		if not _rows.has(key):
			_rows[key] = _make_row(st, (place - 1) * ROW_STEP)
		var row: Dictionary = _rows[key]
		row["y"] = (place - 1) * ROW_STEP
		(row["pos"] as Label).text = str(place)
		(row["gap"] as Label).text = gap_text(st, leader_progress, _lap_length)

## "LEADER", "+1.2" (seconds behind the leader), or "+1 LAP" when a lap or more down.
static func gap_text(st: Dictionary, leader_progress: float, lap_length: float) -> String:
	if int(st["position"]) == 1:
		return "LEADER"
	var behind := leader_progress - float(st["progress"])
	if lap_length > 0.0 and not bool(st["finished"]) and behind >= lap_length:
		var n := int(floor(behind / lap_length))
		return "+%d LAP%s" % [n, "S" if n > 1 else ""]
	var gap := float(st["gap"])
	return "+%.1f" % gap if gap < 99.95 else "+%d" % int(round(gap))

func _make_row(st: Dictionary, y: float) -> Dictionary:
	var is_player := bool(st["is_player"])
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.size = ROW_SIZE
	root.position = Vector2(0.0, y)
	root.z_index = 1 if is_player else 0   # the player's row stays on top while rows swap
	_group.add_child(root)
	var plate: Control = SlantedPanel.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.size = ROW_SIZE
	plate.set(&"slant", 10.0)
	plate.set(&"color", COL_PLAYER_PLATE if is_player else COL_PLATE)
	root.add_child(plate)
	var chip := ColorRect.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.color = st["color"]
	chip.position = Vector2(54.0, 6.0)
	chip.size = Vector2(6.0, ROW_SIZE.y - 12.0)
	root.add_child(chip)
	var pos := _label(root, Rect2(14, 0, 34, ROW_SIZE.y), _num_font, 26, COL_WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	var name_label := _label(root, Rect2(70, 0, 130, ROW_SIZE.y), FONT_SEMI, 24,
			COL_WHITE, HORIZONTAL_ALIGNMENT_LEFT)
	name_label.text = String(st["name"])
	name_label.clip_text = true
	var gap := _label(root, Rect2(190, 0, 94, ROW_SIZE.y), _num_font, 24,
			COL_WHITE if is_player else COL_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	return {"root": root, "pos": pos, "name": name_label, "gap": gap, "y": y}

func _label(parent: Control, rect: Rect2, font: Font, font_size: int, color: Color,
		align: HorizontalAlignment) -> Label:
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
