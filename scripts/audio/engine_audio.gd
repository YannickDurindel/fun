extends Node3D
## STUB engine audio. Reads the Car at `car_path`.

@export var car_path: NodePath

var _car: Car

func _ready() -> void:
	_car = get_node_or_null(car_path) as Car
