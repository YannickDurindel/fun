@tool
extends Control
## Streamer-style input display: four arrows (accelerate, brake, left, right)
## whose brightness follows the analog input strength.

const COL_OFF := Color(0.03, 0.035, 0.05, 0.55)
const COL_EDGE := Color(1, 1, 1, 0.16)
const COL_ACCEL := Color(0.35, 1.0, 0.55)
const COL_BRAKE := Color(1.0, 0.30, 0.25)
const COL_STEER := Color(0.95, 0.97, 1.0)

var accelerate: float = 0.0:
	set(v):
		v = _q(v)
		if v != accelerate:
			accelerate = v
			queue_redraw()
var brake: float = 0.0:
	set(v):
		v = _q(v)
		if v != brake:
			brake = v
			queue_redraw()
var left: float = 0.0:
	set(v):
		v = _q(v)
		if v != left:
			left = v
			queue_redraw()
var right: float = 0.0:
	set(v):
		v = _q(v)
		if v != right:
			right = v
			queue_redraw()

var _arrows: Array[PackedVector2Array] = []  # up, down, left, right
var _edges: Array[PackedVector2Array] = []

static func _q(v: float) -> float:
	return roundf(clampf(v, 0.0, 1.0) * 32.0) / 32.0

func _ready() -> void:
	resized.connect(_build)
	_build()

func _build() -> void:
	# Keyboard layout: up on top, left/down/right on the bottom row.
	var cell := minf(size.x / 3.0, size.y / 2.0)
	var origin := Vector2((size.x - cell * 3.0) * 0.5, (size.y - cell * 2.0) * 0.5)
	var centers: Array[Vector2] = [
		origin + Vector2(cell * 1.5, cell * 0.5),
		origin + Vector2(cell * 1.5, cell * 1.5),
		origin + Vector2(cell * 0.5, cell * 1.5),
		origin + Vector2(cell * 2.5, cell * 1.5),
	]
	var dirs: Array[Vector2] = [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]
	_arrows.clear()
	_edges.clear()
	var h := cell * 0.34
	for i in 4:
		var d := dirs[i]
		var n := Vector2(-d.y, d.x)
		var tip := centers[i] + d * h
		var poly := PackedVector2Array([tip, centers[i] - d * h * 0.8 + n * h * 1.1, centers[i] - d * h * 0.8 - n * h * 1.1])
		_arrows.append(poly)
		var edge := poly.duplicate()
		edge.append(poly[0])
		_edges.append(edge)
	queue_redraw()

func _draw() -> void:
	if _arrows.size() != 4:
		return
	var vals: Array[float] = [accelerate, brake, left, right]
	var cols: Array[Color] = [COL_ACCEL, COL_BRAKE, COL_STEER, COL_STEER]
	for i in 4:
		draw_colored_polygon(_arrows[i], COL_OFF.lerp(cols[i], vals[i]))
		draw_polyline(_edges[i], COL_EDGE, 1.5, true)
