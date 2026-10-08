@tool
extends Control
## Semi-transparent parallelogram backing (Trackmania-style slanted plate).

@export var color: Color = Color(0.03, 0.035, 0.05, 0.62):
	set(v):
		color = v
		queue_redraw()
@export var accent: Color = Color(1, 1, 1, 0.0):
	set(v):
		accent = v
		queue_redraw()
## Horizontal offset of the top edge relative to the bottom edge, in pixels.
@export var slant: float = 18.0:
	set(v):
		slant = v
		queue_redraw()

var _poly: PackedVector2Array = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _accent_line: PackedVector2Array = PackedVector2Array([Vector2.ZERO, Vector2.ZERO])

func _ready() -> void:
	resized.connect(queue_redraw)

func _draw() -> void:
	var s := size
	_poly[0] = Vector2(slant, 0)
	_poly[1] = Vector2(s.x, 0)
	_poly[2] = Vector2(s.x - slant, s.y)
	_poly[3] = Vector2(0, s.y)
	draw_colored_polygon(_poly, color)
	if accent.a > 0.0:
		_accent_line[0] = Vector2(slant * 0.15, s.y - 1.5)
		_accent_line[1] = Vector2(s.x - slant * 1.05, s.y - 1.5)
		draw_line(_accent_line[0], _accent_line[1], accent, 3.0)
