extends MultiMeshInstance3D
## Tyre smoke: a small CPU-simulated particle pool drawn as one billboarded MultiMesh
## (a single draw call, no GPU particle pipeline, works the same on every renderer).
## Puffs grow, fade, inherit part of the car velocity and drift upwards.
## Each puff remembers the road plane it was born on (contact point + normal) and never
## sinks below it, so smoke behaves the same on slopes, banking and the flat.

const MAX_PER_SOURCE: int = 150
const SOURCES: int = 2
const MAX_RATE: float = 80.0          ## puffs per second per wheel at full intensity
const LIFE_MIN: float = 1.3
const LIFE_MAX: float = 2.1
const SIZE_START: float = 0.45
const SIZE_END: float = 2.8
const INHERIT_VELOCITY: float = 0.5
const RISE_ACCEL: float = 0.5
const DRAG: float = 1.6
const MAX_ALPHA: float = 0.42
const SPAWN_LIFT: float = 0.3         ## spawn height above the contact, along the road normal
const FLOOR_CLEARANCE: float = 0.2    ## puff centres stay at least this far above their road plane
const TINT: Color = Color(0.86, 0.86, 0.88)

var pool_size: int = MAX_PER_SOURCE * SOURCES

var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _age := PackedFloat32Array()
var _life := PackedFloat32Array()   ## 0 = dead
var _strength := PackedFloat32Array()
var _rot := PackedFloat32Array()
var _rot_speed := PackedFloat32Array()
var _seed := PackedFloat32Array()
var _floor_p := PackedVector3Array()   ## road plane each puff was spawned on (point...
var _floor_n := PackedVector3Array()   ## ...and unit normal)
var _next: int = 0
var _accum := PackedFloat32Array()
var _prev_src := PackedVector3Array()
var _has_prev: Array[bool] = []
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/fx_smoke.gdshader")
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = pool_size
	mm.visible_instance_count = 0
	multimesh = mm
	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Particles are scattered across the world; never frustum-cull the whole pool.
	custom_aabb = AABB(Vector3(-1e5, -1e3, -1e5), Vector3(2e5, 2e3, 2e5))
	_pos.resize(pool_size)
	_vel.resize(pool_size)
	_age.resize(pool_size)
	_life.resize(pool_size)
	_strength.resize(pool_size)
	_rot.resize(pool_size)
	_rot_speed.resize(pool_size)
	_seed.resize(pool_size)
	_floor_p.resize(pool_size)
	_floor_n.resize(pool_size)
	_life.fill(0.0)
	_accum.resize(SOURCES)
	_accum.fill(0.0)
	_prev_src.resize(SOURCES)
	_has_prev.resize(SOURCES)
	_has_prev.fill(false)

func clear() -> void:
	_life.fill(0.0)
	_accum.fill(0.0)
	_has_prev.fill(false)
	if multimesh:
		multimesh.visible_instance_count = 0

func alive_count() -> int:
	var n := 0
	for i in pool_size:
		if _life[i] > 0.0:
			n += 1
	return n

## Advances the simulation. `positions`/`intensities` are per source (rear wheels);
## intensity 0..1 drives the emission rate. `car_velocity` is inherited in part.
## `normals` (optional, per source) are the road normals at the contacts; world up if missing.
func step(delta: float, positions: PackedVector3Array, intensities: PackedFloat32Array, car_velocity: Vector3,
		normals: PackedVector3Array = PackedVector3Array()) -> void:
	if multimesh == null or delta <= 0.0:
		return
	for s in mini(SOURCES, positions.size()):
		var k := intensities[s]
		var nrm := Vector3.UP
		if s < normals.size() and normals[s].length_squared() > 0.01:
			nrm = normals[s].normalized()
		var contact := positions[s]
		var p := contact + nrm * SPAWN_LIFT
		if k <= 0.02:
			_accum[s] = 0.0
			_has_prev[s] = false
			continue
		var from := _prev_src[s] if _has_prev[s] else p
		if from.distance_to(p) > 6.0:
			from = p
		_accum[s] += MAX_RATE * k * delta
		var n := int(_accum[s])
		_accum[s] -= n
		for j in n:
			# Spread spawns along the wheel path travelled this frame.
			var f := (j + _rng.randf()) / float(n)
			_spawn(from.lerp(p, f), car_velocity, k, contact, nrm)
		_prev_src[s] = p
		_has_prev[s] = true
	_simulate(delta)

func _spawn(p: Vector3, car_velocity: Vector3, k: float, floor_p: Vector3, floor_n: Vector3) -> void:
	var i := _next
	_next = (_next + 1) % pool_size
	var spread := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(0.2, 1.0), _rng.randf_range(-1, 1)) * 1.4
	var jitter := Vector3(_rng.randf_range(-0.15, 0.15), 0.0, _rng.randf_range(-0.15, 0.15))
	_pos[i] = p + jitter - floor_n * jitter.dot(floor_n)   # jitter within the road plane
	_floor_p[i] = floor_p
	_floor_n[i] = floor_n
	_vel[i] = car_velocity * INHERIT_VELOCITY + spread + Vector3.UP * 0.6
	_age[i] = 0.0
	_life[i] = _rng.randf_range(LIFE_MIN, LIFE_MAX)
	_strength[i] = clampf(0.45 + 0.55 * k, 0.0, 1.0)
	_rot[i] = _rng.randf() * TAU
	_rot_speed[i] = _rng.randf_range(-0.8, 0.8)
	_seed[i] = _rng.randf()

func _simulate(delta: float) -> void:
	var mm := multimesh
	var drag := exp(-DRAG * delta)
	var vis := 0
	for i in pool_size:
		if _life[i] <= 0.0:
			continue
		_age[i] += delta
		if _age[i] >= _life[i]:
			_life[i] = 0.0
			continue
		var v := _vel[i] * drag + Vector3.UP * RISE_ACCEL * delta
		_vel[i] = v
		var p := _pos[i] + v * delta
		var h := (p - _floor_p[i]).dot(_floor_n[i])
		if h < FLOOR_CLEARANCE:
			p += _floor_n[i] * (FLOOR_CLEARANCE - h)   # stay above the road it was born on
		_pos[i] = p
		_rot[i] += _rot_speed[i] * delta
		var t := _age[i] / _life[i]
		var size := lerpf(SIZE_START, SIZE_END, 1.0 - (1.0 - t) * (1.0 - t))
		var a := minf(_age[i] / 0.08, 1.0) * pow(1.0 - t, 1.6) * MAX_ALPHA * _strength[i]
		mm.set_instance_transform(vis, Transform3D(Basis.from_scale(Vector3.ONE * size), p))
		mm.set_instance_color(vis, Color(TINT.r, TINT.g, TINT.b, a))
		mm.set_instance_custom_data(vis, Color(_rot[i], _seed[i], 0.0, 0.0))
		vis += 1
	mm.visible_instance_count = vis
