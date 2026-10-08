extends Camera3D
## STUB chase camera. Follows the node at `target_path` (a Car).

@export var target_path: NodePath

var _target: Node3D

func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D

func _process(_delta: float) -> void:
	if _target == null:
		return
	var t := _target.global_transform
	global_position = t.origin + t.basis.z * 7.0 + Vector3.UP * 2.5
	look_at(t.origin + Vector3.UP * 0.8, Vector3.UP)
