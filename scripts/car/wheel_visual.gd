extends Node3D
## Visual for one wheel; reads Car.wheels[wheel_index] each frame.
## Children should be modelled with the axle along local X, rolling about X.

@export var wheel_index: int = 0

@onready var _car: Car = _find_car()
@onready var _spin: Node3D = get_node_or_null("Steer/Spin")
@onready var _steer: Node3D = get_node_or_null("Steer")

func _find_car() -> Car:
	var n: Node = get_parent()
	while n and not (n is Car):
		n = n.get_parent()
	return n as Car

func _process(_delta: float) -> void:
	if _car == null or _car.wheels.size() <= wheel_index:
		return
	var w: WheelState = _car.wheels[wheel_index]
	position = Car.WHEEL_OFFSETS[wheel_index] + Vector3(0, w.compression, 0)
	if _steer:
		_steer.rotation.y = w.steer_angle
	if _spin:
		_spin.rotation.x = -w.spin_angle
