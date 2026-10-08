class_name GhostPlayer
extends Node3D
## Ghost system of a race (scenes/race/ghost_system.tscn, child `Ghost` of the race scene).
##   Recorder   GhostRecorder: records the player's laps, saves the best per track
##   GhostCar   body + wheel visuals only (no physics, no collision), drawn with ghost.gdshader
##
## Playback: when Game.config.ghost is on and the track has a saved ghost, the ghost car replays
## that lap in sync with the player's lap clock. It restarts at every lap start, is hidden during
## the countdown, on an out lap and once its own lap is over, and freezes with the game when
## paused. A new best lap replaces the ghost from the next lap on. The pose is computed in
## _process from the render-time lap clock (lerp / slerp between 30 Hz samples), so it is smooth
## at any frame rate. Wheel spin and steering are approximated from the recorded speed / steer.
##
## Works without a RaceManager (free-roam scenes): it just stays hidden.
## Dev flag: --ghost-demo replays a synthetic lap built from the track centreline (never saved),
## paced to stay `demo_lead` metres ahead of the player so screenshots always have it in view.

const SHADER: Shader = preload("res://shaders/ghost.gdshader")
const WHEEL_NAMES: Array[String] = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]
const FADE_OUT_TIME: float = 0.5
const LENGTH_TOLERANCE: float = 1.0

@export var tint: Color = Color(0.45, 0.8, 1.0)
## Distance from the camera (m) below which the ghost is invisible / above which fully shown.
@export var fade_near: float = 3.0
@export var fade_far: float = 7.0

var race: RaceManager
## The lap being replayed (null = nothing to show).
var data: GhostData
## Set by --ghost-demo.
var demo: bool = false

## Metres the --ghost-demo ghost keeps ahead of the player.
var demo_lead: float = 10.0

var _loaded_track: String = ""
var _demo_s: PackedFloat32Array = []   ## --ghost-demo: distance along the lap of each sample
var _spin: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0])
var _materials: Array[ShaderMaterial] = []
var _wheels: Array[Node3D] = []
var _steer_nodes: Array[Node3D] = []
var _spin_nodes: Array[Node3D] = []

@onready var ghost_car: Node3D = $GhostCar
@onready var recorder: GhostRecorder = $Recorder

func _ready() -> void:
	demo = OS.get_cmdline_user_args().has("--ghost-demo")
	_setup_visuals()
	ghost_car.visible = false
	race = get_node_or_null(^"../Track/Race") as RaceManager
	if race == null:
		for n in get_tree().get_nodes_in_group(&"race_manager"):
			if n is RaceManager and (owner == null or owner.is_ancestor_of(n)):
				race = n
				break
	if race == null:
		set_process(false)
		return
	recorder.setup(race)
	recorder.best_recorded.connect(_on_best_recorded)
	race.race_restarted.connect(_on_race_restarted)

## On the grid (also at every restart): read the ghost now, not on the first racing frame.
func _on_race_restarted() -> void:
	if is_enabled():
		_ensure_loaded()

## Ghost look on every mesh, wheels placed at their rest position (nothing drives them here:
## wheel_visual.gd only follows a Car ancestor).
func _setup_visuals() -> void:
	var depth := ShaderMaterial.new()
	depth.shader = SHADER
	depth.render_priority = 0
	depth.set_shader_parameter(&"depth_only", true)
	var colour := ShaderMaterial.new()
	colour.shader = SHADER
	colour.render_priority = 1
	colour.set_shader_parameter(&"depth_only", false)
	colour.set_shader_parameter(&"tint", tint)
	depth.next_pass = colour
	_materials = [depth, colour]
	for m in _materials:
		m.set_shader_parameter(&"fade_near", fade_near)
		m.set_shader_parameter(&"fade_far", fade_far)
	for i in WHEEL_NAMES.size():
		var w := ghost_car.get_node_or_null(WHEEL_NAMES[i]) as Node3D
		_wheels.append(w)
		_steer_nodes.append(w.get_node_or_null(^"Steer") as Node3D if w != null else null)
		_spin_nodes.append(w.get_node_or_null(^"Steer/Spin") as Node3D if w != null else null)
		if w == null:
			continue
		w.set_process(false)
		w.set_physics_process(false)
		# Rest ride height: the body is level, so the smaller front wheels sit a little lower.
		var comp := Car.FRONT_WHEEL_RADIUS - Car.REAR_WHEEL_RADIUS if i < 2 else 0.0
		w.position = Car.WHEEL_OFFSETS[i] + Vector3(0.0, comp, 0.0)
		var pivot := w.get_node_or_null(^"Suspension/Pivot") as Node3D
		var arm: float = w.get(&"_arm_length") if w.get(&"_arm_length") != null else 0.273
		if pivot != null and arm > 0.0:
			pivot.position.y = -comp
			pivot.basis = Basis(Vector3(1.0, comp / arm, 0.0), Vector3.UP, Vector3.BACK)
	for mesh: MeshInstance3D in ghost_car.find_children("*", "MeshInstance3D", true, false):
		if mesh.name == &"BlurDisc":
			mesh.visible = false   # the speed-blur overlay of the real wheels
			continue
		mesh.material_override = depth
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

func is_enabled() -> bool:
	return demo or Game.config.ghost

func is_ghost_visible() -> bool:
	return ghost_car.visible

## Lap time (s) the ghost is drawn at: the lap clock at render time. In a tick the RaceManager
## (and the recorder) pair the clock value T with the car's pose *before* that tick's step;
## between ticks the interpolated car is drawn a fraction f of a step past that pose, which is
## what a recording holds at T + f ticks.
func render_lap_time() -> float:
	if race == null or race.state != RaceManager.State.RACING:
		return 0.0
	var t := race.lap_time()
	if get_tree().physics_interpolation:
		t += Engine.get_physics_interpolation_fraction() / Engine.physics_ticks_per_second
	return maxf(t, 0.0)

func _on_best_recorded(ghost: GhostData) -> void:
	# The lap that just ended is the new reference; it replays from the lap starting now.
	if not demo:
		data = ghost
		_loaded_track = ghost.track_id

func _ensure_loaded() -> void:
	var id := race.track.track_id if race.track != null else ""
	if id == _loaded_track:
		return
	_loaded_track = id
	_demo_s.clear()
	data = make_demo(race.track, 2.5, _demo_s) if demo else GhostData.load_for(id)
	# A lap driven on another version of the track (the centreline was rebuilt) is not replayed.
	if data != null and data.track_length > 0.0 and race.data != null \
			and absf(data.track_length - race.data.length) > LENGTH_TOLERANCE:
		data = null

func _process(delta: float) -> void:
	if race.state != RaceManager.State.RACING or not is_enabled():
		ghost_car.visible = false
		return
	_ensure_loaded()
	if data == null or data.size() < 2 or race.out_lap:
		ghost_car.visible = false
		return
	show_at(_demo_time() if demo else render_lap_time(), delta)

## --ghost-demo: the lap time at which the synthetic ghost is `demo_lead` metres ahead.
func _demo_time() -> float:
	if _demo_s.size() != data.size():
		return render_lap_time()
	var target := race.s + demo_lead
	var hi := clampi(_demo_s.bsearch(target), 1, _demo_s.size() - 1)
	var span := _demo_s[hi] - _demo_s[hi - 1]
	var f := clampf((target - _demo_s[hi - 1]) / span, 0.0, 1.0) if span > 1e-4 else 0.0
	return lerpf(data.times[hi - 1], data.times[hi], f)

## Places the ghost where the recorded car was at lap time t. `delta` advances the wheel spin.
func show_at(t: float, delta: float = 0.0) -> void:
	var end := data.duration()
	# Its lap is over: it waits where it finished and fades away.
	var opacity := 1.0 - maxf(t - end, 0.0) / FADE_OUT_TIME
	if opacity <= 0.0:
		ghost_car.visible = false
		return
	ghost_car.visible = true
	ghost_car.global_transform = data.pose_at(t)
	for m in _materials:
		m.set_shader_parameter(&"opacity", opacity)
	var speed := data.speed_at(t) if t <= end else 0.0
	var steer := data.steer_at(t)
	for i in _wheels.size():
		_spin[i] = fmod(_spin[i] + speed * delta / (Car.FRONT_WHEEL_RADIUS if i < 2 else Car.REAR_WHEEL_RADIUS), TAU)
		if _spin_nodes[i] != null:
			_spin_nodes[i].rotation.x = -_spin[i]
		if i < 2 and _steer_nodes[i] != null:
			_steer_nodes[i].rotation.y = steer

## --ghost-demo: a plausible lap along the centreline (standing start on the grid, corner speeds
## from the curvature, braking and acceleration limits), 2.5 m right of centre.
## `sample_s`, when given, receives the distance along the lap of every sample.
static func make_demo(track: Track, lateral: float = 2.5, sample_s: PackedFloat32Array = []) -> GhostData:
	if track == null or track.data == null or track.data.length < 50.0:
		return null
	var d := track.data
	const DS: float = 2.0
	const V_CAP: float = 90.0
	var s0 := d.start_s - 8.0
	var n := int((d.length - s0) / DS) + 1
	if n < 3:
		return null
	var v := PackedFloat32Array()
	var curv := PackedFloat32Array()
	v.resize(n)
	curv.resize(n)
	for i in n:
		var s := s0 + i * DS
		var a := d.tangent_at(s - 6.0)
		var b := d.tangent_at(s + 6.0)
		var k := (b - a).length() / 12.0
		curv[i] = k * signf(a.cross(b).y)
		v[i] = minf(V_CAP, sqrt(21.0 / maxf(k, 1e-4)))
	v[0] = 0.0
	for i in range(n - 2, -1, -1):   # braking
		v[i] = minf(v[i], sqrt(v[i + 1] * v[i + 1] + 2.0 * 17.0 * DS))
	for i in range(1, n):            # acceleration, tapering with speed
		var acc := maxf(1.5, 15.0 * (1.0 - v[i - 1] / 96.0))
		v[i] = minf(v[i], sqrt(v[i - 1] * v[i - 1] + 2.0 * acc * DS))
	var at := PackedFloat32Array()   # time at each point
	at.resize(n)
	at[0] = 0.0
	for i in range(1, n):
		at[i] = at[i - 1] + 2.0 * DS / maxf(v[i - 1] + v[i], 0.5)
	var g := GhostData.new()
	g.track_id = track.track_id
	g.track_length = d.length
	g.lap_time = at[n - 1]
	g.sample_interval = maxf(1.0 / 30.0, g.lap_time / (GhostData.MAX_SAMPLES - 2))
	g.date = int(Time.get_unix_time_from_system())
	var j := 0
	var t := 0.0
	while true:
		t = minf(t, g.lap_time)
		while j < n - 2 and at[j + 1] < t:
			j += 1
		var f := clampf((t - at[j]) / maxf(at[j + 1] - at[j], 1e-5), 0.0, 1.0)
		var xf := track.spawn_transform(s0 + (j + f) * DS, lateral)
		sample_s.append(s0 + (j + f) * DS)
		xf.origin -= xf.basis.y * 0.05   # spawn_transform leaves a small drop; the ghost rides
		g.add_sample(t, xf, lerpf(v[j], v[j + 1], f), atan(Car.WHEELBASE * lerpf(curv[j], curv[j + 1], f)))
		if t >= g.lap_time:
			break
		t += g.sample_interval
	return g
