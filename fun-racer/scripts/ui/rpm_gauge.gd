@tool
extends Control
## Round speedometer backing with a segmented RPM arc (LED style) and a drift glow.
## Geometry is built once; per-frame work is only colour picks and polygon draws.

const SEGMENTS: int = 40
const ARC_START_DEG: float = 135.0  # bottom-left
const ARC_SWEEP_DEG: float = 270.0  # clockwise to bottom-right, gap at the bottom
const RING_INNER: float = 0.80  # fractions of the gauge radius
const RING_OUTER: float = 0.92
const SEG_GAP: float = 0.22  # fraction of each segment's angle left empty
const WARM_FROM: float = 0.70
const RED_FROM: float = 0.88
const SHIFT_FLASH_FROM: float = 0.95

const COL_BACK := Color(0.03, 0.035, 0.05, 0.62)
const COL_BACK_EDGE := Color(1, 1, 1, 0.07)
const COL_OFF := Color(1, 1, 1, 0.09)
const COL_LOW := Color(0.96, 0.97, 1.0, 0.95)
const COL_WARM := Color(1.0, 0.70, 0.16, 1.0)
const COL_RED := Color(1.0, 0.18, 0.14, 1.0)
const COL_DRIFT := Color(0.25, 0.85, 1.0)

## 0..1 fill of the RPM arc (rpm / MAX_RPM).
@export_range(0.0, 1.0) var value: float = 0.0:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if absf(v - value) > 0.001 or (v != value and (v == 0.0 or v == 1.0)):
			value = v
			queue_redraw()
## 0..1 drift glow intensity (eased by the HUD).
@export_range(0.0, 1.0) var drift: float = 0.0:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if absf(v - drift) > 0.004 or (v != drift and (v == 0.0 or v == 1.0)):
			drift = v
			queue_redraw()
## Toggled by the HUD to blink the arc near the limiter.
var flash_on: bool = false:
	set(v):
		if v != flash_on:
			flash_on = v
			queue_redraw()

var _segments: Array[PackedVector2Array] = []
var _seg_colors: PackedColorArray = PackedColorArray()
var _redline: PackedVector2Array = PackedVector2Array()
var _ticks: Array[PackedVector2Array] = []
var _built_for: Vector2 = Vector2.ZERO

func _ready() -> void:
	resized.connect(_build)
	_build()

func _radius() -> float:
	return minf(size.x, size.y) * 0.5

func _center() -> Vector2:
	return size * 0.5

func _angle_at(t: float) -> float:
	return deg_to_rad(ARC_START_DEG + ARC_SWEEP_DEG * t)

func _build() -> void:
	if size == _built_for:
		return
	_built_for = size
	var c := _center()
	var r := _radius()
	var r_in := r * RING_INNER
	var r_out := r * RING_OUTER
	_segments.clear()
	_seg_colors.resize(SEGMENTS)
	var seg_t := 1.0 / SEGMENTS
	for i in SEGMENTS:
		var t0 := (i + SEG_GAP * 0.5) * seg_t
		var t1 := (i + 1 - SEG_GAP * 0.5) * seg_t
		var poly := PackedVector2Array()
		const STEPS := 3
		for k in STEPS + 1:
			var a := _angle_at(lerpf(t0, t1, float(k) / STEPS))
			poly.append(c + Vector2(cos(a), sin(a)) * r_out)
		for k in range(STEPS, -1, -1):
			var a := _angle_at(lerpf(t0, t1, float(k) / STEPS))
			# Slight slant on the inner edge gives the italic "speed" look.
			poly.append(c + Vector2(cos(a - 0.02), sin(a - 0.02)) * r_in)
		_segments.append(poly)
		var mid := (i + 0.5) * seg_t
		_seg_colors[i] = _color_for(mid)
	# Thin red-line strip just outside the ring.
	_redline = PackedVector2Array()
	for k in 17:
		var a := _angle_at(lerpf(RED_FROM, 1.0, k / 16.0))
		_redline.append(c + Vector2(cos(a), sin(a)) * (r_out + r * 0.035))
	# Minor tick marks every 1000 rpm on the inner side.
	_ticks.clear()
	for k in 12:
		var a := _angle_at(k / 11.0)
		var dir := Vector2(cos(a), sin(a))
		_ticks.append(PackedVector2Array([c + dir * (r_in - r * 0.03), c + dir * (r_in - r * 0.075)]))
	queue_redraw()

static func _color_for(t: float) -> Color:
	if t >= RED_FROM:
		return COL_RED
	if t >= WARM_FROM:
		return COL_LOW.lerp(COL_WARM, (t - WARM_FROM) / (RED_FROM - WARM_FROM))
	return COL_LOW

func _draw() -> void:
	if _segments.is_empty():
		return
	var c := _center()
	var r := _radius()
	# Backing disc + faint rim, rim glows while drifting.
	draw_circle(c, r, COL_BACK)
	var rim := COL_BACK_EDGE.lerp(COL_DRIFT, drift * 0.85)
	draw_arc(c, r - 1.5, 0.0, TAU, 96, rim, 2.0 + drift * 3.0, true)
	draw_polyline(_redline, Color(COL_RED, 0.85), r * 0.018, true)
	for tick in _ticks:
		draw_line(tick[0], tick[1], Color(1, 1, 1, 0.22), maxf(1.0, r * 0.01), true)
	var lit := value * SEGMENTS
	var blink := flash_on and value >= SHIFT_FLASH_FROM
	for i in SEGMENTS:
		var col: Color
		if float(i) + 1.0 <= lit:
			col = COL_RED if blink else _seg_colors[i]
		elif float(i) < lit:
			# Leading segment fades in so the arc moves smoothly between LEDs.
			col = COL_OFF.lerp(_seg_colors[i], lit - float(i))
		else:
			col = COL_OFF
		draw_colored_polygon(_segments[i], col)
	if drift > 0.01:
		_draw_tyre_marks(c + Vector2(-r * 0.30, -r * 0.43), r * 0.11, Color(COL_DRIFT, drift))

## Small "tyre marks" icon: two slanted, slightly curved strokes.
func _draw_tyre_marks(at: Vector2, h: float, col: Color) -> void:
	var w := maxf(1.5, h * 0.22)
	for k in 2:
		var x := at.x + k * h * 0.42
		draw_line(Vector2(x + h * 0.25, at.y - h * 0.5), Vector2(x, at.y), col, w, true)
		draw_line(Vector2(x, at.y), Vector2(x + h * 0.12, at.y + h * 0.5), col, w, true)
