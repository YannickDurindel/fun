class_name Autopilot
extends Node
## Autopilot: a driving brain that laps a Track on its racing line. Two ways to use it:
##   * Mode.PROVIDER (default, the race scene's Autodrive node): registers itself as
##     Bootstrap.autodrive_provider, so `--autodrive` (or Bootstrap.autodrive = true) lets it
##     drive the PLAYER car through Bootstrap.get_throttle/brake/steer().
##   * Mode.DIRECT (bots, see BotDriver): drives its own `car` through
##     Car.set_input_override() every think tick, whenever that car simulates.
## The racing line and the speed profiles are cached statically (per track, per pace / car
## tuning), so any number of drivers on one track share one precomputation.
##
## Pipeline (computed once per track, lazily or with prepare()):
##   1. Racing line: a lateral offset n(s) from the centreline, bounded by
##      +/-(width/2 - line_margin), found by curvature minimisation (Gauss-Seidel relaxation of
##      each point towards the midpoint of its neighbours, coarse-to-fine strides). Out-in-out.
##   2. Speed profile on that line: v_max(s) = sqrt(a_lat(v) / |k(s)|), then a backward pass with
##      the braking limit and a forward pass with the car's acceleration table, both corrected
##      for the road grade (gravity along the slope).
##   3. Each physics tick: pure pursuit on the racing line (lookahead grows with speed) plus a
##      small cross-track PD term, converted to a steering input through the Car's speed-limited
##      steering law; throttle/brake from the speed error against the profile.
##
## Car capability (measured with tools/lap_grip_sweep.gd, flat ground, full lock, steady state):
##     km/h      60     80    100    130    160    200    250    300
##     a_lat   18.3   18.5   18.9   19.5   20.3   21.7   23.8   26.4  m/s^2
##   i.e. a_lat_full(v) ~= 0.90 * g * (lateral_grip_g + aero_grip_g * v^2) * steer_grip_usage
##   (17.95 + 0.00121 v^2 m/s^2 with the default tuning); steering is linear in curvature
##   (60 % input -> 59 % of the full-lock lateral acceleration).
##   Straight-line braking 320 -> 0 km/h: 18.9 m/s^2 mean, 209 m. 0-100 2.0 s, 0-300 12.8 s.
## The profile uses `lateral_usage` of a_lat_full and `brake_usage` of the brake decel, leaving
## margin for corrections. Car parameters are read from the Car at runtime, so physics retunes
## carry over automatically.
##
## Drift guard: the Car drifts on brake + |steer| > 0.5 above 80 km/h, so above
## `drift_guard_kmh` the brake is held below the drift threshold whenever |steer| is large.

enum Mode { PROVIDER, DIRECT }

@export var car_path: NodePath
@export var mode: Mode = Mode.PROVIDER
## DIRECT mode: the brain thinks every N physics ticks and holds its inputs in between
## (4 = 60 Hz at 240 Hz physics). `think_phase` staggers several drivers over the ticks.
@export var think_every: int = 1
@export var think_phase: int = 0
## Per-turn / tracking statistics (lap timing always runs). Off for bots: it is per-tick work.
@export var collect_stats: bool = true
@export_group("Pace")
## Throttle ceiling (1 = flat out).
@export var throttle_cap: float = 1.0
## Multiplier on the profile's target speed (per-driver pace variation; <= 1).
@export var speed_scale: float = 1.0
## Lateral shift of this driver's line (m, + right), clamped to the road like the line itself.
@export var line_shift: float = 0.0
## How far past the racing-line bound (width/2 - line_margin) the shifted line may go (m).
@export var line_shift_overrun: float = 0.0
@export_group("Racing line")
## Distance kept between the racing line and the road edge (m).
@export var line_margin: float = 1.5
## Set false to drive the centreline (debug).
@export var use_racing_line: bool = true
@export_group("Speed profile")
## Fraction of the measured full-lock lateral acceleration used by the profile.
@export var lateral_usage: float = 0.92
## Fraction of the car's brake deceleration used to place braking points.
@export var brake_usage: float = 0.9
## Measured / theoretical full-lock lateral acceleration (see the sweep table above).
@export var lateral_efficiency: float = 0.90
@export var v_cap: float = 125.0                 ## m/s, profile ceiling
@export_group("Steering")
@export var lookahead_base: float = 5.0          ## m
@export var lookahead_time: float = 0.22         ## s (lookahead grows with speed)
@export var lookahead_max: float = 30.0          ## m
@export var cross_track_gain: float = 0.004      ## curvature (1/m) per m of cross-track error
@export var cross_track_damping: float = 0.004   ## curvature per m/s of cross-track error rate
@export var steer_gain: float = 1.1              ## compensates the measured 0.9 efficiency
@export_group("Pedals")
@export var speed_preview_time: float = 0.12     ## s, profile read ahead for actuator lag
@export var drift_guard_kmh: float = 85.0
@export var drift_guard_steer: float = 0.4

const G_TRACK := 9.81

## Statistics (since the last reset_stats(); lap_time / per_turn_stats per completed lap).
var lap_time: float = -1.0          ## s, last completed lap, line to line (timing_s)
var laps_completed: int = 0
var lap_clock: float = 0.0          ## s since the current lap started (physics clock)
var predicted_lap_time: float = 0.0 ## s, flying lap from the speed profile
var lateral_error_max: float = 0.0  ## m, max |car - racing line| (tracking error)
var lateral_offset_max: float = 0.0 ## m, max |car - centreline|
var edge_margin_min: float = INF    ## m, min (width/2 - |offset|); < 0 means off the road
var drift_ticks: int = 0
var straight_drift_ticks: int = 0   ## drift ticks where the line is straight (R > 250 m)
var max_speed_kmh: float = 0.0
## One Dictionary per track turn: {id, name, s_apex, entry_kmh, min_kmh, exit_kmh, max_before_kmh}
## (window apex -/+ turn_window m; max_before = top speed since the previous turn's apex).
var per_turn_stats: Array[Dictionary] = []
var last_lap_turn_stats: Array[Dictionary] = []
@export var turn_window: float = 60.0
## Line used for lap timing (defaults to the track's start line).
var timing_s: float = -1.0
var current_s: float = -1.0

var _car: Car
var _track: Track
var _data: TrackData
var _n: int = 0
var _line_off: PackedFloat32Array = []   ## racing-line lateral offset per point (+ right)
var _line_k: PackedFloat32Array = []     ## signed racing-line curvature (+ left)
var _v_prof: PackedFloat32Array = []     ## target speed (m/s)
var _line_pts: PackedVector3Array = []   ## racing-line points (world)
var _throttle: float = 0.0
var _brake: float = 0.0
var _steer: float = 0.0
var _prev_err: float = 0.0
var _have_prev_err: bool = false
var _clock: float = 0.0
var _lap_t0: float = -1.0
var _prev_s: float = -1.0
var _turn_state: Array[Dictionary] = []
var _tick: int = 0

const RaceTimer := preload("res://scripts/ui/race_timer.gd")

## Racing lines, keyed by track geometry + line options: {off, pts, k}.
static var _cache: Dictionary = {}
## Speed profiles, keyed by line key + pace + car tuning: {v, predicted}.
static var _profile_cache: Dictionary = {}
## Number of racing lines / profiles actually computed (tests check the sharing).
static var line_builds: int = 0
static var profile_builds: int = 0

## The car this brain drives (set from car_path in _ready, or assign before / after).
var car: Car:
	get:
		return _car
	set(v):
		set_car(v)
## The track driven (defaults to the first node in group "track").
var track: Track:
	get:
		return _track
	set(v):
		_track = v
		_data = null

func _ready() -> void:
	process_physics_priority = -10   # run before the Car reads its inputs this tick
	if _car == null:
		set_car(get_node_or_null(car_path) as Car)
	if _track == null:
		_track = get_tree().get_first_node_in_group(&"track") as Track
	if mode == Mode.PROVIDER and (Bootstrap.autodrive_provider == null \
			or not is_instance_valid(Bootstrap.autodrive_provider)):
		Bootstrap.autodrive_provider = self
	# The racing line / profile are built lazily on the first tick this node actually drives,
	# so loading the scene without --autodrive costs nothing. Call prepare() to build them now.

func set_car(p_car: Car) -> void:
	if _car == p_car:
		return
	if _car != null and is_instance_valid(_car) and _car.respawned.is_connected(_on_car_respawned):
		_car.respawned.disconnect(_on_car_respawned)
	_car = p_car
	_data = null
	if _car != null:
		_car.respawned.connect(_on_car_respawned)

## Builds (or fetches from the shared cache) the racing line and speed profile now.
func prepare() -> bool:
	if _data == null:
		_setup()
	return _data != null

## Teleports invalidate the local closest_s search window and the error derivative.
func _on_car_respawned() -> void:
	current_s = -1.0
	_prev_s = -1.0
	_have_prev_err = false

func _exit_tree() -> void:
	if Bootstrap.autodrive_provider == self:
		Bootstrap.autodrive_provider = null

func get_throttle() -> float:
	return _throttle

func get_brake() -> float:
	return _brake

func get_steer() -> float:
	return _steer

## Target speed (m/s) of the profile at centreline distance s.
func target_speed_at(s: float) -> float:
	return _lerp_arr(_v_prof, s)

## Lateral offset (m, + right of the centreline) of the line this driver follows at s: the
## shared racing line plus this driver's line_shift, kept on the road.
func line_offset_at(s: float) -> float:
	var off := _lerp_arr(_line_off, s)
	if line_shift == 0.0 or _data == null:
		return off
	var bound := maxf(0.0, _data.width_at(s) * 0.5 - line_margin) + line_shift_overrun
	return clampf(off + line_shift, minf(-bound, off), maxf(bound, off))

## Metres of centreline s covered per metre driven along the racing line at s (the inside of
## a corner is shorter than the centreline).
func line_s_rate_at(s: float) -> float:
	if _line_pts.is_empty():
		return 1.0
	var i := int(_data.wrap_s(s) / _data.step) % _n
	return _data.step / maxf(0.1, _line_pts[i].distance_to(_line_pts[(i + 1) % _n]))

## Unit direction of travel along the racing line at s.
func line_direction_at(s: float) -> Vector3:
	if _line_pts.is_empty():
		return -_data.sample(s).basis.z
	var i := int(_data.wrap_s(s) / _data.step) % _n
	return (_line_pts[(i + 1) % _n] - _line_pts[i]).normalized()

## Signed curvature (1/m, + = left) of the racing line at s.
func line_curvature_at(s: float) -> float:
	return _lerp_arr(_line_k, s)

func reset_stats() -> void:
	lap_time = -1.0
	laps_completed = 0
	lap_clock = 0.0
	lateral_error_max = 0.0
	lateral_offset_max = 0.0
	edge_margin_min = INF
	drift_ticks = 0
	straight_drift_ticks = 0
	max_speed_kmh = 0.0
	_lap_t0 = -1.0
	_init_turn_stats()

# ================================================================ setup
func _setup() -> void:
	if _car == null or _track == null or _track.data == null:
		return
	_data = _track.data
	_n = _data.points.size()
	if timing_s < 0.0:
		timing_s = _data.start_s
	# The (expensive, geometry-only) racing line is shared by every driver of the track; the
	# speed profile also depends on the pace settings and the Car tuning, so it is shared by
	# the drivers that agree on those. The arrays are shared by reference: never write to them.
	var key := "%s|%d|%.3f|%s|%.3f" % [_track.track_json, _n, _data.length, use_racing_line, line_margin]
	if _cache.has(key):
		var c: Dictionary = _cache[key]
		_line_off = c["off"]
		_line_pts = c["pts"]
		_line_k = c["k"]
	else:
		line_builds += 1
		_line_off = _racing_line() if use_racing_line else _zeros()
		_line_pts = PackedVector3Array()
		_line_pts.resize(_n)
		for i in _n:
			var t := _data.tangent_at(i * _data.step)
			_line_pts[i] = _data.points[i] + t.cross(Vector3.UP).normalized() * _line_off[i]
		_line_k = _line_curvature()
		_cache[key] = {"off": _line_off, "pts": _line_pts, "k": _line_k}
	var pkey := key + "|" + _profile_key()
	if _profile_cache.has(pkey):
		var p: Dictionary = _profile_cache[pkey]
		_v_prof = p["v"]
		predicted_lap_time = p["predicted"]
	else:
		profile_builds += 1
		_v_prof = _speed_profile()
		_profile_cache[pkey] = {"v": _v_prof, "predicted": predicted_lap_time}
	_init_turn_stats()

## Everything _speed_profile() reads besides the racing line: pace settings and Car tuning.
func _profile_key() -> String:
	return var_to_str([lateral_usage, brake_usage, lateral_efficiency, v_cap, steer_gain,
			drift_guard_kmh, drift_guard_steer, _car.steer_grip_usage, _car.lateral_grip_g,
			_car.aero_grip_g, _car.brake_decel, _car.coast_decel, _car.drag_decel_coef,
			_car.gravity_multiplier, _car.accel_curve_kmh, _car.accel_curve_ms2])

func _zeros() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(_n)
	a.fill(0.0)
	return a

func _right(i: int) -> Vector2:
	var t := _data.tangent_at(i * _data.step)
	return Vector2(-t.z, t.x).normalized()   # (fwd x UP) projected on x/z

func _racing_line() -> PackedFloat32Array:
	var c := PackedVector2Array()
	var r := PackedVector2Array()
	var bound := PackedFloat32Array()
	c.resize(_n)
	r.resize(_n)
	bound.resize(_n)
	for i in _n:
		var p := _data.points[i]
		c[i] = Vector2(p.x, p.z)
		r[i] = _right(i)
		bound[i] = maxf(0.0, _data.widths[i] * 0.5 - line_margin)
	var off := _zeros()
	# Minimise sum |P[j-k] - 2 P[j] + P[j+k]|^2 (discrete curvature) over the lateral offsets:
	# each point moves to the stationary point of its own terms,
	# P_i = (4 (P[i-k] + P[i+k]) - (P[i-2k] + P[i+2k])) / 6, projected on its lateral axis and
	# clamped to the road. (A plain midpoint rule would minimise length and hug the inside.)
	# Coarse-to-fine: large strides shape the out-in-out line, small strides smooth it.
	var plan: Array[Vector2i] = [Vector2i(24, 120), Vector2i(12, 120), Vector2i(6, 100),
			Vector2i(3, 80), Vector2i(1, 60)]
	for stage in plan:
		var k := stage.x
		for it in stage.y:
			for i in _n:
				var a := (i - k + _n) % _n
				var b := (i + k) % _n
				var a2 := (i - 2 * k + _n * 2) % _n
				var b2 := (i + 2 * k) % _n
				var near := c[a] + r[a] * off[a] + c[b] + r[b] * off[b]
				var far := c[a2] + r[a2] * off[a2] + c[b2] + r[b2] * off[b2]
				var goal := (near * 4.0 - far) / 6.0
				var here := c[i] + r[i] * off[i]
				off[i] = clampf(off[i] + (goal - here).dot(r[i]), -bound[i], bound[i])
	return off

func _line_point(i: int) -> Vector3:
	return _line_pts[posmod(i, _n)]

func _line_curvature() -> PackedFloat32Array:
	var h := 3
	var raw := _zeros()
	var pts := _line_pts
	for i in _n:
		var a := pts[(i - h + _n) % _n]
		var b := pts[i]
		var c := pts[(i + h) % _n]
		var t1 := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var t2 := Vector3(c.x - b.x, 0.0, c.z - b.z)
		var len := 0.5 * (t1.length() + t2.length())
		raw[i] = t1.signed_angle_to(t2, Vector3.UP) / maxf(len, 0.01)
	# Light smoothing (+/- 2 points).
	var k := _zeros()
	for i in _n:
		var s := 0.0
		for o in range(-2, 3):
			s += raw[(i + o + _n) % _n]
		k[i] = s / 5.0
	return k

## Full-lock lateral acceleration of the car at speed v (m/s), from its own tuning.
func _a_lat_full(v: float) -> float:
	return lateral_efficiency * G_TRACK * _car.steer_grip_usage \
			* (_car.lateral_grip_g + _car.aero_grip_g * v * v)

func _accel_at(v: float) -> float:
	var kmh := v * Car.KMH
	var xs := _car.accel_curve_kmh
	var ys := _car.accel_curve_ms2
	var m := mini(xs.size(), ys.size())
	if m == 0:
		return 0.0
	if kmh <= xs[0]:
		return ys[0]
	for i in range(1, m):
		if kmh <= xs[i]:
			return lerpf(ys[i - 1], ys[i], (kmh - xs[i - 1]) / maxf(xs[i] - xs[i - 1], 0.001))
	return ys[m - 1]

func _speed_profile() -> PackedFloat32Array:
	var g_eff := G_TRACK * _car.gravity_multiplier
	var v := _zeros()
	var ds := _zeros()
	var grade := _zeros()
	for i in _n:
		ds[i] = maxf(0.1, _line_point(i).distance_to(_line_point(i + 1)))
		grade[i] = _data.grades[i]   # + = uphill
	# Corner limit: v^2 |k| = u * (a0 + a2 v^2)  ->  v^2 = u a0 / (|k| - u a2).
	var a0 := _a_lat_full(0.0) * lateral_usage
	var a2 := (_a_lat_full(10.0) * lateral_usage - a0) / 100.0
	for i in _n:
		var kk := 0.0
		for o in range(-3, 4):   # conservative: tightest curvature nearby
			kk = maxf(kk, absf(_line_k[(i + o + _n) % _n]))
		var den := kk - a2
		v[i] = v_cap if den <= 1e-6 else minf(v_cap, sqrt(a0 / den))
	# Backward pass (braking), twice round the loop to settle the wrap.
	# Where the line curves enough that the steering input exceeds the drift guard, the
	# controller may only lift / feather the brake, so the profile only counts on that decel.
	var dec := _car.brake_decel * brake_usage
	var guard_v := drift_guard_kmh * 0.9 / Car.KMH
	for lap in 2:
		for j in range(_n - 1, -1, -1):
			var nxt := (j + 1) % _n
			var vn := v[nxt]
			var a := dec
			if vn > guard_v:
				var steer_frac := absf(_line_k[j]) * vn * vn / _a_lat_full(vn) * steer_gain
				if steer_frac > drift_guard_steer * 0.85:
					a = _car.coast_decel + _car.drag_decel_coef * vn * vn + _car.brake_decel * 0.08
			a = maxf(1.0, a + g_eff * grade[j])
			v[j] = minf(v[j], sqrt(vn * vn + 2.0 * a * ds[j]))
	# Forward pass (acceleration) for the predicted lap time.
	var vf := v.duplicate()
	for lap in 2:
		for j in _n:
			var nxt := (j + 1) % _n
			var a := maxf(0.0, _accel_at(vf[j]) - g_eff * grade[j])
			vf[nxt] = minf(vf[nxt], sqrt(vf[j] * vf[j] + 2.0 * a * ds[j]))
	predicted_lap_time = 0.0
	for j in _n:
		predicted_lap_time += ds[j] / maxf(0.5 * (vf[j] + vf[(j + 1) % _n]), 1.0)
	return v   # braking-limited envelope (the car accelerates as hard as it can below it)

func _lerp_arr(arr: PackedFloat32Array, s: float) -> float:
	if arr.is_empty():
		return 0.0
	var u := _data.wrap_s(s) / _data.step
	var i := int(floor(u)) % _n
	return lerpf(arr[i], arr[(i + 1) % _n], u - floor(u))

# ================================================================ driving
func _physics_process(delta: float) -> void:
	if mode == Mode.PROVIDER:
		if not Bootstrap.autodrive or Bootstrap.autodrive_provider != self:
			return
	elif _car == null or not is_instance_valid(_car) or not _car.simulate:
		return
	if _data == null:
		_setup()
		if _data == null:
			return
	_clock += delta
	if mode == Mode.PROVIDER:
		_think(delta)
		return
	_tick += 1
	var every := maxi(think_every, 1)
	if (_tick + think_phase) % every != 0:
		return   # the Car keeps the last override
	_think(delta * every)
	_car.set_input_override(_throttle, _brake, _steer)

## Speed (m/s) this driver aims for at s when moving at v: the profile, read a little ahead
## for the actuator lag, times the driver's pace scale.
func _target_speed(s: float, v: float) -> float:
	return minf(target_speed_at(s), target_speed_at(s + v * speed_preview_time)) * speed_scale

## Subclass hook, called at the start of every think (dt = time since the previous one).
func _before_think(_dt: float) -> void:
	pass

## One control step: reads the car, updates _throttle / _brake / _steer and the statistics.
func _think(delta: float) -> void:
	_before_think(delta)
	var pos := _car.global_position
	var s := _data.closest_s(pos, current_s)
	current_s = s
	var vel := _car.linear_velocity
	var v := vel.length()
	var xf := _car.global_transform

	# ---- steering: pure pursuit on the racing line + cross-track PD
	var ld := clampf(lookahead_base + v * lookahead_time, lookahead_base, lookahead_max)
	var ts := s + ld
	var tf := _data.sample(ts)
	var target := tf.origin + tf.basis.x * line_offset_at(ts)
	var local := xf.affine_inverse() * target
	var d2 := maxf(local.x * local.x + local.z * local.z, 1.0)
	var k_cmd := -2.0 * local.x / d2          # + = turn left
	var sf := _data.sample(s)
	var off := (pos - sf.origin).dot(sf.basis.x)
	var err := off - line_offset_at(s)        # + = car right of the line
	var err_rate := (err - _prev_err) / maxf(delta, 1e-4) if _have_prev_err else 0.0
	_prev_err = err
	_have_prev_err = true
	k_cmd += cross_track_gain * err + cross_track_damping * clampf(err_rate, -10.0, 10.0)
	var steer_max := _steer_max(v)
	var steer := -atan(k_cmd * Car.WHEELBASE) / maxf(steer_max, 1e-3) * steer_gain
	_steer = clampf(steer, -1.0, 1.0)

	# ---- pedals: speed error against the profile
	var v_t := _target_speed(s, v)
	var e := v_t - _car.forward_speed
	if e > 0.0:
		_throttle = clampf(0.45 + e * 0.6, 0.0, 1.0)
		_brake = 0.0
	elif e > -1.5:
		_throttle = clampf(0.3 + e * 0.2, 0.0, 1.0)
		_brake = 0.0
	else:
		_throttle = 0.0
		_brake = clampf(0.3 + (-e - 1.5) * 0.35, 0.0, 1.0)
	var kmh := v * Car.KMH
	# The Car tests its *smoothed* steer, which lags the command when unwinding.
	if kmh > drift_guard_kmh * 0.9 and maxf(absf(_steer), absf(_car.steer)) > drift_guard_steer:
		_brake = minf(_brake, 0.08)   # below the Car's drift brake threshold
	if _car.is_drifting:
		_brake = 0.0
	_throttle = minf(_throttle, throttle_cap)

	_update_stats(s, v, err, off)

func _steer_max(v: float) -> float:
	var a_lat := G_TRACK * (_car.lateral_grip_g + _car.aero_grip_g * v * v)
	if v <= 1.0:
		return _car.max_steer_angle
	return minf(_car.max_steer_angle, atan(Car.WHEELBASE * _car.steer_grip_usage * a_lat / (v * v)))

# ================================================================ statistics
func _init_turn_stats() -> void:
	per_turn_stats.clear()
	_turn_state.clear()
	if _data == null:
		return
	for t: Dictionary in _data.turns:
		per_turn_stats.append({"id": t.get("id", ""), "name": t.get("name", ""),
				"s_apex": float(t.get("s_apex", 0.0)), "entry_kmh": -1.0, "min_kmh": -1.0,
				"exit_kmh": -1.0, "max_before_kmh": -1.0})
		_turn_state.append({"inside": false, "min": INF, "max_before": 0.0})

func _update_stats(s: float, v: float, err: float, off: float) -> void:
	var moving := _car.simulate and v > 0.5
	var kmh := v * Car.KMH
	if collect_stats:
		_update_turn_stats(s, kmh, err, off, moving)
	_update_lap_timing(s, moving)

## Lap timing on the physics clock (line: timing_s).
func _update_lap_timing(s: float, moving: bool) -> void:
	if _prev_s >= 0.0 and moving:
		var a := _data.delta_s(timing_s, _prev_s)
		var b := _data.delta_s(timing_s, s)
		if a < 0.0 and b >= 0.0 and absf(b - a) < 50.0:
			if _lap_t0 >= 0.0:
				lap_time = _clock - _lap_t0
				laps_completed += 1
				last_lap_turn_stats = per_turn_stats.duplicate(true)
			_lap_t0 = _clock
	_prev_s = s
	lap_clock = _clock - _lap_t0 if _lap_t0 >= 0.0 else 0.0

func _update_turn_stats(s: float, kmh: float, err: float, off: float, moving: bool) -> void:
	if moving:
		max_speed_kmh = maxf(max_speed_kmh, kmh)
		lateral_error_max = maxf(lateral_error_max, absf(err))
		lateral_offset_max = maxf(lateral_offset_max, absf(off))
		edge_margin_min = minf(edge_margin_min, _data.width_at(s) * 0.5 - absf(off))
		if _car.is_drifting:
			drift_ticks += 1
			if absf(_lerp_arr(_line_k, s)) < 1.0 / 250.0:
				straight_drift_ticks += 1
	# Turn windows.
	for i in per_turn_stats.size():
		var st := per_turn_stats[i]
		var ts := _turn_state[i]
		var d := _data.delta_s(float(st["s_apex"]), s)
		var inside := absf(d) <= turn_window
		if inside and not ts["inside"]:
			st["entry_kmh"] = kmh
			st["max_before_kmh"] = ts["max_before"]
			ts["min"] = INF
		if inside:
			ts["min"] = minf(ts["min"], kmh)
			st["min_kmh"] = ts["min"]
		if not inside and ts["inside"]:
			st["exit_kmh"] = kmh
		ts["inside"] = inside
		# Top speed on the run up to this turn: restarts when the previous turn's apex is passed.
		var prev := per_turn_stats[(i - 1 + per_turn_stats.size()) % per_turn_stats.size()]
		var since_prev := _data.delta_s(float(prev["s_apex"]), s)
		if since_prev >= 0.0 and since_prev < 4.0 * _data.step:
			ts["max_before"] = 0.0
		if not inside:
			ts["max_before"] = maxf(ts["max_before"], kmh)

## Human-readable per-turn table plus lap figures.
func report() -> String:
	var lines: PackedStringArray = []
	lines.append("turn  name                    apex_s  entry  min(apex)  exit  top_before   (km/h)")
	var rows := last_lap_turn_stats if not last_lap_turn_stats.is_empty() else per_turn_stats
	for st in rows:
		lines.append("%-5s %-22s %7.0f %6.0f %9.0f %6.0f %10.0f" % [st["id"], String(st["name"]).left(22),
				st["s_apex"], st["entry_kmh"], st["min_kmh"], st["exit_kmh"], st["max_before_kmh"]])
	lines.append("lap_time %s  predicted %.2f s  max %.0f km/h  laps %d" % [
			_fmt_time(lap_time), predicted_lap_time, max_speed_kmh, laps_completed])
	lines.append("max |line error| %.2f m  max |offset| %.2f m  min edge margin %.2f m  drift ticks %d (straights %d)" % [
			lateral_error_max, lateral_offset_max, edge_margin_min, drift_ticks, straight_drift_ticks])
	return "\n".join(lines)

static func _fmt_time(t: float) -> String:
	return RaceTimer.format_time(t) if t >= 0.0 else "--:--.---"
