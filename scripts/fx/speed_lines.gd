extends CanvasLayer
## Subtle edge speed streaks above ~300 km/h. Sits below the HUD layer and ignores input.

const START_KMH: float = 300.0
const FULL_KMH: float = 480.0

var _rect: ColorRect
var _mat: ShaderMaterial
var _level: float = 0.0

func _ready() -> void:
	layer = 0
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/fx_speed_lines.gdshader")
	_rect = ColorRect.new()
	_rect.name = "Streaks"
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.material = _mat
	_rect.visible = false
	add_child(_rect)

func update_speed(speed_kmh: float, delta: float) -> void:
	var target := smoothstep(START_KMH, FULL_KMH, speed_kmh)
	_level = lerpf(_level, target, 1.0 - exp(-4.0 * delta))
	if _level < 0.01 and target == 0.0:
		_level = 0.0
	_rect.visible = _level > 0.0
	_mat.set_shader_parameter("intensity", _level)

func level() -> float:
	return _level
