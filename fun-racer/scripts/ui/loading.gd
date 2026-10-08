extends Control
## Loading screen (scenes/ui/loading.tscn), shown by the `Transitions` autoload while a race
## loads: track name, grand prix, place, length, turns, the player's best lap, one gameplay tip,
## a map outline that lights up along the lap as loading progresses, and a progress bar.
##   setup(info)            fill the texts and the map for a TrackInfo
##   set_progress(p)        0..1 target; the bar and the map glide towards it
##   set_progress(p, true)  same, without the glide
##   set_phase("TEXT")      caption above the bar
## Designed at 1920x1080 and scaled to the window height, like the menu screens.
## The map is a local `_draw()` polyline; it can be swapped for scripts/menu/track_map.gd later.

const REF_SIZE := Vector2(1920, 1080)
const MAP_MAX_POINTS: int = 480
const TIP_SECONDS: float = 4.5
const TIPS: PackedStringArray = [
	"Hold brake + steer above 110 km/h to drift.",
	"Backspace respawns at the last checkpoint.",
	"Steering builds up the longer you hold the key: tap for small corrections.",
	"Brake in a straight line, then turn in: the car grips best off the brakes.",
	"Keys 1, 2 and 3 switch the camera.",
	"Blue split = faster than your best. Red = slower.",
	"Kerbs are fine. Grass and gravel cost a lot of speed.",
]
const COL_BG_TOP := Color(0.055, 0.075, 0.13)
const COL_BG_BOTTOM := Color(0.02, 0.022, 0.032)
const COL_ACCENT := Color(0.16, 0.45, 1.0)
const COL_HILITE := Color(0.93, 0.16, 0.16)
const SIDE: float = 130.0
const TITLE_SIZE: int = 118
const TITLE_MAX_WIDTH: float = 800.0

const FONT_BOLD: FontFile = preload("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")
const SlantedPanel := preload("res://scripts/ui/slanted_panel.gd")
const RaceTimer := preload("res://scripts/ui/race_timer.gd")

var info: TrackInfo
## Target progress, 0..1 (what the loader reported last).
var progress: float = 0.0
## Progress currently drawn by the bar and the map (glides towards `progress`).
var bar_ratio: float = 0.0
## Map outline, one lap in race order, normalised around the origin (y down).
var map_points: PackedVector2Array = PackedVector2Array()
## Player's best lap in seconds, -1 when there is none.
var best_lap: float = -1.0
## When false the tip does not rotate (screenshots).
var rotate_tips: bool = true
var tip_index: int = 0

var name_label: Label
var grand_prix_label: Label
var place_label: Label
var length_label: Label
var turns_label: Label
var best_label: Label
var tip_label: Label
var phase_label: Label
var percent_label: Label
var map_view: Control
var bar: Control
var bar_fill: Control

## Outlines by track.json path: the file is parsed once per run, not on every (re)start.
static var _map_cache: Dictionary = {}

var _canvas: Control
var _tip_time: float = 0.0
var _built: bool = false

func _ready() -> void:
	_build()
	get_viewport().size_changed.connect(_fit)
	_fit()

## Fills the screen for `track`. Can be called before or after the node enters the tree.
func setup(track: TrackInfo, first_tip: int = -1) -> void:
	_build()
	info = track
	tip_index = (first_tip if first_tip >= 0 else randi()) % TIPS.size()
	tip_label.text = TIPS[tip_index]
	_tip_time = 0.0
	if track == null:
		return
	name_label.text = track.name.to_upper()
	_fit_title()
	grand_prix_label.text = track.grand_prix.to_upper()
	var place := track.city
	if not track.country.is_empty():
		place = track.country if place.is_empty() else "%s, %s" % [place, track.country]
	place_label.text = place
	length_label.text = "%.3f KM" % (track.length_m / 1000.0)
	turns_label.text = str(track.turns)
	best_lap = read_best_lap(track.best_path())
	best_label.text = RaceTimer.format_time(best_lap) if best_lap > 0.0 else "NO TIME"
	best_label.modulate.a = 1.0 if best_lap > 0.0 else 0.4
	map_points = build_map_points(track.track_json)
	map_view.queue_redraw()

func set_progress(p: float, snap: bool = false) -> void:
	_build()
	progress = clampf(p, 0.0, 1.0)
	if snap:
		bar_ratio = progress
	_apply_ratio()

func set_phase(text: String) -> void:
	_build()
	phase_label.text = text

## Best lap stored in a `user://best_<id>.json` (see RaceManager._save_best), or -1.
static func read_best_lap(path: String) -> float:
	if path.is_empty() or not FileAccess.file_exists(path):
		return -1.0
	var f := FileAccess.open(path, FileAccess.READ)
	var json := JSON.new()   # parse() instead of parse_string(): a broken file is not an error
	if f == null or json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return -1.0
	var v: Variant = (json.data as Dictionary).get("best_lap", -1.0)
	return float(v) if (v is float or v is int) and float(v) > 0.0 else -1.0

## Top view of the centreline (east = right, north = up), decimated and normalised so the
## larger side spans -0.5..0.5. Empty when the track has no data.
static func build_map_points(track_json: String) -> PackedVector2Array:
	var out := PackedVector2Array()
	if _map_cache.has(track_json):
		return _map_cache[track_json]
	if track_json.is_empty() or not FileAccess.file_exists(track_json):
		return out
	var data := TrackData.load_track(track_json)
	if data == null or data.points.size() < 3:
		return out
	var n := data.points.size()
	var stride := maxi(1, ceili(float(n) / MAP_MAX_POINTS))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in range(0, n, stride):
		var p := Vector2(data.points[i].x, data.points[i].z)
		out.append(p)
		lo = lo.min(p)
		hi = hi.max(p)
	var centre := (lo + hi) * 0.5
	var span := maxf(maxf(hi.x - lo.x, hi.y - lo.y), 1.0)
	for i in out.size():
		out[i] = (out[i] - centre) / span
	_map_cache[track_json] = out
	return out

func _process(delta: float) -> void:
	if not is_equal_approx(bar_ratio, progress):
		bar_ratio = lerpf(bar_ratio, progress, 1.0 - exp(-10.0 * delta))
		if absf(bar_ratio - progress) < 0.002:
			bar_ratio = progress
		_apply_ratio()
	if rotate_tips:
		_tip_time += delta
		if _tip_time >= TIP_SECONDS:
			_tip_time = 0.0
			tip_index = (tip_index + 1) % TIPS.size()
			tip_label.text = TIPS[tip_index]
		# Short fade around each change.
		tip_label.modulate.a = clampf(minf(_tip_time, TIP_SECONDS - _tip_time) / 0.25, 0.0, 1.0)

func _apply_ratio() -> void:
	bar_fill.anchor_right = bar_ratio
	bar_fill.offset_right = 0.0
	percent_label.text = "%d%%" % roundi(bar_ratio * 100.0)
	map_view.queue_redraw()
	bar.queue_redraw()

# ---------------------------------------------------------------------------- layout

func _fit() -> void:
	if not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	var k := vp.y / REF_SIZE.y
	_canvas.scale = Vector2(k, k)
	_canvas.position = Vector2.ZERO
	_canvas.size = Vector2(vp.x / k, REF_SIZE.y)
	queue_redraw()

func _build() -> void:
	if _built:
		return
	_built = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas = Control.new()
	_canvas.name = "Canvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.size = REF_SIZE
	add_child(_canvas)

	# Map: the right-hand side of the screen.
	map_view = Control.new()
	map_view.name = "Map"
	map_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_view.anchor_right = 1.0
	map_view.offset_left = 960.0
	map_view.offset_right = -110.0
	map_view.offset_top = 110.0
	map_view.offset_bottom = 860.0
	map_view.draw.connect(_draw_map)
	_canvas.add_child(map_view)

	# Left column: what is being loaded.
	var tag := ColorRect.new()
	tag.color = COL_HILITE
	tag.position = Vector2(SIDE, 168)
	tag.size = Vector2(46, 6)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(tag)
	_label("LOADING CIRCUIT", &"DimLabel", Vector2(SIDE + 60, 153), 26)
	name_label = _label("", &"TitleLabel", Vector2(SIDE - 4, 186), TITLE_SIZE)
	grand_prix_label = _label("", &"HeaderLabel", Vector2(SIDE, 322), 42)
	grand_prix_label.add_theme_color_override(&"font_color", COL_ACCENT.lightened(0.3))
	place_label = _label("", &"DimLabel", Vector2(SIDE, 376), 30)

	length_label = _stat("LENGTH", Vector2(SIDE, 476))
	turns_label = _stat("TURNS", Vector2(SIDE + 290, 476))
	best_label = _stat("BEST LAP", Vector2(SIDE + 450, 476))

	var tip_panel: Control = SlantedPanel.new()
	tip_panel.set(&"color", Color(0.5, 0.62, 1.0, 0.07))
	tip_panel.set(&"accent", COL_ACCENT)
	tip_panel.set(&"slant", 22.0)
	tip_panel.position = Vector2(SIDE - 22, 676)
	tip_panel.size = Vector2(700, 126)
	tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(tip_panel)
	var tip_tag := _label("TIP", &"HeaderLabel", Vector2(44, 12), 24, tip_panel)
	tip_tag.add_theme_color_override(&"font_color", COL_HILITE)
	tip_label = _label("", &"Label", Vector2(44, 42), 30, tip_panel)
	tip_label.size = Vector2(620, 76)
	tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip_label.clip_text = true

	# Bottom: progress.
	phase_label = _label("LOADING", &"DimLabel", Vector2(SIDE, 916), 26)
	percent_label = _label("0%", &"HeaderLabel", Vector2.ZERO, 34)
	percent_label.anchor_left = 1.0
	percent_label.anchor_right = 1.0
	percent_label.offset_left = -SIDE - 200.0
	percent_label.offset_right = -SIDE
	percent_label.offset_top = 906.0
	percent_label.offset_bottom = 950.0
	percent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar = Control.new()
	bar.name = "Bar"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.anchor_right = 1.0
	bar.offset_left = SIDE
	bar.offset_right = -SIDE
	bar.offset_top = 960.0
	bar.offset_bottom = 972.0
	bar.draw.connect(_draw_bar)
	_canvas.add_child(bar)
	bar_fill = Control.new()   # layout only: its width is the filled part of the bar
	bar_fill.name = "Fill"
	bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_fill.anchor_right = 0.0
	bar_fill.anchor_bottom = 1.0
	bar.add_child(bar_fill)

func _label(text: String, variation: StringName, pos: Vector2, font_size: int, parent: Control = null) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.add_theme_font_size_override(&"font_size", font_size)
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(parent if parent != null else _canvas).add_child(l)
	return l

## A caption with a large value under it; returns the value label.
func _stat(caption: String, pos: Vector2) -> Label:
	_label(caption, &"DimLabel", pos, 24)
	return _label("-", &"HeaderLabel", pos + Vector2(0, 28), 60)

## Shrinks the title so long circuit names stay left of the map.
func _fit_title() -> void:
	var size_px := TITLE_SIZE
	var w := FONT_BOLD.get_string_size(name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	if w > TITLE_MAX_WIDTH:
		size_px = maxi(48, floori(size_px * TITLE_MAX_WIDTH / w))
	name_label.add_theme_font_size_override(&"font_size", size_px)
	# Keep the baseline roughly where the full-size title has it.
	name_label.position.y = 186.0 + (TITLE_SIZE - size_px) * 0.95

# ---------------------------------------------------------------------------- drawing

func _draw() -> void:
	var s := size
	draw_polygon(
		PackedVector2Array([Vector2.ZERO, Vector2(s.x, 0), s, Vector2(0, s.y)]),
		PackedColorArray([COL_BG_TOP, COL_BG_BOTTOM.lerp(COL_BG_TOP, 0.35), COL_BG_BOTTOM, COL_BG_BOTTOM]))
	# Slanted plate and stripe behind the map.
	var k := s.y / REF_SIZE.y
	var x0 := 760.0 * k
	draw_colored_polygon(PackedVector2Array([
		Vector2(x0 + 190.0 * k, 0), Vector2(s.x, 0), Vector2(s.x, s.y), Vector2(x0, s.y)]),
		Color(1, 1, 1, 0.025))
	draw_colored_polygon(PackedVector2Array([
		Vector2(x0 + 160.0 * k, 0), Vector2(x0 + 190.0 * k, 0), Vector2(x0, s.y), Vector2(x0 - 30.0 * k, s.y)]),
		Color(COL_ACCENT, 0.18))

func _draw_map() -> void:
	var n := map_points.size()
	if n < 3:
		return
	var area := map_view.size
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in map_points:
		lo = lo.min(p)
		hi = hi.max(p)
	var ext := (hi - lo).max(Vector2(0.01, 0.01))
	var margin := 30.0
	var k := minf((area.x - margin * 2.0) / ext.x, (area.y - margin * 2.0) / ext.y)
	var origin := area * 0.5 - (lo + hi) * 0.5 * k
	var pts := PackedVector2Array()
	pts.resize(n + 1)
	for i in n:
		pts[i] = origin + map_points[i] * k
	pts[n] = pts[0]
	# Whole lap, dim.
	map_view.draw_polyline(pts, Color(0, 0, 0, 0.45), 22.0, true)
	map_view.draw_polyline(pts, Color(0.42, 0.48, 0.6, 0.55), 9.0, true)
	# Lit part: from the start line, along the lap, up to the loading progress.
	var u := clampf(bar_ratio, 0.0, 1.0) * n
	var whole := mini(int(u), n)
	if u > 0.01:
		var lit := pts.slice(0, whole + 1)
		var head := pts[whole]
		if whole < n:
			head = pts[whole].lerp(pts[whole + 1], u - whole)
			lit.append(head)
		if lit.size() >= 2:
			map_view.draw_polyline(lit, Color(COL_ACCENT, 0.28), 26.0, true)
			map_view.draw_polyline(lit, COL_ACCENT.lightened(0.2), 11.0, true)
			map_view.draw_polyline(lit, Color.WHITE, 4.0, true)
		map_view.draw_circle(head, 16.0, Color(COL_HILITE, 0.35), true, -1.0, true)
		map_view.draw_circle(head, 9.0, COL_HILITE, true, -1.0, true)
		map_view.draw_circle(head, 4.0, Color.WHITE, true, -1.0, true)
	# Start / finish line across the track at point 0.
	var dir := (pts[1] - pts[0]).normalized()
	var across := Vector2(-dir.y, dir.x)
	map_view.draw_line(pts[0] - across * 20.0, pts[0] + across * 20.0, Color.WHITE, 5.0, true)

func _draw_bar() -> void:
	var s := bar.size
	var slant := 10.0
	bar.draw_colored_polygon(PackedVector2Array([
		Vector2(slant, 0), Vector2(s.x, 0), Vector2(s.x - slant, s.y), Vector2(0, s.y)]),
		Color(1, 1, 1, 0.12))
	var w := s.x * bar_ratio
	if w < slant + 2.0:
		return
	bar.draw_colored_polygon(PackedVector2Array([
		Vector2(slant, 0), Vector2(w, 0), Vector2(w - slant, s.y), Vector2(0, s.y)]), COL_ACCENT)
	var hw := minf(36.0, w - slant)
	bar.draw_colored_polygon(PackedVector2Array([
		Vector2(w - hw, 0), Vector2(w, 0), Vector2(w - slant, s.y), Vector2(w - hw - slant, s.y)]), COL_HILITE)
