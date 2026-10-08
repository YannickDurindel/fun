extends Node3D
## Visual for one wheel corner; reads Car.wheels[wheel_index] every frame.
##
## Node layout (see scenes/car/wheel_visual.tscn); meshes are instanced in _ready:
##   WheelVisual (this)        position = wheel centre + compression (car frame, unrotated)
##     Suspension              scale.x = side; wishbones + push/pull rod, never steer or spin
##       Pivot                 sits on the chassis pickup line; sheared with compression so the
##         Arms                inboard ends stay on the chassis and the outer ends follow the hub
##     Steer                   on the kingpin (outer ball joints); rotation.y = steer_angle
##       Upright               scale.x = side; upright, caliper, brake duct
##       BlurDisc              speed-blurred rim overlay (fades in at speed)
##       Spin                  at the wheel centre; rotation.x = -spin_angle
##         Wheel               scale.x = side; tyre, rim, nut, brake disc
## Meshes come from cad/wheels/f1_wheels.py, modelled for a right-hand wheel (outer face +X);
## left wheels (index 0, 2) mirror them. Geometry numbers come from the same CAD script.

@export var wheel_index: int = 0

const GEOMETRY_PATH := "res://assets/car/wheel_geometry.json"
const SCENES := {
	"front": [
		preload("res://assets/car/wheel_front.glb"),
		preload("res://assets/car/wheel_upright_front.glb"),
		preload("res://assets/car/suspension_front.glb"),
	],
	"rear": [
		preload("res://assets/car/wheel_rear.glb"),
		preload("res://assets/car/wheel_upright_rear.glb"),
		preload("res://assets/car/suspension_rear.glb"),
	],
}
## Fallback if the geometry file is missing (matches the CAD defaults).
const DEFAULT_GEOMETRY := {
	"front": {"rim_radius": 0.2286, "rim_face_x": 0.134, "joint_x": -0.127, "chassis_x": -0.40},
	"rear": {"rim_radius": 0.2286, "rim_face_x": 0.174, "joint_x": -0.167, "chassis_x": -0.38},
}

## Rim surface speed (km/h) where the blurred disc starts/finishes fading in.
const BLUR_START_KMH: float = 130.0
const BLUR_FULL_KMH: float = 230.0
const BLUR_MAX_ALPHA: float = 0.92
## Wheel spin rates above this (rad/s, ~600 km/h) are treated as a state reset, not motion.
const MAX_PLAUSIBLE_OMEGA: float = 500.0

static var _geometry_cache: Dictionary = {}

@onready var _car: Car = _find_car()
@onready var _steer: Node3D = get_node_or_null("Steer")
@onready var _spin: Node3D = get_node_or_null("Steer/Spin")
@onready var _pivot: Node3D = get_node_or_null("Suspension/Pivot")
@onready var _blur: MeshInstance3D = get_node_or_null("Steer/BlurDisc")

var _is_front: bool = true
var _side: float = 1.0
## Horizontal distance from the chassis pickup line to the outer ball joints (model frame).
var _arm_length: float = 0.273
var _blur_mat: ShaderMaterial
var _last_spin: float = 0.0
var _has_last_spin: bool = false
var _omega: float = 0.0
var _rim_speed_kmh: float = 0.0

static func geometry(front: bool) -> Dictionary:
	if _geometry_cache.is_empty():
		var json := load(GEOMETRY_PATH) as JSON if ResourceLoader.exists(GEOMETRY_PATH) else null
		_geometry_cache = json.data if json and json.data is Dictionary else DEFAULT_GEOMETRY
	return _geometry_cache.get("front" if front else "rear", DEFAULT_GEOMETRY["front" if front else "rear"])

func _ready() -> void:
	_is_front = wheel_index < 2
	_side = -1.0 if wheel_index % 2 == 0 else 1.0
	var g := geometry(_is_front)
	var joint_x: float = g["joint_x"]
	var chassis_x: float = g["chassis_x"]
	_arm_length = maxf(joint_x - chassis_x, 0.05)
	var scenes: Array = SCENES["front" if _is_front else "rear"]
	_attach(scenes[0], "Steer/Spin/Wheel")
	_attach(scenes[1], "Steer/Upright")
	_attach(scenes[2], "Suspension/Pivot/Arms")
	for mirrored: String in ["Steer/Spin/Wheel", "Steer/Upright", "Suspension"]:
		var n := get_node_or_null(mirrored) as Node3D
		if n:
			n.scale.x = _side
	# Steer about the kingpin (outer ball joints) so the upright stays on the wishbones.
	if _steer:
		_steer.position = Vector3(joint_x * _side, 0.0, 0.0)
		for child: String in ["Upright", "Spin"]:
			var n := _steer.get_node_or_null(child) as Node3D
			if n:
				n.position = Vector3(-joint_x * _side, 0.0, 0.0)
	if _pivot:
		_pivot.position = Vector3(chassis_x, 0.0, 0.0)
		var arms := _pivot.get_node_or_null("Arms") as Node3D
		if arms:
			arms.position = Vector3(-chassis_x, 0.0, 0.0)
	if _blur:
		_blur_mat = _blur.material_override as ShaderMaterial
		if _blur_mat:
			_blur_mat = _blur_mat.duplicate() as ShaderMaterial
			_blur.material_override = _blur_mat
		var quad := _blur.mesh as QuadMesh
		if quad:
			var d: float = 2.0 * float(g["rim_radius"]) - 0.007
			quad.size = Vector2(d, d)
		var face_x: float = g["rim_face_x"]
		_blur.position = Vector3((face_x - joint_x) * _side, 0.0, 0.0)
		# QuadMesh faces +Z; turn it to face outward (+X right, -X left).
		_blur.rotation = Vector3(0.0, _side * PI * 0.5, 0.0)
		_blur.visible = false

func _attach(scene: PackedScene, holder_path: String) -> void:
	var holder := get_node_or_null(holder_path)
	if holder and scene:
		var inst := scene.instantiate()
		inst.name = scene.resource_path.get_file().get_basename()  # e.g. "wheel_front"
		holder.add_child(inst)

func _find_car() -> Car:
	var n: Node = get_parent()
	while n and not (n is Car):
		n = n.get_parent()
	return n as Car

func _state() -> WheelState:
	if _car == null or wheel_index < 0 or _car.wheels.size() <= wheel_index:
		return null
	return _car.wheels[wheel_index]

func _physics_process(delta: float) -> void:
	# Sample the spin rate at the rate spin_angle is integrated, so it is not aliased by
	# render frames that fall between physics ticks.
	var w := _state()
	if w == null or delta <= 0.0:
		return
	var omega := (w.spin_angle - _last_spin) / delta
	# Skip the first tick and discontinuities (e.g. spin reset on respawn).
	if _has_last_spin and absf(omega) < MAX_PLAUSIBLE_OMEGA:
		_omega = omega
	_last_spin = w.spin_angle
	_has_last_spin = true

func _process(delta: float) -> void:
	var w := _state()
	if w == null:
		return
	position = Car.WHEEL_OFFSETS[wheel_index] + Vector3(0, w.compression, 0)
	if _steer:
		_steer.rotation.y = w.steer_angle
	if _spin:
		# Same rotation as -spin_angle, but keeps the stored Euler angle small.
		_spin.rotation.x = -fmod(w.spin_angle, TAU)
	if _pivot:
		# The wheel frame moved up by `compression`; shear the arms vertically about the
		# pickup line so every inboard point stays on the chassis and every outer joint
		# rises exactly with the hub.
		_pivot.position.y = -w.compression
		_pivot.basis = Basis(Vector3(1.0, w.compression / _arm_length, 0.0), Vector3.UP, Vector3.BACK)
	_update_blur(delta)

func _update_blur(delta: float) -> void:
	if _blur == null or _blur_mat == null:
		return
	var radius := Car.FRONT_WHEEL_RADIUS if _is_front else Car.REAR_WHEEL_RADIUS
	var v := absf(_omega) * radius * 3.6
	_rim_speed_kmh = lerpf(_rim_speed_kmh, v, 1.0 - exp(-10.0 * maxf(delta, 0.0)))
	var a := smoothstep(BLUR_START_KMH, BLUR_FULL_KMH, _rim_speed_kmh) * BLUR_MAX_ALPHA
	_blur.visible = a > 0.01
	if _blur.visible:
		_blur_mat.set_shader_parameter("blur", a)
