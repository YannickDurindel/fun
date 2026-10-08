extends Control
## STUB HUD. Reads the Car at `car_path`.

@export var car_path: NodePath

var _car: Car

@onready var _speed: Label = $Speed

func _ready() -> void:
	_car = get_node_or_null(car_path) as Car

func _process(_delta: float) -> void:
	if _car:
		_speed.text = "%d km/h" % int(_car.speed_kmh)
