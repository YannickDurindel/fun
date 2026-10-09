class_name Minimap
extends Control
## Track map in the top right corner: the circuit's outline (north up), the start line, the
## player (a red arrow pointing where the car heads) and the bots (white dots).
##
## Reads the RaceManager (group `race_manager`) for the track and the player's car, and the
## BotManager (group `bot_manager`) for the other cars. Hidden until a track is loaded.
## The outline is drawn once into a child; only the dots are redrawn every frame.

const REF_HEIGHT: float = 1080.0
const BOX := Vector2(250.0, 250.0)     ## design size at 1080p
const MARGIN := Vector2(44.0, 34.0)
const PAD: float = 16.0
const MAX_POINTS: int = 360
const COL_BG := Color(0.03, 0.035, 0.05, 0.55)
const COL_EDGE := Color(0.0, 0.0, 0.0, 0.85)
const COL_ROAD := Color(1.0, 1.0, 1.0, 0.92)
const COL_PLAYER := Color(0.93, 0.16, 0.16)
const COL_BOT := Color(1.0, 1.0, 1.0)

var race: RaceManager
var bot_manager: BotManager
var _data: TrackData
var _line: PackedVector2Array = []     ## outline in design pixels inside BOX
var _origin: Vector2 = Vector2.ZERO    ## world (x, z) of the map's centre
var _scale: float = 1.0                ## design pixels per metre
var _track: Control
var _dots: Control
var _search_in: float = 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_track = Control.new()
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track.size = BOX
	_track.draw.connect(_draw_track)
	add_child(_track)
	_dots = Control.new()
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.size = BOX
	_dots.draw.connect(_draw_dots)
	_track.add_child(_dots)
	get_viewport().size_changed.connect(_layout)
	_layout()

## Placed from the viewport's size: under a CanvasLayer the control's own size can still be
## zero when the scene starts.
func _layout() -> void:
	var view := get_viewport_rect().size
	var sc := clampf(view.y / REF_HEIGHT, 0.4, 4.0)
	_track.scale = Vector2(sc, sc)
	_track.position = Vector2(view.x - (BOX.x + MARGIN.x) * sc, MARGIN.y * sc)

func _process(delta: float) -> void:
	if race == null or not is_instance_valid(race):
		_search_in -= delta
		if _search_in > 0.0:
			return
		_search_in = 0.5
		race = get_tree().get_first_node_in_group(&"race_manager") as RaceManager
		bot_manager = get_tree().get_first_node_in_group(&"bot_manager") as BotManager
		if race == null:
			return
	if race.data != _data:
		_set_track(race.data)
	if visible:
		_dots.queue_redraw()

## Fits the centreline into the box (north = -Z up, east = +X right).
func _set_track(data: TrackData) -> void:
	_data = data
	_line = PackedVector2Array()
	visible = data != null and data.points.size() >= 8
	if not visible:
		return
	var n := data.points.size()
	var stride := maxi(1, int(ceil(float(n) / MAX_POINTS)))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in range(0, n, stride):
		var p := Vector2(data.points[i].x, data.points[i].z)
		lo = lo.min(p)
		hi = hi.max(p)
	_origin = (lo + hi) * 0.5
	var span := (hi - lo).max(Vector2(1.0, 1.0))
	_scale = minf((BOX.x - PAD * 2.0) / span.x, (BOX.y - PAD * 2.0) / span.y)
	for i in range(0, n, stride):
		_line.append(to_map(data.points[i]))
	_line.append(_line[0])
	_track.queue_redraw()

## World position -> design pixels inside the box.
func to_map(world: Vector3) -> Vector2:
	return BOX * 0.5 + (Vector2(world.x, world.z) - _origin) * _scale

func _draw_track() -> void:
	if _line.size() < 3:
		return
	_track.draw_style_box(_panel(), Rect2(Vector2.ZERO, BOX))
	_track.draw_polyline(_line, COL_EDGE, 7.0, true)
	_track.draw_polyline(_line, COL_ROAD, 3.0, true)
	# Start / finish line: a short tick across the road.
	var a := to_map(_data.position_at(0.0))
	var t := _data.tangent_at(0.0)
	var across := Vector2(-t.z, t.x).normalized() * 8.0
	_track.draw_line(a - across, a + across, COL_PLAYER, 3.0, true)

func _panel() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_BG
	sb.set_corner_radius_all(10)
	return sb

func _draw_dots() -> void:
	if _data == null or race == null or not is_instance_valid(race):
		return
	if bot_manager != null and is_instance_valid(bot_manager):
		for bot: Car in bot_manager.bots:
			if is_instance_valid(bot) and bot.visible:
				var p := to_map(bot.global_position)
				_dots.draw_circle(p, 5.5, COL_EDGE)
				_dots.draw_circle(p, 4.0, COL_BOT)
	var car := race.car
	if car == null or not is_instance_valid(car):
		return
	var c := to_map(car.global_position)
	var fwd3 := -car.global_transform.basis.z
	var fwd := Vector2(fwd3.x, fwd3.z)
	fwd = fwd.normalized() if fwd.length_squared() > 1.0e-6 else Vector2.UP
	var side := Vector2(-fwd.y, fwd.x)
	var tri := PackedVector2Array([c + fwd * 11.0, c - fwd * 6.0 + side * 7.0, c - fwd * 6.0 - side * 7.0])
	var rim := PackedVector2Array([c + fwd * 14.0, c - fwd * 8.5 + side * 10.0, c - fwd * 8.5 - side * 10.0])
	_dots.draw_colored_polygon(rim, COL_EDGE)
	_dots.draw_colored_polygon(tri, COL_PLAYER)
