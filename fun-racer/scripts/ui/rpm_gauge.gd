@tool
extends Control
## Round speedometer backing with a segmented RPM arc (LED style) and a drift glow.
## Geometry is built once; per-frame work is only colour picks and polygon draws.
## The defaults are the arcade car's gauge (0..11000 rpm). set_rev_range() rescales the
## ticks and the red zone for another engine, and `shift_leds` adds a row of shift lights
## above the gauge (the simulation car uses both).

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
## Shift lights: a row of LEDs above the gauge, lit left to right, green then red then blue.
const LED_COUNT: int = 12
const LED_SIZE := Vector2(0.094, 0.056)   # fractions of the gauge radius
const LED_GAP: float = 0.03
const LED_Y: float = -0.19                # top of the row, above the gauge's top edge
const LED_SLANT: float = 0.022
const COL_LED_OFF := Color(1, 1, 1, 0.11)
const COL_LED: Array[Color] = [Color(0.25, 0.95, 0.38), Color(1.0, 0.2, 0.15), Color(0.3, 0.5, 1.0)]

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

## Fraction of the shift lights lit (0..1); below 0 the row is hidden (arcade).
var shift_leds: float = -1.0:
	set(v):
		v = clampf(v, -1.0, 1.0)
		# Only the number of lit LEDs is drawn, so only that triggers a redraw.
		if _leds_lit(v) != _leds_lit(shift_leds):
			shift_leds = v
			queue_redraw()
		else:
			shift_leds = v

## Arc fractions where the colour warms, turns red, and the arc blinks (see set_rev_range).
var warm_from: float = WARM_FROM
var red_from: float = RED_FROM
var flash_from: float = SHIFT_FLASH_FROM
## Tick marks along the arc, one per 1000 rpm; `_tick_span` is the arc fraction of the last one.
var _tick_count: int = 12
var _tick_span: float = 1.0

var _segments: Array[PackedVector2Array] = []
var _seg_colors: PackedColorArray = PackedColorArray()
var _redline: PackedVector2Array = PackedVector2Array()
var _ticks: Array[PackedVector2Array] = []
var _built_for: Vector2 = Vector2.ZERO
var _led_poly: PackedVector2Array = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])

func _ready() -> void:
	resized.connect(_build)
	_build()

## Rescales the gauge for an engine revving to `max_rpm` that should be shifted at
## `shift_rpm`: a tick every 1000 rpm, red from a little before the shift point, blinking at it.
func set_rev_range(max_rpm: float, shift_rpm: float) -> void:
	max_rpm = maxf(max_rpm, 1000.0)
	var flash := clampf(shift_rpm / max_rpm, 0.5, 0.99)
	var red := flash - 0.05
	var ticks := int(max_rpm / 1000.0 + 0.001) + 1
	var span := float(ticks - 1) * 1000.0 / max_rpm
	if is_equal_approx(flash, flash_from) and is_equal_approx(red, red_from) \
			and ticks == _tick_count and is_equal_approx(span, _tick_span):
		return
	flash_from = flash
	red_from = red
	warm_from = red - 0.18
	_tick_count = ticks
	_tick_span = span
	_built_for = Vector2.ZERO
	_build()

static func _leds_lit(fraction: float) -> int:
	return -1 if fraction < 0.0 else int(fraction * LED_COUNT + 0.001)

## Number of shift lights lit right now (-1 when the row is hidden).
func leds_lit() -> int:
	return _leds_lit(shift_leds)

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
		var a := _angle_at(lerpf(red_from, 1.0, k / 16.0))
		_redline.append(c + Vector2(cos(a), sin(a)) * (r_out + r * 0.035))
	# Minor tick marks every 1000 rpm on the inner side.
	_ticks.clear()
	for k in _tick_count:
		var a := _angle_at(_tick_span * k / maxf(_tick_count - 1, 1.0))
		var dir := Vector2(cos(a), sin(a))
		_ticks.append(PackedVector2Array([c + dir * (r_in - r * 0.03), c + dir * (r_in - r * 0.075)]))
	queue_redraw()

func _color_for(t: float) -> Color:
	if t >= red_from:
		return COL_RED
	if t >= warm_from:
		return COL_LOW.lerp(COL_WARM, (t - warm_from) / (red_from - warm_from))
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
	var blink := flash_on and value >= flash_from
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
	if shift_leds >= 0.0:
		_draw_shift_leds(c, r)

## Row of slanted LEDs on a dark plate above the gauge. All lit and blinking = shift now.
func _draw_shift_leds(c: Vector2, r: float) -> void:
	var w := LED_SIZE.x * r
	var h := LED_SIZE.y * r
	var gap := LED_GAP * r
	var sl := LED_SLANT * r
	var total := LED_COUNT * w + (LED_COUNT - 1) * gap
	var x0 := c.x - total * 0.5
	var y0 := c.y - r + LED_Y * r
	var pad := 0.045 * r
	_led_poly[0] = Vector2(x0 - pad + sl * 2.0, y0 - pad)
	_led_poly[1] = Vector2(x0 + total + pad + sl * 2.0, y0 - pad)
	_led_poly[2] = Vector2(x0 + total + pad - sl, y0 + h + pad)
	_led_poly[3] = Vector2(x0 - pad - sl, y0 + h + pad)
	draw_colored_polygon(_led_poly, COL_BACK)
	var lit := leds_lit()
	var full := lit >= LED_COUNT
	for i in LED_COUNT:
		var x := x0 + i * (w + gap)
		_led_poly[0] = Vector2(x + sl, y0)
		_led_poly[1] = Vector2(x + w + sl, y0)
		_led_poly[2] = Vector2(x + w, y0 + h)
		_led_poly[3] = Vector2(x, y0 + h)
		var col := COL_LED_OFF
		if full:
			# Shift now: the whole row blinks blue with the arc.
			col = COL_LED[2] if flash_on else COL_LED_OFF
		elif i < lit:
			col = COL_LED[i * COL_LED.size() / LED_COUNT]
		draw_colored_polygon(_led_poly, col)

## Small "tyre marks" icon: two slanted, slightly curved strokes.
func _draw_tyre_marks(at: Vector2, h: float, col: Color) -> void:
	var w := maxf(1.5, h * 0.22)
	for k in 2:
		var x := at.x + k * h * 0.42
		draw_line(Vector2(x + h * 0.25, at.y - h * 0.5), Vector2(x, at.y), col, w, true)
		draw_line(Vector2(x, at.y), Vector2(x + h * 0.12, at.y + h * 0.5), col, w, true)
