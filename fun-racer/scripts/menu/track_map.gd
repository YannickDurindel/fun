class_name TrackMap
extends Control
## 2D map of a track's centreline (north up), drawn from its track.json.
##   map.set_track(info)   show a TrackInfo; tracks without geometry get a "?" placeholder
## The lap is fitted to the control's rect with its aspect ratio preserved. Shows the
## start/finish line with a direction arrow, sector colours and turn numbers (each optional).
## Reusable by any screen: drop it in a container, it has a sensible minimum size.

## F1 timing-screen sector colours (sector 1, 2, 3, then repeating).
const SECTOR_COLORS: Array[Color] = [Color(0.93, 0.16, 0.16), Color(0.16, 0.45, 1.0), Color(1.0, 0.8, 0.12)]
const LINE_COLOR := Color(1, 1, 1)
const OUTLINE_COLOR := Color(0, 0, 0, 0.6)
const PLACEHOLDER_COLOR := Color(1, 1, 1, 0.28)
const MAX_POINTS := 720          ## the centreline is decimated to at most this many vertices

@export var show_sectors: bool = true:
	set(v):
		show_sectors = v
		queue_redraw()
@export var show_turns: bool = true:
	set(v):
		show_turns = v
		queue_redraw()
@export var show_start: bool = true:
	set(v):
		show_start = v
		queue_redraw()
@export var line_width: float = 5.0:
	set(v):
		line_width = v
		queue_redraw()
## Free border around the lap, in pixels (room for turn numbers).
@export var padding: float = 34.0:
	set(v):
		padding = v
		_dirty = true
		queue_redraw()
@export var turn_font_size: int = 20

var info: TrackInfo
var data: TrackData

static var _data_cache: Dictionary = {}   # track_json path -> TrackData

var _dirty: bool = true
var _poly: PackedVector2Array = []
var _poly_s: PackedFloat32Array = []      # lap distance of each vertex of _poly
var _origin: Vector2 = Vector2.ZERO       # fit: screen = _origin + (x, z) * _scale
var _scale: float = 1.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	resized.connect(_on_resized)

func _get_minimum_size() -> Vector2:
	return Vector2(160, 120)

func set_track(track: TrackInfo) -> void:
	info = track
	data = load_data(track)
	_dirty = true
	queue_redraw()

## True when the track has a centreline to draw (false: the placeholder is shown).
func has_geometry() -> bool:
	return data != null and data.points.size() >= 3

## The fitted centreline in local coordinates (empty without geometry).
func polyline() -> PackedVector2Array:
	_refit()
	return _poly

## Local position of lap distance `s` on the map.
func map_position(s: float) -> Vector2:
	_refit()
	if not has_geometry():
		return size * 0.5
	return _to_map(data.position_at(s))

## Centreline data of a track, or null when it has none yet. Cached per file.
static func load_data(track: TrackInfo) -> TrackData:
	if track == null or track.track_json.is_empty():
		return null
	if _data_cache.has(track.track_json):
		return _data_cache[track.track_json]
	var d: TrackData = null
	if FileAccess.file_exists(track.track_json):
		d = TrackData.load_track(track.track_json)
	_data_cache[track.track_json] = d
	return d

## Difference between the highest and lowest point of the lap, in metres (0 without geometry).
static func elevation_change(d: TrackData) -> float:
	if d == null or d.points.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for p in d.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	return hi - lo

func _on_resized() -> void:
	_dirty = true
	queue_redraw()

func _to_map(p: Vector3) -> Vector2:
	# x = east -> right; z = -north -> down, so north is up.
	return _origin + Vector2(p.x, p.z) * _scale

func _refit() -> void:
	if not _dirty:
		return
	_dirty = false
	_poly = PackedVector2Array()
	_poly_s = PackedFloat32Array()
	if not has_geometry():
		return
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in data.points:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	var extent := (hi - lo).max(Vector2(1e-3, 1e-3))
	var pad := minf(padding, minf(size.x, size.y) * 0.25)
	var avail := (size - Vector2(pad, pad) * 2.0).max(Vector2.ONE)
	_scale = minf(avail.x / extent.x, avail.y / extent.y)
	_origin = size * 0.5 - (lo + hi) * 0.5 * _scale
	var n := data.points.size()
	var stride := maxi(1, ceili(float(n) / MAX_POINTS))
	for i in range(0, n, stride):
		_poly.append(_to_map(data.points[i]))
		_poly_s.append(i * data.step)

func _draw() -> void:
	_refit()
	if not has_geometry():
		_draw_placeholder()
		return
	var closed := _poly.duplicate()
	closed.append(_poly[0])
	draw_polyline(closed, OUTLINE_COLOR, line_width + 5.0, true)
	if show_sectors and _sector_bounds().size() > 1:
		_draw_sectors()
	else:
		draw_polyline(closed, LINE_COLOR, line_width, true)
	if show_start:
		_draw_start()
	if show_turns:
		_draw_turns()

## Sector start distances, ascending, always beginning at 0.
func _sector_bounds() -> Array[float]:
	var out: Array[float] = [0.0]
	for b in data.sectors:
		if b > 0.5 and b < data.length - 0.5:
			out.append(b)
	out.sort()
	return out

func _draw_sectors() -> void:
	var bounds := _sector_bounds()
	var n := _poly.size()
	var seg := PackedVector2Array()
	var sector := 0
	for i in n + 1:
		var s := _poly_s[i] if i < n else data.length
		while sector + 1 < bounds.size() and s >= bounds[sector + 1]:
			# Split exactly on the boundary so the colours meet there.
			var cut := _to_map(data.position_at(bounds[sector + 1]))
			seg.append(cut)
			_stroke(seg, SECTOR_COLORS[sector % SECTOR_COLORS.size()])
			seg = PackedVector2Array([cut])
			sector += 1
		seg.append(_poly[i % n])
	_stroke(seg, SECTOR_COLORS[sector % SECTOR_COLORS.size()])

func _stroke(pts: PackedVector2Array, color: Color) -> void:
	if pts.size() >= 2:
		draw_polyline(pts, color, line_width, true)

func _dir_at(s: float) -> Vector2:
	var t := data.tangent_at(s)
	var d := Vector2(t.x, t.z)
	return d.normalized() if d.length_squared() > 1e-9 else Vector2.RIGHT

func _draw_start() -> void:
	var p := _to_map(data.position_at(0.0))
	var dir := _dir_at(0.0)
	var side := Vector2(-dir.y, dir.x)
	var half := line_width * 1.9 + 3.0
	draw_line(p - side * half, p + side * half, OUTLINE_COLOR, line_width + 3.0, true)
	draw_line(p - side * half, p + side * half, LINE_COLOR, line_width * 0.8, true)
	# Direction-of-travel arrow beside the line.
	var a := p + side * (half + line_width * 2.6)
	var l := line_width * 3.0
	draw_colored_polygon(PackedVector2Array([a + dir * l, a - dir * l * 0.5 + side * l * 0.6, a - dir * l * 0.5 - side * l * 0.6]), LINE_COLOR)

func _draw_turns() -> void:
	var font := get_theme_font(&"font", &"Button")
	var offset := line_width * 0.5 + turn_font_size * 0.85
	for turn in data.turns:
		var s := float(turn.get("s_apex", 0.0))
		var dir := _dir_at(s)
		var right := Vector2(-dir.y, dir.x)
		# Numbers sit on the outside of the corner.
		var out := -right if String(turn.get("direction", "right")) == "right" else right
		var c := _to_map(data.position_at(s)) + out * offset
		var text := String(turn.get("id", "")).trim_prefix("T")
		var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, turn_font_size)
		var at := c + Vector2(-ts.x * 0.5, font.get_ascent(turn_font_size) - font.get_height(turn_font_size) * 0.5)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, turn_font_size, 5, OUTLINE_COLOR)
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, turn_font_size, Color(1, 1, 1, 0.92))

## Tracks without geometry: a dashed generic circuit outline and a question mark.
func _draw_placeholder() -> void:
	var c := size * 0.5
	var r := (size * 0.5 - Vector2(padding, padding)).max(Vector2(10, 10))
	r.x = minf(r.x, r.y * 1.9)
	var steps := 72
	for i in range(0, steps, 2):
		var a0 := TAU * i / steps
		var a1 := TAU * (i + 1) / steps
		draw_line(c + _blob(a0) * r, c + _blob(a1) * r, PLACEHOLDER_COLOR, line_width, true)
	var font := get_theme_font(&"font", &"Button")
	var fs := int(clampf(r.y * 0.9, 24.0, 160.0))
	var ts := font.get_string_size("?", HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(font, c + Vector2(-ts.x * 0.5, font.get_ascent(fs) - font.get_height(fs) * 0.5), "?",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, PLACEHOLDER_COLOR)

## A slightly irregular closed loop (unit-ish radius), so the placeholder reads as a circuit.
func _blob(a: float) -> Vector2:
	var k := 0.86 + 0.1 * cos(a * 3.0 + 0.6) + 0.04 * sin(a * 5.0)
	return Vector2(cos(a), sin(a)) * k
