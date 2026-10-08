class_name Car
extends RigidBody3D
## Player car. CONTRACT (other systems depend on these; do not rename):
##   speed_kmh, rpm, gear, throttle, brake_input, steer, is_drifting, is_grounded,
##   wheels: Array[WheelState] (order FL, FR, RL, RR), signal respawned,
##   WHEEL_OFFSETS / WHEEL_RADIUS (local, forward = -Z, up = +Y), respawn().
## This file is a STUB with placeholder arcade motion; unit "Vehicle physics core" replaces it.

signal respawned

const WHEEL_OFFSETS: Array[Vector3] = [
	Vector3(-0.80, 0.0, -1.80), Vector3(0.80, 0.0, -1.80),
	Vector3(-0.78, 0.0, 1.80), Vector3(0.78, 0.0, 1.80),
]
const FRONT_WHEEL_RADIUS: float = 0.33
const REAR_WHEEL_RADIUS: float = 0.36
const MAX_RPM: float = 11000.0

var speed_kmh: float = 0.0
var rpm: float = 0.0
var gear: int = 1
var throttle: float = 0.0
var brake_input: float = 0.0
var steer: float = 0.0
var is_drifting: bool = false
var is_grounded: bool = true
var wheels: Array[WheelState] = []

var spawn_transform: Transform3D

func _ready() -> void:
	spawn_transform = global_transform
	for i in 4:
		wheels.append(WheelState.new())
	mass = 800.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.1, 0)
	can_sleep = false

func wheel_radius(i: int) -> float:
	return FRONT_WHEEL_RADIUS if i < 2 else REAR_WHEEL_RADIUS

func _physics_process(delta: float) -> void:
	throttle = Bootstrap.get_throttle()
	brake_input = Bootstrap.get_brake()
	steer = Bootstrap.get_steer()
	if Input.is_action_just_pressed("respawn"):
		respawn()
		return
	# --- placeholder kinematics (replaced by real vehicle physics) ---
	var fwd := -global_transform.basis.z
	var v := linear_velocity
	var fwd_speed := v.dot(fwd)
	var accel := throttle * 20.0 - brake_input * 30.0 * signf(fwd_speed)
	v += fwd * accel * delta
	var lateral := v - fwd * v.dot(fwd) - Vector3.UP * v.y
	v -= lateral * minf(1.0, 10.0 * delta)
	linear_velocity = v
	angular_velocity.y = -steer * clampf(fwd_speed / 10.0, -1.0, 1.0) * 1.5
	speed_kmh = absf(fwd_speed) * 3.6
	gear = clampi(int(speed_kmh / 60.0) + 1, 1, 7)
	rpm = lerpf(4000.0, MAX_RPM, fmod(speed_kmh, 60.0) / 60.0)
	for i in 4:
		var w := wheels[i]
		var local := WHEEL_OFFSETS[i] + Vector3(0, -0.15, 0)
		w.contact = true
		w.contact_point = global_transform * (local - Vector3(0, wheel_radius(i), 0))
		w.contact_normal = Vector3.UP
		w.spin_angle += fwd_speed / wheel_radius(i) * delta
		w.steer_angle = -steer * 0.35 if i < 2 else 0.0
		w.slip = 0.0
		w.compression = 0.0

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = spawn_transform
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, spawn_transform)
	respawned.emit()
