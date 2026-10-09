extends Camera3D
## Trackmania-style camera rig for the node at `target_path` (normally a Car).
##   Mode 1 (key 1): low, close chase cam (default).
##   Mode 2 (key 2): high, far chase cam.
##   Mode 3 (key 3): cockpit cam, rigidly attached to the car.
## Chase modes follow the car's horizontal heading through a critically damped
## spring, blending towards the velocity heading while the car slides, keep the
## horizon level, damp height changes and widen the FOV with speed.
##
## Hills: the boom pitches with the road (`slope_follow` of the grade, taken from
## the averaged wheel contact normals, not the bouncing body) so a climb or a
## descent is framed like the flat; banking rolls the view only a little
## (`bank_follow`). The height spring is fed the car's (smoothed) vertical speed
## so it does not trail below the car on long grades, yet still soaks up bumps.
## A ray from the car to the camera pulls the boom in when terrain, a crest or a
## wall is in the way, and a ground probe keeps a minimum clearance; neither
## assumes a flat world.
##
## Jitter-free: physics runs at 240 Hz but rendering at 30..144+ Hz, so a frame
## sees 0, 1 or 2 physics steps. The camera updates in _process and follows the
## car's *render-time* transform, which must match what the car mesh is drawn
## at, otherwise the car shakes on screen. Engine physics interpolation provides
## exactly that (car mesh and camera target both interpolated between ticks), so
## by default this camera switches SceneTree.physics_interpolation on (see
## `enable_physics_interpolation`; ideally also set in project.godot). With it
## off, the camera tracks the raw physics transform so the car stays steady.
## All filters are frame-rate independent (closed-form springs / exp decay).
##
## Dev flags: --camera=N picks the starting mode (1..3).
## Screenshot cameras (parsed by Bootstrap), which replace the rig while set:
##   --cam-pos=x,y,z [--cam-look=x,y,z]  a fixed camera at a world position, looking at a
##                                       point (default: at the car)
##   --overview                          high above the circuit centre, looking down at
##                                       OVERVIEW_PITCH_DEG and framing the whole lap; the fog
##                                       is pushed back so the ground is visible from there

enum Mode { CHASE_LOW = 1, CHASE_HIGH = 2, COCKPIT = 3 }

const OVERVIEW_PITCH_DEG: float = 55.0
const OVERVIEW_FOV: float = 50.0

## Car (or any Node3D) to follow. main.tscn sets this; keep the name.
@export var target_path: NodePath
@export var mode: Mode = Mode.CHASE_LOW
## Turns on engine physics interpolation (SceneTree-wide) so the car mesh and the
## camera are both drawn at the interpolated render-time state. Strongly recommended.
@export var enable_physics_interpolation: bool = true

@export_group("Chase low (Cam 1)")
@export var low_distance: float = 5.4      ## metres behind the car origin
@export var low_height: float = 1.55       ## metres above the car origin
@export var low_look_height: float = 0.9   ## look-at point height above car origin
@export var low_look_ahead: float = 7.0    ## look-at point distance ahead of car origin

@export_group("Chase high (Cam 2)")
@export var high_distance: float = 9.0 
@export var high_height: float = 3.3
@export var high_look_height: float = 0.8
@export var high_look_ahead: float = 12.0

@export_group("Cockpit (Cam 3)")
@export var cockpit_offset: Vector3 = Vector3(0.0, 0.75, 0.2)

@export_group("Follow dynamics")
## Time constant (s) of the critically damped yaw spring.
@export var yaw_lag: float = 0.14
## Time constant (s) of the height spring (bumps / landings).
@export var height_lag: float = 0.22
## Time constant (s) of the slope pitch follow.
@export var pitch_lag: float = 0.35
## Fraction of the road's pitch (slopes) applied to the boom.
@export_range(0.0, 1.0) var slope_follow: float = 0.72
## Fraction of the road's banking applied as camera roll (horizon otherwise level).
@export_range(0.0, 1.0) var bank_follow: float = 0.2
## Time constant (s) of the banking roll follow.
@export var roll_lag: float = 0.4
## Time constant (s) of the vertical-speed filter used to stop the height spring
## from trailing below the car on long grades. 0 disables the compensation.
@export var climb_lag: float = 0.2
## Time constant (s) for the boom to extend again after an obstruction pulled it in.
@export var boom_recover_lag: float = 0.35
## How far the heading blends towards the velocity direction when sliding (0..1).
@export_range(0.0, 1.0) var drift_follow: float = 0.75
## Slip angle (deg) at which the velocity blend starts / is fully applied.
@export var drift_slip_start_deg: float = 4.0
@export var drift_slip_full_deg: float = 30.0
## Extra pull-back (m) at top speed, gives a sense of acceleration.
@export var speed_pullback: float = 0.6

@export_group("Field of view")
@export var fov_rest: float = 70.0
@export var fov_max: float = 88.0
@export var fov_max_speed_kmh: float = 500.0
@export var fov_lag: float = 0.25
@export var cockpit_fov_rest: float = 75.0
@export var cockpit_fov_max: float = 92.0

@export_group("Shake")
@export var shake_enabled: bool = true
## Positional amplitude (m) at shake_full_kmh. Very subtle by design.
@export var shake_amplitude: float = 0.012
@export var shake_start_kmh: float = 250.0
@export var shake_full_kmh: float = 550.0

@export_group("Ground")
## Minimum clearance above the ground under the camera.
@export var min_ground_clearance: float = 0.6
## Gap (m) kept between the camera and anything blocking the car->camera line.
@export var occlusion_margin: float = 0.35

var _target: Node3D

# Spring states.
var _yaw: float = 0.0
var _yaw_vel: float = 0.0
var _pivot_y: float = 0.0
var _pivot_y_vel: float = 0.0
var _pitch: float = 0.0
var _pitch_vel: float = 0.0
var _roll: float = 0.0
var _roll_vel: float = 0.0
var _vy_filtered: float = 0.0
# Road normal under the car (averaged wheel contact normals), held while airborne.
var _road_normal: Vector3 = Vector3.UP
var _has_road_normal: bool = false
var _speed_kmh: float = 0.0
var _initialized: bool = false
# After a snap, the engine's interpolated transform can still be the pre-teleport
# one until a full physics tick has passed, so follow the live transform until then.
var _live_target_ticks: int = 2
var _time: float = 0.0
var _last_delta: float = 0.0

# Ground height under the camera, sampled in _physics_process (safe for the space state).
var _ground_y: float = -INF
var _ground_dirty: bool = true
# Boom obstruction: ray from the car to the desired camera position, cast in _physics_process.
var _boom_from: Vector3
var _boom_to: Vector3
var _boom_valid: bool = false
var _boom_limit: float = INF     ## max boom length allowed by the last obstruction probe
var _boom_len: float = INF       ## smoothed boom length actually used
# --overview pose (see _setup_overview).
var _fixed: bool = false
var _fixed_pos: Vector3
var _fixed_look: Vector3

func _init() -> void:
	# Exported values are not applied yet in _init, so this reads the script default;
	# it runs while main.tscn is being instanced, i.e. before any of its nodes enter
	# the tree. Turning interpolation on later (in _ready) leaves already-registered
	# render instances (e.g. the sun) with broken transforms, a Godot quirk.
	# Prefer setting physics/common/physics_interpolation=true in project.godot.
	var tree := Engine.get_main_loop() as SceneTree
	if enable_physics_interpolation and tree and not tree.physics_interpolation:
		tree.physics_interpolation = true

func _ready() -> void:
	# This node is moved in _process; never let engine physics interpolation touch it.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	for arg: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg.begins_with("--camera="):
			var n := int(arg.get_slice("=", 1))
			if n >= 1 and n <= 3:
				mode = n as Mode
	set_target(get_node_or_null(target_path) as Node3D)
	if Bootstrap.overview:
		_setup_overview()

## --overview: frames the whole lap from above (the camera stays there, see _process).
func _setup_overview() -> void:
	var track := get_tree().get_first_node_in_group(&"track") as Track
	if track == null or track.data == null or track.data.points.is_empty():
		return
	var lo := track.data.points[0]
	var hi := lo
	for p in track.data.points:
		lo = lo.min(p)
		hi = hi.max(p)
	var centre := (lo + hi) * 0.5
	var radius := 0.0
	for p in track.data.points:
		radius = maxf(radius, Vector2(p.x - centre.x, p.z - centre.z).length())
	# Far enough that the lap's circle fits the view height when seen at this pitch.
	var pitch := deg_to_rad(OVERVIEW_PITCH_DEG)
	var dist := maxf(radius, 50.0) * sin(pitch) / tan(deg_to_rad(OVERVIEW_FOV) * 0.5) * 1.12
	_fixed_pos = centre + Vector3(0.0, sin(pitch), cos(pitch)) * dist
	_fixed_look = centre
	_fixed = true
	fov = OVERVIEW_FOV
	near = 1.0
	far = maxf(far, dist * 4.0)
	track.environment.push_fog_back(dist, track.find_sky())
	if track.scenery != null:
		track.scenery.set_tree_range_bonus(dist)
	var terrain := track.get_node_or_null(^"Terrain") as Terrain
	if terrain != null and terrain.material != null:
		terrain.material.set_shader_parameter("max_view", far * 0.95)
	global_transform = Transform3D(Basis.looking_at(_fixed_look - _fixed_pos, Vector3.UP), _fixed_pos)

func set_target(t: Node3D) -> void:
	if is_instance_valid(_target) and _target.has_signal("respawned") and _target.is_connected("respawned", _on_target_respawned):
		_target.disconnect("respawned", _on_target_respawned)
	_target = t
	if _target and _target.has_signal("respawned"):
		_target.connect("respawned", _on_target_respawned)
	snap()

## Switches camera mode instantly (no blend).
func set_mode(m: int) -> void:
	mode = clampi(m, 1, 3) as Mode
	snap()

## Resets all filters so the camera jumps straight to its resting pose.
func snap() -> void:
	_initialized = false
	_live_target_ticks = 2
	_ground_y = -INF
	_ground_dirty = true
	_boom_valid = false
	_boom_limit = INF
	_boom_len = INF
	_has_road_normal = false
	if is_inside_tree() and _target and _target.is_inside_tree():
		_update(0.0)

func _on_target_respawned() -> void:
	# A teleport must not be interpolated from the old position (no swoop).
	_target.reset_physics_interpolation()
	snap()

func _physics_process(_delta: float) -> void:
	_live_target_ticks = maxi(_live_target_ticks - 1, 0)
	if not is_instance_valid(_target):
		return
	# One ground probe per rendered frame is plenty; cockpit mode does not need it.
	if _ground_dirty and mode != Mode.COCKPIT:
		_ground_dirty = false
		_sample_ground()
		_sample_boom()

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("camera_1"):
		set_mode(Mode.CHASE_LOW)
	elif Input.is_action_just_pressed("camera_2"):
		set_mode(Mode.CHASE_HIGH)
	elif Input.is_action_just_pressed("camera_3"):
		set_mode(Mode.COCKPIT)
	elif Bootstrap.take_button(&"camera"):
		set_mode(int(mode) % 3 + 1)   # the phone's CAM button cycles the three views
	if _fixed or Bootstrap.free_cam:
		_update_fixed()
		return
	if not is_instance_valid(_target):
		return
	_update(delta)
	_ground_dirty = true

## The screenshot cameras: --overview, or --cam-pos looking at --cam-look / the car.
func _update_fixed() -> void:
	var pos := _fixed_pos
	var look := _fixed_look
	if not _fixed:
		pos = Bootstrap.cam_pos
		look = Bootstrap.cam_look
		if not Bootstrap.cam_has_look:
			if not is_instance_valid(_target):
				return
			look = _target_transform().origin
		fov = fov_rest
	var dir := look - pos
	if dir.length_squared() < 1e-6:
		return
	var up := Vector3.UP if absf(dir.normalized().y) < 0.999 else Vector3.FORWARD
	global_transform = Transform3D(Basis.looking_at(dir, up), pos)

## Car transform at render time (what the car mesh is drawn at this frame).
func _target_transform() -> Transform3D:
	if _live_target_ticks == 0 and get_tree().physics_interpolation and _target.is_physics_interpolated():
		return _target.get_global_transform_interpolated()
	return _target.global_transform

func _target_velocity() -> Vector3:
	if _target is RigidBody3D:
		return (_target as RigidBody3D).linear_velocity
	if _target is CharacterBody3D:
		return (_target as CharacterBody3D).velocity
	return Vector3.ZERO

func _update(delta: float) -> void:
	_time += delta
	_last_delta = delta
	var xf := _target_transform()
	var vel := _target_velocity()
	var speed_kmh_now: float = vel.length() * 3.6
	if "speed_kmh" in _target:
		speed_kmh_now = maxf(float(_target.get("speed_kmh")), 0.0)
	var flat_fwd := Vector3(-xf.basis.z.x, 0.0, -xf.basis.z.z)
	# Near-vertical or upside down (walls, loops): hold the current heading instead of
	# flipping round with the degenerate / reversed flattened forward vector.
	var hold_yaw := flat_fwd.length_squared() < 0.04 or xf.basis.y.y < 0.0
	var target_yaw := _yaw if hold_yaw else _heading_yaw(flat_fwd, vel)
	var road := _road_angles(xf)
	var target_pitch := road.x * slope_follow
	var target_roll := road.y * bank_follow

	if not _initialized:
		_yaw = target_yaw
		_yaw_vel = 0.0
		_pivot_y = xf.origin.y
		_pivot_y_vel = 0.0
		_pitch = target_pitch
		_pitch_vel = 0.0
		_roll = target_roll
		_roll_vel = 0.0
		_vy_filtered = (vel - _road_normal * vel.dot(_road_normal)).y
		# Velocity, not speed_kmh: right after respawn speed_kmh is stale until the next tick.
		_speed_kmh = vel.length() * 3.6
		_initialized = true
	elif delta > 0.0:
		# Yaw: spring on the wrapped angle error (shortest way round).
		var yaw_goal := _yaw + wrapf(target_yaw - _yaw, -PI, PI)
		var r := _spring(_yaw, _yaw_vel, yaw_goal, yaw_lag, delta)
		_yaw = wrapf(r.x, -PI, PI)
		_yaw_vel = r.y
		# A critically damped spring chasing a target that moves at speed v trails it by
		# 2 * lag * v; lead the goal by that much (smoothed vertical speed) so the camera
		# stays level with the car on a 14 % climb instead of sinking towards the road.
		# Only the road-implied vertical speed (velocity projected onto the road plane):
		# landings, kerb strikes and suspension bounce are along the normal and are ignored.
		var y_goal := xf.origin.y
		if climb_lag > 0.0:
			var vy_road := (vel - _road_normal * vel.dot(_road_normal)).y
			_vy_filtered = lerpf(_vy_filtered, vy_road, 1.0 - exp(-delta / climb_lag))
			y_goal += clampf(2.0 * height_lag * _vy_filtered, -4.0, 4.0)
		r = _spring(_pivot_y, _pivot_y_vel, y_goal, height_lag, delta)
		_pivot_y = r.x
		_pivot_y_vel = r.y
		r = _spring(_pitch, _pitch_vel, target_pitch, pitch_lag, delta)
		_pitch = r.x
		_pitch_vel = r.y
		r = _spring(_roll, _roll_vel, target_roll, roll_lag, delta)
		_roll = r.x
		_roll_vel = r.y
		_speed_kmh = lerpf(_speed_kmh, speed_kmh_now, 1.0 - exp(-delta / maxf(fov_lag, 1e-3)))

	if mode == Mode.COCKPIT:
		_update_cockpit(xf)
	else:
		_update_chase(xf)

## Heading the chase camera aims for: car heading blended towards velocity heading with slip.
func _heading_yaw(flat_fwd: Vector3, vel: Vector3) -> float:
	var fwd_yaw := atan2(-flat_fwd.x, -flat_fwd.z)
	var flat_vel := Vector3(vel.x, 0.0, vel.z)
	var spd := flat_vel.length()
	if spd < 1.0:
		return fwd_yaw
	var vel_yaw := atan2(-flat_vel.x, -flat_vel.z)
	var slip := wrapf(vel_yaw - fwd_yaw, -PI, PI)
	# Reversing / spinning past 90 deg: stay behind the car rather than swing round.
	if absf(slip) > PI * 0.5:
		return fwd_yaw
	var w := smoothstep(deg_to_rad(drift_slip_start_deg), deg_to_rad(drift_slip_full_deg), absf(slip))
	w *= smoothstep(2.0, 10.0, spd)
	if "is_drifting" in _target and bool(_target.get("is_drifting")):
		w = maxf(w, 0.5 * smoothstep(2.0, 10.0, spd))
	return fwd_yaw + slip * w * drift_follow

## Road pitch (x, + = uphill ahead) and bank (y, + = right edge higher) under the car, in
## radians. Uses the averaged wheel contact normals (stable: no body pitch from braking,
## squat or suspension bounce); falls back to the car's up axis for non-Car targets.
func _road_angles(xf: Transform3D) -> Vector2:
	var n := Vector3.ZERO
	if "wheels" in _target:
		for w: Variant in _target.get("wheels"):
			if w != null and bool(w.get("contact")):
				n += w.get("contact_normal") as Vector3
		if n.length_squared() > 1e-4:
			_road_normal = n.normalized()
			_has_road_normal = true
		elif not _has_road_normal:
			_road_normal = xf.basis.y.normalized()
	else:
		_road_normal = xf.basis.y.normalized()
	n = _road_normal
	if n.y < 0.3:   # wall / loop / upside down: no sensible slope to follow
		return Vector2.ZERO
	var fwd := -xf.basis.z
	var road_fwd := fwd - n * fwd.dot(n)
	if road_fwd.length_squared() < 1e-4:
		return Vector2.ZERO
	road_fwd = road_fwd.normalized()
	var road_right := road_fwd.cross(n).normalized()
	return Vector2(asin(clampf(road_fwd.y, -1.0, 1.0)), asin(clampf(road_right.y, -1.0, 1.0)))

func _update_chase(xf: Transform3D) -> void:
	var high := mode == Mode.CHASE_HIGH
	var dist := high_distance if high else low_distance
	var height := high_height if high else low_height
	var look_h := high_look_height if high else low_look_height
	var look_ahead := high_look_ahead if high else low_look_ahead
	var speed_t := _speed_t()
	dist += speed_pullback * speed_t

	# Heading basis: yaw around world up, then gentle slope pitch. Horizon stays level.
	var heading := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	var back := heading.z      # +Z = behind the car
	var up := heading.y
	var pivot := Vector3(xf.origin.x, _pivot_y, xf.origin.z)

	var cam_pos := pivot + back * dist + up * height
	var look_at_pt := pivot - back * look_ahead + up * look_h

	# Pull the boom in when something (a crest, terrain, a wall) blocks the line from
	# the car to the camera. The probe runs in _physics_process on last frame's boom;
	# shorten instantly, extend again smoothly.
	# From the car's real (not spring-lagged) height, so the ray never starts under the road.
	var boom_from := xf.origin + up * look_h
	var boom := cam_pos - boom_from
	var boom_full := boom.length()
	# _boom_len is INF while unobstructed (the boom then tracks its full length freely).
	if _boom_limit < minf(_boom_len, boom_full):
		_boom_len = _boom_limit
	elif _boom_len < INF:
		var goal_len := minf(_boom_limit, boom_full + 0.5)
		_boom_len = lerpf(_boom_len, goal_len, 1.0 - exp(-_last_delta / maxf(boom_recover_lag, 1e-3)))
		if _boom_len >= boom_full and _boom_limit >= boom_full:
			_boom_len = INF
	if _boom_len < boom_full and boom_full > 1e-3:
		cam_pos = boom_from + boom * (maxf(_boom_len, 0.2) / boom_full)
	_boom_from = boom_from
	_boom_to = boom_from + boom
	_boom_valid = true

	# Never dip under the ground (sampled under the camera in _physics_process).
	var floor_y := (_ground_y if _ground_y > -INF else xf.origin.y - 2.0) + min_ground_clearance
	cam_pos.y = maxf(cam_pos.y, floor_y)

	if shake_enabled and shake_amplitude > 0.0:
		var s := smoothstep(shake_start_kmh, shake_full_kmh, _speed_kmh) * shake_amplitude
		if s > 0.0:
			var t := _time
			cam_pos += Vector3(
				sin(t * 37.1) * 0.6 + sin(t * 53.7 + 1.3) * 0.4,
				sin(t * 41.3 + 0.7) * 0.6 + sin(t * 67.9 + 2.1) * 0.4,
				0.0) * s

	var b := Basis.looking_at(look_at_pt - cam_pos, Vector3.UP)
	if absf(_roll) > 1e-5:
		b = b * Basis(Vector3.BACK, _roll)   # roll about the view axis: right edge up for + roll
	global_transform = Transform3D(b, cam_pos)
	fov = lerpf(fov_rest, fov_max, speed_t)
	near = 0.1

func _update_cockpit(xf: Transform3D) -> void:
	# Rigidly attached: no lag, inherits pitch and roll.
	global_transform = Transform3D(xf.basis.orthonormalized(), xf * cockpit_offset)
	fov = lerpf(cockpit_fov_rest, cockpit_fov_max, _speed_t())
	near = 0.05

## Ease-out 0..1 speed factor for FOV / pull-back.
func _speed_t() -> float:
	var t := clampf(_speed_kmh / maxf(fov_max_speed_kmh, 1.0), 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t)

func _sample_ground() -> void:
	var space := get_world_3d().direct_space_state if get_world_3d() else null
	if space == null:
		return
	# Start a little above the camera / car (whichever is higher), not far above, so
	# bridges and tunnel roofs overhead are not mistaken for the ground. Works on any
	# terrain or trimesh road (one-sided faces are hit from above).
	var top := maxf(global_position.y, _target.global_position.y) + 1.0
	var from := Vector3(global_position.x, top, global_position.z)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 60.0)
	if _target is CollisionObject3D:
		q.exclude = [(_target as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(q)
	_ground_y = (hit["position"] as Vector3).y if not hit.is_empty() else -INF

## Casts the car->camera boom ray; a hit limits the boom length (see _update_chase).
func _sample_boom() -> void:
	if not _boom_valid:
		_boom_limit = INF
		return
	var space := get_world_3d().direct_space_state if get_world_3d() else null
	if space == null:
		return
	var seg := _boom_to - _boom_from
	var seg_len := seg.length()
	if seg_len < 1e-3:
		_boom_limit = INF
		return
	var q := PhysicsRayQueryParameters3D.create(_boom_from, _boom_to + seg / seg_len * occlusion_margin)
	q.collide_with_areas = false
	if _target is CollisionObject3D:
		q.exclude = [(_target as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(q)
	_boom_limit = INF if hit.is_empty() \
		else maxf(_boom_from.distance_to(hit["position"] as Vector3) - occlusion_margin, 0.0)

## Closed-form critically damped spring step. Returns Vector2(position, velocity).
## `lag` is the time constant (1/omega); exact for any dt, so frame-rate independent.
static func _spring(x: float, v: float, goal: float, lag: float, dt: float) -> Vector2:
	var omega := 1.0 / maxf(lag, 1e-4)
	var d := x - goal
	var tmp := (v + omega * d) * dt
	var e := exp(-omega * dt)
	return Vector2(goal + (d + tmp) * e, (v - omega * tmp) * e)
