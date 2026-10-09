extends Node3D
## Driving FX: skid marks, tyre smoke and edge speed streaks, driven by the Car contract.
## Dev flag: `--fx-force-slip` (user arg) or `force_slip` makes the rear wheels mark/smoke as if
## drifting, independent of the physics, for screenshots and tuning.
##
## Arcade car: marks and smoke come from WheelState.slip and `is_drifting`, rear wheels smoke.
## Simulation car: every wheel marks and smokes from what its tyre really does (tyre_slip.gd):
## wheelspin on a driven wheel, a lock-up (whiter smoke, darker mark) or sliding sideways,
## scaled by the load on the tyre and how fast the patch rubs over the road. Sparks fly when
## the floor bottoms out at speed (floor_sparks.gd).

const SkidMarks := preload("res://scripts/fx/skid_marks.gd")
const TyreSmoke := preload("res://scripts/fx/tyre_smoke.gd")
const SpeedLines := preload("res://scripts/fx/speed_lines.gd")
const TyreSlip := preload("res://scripts/fx/tyre_slip.gd")
const FloorSparks := preload("res://scripts/fx/floor_sparks.gd")

const FRONT_TYRE_WIDTH: float = 0.30
const REAR_TYRE_WIDTH: float = 0.38
## Smoke from a locked wheel is whiter than the grey of a spinning or sliding one.
const LOCK_SMOKE_TINT := Color(0.97, 0.97, 0.98)
## A lock-up lays a dark mark from the start (a flat spot being ground off).
const LOCK_MARK_MIN_ALPHA: float = 0.75
## The floor counts as touching when a wheel is within this of its bump stop (m).
const SPARK_TRAVEL_MARGIN: float = 0.003
## Only a hard surface strikes sparks.
const SPARK_SURFACES: Array[StringName] = [&"asphalt", &"kerb"]
## Smoke pool for a simulation car: four wheels instead of the arcade car's two.
const SIM_SMOKE_POOL: int = 2 * TyreSmoke.MAX_PER_SOURCE * 2

@export var car_path: NodePath
@export var force_slip: bool = false
@export var speed_lines_enabled: bool = true
## Wheel slip above which a mark is laid (0..1).
@export_range(0.0, 1.0) var skid_slip_threshold: float = 0.3
## Effective slip of the rear wheels while `car.is_drifting`.
@export_range(0.0, 1.0) var drift_slip: float = 0.75
## Speed (m/s) at which smoke reaches full rate for a fully sliding wheel.
@export var smoke_full_speed: float = 25.0
## Simulation: speed of the contact patch over the road (m/s) for full smoke from that wheel.
@export var sim_smoke_full_speed: float = 14.0
## Simulation: sparks from a bottoming floor start at this speed (m/s) and are full at twice it.
@export var spark_min_speed: float = 28.0

@onready var skid_marks: SkidMarks = $SkidMarks
@onready var tyre_smoke: TyreSmoke = $TyreSmoke
@onready var speed_lines: SpeedLines = $SpeedLines

var car: Car
## Created the first time a simulation car's floor touches; null until then.
var floor_sparks: FloorSparks

# Per-frame buffers of the simulation path (four wheels), reused.
var _sim_pos := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var _sim_nrm := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
var _sim_int := PackedFloat32Array([0, 0, 0, 0])
var _sim_tint := PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])

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
	if floor_sparks != null:
		floor_sparks.clear()

func _on_car_respawned() -> void:
	# Don't connect a ribbon across the teleport; keep the marks themselves.
	skid_marks.end_all_strips()

## Effective slip of wheel i (0 when it should not mark), including drift/forced overrides.
func wheel_effect_slip(i: int) -> float:
	if car == null or i >= car.wheels.size():
		return 0.0
	var w := car.wheels[i]
	var rear := i >= 2
	if car.sim != null:
		# Simulation: the tyre's real slip. is_drifting is not used, it is already in there.
		return 1.0 if rear and force_slip else TyreSlip.strength(car, i)
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
			if car.sim != null and TyreSlip.lock_dominant(car, i):
				alpha = maxf(alpha, LOCK_MARK_MIN_ALPHA)
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
	if car.sim != null:
		_process_simulation(delta)
		speed_lines.update_speed(car.speed_kmh if speed_lines_enabled else 0.0, delta)
		return
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var intensities := PackedFloat32Array()
	var speed := car.linear_velocity.length()
	for i in [2, 3]:
		if i >= car.wheels.size():
			break
		positions.append(car.wheels[i].contact_point)
		normals.append(car.wheels[i].contact_normal)
		var slip := wheel_effect_slip(i)
		intensities.append(slip * clampf(speed / smoke_full_speed, 0.0, 1.0) if slip > skid_slip_threshold else 0.0)
	tyre_smoke.step(delta, positions, intensities, car.linear_velocity, normals)
	speed_lines.update_speed(car.speed_kmh if speed_lines_enabled else 0.0, delta)

## Simulation car: smoke from each of the four wheels, and sparks from the floor.
func _process_simulation(delta: float) -> void:
	if tyre_smoke.pool_size < SIM_SMOKE_POOL:
		tyre_smoke.set_pool_size(SIM_SMOKE_POOL)
	var car_speed := absf(car.speed_kmh) / Car.KMH
	for i in mini(4, car.wheels.size()):
		var w := car.wheels[i]
		_sim_pos[i] = w.contact_point
		_sim_nrm[i] = w.contact_normal
		var k := wheel_effect_slip(i)
		var intensity := 0.0
		if k > skid_slip_threshold:
			if i >= 2 and force_slip:
				intensity = k * clampf(car_speed / smoke_full_speed, 0.0, 1.0)
			else:
				intensity = k * clampf(TyreSlip.sliding_speed(car, i) / sim_smoke_full_speed, 0.0, 1.0)
		_sim_int[i] = intensity
		_sim_tint[i] = LOCK_SMOKE_TINT if TyreSlip.lock_dominant(car, i) else TyreSmoke.TINT
	tyre_smoke.step(delta, _sim_pos, _sim_int, car.linear_velocity, _sim_nrm, _sim_tint)
	_update_sparks(delta, car_speed)

## Sparks while a loaded wheel sits on its bump stop at speed: the floor is on the road.
func _update_sparks(delta: float, car_speed: float) -> void:
	var st := car.sim.state
	var spec := car.sim.spec
	var touching := 0
	var at := Vector3.ZERO
	var normal := Vector3.ZERO
	if st != null and spec != null and car_speed > spark_min_speed:
		for i in mini(4, car.wheels.size()):
			if st.contact[i] and st.load[i] > 0.0 and car.wheels[i].surface in SPARK_SURFACES \
					and st.compression[i] >= spec.travel_bump - SPARK_TRAVEL_MARGIN:
				touching += 1
				at += car.wheels[i].contact_point
				normal += car.wheels[i].contact_normal
	if touching == 0:
		if floor_sparks != null:
			floor_sparks.step(delta, Vector3.ZERO, Vector3.UP, Vector3.ZERO, 0.0)
		return
	if floor_sparks == null:
		floor_sparks = FloorSparks.new()
		floor_sparks.name = "FloorSparks"
		add_child(floor_sparks)
	# The floor, not the tyre, is what touches: emit under the car, towards its centreline.
	var local := car.global_transform.affine_inverse() * (at / touching)
	local.x *= 0.3
	local.z *= 0.7
	normal = normal.normalized() if normal.length_squared() > 0.01 else Vector3.UP
	var intensity := clampf(car_speed / spark_min_speed - 1.0, 0.0, 1.0) * (0.5 + 0.5 * touching / 4.0)
	floor_sparks.step(delta, car.global_transform * local, normal, car.linear_velocity, intensity)
