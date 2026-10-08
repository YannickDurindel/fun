extends Node3D
## Driving FX: skid marks, tyre smoke and edge speed streaks, driven by the Car contract.
## Dev flag: `--fx-force-slip` (user arg) or `force_slip` makes the rear wheels mark/smoke as if
## drifting, independent of the physics, for screenshots and tuning.

const SkidMarks := preload("res://scripts/fx/skid_marks.gd")
const TyreSmoke := preload("res://scripts/fx/tyre_smoke.gd")
const SpeedLines := preload("res://scripts/fx/speed_lines.gd")

const FRONT_TYRE_WIDTH: float = 0.30
const REAR_TYRE_WIDTH: float = 0.38

@export var car_path: NodePath
@export var force_slip: bool = false
@export var speed_lines_enabled: bool = true
## Wheel slip above which a mark is laid (0..1).
@export_range(0.0, 1.0) var skid_slip_threshold: float = 0.3
## Effective slip of the rear wheels while `car.is_drifting`.
@export_range(0.0, 1.0) var drift_slip: float = 0.75
## Speed (m/s) at which smoke reaches full rate for a fully sliding wheel.
@export var smoke_full_speed: float = 25.0

@onready var skid_marks: SkidMarks = $SkidMarks
@onready var tyre_smoke: TyreSmoke = $TyreSmoke
@onready var speed_lines: SpeedLines = $SpeedLines

var car: Car

func _ready() -> void:
	# Sample after the car (and any test helpers) have updated their wheel state this tick.
	process_physics_priority = 100
	if "--fx-force-slip" in OS.get_cmdline_user_args():
		force_slip = true
	_resolve_car()

func _resolve_car() -> void:
	if car != null and is_instance_valid(car):
		return
	car = null
	if car_path.is_empty():
		return
	var n := get_node_or_null(car_path)
	if n is Car:
		car = n
		if not car.respawned.is_connected(_on_car_respawned):
			car.respawned.connect(_on_car_respawned)

## Removes all skid marks and smoke (call on map restart). Marks persist across respawns.
func clear() -> void:
	skid_marks.clear()
	tyre_smoke.clear()

func _on_car_respawned() -> void:
	# Don't connect a ribbon across the teleport; keep the marks themselves.
	skid_marks.end_all_strips()

## Effective slip of wheel i (0 when it should not mark), including drift/forced overrides.
func wheel_effect_slip(i: int) -> float:
	if car == null or i >= car.wheels.size():
		return 0.0
	var w := car.wheels[i]
	var rear := i >= 2
	var slip := w.slip
	var contact := w.contact
	if rear and force_slip:
		slip = 1.0
		contact = true
	if rear and car.is_drifting:
		slip = maxf(slip, drift_slip)
	return clampf(slip, 0.0, 1.0) if contact else 0.0

func _physics_process(_delta: float) -> void:
	_resolve_car()
	if car == null:
		return
	for i in mini(4, car.wheels.size()):
		var slip := wheel_effect_slip(i)
		if slip > skid_slip_threshold:
			var w := car.wheels[i]
			var k := inverse_lerp(skid_slip_threshold, 1.0, slip)
			var alpha := lerpf(0.35, 1.0, clampf(k, 0.0, 1.0))
			var width := REAR_TYRE_WIDTH if i >= 2 else FRONT_TYRE_WIDTH
			var surf := _surface_point(w.contact_point, w.contact_normal)
			skid_marks.add_point(i, surf[0], surf[1], width, alpha)
		else:
			skid_marks.end_strip(i)

## Snaps a reported contact onto the actual collision surface (short ray along the normal),
## so marks lie flat even if the physics reports a point slightly above/below the ground.
func _surface_point(p: Vector3, n: Vector3) -> Array:
	var up := n.normalized() if n.length_squared() > 0.01 else Vector3.UP
	var space := get_world_3d().direct_space_state
	if space == null:
		return [p, up]
	var q := PhysicsRayQueryParameters3D.create(p + up * 0.6, p - up * 0.6)
	q.exclude = [car.get_rid()]
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return [p, up]
	return [hit["position"], hit["normal"]]

func _process(delta: float) -> void:
	_resolve_car()
	if car == null:
		tyre_smoke.step(delta, PackedVector3Array(), PackedFloat32Array(), Vector3.ZERO)
		speed_lines.update_speed(0.0, delta)
		return
	var positions := PackedVector3Array()
	var intensities := PackedFloat32Array()
	var speed := car.linear_velocity.length()
	for i in [2, 3]:
		if i >= car.wheels.size():
			break
		positions.append(car.wheels[i].contact_point)
		var slip := wheel_effect_slip(i)
		intensities.append(slip * clampf(speed / smoke_full_speed, 0.0, 1.0) if slip > skid_slip_threshold else 0.0)
	tyre_smoke.step(delta, positions, intensities, car.linear_velocity)
	speed_lines.update_speed(car.speed_kmh if speed_lines_enabled else 0.0, delta)
