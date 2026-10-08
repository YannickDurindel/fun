extends Node3D
## Keeps the visible world "infinite" around the active camera.
##
## - Moves the ground mesh in XZ, snapped to `snap_size` so the world-space
##   pattern never swims, and feeds the shader `pattern_offset`, which is
##   fposmod(mesh_origin, PATTERN_PERIOD). The shader only works with small
##   pattern-space coordinates, so it stays jitter-free at any distance.
## - Keeps the horizon hill ring centred on the camera (it never gets closer).
## - Fits fog and the horizon to the camera's far plane so the ground edge is
##   never visible, even if the camera uses a short `far`.
##
## Collision is a WorldBoundaryShape3D (infinite already) and never moves.
## Precision note: the world origin is never shifted. Shading is stable at any
## distance; vertex positions are transformed in float32 on the GPU, so beyond
## roughly 100 km geometry itself starts to wobble by a few mm (physics and
## every other system share that limit).

const PATTERN_PERIOD: float = 1024.0

@export var ground_mesh_path: NodePath = ^"../Ground/Mesh"
@export var horizon_path: NodePath = ^"../Horizon"
@export var environment_path: NodePath = ^"../Environment"
## Must divide PATTERN_PERIOD and be a multiple of the shader's tile size.
@export var snap_size: float = 32.0
## Half extent of the ground mesh (keep in sync with the PlaneMesh size).
@export var ground_half_extent: float = 3500.0
@export var horizon_radius: float = 3200.0
@export var fog_end: float = 2900.0

var _ground: MeshInstance3D
var _horizon: Node3D
var _env: Environment
var _mat: ShaderMaterial
var _last_snap: Vector2 = Vector2(INF, INF)
var _last_far: float = -1.0
var _fog_begin: float = 250.0 # designed fog start, from the Environment


func _ready() -> void:
	_ground = get_node_or_null(ground_mesh_path) as MeshInstance3D
	_horizon = get_node_or_null(horizon_path) as Node3D
	var we := get_node_or_null(environment_path) as WorldEnvironment
	if we != null:
		_env = we.environment
		if _env != null:
			_fog_begin = _env.fog_depth_begin
	if _ground != null:
		_mat = _ground.get_active_material(0) as ShaderMaterial
	_update(true)


func _process(_delta: float) -> void:
	_update(false)


## World position the visuals should be centred on.
func get_focus() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam.global_position
	var car := get_tree().get_first_node_in_group(&"car") as Node3D
	if car == null:
		# In main.tscn the Car is a sibling of World (this node's parent).
		car = get_parent().get_node_or_null(^"../Car") as Node3D
	if car != null:
		return car.global_position
	return Vector3.ZERO


func _update(force: bool) -> void:
	var focus := get_focus()
	var snapped_xz := Vector2(snappedf(focus.x, snap_size), snappedf(focus.z, snap_size))
	if _ground != null and (force or snapped_xz != _last_snap):
		_last_snap = snapped_xz
		_ground.global_position = Vector3(snapped_xz.x, 0.0, snapped_xz.y)
		if _mat != null:
			_mat.set_shader_parameter(&"pattern_offset", Vector2(
				fposmod(snapped_xz.x, PATTERN_PERIOD), fposmod(snapped_xz.y, PATTERN_PERIOD)))
	if _horizon != null:
		_horizon.global_position = Vector3(focus.x, 0.0, focus.z)
	_fit_to_camera(force)


## Pulls fog and horizon in if the camera's far plane is shorter than designed.
func _fit_to_camera(force: bool) -> void:
	var cam := get_viewport().get_camera_3d()
	var far := cam.far if cam != null else 4000.0
	if not force and is_equal_approx(far, _last_far):
		return
	_last_far = far
	var reach := minf(ground_half_extent, far * 0.97)
	if _env != null:
		_env.fog_depth_end = minf(fog_end, reach * 0.88)
		_env.fog_depth_begin = minf(_fog_begin, _env.fog_depth_end * 0.5)
	if _horizon != null:
		var r := minf(horizon_radius, reach * 0.92)
		_horizon.scale = Vector3(r, 1.0, r)
