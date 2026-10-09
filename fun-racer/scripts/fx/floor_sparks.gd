extends MultiMeshInstance3D
## Sparks thrown from under the car when the floor touches the road at speed (the skid blocks
## of a bottoming car). A small CPU pool drawn as one additive, billboarded MultiMesh: one draw
## call, a few dozen quads at most, nothing at all while the car rides clear.
## driving_fx.gd creates this node for a simulation car and feeds it.

const POOL: int = 48
const MAX_RATE: float = 150.0        ## sparks per second at full intensity
const LIFE_MIN: float = 0.18
const LIFE_MAX: float = 0.45
const SIZE: float = 0.07
const GRAVITY: float = 9.8
const INHERIT_VELOCITY: float = 0.55 ## share of the car's velocity a spark keeps
const COL_HOT := Color(1.0, 0.85, 0.5)
const COL_COOL := Color(1.0, 0.35, 0.05)

var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _age := PackedFloat32Array()
var _life := PackedFloat32Array()   ## 0 = dead
var _floor_p := PackedVector3Array()
var _floor_n := PackedVector3Array()
var _next: int = 0
var _accum: float = 0.0
var _alive: int = 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = POOL
	mm.visible_instance_count = 0
	multimesh = mm
	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-1e5, -1e3, -1e5), Vector3(2e5, 2e3, 2e5))
	_pos.resize(POOL)
	_vel.resize(POOL)
	_age.resize(POOL)
	_life.resize(POOL)
	_floor_p.resize(POOL)
	_floor_n.resize(POOL)
	_life.fill(0.0)

func clear() -> void:
	_life.fill(0.0)
	_accum = 0.0
	_alive = 0
	if multimesh:
		multimesh.visible_instance_count = 0

func alive_count() -> int:
	return _alive

## Advances the sparks; `intensity` 0..1 emits new ones at `point` on the road (normal
## `normal`), thrown back from a car moving at `car_velocity`.
func step(delta: float, point: Vector3, normal: Vector3, car_velocity: Vector3, intensity: float) -> void:
	if multimesh == null or delta <= 0.0:
		return
	if intensity > 0.02:
		_accum += MAX_RATE * intensity * delta
		var n := int(_accum)
		_accum -= n
		for j in n:
			_spawn(point, normal, car_velocity)
	else:
		_accum = 0.0
		if _alive == 0:
			return   # nothing to emit, nothing alive: the common case costs nothing
	_simulate(delta)

func _spawn(point: Vector3, normal: Vector3, car_velocity: Vector3) -> void:
	var i := _next
	_next = (_next + 1) % POOL
	_pos[i] = point + normal * 0.03
	_floor_p[i] = point
	_floor_n[i] = normal
	var spread := Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.0, 1.0)) * 2.2
	_vel[i] = car_velocity * INHERIT_VELOCITY + spread + normal * _rng.randf_range(0.6, 3.2)
	_age[i] = 0.0
	_life[i] = _rng.randf_range(LIFE_MIN, LIFE_MAX)

func _simulate(delta: float) -> void:
	var mm := multimesh
	var vis := 0
	for i in POOL:
		if _life[i] <= 0.0:
			continue
		_age[i] += delta
		if _age[i] >= _life[i]:
			_life[i] = 0.0
			continue
		var v := _vel[i] + Vector3.DOWN * GRAVITY * delta
		var p := _pos[i] + v * delta
		var h := (p - _floor_p[i]).dot(_floor_n[i])
		if h < 0.0:
			# Skip off the road once, losing most of the vertical speed.
			p -= _floor_n[i] * h
			v -= _floor_n[i] * v.dot(_floor_n[i]) * 1.4
		_vel[i] = v
		_pos[i] = p
		var t := _age[i] / _life[i]
		var col := COL_HOT.lerp(COL_COOL, t)
		mm.set_instance_transform(vis, Transform3D(Basis.from_scale(Vector3.ONE * SIZE * (1.0 - 0.6 * t)), p))
		mm.set_instance_color(vis, Color(col.r, col.g, col.b, 1.0 - t * t))
		vis += 1
	mm.visible_instance_count = vis
	_alive = vis
