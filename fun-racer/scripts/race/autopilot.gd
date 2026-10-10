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
##      for the road grade (gravity along the slope). On a banked road (TrackData.banks, a
##      track with declared banking) a_lat is the banked limit, CarEnvelope.banked_lat(): the
##      envelope is the flat-road one, and a banked corner takes a good deal more.
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
##
## Everything the brain knows about the car comes from its CarEnvelope (lateral, braking and
## acceleration limits against speed). For the arcade model the envelope is the analytic one
## above and the pipeline is exactly as described. For the SIMULATION model (car.sim != null)
## the envelope is measured on a hidden copy of the car, and both planning and driving differ,
## because that car forgives nothing:
##   * Line: the same curvature-minimising line, then opened up wherever it asks for a
##     tighter turn than the car's steering lock gives at a sensible speed
##     (_open_tight_corners): the arcade car turns in 7 m, this one needs about 15.
##   * Profile (_speed_profile_sim): corner speed solved against the measured lat(v), reduced
##     over crests; braking AND acceleration passes inside a friction ellipse (the share of
##     grip the corner takes is not available to the pedals), so the plan itself trail-brakes
##     into the apex and feeds the power in on the way out. The target is the lower of the two
##     passes: what the car can really do, not only where it must brake.
##   * Steering (_think_sim): feed-forward of the line's curvature a little ahead, through the
##     measured steering map (input for a share of the cornering limit at this speed), plus a
##     look-ahead feedback on lateral and heading error whose reach grows with speed, a little
##     yaw damping and an inner loop on the curvature really driven. The heading error is
##     taken against the body slip the corner should produce, so a tail that steps out is met
##     with opposite lock. The command is rate limited and never asks the front tyres for
##     more than their limit.
##   * Pedals: wanted acceleration = the profile's own slope + a gain on the speed error,
##     turned into pedal travel with the measured pedal maps, capped by the friction ellipse
##     at the lateral acceleration of the moment, then governed on wheel slip (it holds the
##     tyres short of their peak with or without the car's traction control and anti-lock).
##     Off the brakes in a corner the throttle never drops below neutral (engine braking on
##     the rear axle alone unsettles the car). In a slide the throttle goes to neutral and the
##     brake is released until the car is straight again.
##   * Gears: left to the car's automatic gearbox; the brain only shifts if the engine goes
##     well past the shift points (i.e. the automatic is off).
## Measured on the Red Bull Ring with the skeleton parts (flying lap, aids at their defaults):
## 1:19.98 against a plan of 76.95 s; the difference is traction out of the corners.

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
@export_group("Simulation car")
## PROVIDER default: stand still while the car's envelope is being measured (a few seconds,
## only when no valid envelope file exists) instead of setting off on provisional limits.
@export var wait_for_envelope: bool = true
## Multipliers on lateral_usage / brake_usage for the simulation car: its envelope is the
## true tyre limit, where the arcade numbers already carry the arcade model's margins.
@export var sim_lateral_scale: float = 1.0
@export var sim_brake_scale: float = 1.0
## Share of the traction limit used when accelerating out of a corner.
@export var sim_traction_usage: float = 0.9
## Share of the car's tightest practical curvature (CarEnvelope.max_curvature) the racing
## line may ask for; corners tighter than that are opened up.
@export var sim_line_lock_usage: float = 0.95
@export var sim_lookahead_base: float = 6.0      ## m
@export var sim_lookahead_time: float = 0.34     ## s
@export var sim_lookahead_max: float = 45.0      ## m
## Line curvature is read this far ahead (s) for the steering feed-forward (yaw lag).
@export var sim_curvature_preview: float = 0.10
## Weight of the body-slip excess in the heading error (1 = full counter-steer).
@export var sim_slide_gain: float = 1.0
@export var sim_steer_rate: float = 3.5          ## steering input per second
## Gain on the difference between the curvature the car is turning and the one asked for:
## under braking the car turns in far more sharply for the same lock (load on the nose).
@export var sim_yaw_gain: float = 0.4
## Gain of the inner loop on the curvature of the path really driven (from the lateral
## acceleration) against the one asked for.
@export var sim_path_gain: float = 0.8
## Shape of the friction "ellipse" shared by cornering and the pedals:
## long^p + lat^p <= 1. 2 = a true ellipse; lower leaves the tyres more in hand (1 = straight
## trade-off). Braking into a corner gets the cautious one: the load on the nose makes the car
## turn in much more sharply, long before the tyres themselves give up.
@export var sim_trail_power: float = 1.6
@export var sim_exit_power: float = 2.0
@export var sim_speed_gain: float = 2.2          ## m/s^2 of wanted acceleration per m/s of error

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
var _env: CarEnvelope
var _env_rev: int = -1
var _sim: bool = false
var _shift_cool: float = 0.0
var _slide_hold: float = 0.0
var _prev_vel: Vector3 = Vector3.ZERO
var _have_prev_vel: bool = false
var _a_lat: float = 0.0                  ## lateral acceleration of the car's path (m/s^2, + = left)
## Simulation controller, last think: commanded curvature (1/m), heading error (rad), expected
## body slip (rad), wanted acceleration (m/s^2), share of the grip left for the pedals (0..1),
## 1 while a slide is being caught.
var diag: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

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
	_reset_sim_controller()

## The simulation controller carries state from one think to the next (rate-limited steering,
## governed pedals, the slide timer): after a teleport it starts from neutral.
func _reset_sim_controller() -> void:
	_have_prev_vel = false
	_a_lat = 0.0
	_slide_hold = 0.0
	if _sim:
		_throttle = 0.0
		_brake = 0.0
		_steer = 0.0

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
	_sim = _car.sim != null
	_env = CarEnvelope.for_car(_car, lateral_efficiency)
	_env_rev = CarEnvelope.revision
	# The simulation car cannot turn as tightly as the arcade one: its line is opened up where
	# it would ask for more than the car's lock gives (so it is a line of its own).
	var k_limit := _env.max_curvature() * sim_line_lock_usage if _sim and use_racing_line else INF
	var base_key := "%s|%d|%.3f|%s|%.3f" % [_track.track_json, _n, _data.length, use_racing_line, line_margin]
	var key := base_key + "|k%.4f" % k_limit if k_limit < INF else base_key
	if _cache.has(key):
		var c: Dictionary = _cache[key]
		_line_off = c["off"]
		_line_pts = c["pts"]
		_line_k = c["k"]
	else:
		if _cache.has(base_key):
			var c: Dictionary = _cache[base_key]
			_line_off = c["off"]
			_line_pts = c["pts"]
			_line_k = c["k"]
		else:
			line_builds += 1
			_line_off = _racing_line() if use_racing_line else _zeros()
			_line_pts = PackedVector3Array()
			_line_pts.resize(_n)
			for i in _n:
				_line_pts[i] = _offset_point(i, _line_off[i])
			_line_k = _line_curvature()
			_cache[base_key] = {"off": _line_off, "pts": _line_pts, "k": _line_k}
		if k_limit < INF:
			# From the shared line (the expensive part), into arrays of its own.
			_open_tight_corners(k_limit)
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
	if _sim:
		return var_to_str([&"sim", _env.key, _env.provisional, lateral_usage, brake_usage, v_cap,
				sim_lateral_scale, sim_brake_scale, sim_traction_usage, sim_trail_power, sim_exit_power])
	return var_to_str([lateral_usage, brake_usage, lateral_efficiency, v_cap, steer_gain,
			drift_guard_kmh, drift_guard_steer, _car.steer_grip_usage, _car.lateral_grip_g,
			_car.aero_grip_g, _car.brake_decel, _car.coast_decel, _car.drag_decel_coef,
			_car.gravity_multiplier, _car.slope_gravity_multiplier, _car.accel_curve_kmh, _car.accel_curve_ms2])

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

## Widens the line where its curvature exceeds k_limit (1/m): there the bound on the inside
## of the corner is moved outwards a little and the neighbourhood relaxed again, until the
## corner fits or the road is used up. Rewrites _line_off, _line_pts and _line_k.
func _open_tight_corners(k_limit: float) -> void:
	var c := PackedVector2Array()
	var r := PackedVector2Array()
	var lo := PackedFloat32Array()   # lateral bounds, + = right
	var hi := PackedFloat32Array()
	c.resize(_n)
	r.resize(_n)
	lo.resize(_n)
	hi.resize(_n)
	for i in _n:
		var p := _data.points[i]
		c[i] = Vector2(p.x, p.z)
		r[i] = _right(i)
		var b := maxf(0.0, _data.widths[i] * 0.5 - line_margin)
		lo[i] = -b
		hi[i] = b
	var off := _line_off.duplicate()
	var reach := maxi(8, int(50.0 / _data.step))
	for attempt in 24:
		var tight: Array[int] = []
		for i in _n:
			if absf(_line_k[i]) > k_limit:
				tight.append(i)
		if tight.is_empty():
			break
		var active := PackedByteArray()
		active.resize(_n)
		active.fill(0)
		var moved := false
		for i in tight:
			# k > 0 turns left: the inside is the left (negative offsets).
			if _line_k[i] > 0.0:
				if lo[i] < hi[i] - 0.05:
					lo[i] = minf(lo[i] + 0.25, hi[i])
					moved = true
			elif hi[i] > lo[i] + 0.05:
				hi[i] = maxf(hi[i] - 0.25, lo[i])
				moved = true
			for o in range(-reach, reach + 1):
				active[(i + o + _n) % _n] = 1
		if not moved:
			break
		for stage: Vector2i in [Vector2i(6, 30), Vector2i(3, 30), Vector2i(1, 30)]:
			var k := stage.x
			for it in stage.y:
				for i in _n:
					if active[i] == 0:
						continue
					var a := (i - k + _n) % _n
					var b := (i + k) % _n
					var a2 := (i - 2 * k + _n * 2) % _n
					var b2 := (i + 2 * k) % _n
					var near := c[a] + r[a] * off[a] + c[b] + r[b] * off[b]
					var far := c[a2] + r[a2] * off[a2] + c[b2] + r[b2] * off[b2]
					var goal := (near * 4.0 - far) / 6.0
					var here := c[i] + r[i] * off[i]
					off[i] = clampf(off[i] + (goal - here).dot(r[i]), lo[i], hi[i])
		_line_off = off
		_line_pts = PackedVector3Array()
		_line_pts.resize(_n)
		for i in _n:
			_line_pts[i] = _offset_point(i, off[i])
		_line_k = _line_curvature()

## The point `off` m right of centreline point i, across the road: horizontally on a level
## road, in the banked plane where TrackData carries a bank (the frame the driving uses).
func _offset_point(i: int, off: float) -> Vector3:
	var right := _data.tangent_at(i * _data.step).cross(Vector3.UP).normalized()
	if absf(_data.banks[i]) > 1e-5:
		right = _data.sample(i * _data.step).basis.x
	return _data.points[i] + right * off

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
	return _env.lat_at(v)

## Curvature (1/m) from which a corner counts as one for the banking: below it the bank's help
## fades in, so a banked straight is neither a help nor adverse camber.
const BANK_CORNER_CURVATURE := 1.0 / 400.0

## Bank of the road towards the inside of a turn of curvature k (+ = left) at centreline
## point i (rad; negative = adverse camber). TrackData.banks: + = left edge higher, which is
## the inside of a right-hander lower.
func _bank_into(i: int, k: float) -> float:
	return _data.banks[i] * clampf(-k / BANK_CORNER_CURVATURE, -1.0, 1.0)

## The same at distance s along the lap.
func _bank_into_at(s: float, k: float) -> float:
	return _data.bank_at(s) * clampf(-k / BANK_CORNER_CURVATURE, -1.0, 1.0)

func _accel_at(v: float) -> float:
	return _env.accel_at(v)

## The car's performance envelope (null before the first prepare()).
func envelope() -> CarEnvelope:
	return _env

## Gravity the car feels along a slope (the arcade model scales it).
func _g_eff() -> float:
	return G_TRACK if _sim else G_TRACK * _car.gravity_multiplier

func _speed_profile() -> PackedFloat32Array:
	if _sim:
		return _speed_profile_sim()
	var g_eff := G_TRACK * _car.gravity_multiplier
	var v := _zeros()
	var ds := _zeros()
	var grade := _zeros()
	for i in _n:
		ds[i] = maxf(0.1, _line_point(i).distance_to(_line_point(i + 1)))
		grade[i] = _data.grades[i]   # + = uphill
	# Corner limit: v^2 |k| = u * (a0 + a2 v^2)  ->  v^2 = u a0 / (|k| - u a2). On a banked
	# road: v^2 |k| = u * banked(a0 + a2 v^2) = u * (a0 + a2 v^2 + b) / cos, with b the pull of
	# gravity down the banking (CarEnvelope.banked_lat; b = 0 and cos = 1 on a level road).
	var a0 := _a_lat_full(0.0) * lateral_usage
	var a2 := (_a_lat_full(10.0) * lateral_usage - a0) / 100.0
	for i in _n:
		var kk := 0.0
		var theta := INF
		for o in range(-3, 4):   # conservative: tightest curvature and least helpful bank nearby
			var j := (i + o + _n) % _n
			kk = maxf(kk, absf(_line_k[j]))
			theta = minf(theta, _bank_into(j, _line_k[j]))
		var b := _env.bank_pull(theta) * lateral_usage
		var den := kk * cos(theta) - a2
		v[i] = v_cap if den <= 1e-6 else minf(v_cap, sqrt(maxf(a0 + b, 0.2 * a0) / den))
	# Backward pass (braking), twice round the loop to settle the wrap.
	# Where the line curves enough that the steering input exceeds the drift guard, the
	# controller may only lift / feather the brake, so the profile only counts on that decel.
	var dec := _env.brake_at(0.0) * brake_usage
	var guard_v := drift_guard_kmh * 0.9 / Car.KMH
	for lap in 2:
		for j in range(_n - 1, -1, -1):
			var nxt := (j + 1) % _n
			var vn := v[nxt]
			var a := dec
			if vn > guard_v:
				var lat_full := _env.banked_lat(_a_lat_full(vn), _bank_into(j, _line_k[j]))
				var steer_frac := absf(_line_k[j]) * vn * vn / lat_full * steer_gain
				if steer_frac > drift_guard_steer * 0.85:
					a = _env.coast_at(vn) + _env.brake_at(vn) * 0.08
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

# ---------------------------------------------------------------- simulation car
## Vertical curvature of the road along s (1/m): + in a dip (the car is pressed down), - over
## a crest (it goes light). From the grades, lightly smoothed.
func _vertical_curvature() -> PackedFloat32Array:
	var raw := _zeros()
	for i in _n:
		var a := atan(_data.grades[(i - 2 + _n) % _n])
		var b := atan(_data.grades[(i + 2) % _n])
		raw[i] = (b - a) / (4.0 * _data.step)
	var kv := _zeros()
	for i in _n:
		var sum := 0.0
		for o in range(-3, 4):
			sum += raw[(i + o + _n) % _n]
		kv[i] = sum / 7.0
	return kv

## Share of the longitudinal grip left when `share` (0..1) of the lateral grip is in use.
func _long_room(share: float, power: float) -> float:
	var p := maxf(power, 0.5)
	return pow(maxf(0.0, 1.0 - pow(clampf(share, 0.0, 1.0), p)), 1.0 / p)

## Speed profile for the simulation car, from its measured envelope. See the class comment.
func _speed_profile_sim() -> PackedFloat32Array:
	var line_kv := _vertical_curvature()
	var v := _zeros()
	var ds := _zeros()
	for i in _n:
		ds[i] = maxf(0.1, _line_point(i).distance_to(_line_point(i + 1)))
	var lu := clampf(lateral_usage * sim_lateral_scale, 0.1, 1.0)
	var bu := clampf(brake_usage * sim_brake_scale, 0.1, 1.0)
	var mu0 := _env.grip_mu()
	# Envelope tables on a 1 m/s grid: the passes below read them a few thousand times.
	var m := int(ceil(v_cap)) + 2
	var trc_g := PackedFloat32Array()
	trc_g.resize(m)
	var lat_g := PackedFloat32Array()
	var brk_g := PackedFloat32Array()
	var acc_g := PackedFloat32Array()
	var cst_g := PackedFloat32Array()
	var grp_g := PackedFloat32Array()
	grp_g.resize(m)
	lat_g.resize(m)
	brk_g.resize(m)
	acc_g.resize(m)
	cst_g.resize(m)
	for j in m:
		lat_g[j] = _env.lat_at(float(j))
		grp_g[j] = _env.grip_at(float(j))
		trc_g[j] = _env.traction_at(float(j)) * sim_traction_usage
		brk_g[j] = _env.brake_at(float(j))
		acc_g[j] = _env.accel_at(float(j))
		cst_g[j] = _env.coast_at(float(j))
	# Tightest curvature and sharpest crest near each point (conservative, as for the arcade car).
	var kmax := _zeros()
	var crest := _zeros()
	var bank := _zeros()    # towards the inside of the corner (rad), 0 on a level road
	for i in _n:
		var kk := 0.0
		var cc := 0.0
		var bb := INF
		for o in range(-3, 4):
			var j := (i + o + _n) % _n
			kk = maxf(kk, absf(_line_k[j]))
			cc = minf(cc, line_kv[j])
			bb = minf(bb, _bank_into(j, _line_k[j]))
		kmax[i] = kk
		crest[i] = cc
		bank[i] = bb       # the least helpful nearby, like the curvature and the crest
	# Corner limit: the highest speed up to which k v^2 stays within the usable share of
	# lat(v), less what a crest takes off the tyres. Scanned upwards: lat(v) is a table.
	var v_floor := 4.0
	for i in _n:
		var kk := kmax[i]
		v[i] = v_cap
		if kk < 1e-5:
			continue
		var prev_room := 1.0
		for j in range(int(v_floor), m):
			var vv := float(j)
			var room := lu * _env.banked_lat(maxf(0.3 * lat_g[j], lat_g[j] + mu0 * crest[i] * vv * vv), bank[i]) - kk * vv * vv
			if room < 0.0:
				v[i] = v_floor if j == int(v_floor) else minf(v_cap, vv - 1.0 + prev_room / (prev_room - room))
				break
			prev_room = room
	# Backward pass: braking inside the friction ellipse (what the corner uses of the grip is
	# not there to brake with), so the car trail-brakes down to the apex speed.
	for lap in 2:
		for j in range(_n - 1, -1, -1):
			var nxt := (j + 1) % _n
			var vn := v[nxt]
			var g := clampi(int(vn), 0, m - 2)
			var t := clampf(vn - float(g), 0.0, 1.0)
			var lat := lerpf(grp_g[g], grp_g[g + 1], t)
			var light := mu0 * crest[j] * vn * vn
			var share := clampf(absf(_line_k[j]) * vn * vn / maxf(lu * _env.banked_lat(maxf(0.3 * lat, lat + light), bank[j]), 0.1), 0.0, 1.0)
			var cst := lerpf(cst_g[g], cst_g[g + 1], t)
			var a := bu * maxf(1.0, lerpf(brk_g[g], brk_g[g + 1], t) + light) * _long_room(share, sim_trail_power)
			a = maxf(0.3, maxf(a, 0.7 * cst) + G_TRACK * _data.grades[j])
			v[j] = minf(v[j], sqrt(vn * vn + 2.0 * a * ds[j]))
	# Forward pass: traction inside the same ellipse, then the engine.
	for lap in 2:
		for j in _n:
			var nxt := (j + 1) % _n
			var vj := v[j]
			var g := clampi(int(vj), 0, m - 2)
			var t := clampf(vj - float(g), 0.0, 1.0)
			var lat := lerpf(grp_g[g], grp_g[g + 1], t)
			var light := mu0 * crest[j] * vj * vj
			var share := clampf(absf(_line_k[j]) * vj * vj / maxf(lu * _env.banked_lat(maxf(0.3 * lat, lat + light), bank[j]), 0.1), 0.0, 1.0)
			var grip := maxf(1.0, lerpf(trc_g[g], trc_g[g + 1], t) + 0.5 * light) * _long_room(share, sim_exit_power)
			var a := minf(lerpf(acc_g[g], acc_g[g + 1], t), grip) - G_TRACK * _data.grades[j]
			v[nxt] = minf(v[nxt], sqrt(maxf(v_floor * v_floor, vj * vj + 2.0 * a * ds[j])))
	predicted_lap_time = 0.0
	for j in _n:
		predicted_lap_time += ds[j] / maxf(0.5 * (v[j] + v[(j + 1) % _n]), 1.0)
	return v

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
	if _envelope_arrived():
		_data = null   # plan again from the measured envelope
	if _data == null:
		_setup()
		if _data == null:
			return
	_clock += delta
	if mode == Mode.PROVIDER:
		if _sim:
			_think_sim(delta)
		else:
			_think(delta)
		return
	_tick += 1
	var every := maxi(think_every, 1)
	if (_tick + think_phase) % every != 0:
		return   # the Car keeps the last override
	if _sim:
		_think_sim(delta * every)
	else:
		_think(delta * every)
	_car.set_input_override(_throttle, _brake, _steer)

## True when this driver still plans from a provisional envelope and the measured one is in.
func _envelope_arrived() -> bool:
	return _data != null and _env != null and _env.provisional and _env_rev != CarEnvelope.revision

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
	var steer_max := _steer_max(v, k_cmd)
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

## Direction of travel along the racing line at s, interpolated between its points (the plain
## segment direction steps by several degrees per point in a hairpin).
func _line_heading(s: float) -> Vector3:
	var u := _data.wrap_s(s) / _data.step
	var i := int(floorf(u)) % _n
	var f := u - floorf(u)
	var a := _line_pts[(i + 1) % _n] - _line_pts[(i - 1 + _n) % _n]
	var b := _line_pts[(i + 2) % _n] - _line_pts[i]
	return Vector3(lerpf(a.x, b.x, f), 0.0, lerpf(a.z, b.z, f)).normalized()

## One control step for the simulation car. See the class comment.
func _think_sim(delta: float) -> void:
	_before_think(delta)
	var pos := _car.global_position
	var s := _data.closest_s(pos, current_s)
	current_s = s
	var vel := _car.linear_velocity
	var v := vel.length()
	var xf := _car.global_transform
	var fwd := -xf.basis.z
	var v_long := vel.dot(fwd)
	var sf := _data.sample(s)
	var off := (pos - sf.origin).dot(sf.basis.x)
	var err := off - line_offset_at(s)        # + = car right of the line
	if _env.provisional and wait_for_envelope:
		# The envelope is being measured: wait on the spot (light brake: no reverse gear).
		_throttle = 0.0
		_brake = 0.3
		_steer = 0.0
		_update_stats(s, v, err, off)
		return
	var lu := clampf(lateral_usage * sim_lateral_scale, 0.1, 1.0)
	# What the tyres hold here: on a banked corner more than the flat-road envelope says.
	var lat := maxf(_env.banked_lat(_env.grip_at(v), _bank_into_at(s, line_curvature_at(s))), 0.5)
	# Lateral acceleration of the path itself (the yaw rate also counts the body rotating
	# into the corner, which uses no grip), lightly filtered.
	if _have_prev_vel and v > 2.0:
		var a_vec := (vel - _prev_vel) / maxf(delta, 1e-4)
		var left := Vector3.UP.cross(vel).normalized()
		_a_lat = lerpf(_a_lat, a_vec.dot(left), clampf(delta / 0.04, 0.0, 1.0))
	else:
		_a_lat = 0.0
	_prev_vel = vel
	_have_prev_vel = true
	var yaw := _car.angular_velocity.dot(xf.basis.y)      # + = turning left
	var beta := atan2(vel.dot(xf.basis.x), maxf(absf(v_long), 1.0)) if v > 3.0 else 0.0

	# ---- steering: curvature feed-forward + look-ahead feedback on lateral and heading error
	var k_here := line_curvature_at(s)
	var k_ff := line_curvature_at(s + v * sim_curvature_preview)
	var bank_here := _bank_into_at(s, k_here)
	var head := _line_heading(s)
	var e_psi := Vector3(fwd.x, 0.0, fwd.z).signed_angle_to(head, Vector3.UP)   # + = line is to the left
	# Body slip the corner itself produces (nose in at speed, out when slow): only the excess
	# is a slide, and that part of the heading error turns into opposite lock.
	var share_line := _tyre_share(v, k_here, bank_here)
	var beta_ref := signf(k_here) * (_env.slip_rear_at(v) * share_line - _env.cg_to_rear * absf(k_here))
	var slide := beta - beta_ref
	var e_head := e_psi + (1.0 - sim_slide_gain) * beta + sim_slide_gain * beta_ref
	var ld := clampf(sim_lookahead_base + v * sim_lookahead_time, sim_lookahead_base, sim_lookahead_max)
	var k_cmd := k_ff + 2.0 / (ld * ld) * clampf(err, -4.0, 4.0) + 2.0 / ld * clampf(e_head, -0.6, 0.6)
	if v > 10.0:
		# (The yaw rate is about the car's own vertical: on a banked road cos(bank) of the turn.)
		k_cmd -= sim_yaw_gain * clampf(yaw / v - k_here * cos(bank_here), -0.02, 0.02)
		k_cmd += sim_path_gain * clampf(k_cmd - _a_lat / (v * v), -0.01, 0.01)
	var want_steer := -signf(k_cmd) * _sim_steer_for(v, k_cmd, _bank_into_at(s, k_cmd))
	# Understeer: more lock on front tyres already past their limit only scrubs speed.
	var front_slip := 0.5 * (absf(_car.wheels[0].slip_angle) + absf(_car.wheels[1].slip_angle))
	if v > 8.0 and front_slip > 1.3 * maxf(_env.slip_front_at(v), 0.5 * _env.peak_slip_angle) \
			and signf(want_steer) == signf(_steer) and absf(want_steer) > absf(_steer):
		want_steer = _steer
	_steer = clampf(move_toward(_steer, want_steer, sim_steer_rate * delta), -1.0, 1.0)

	# ---- pedals: wanted acceleration from the profile's slope and the speed error
	var sp := s + v * speed_preview_time
	var v_t := minf(target_speed_at(s), target_speed_at(sp)) * speed_scale
	var d := maxf(4.0, v * 0.25)
	var v_a := target_speed_at(sp) * speed_scale
	var v_b := target_speed_at(sp + d) * speed_scale
	var a_ff := (v_b * v_b - v_a * v_a) / (2.0 * d)
	if a_ff < 0.0:
		# Below the braking curve there is nothing to brake for yet: carry on until it is met.
		a_ff *= clampf(1.0 - (v_t - v_long) / 2.5, 0.0, 1.0)
	var a_want := a_ff + sim_speed_gain * (v_t - v_long)
	a_want += G_TRACK * _data.grade_at(s)     # the pedals also carry the car up the slope
	var coast := _env.coast_at(v)
	var acc := maxf(_env.accel_at(v), 0.2)
	var brk := maxf(_env.brake_at(v), 2.0)
	# Friction ellipse at the lateral acceleration of the moment (measured and commanded).
	var share := clampf(maxf(absf(_a_lat), absf(k_cmd) * v * v) / (0.5 * (1.0 + lu) * lat), 0.0, 1.0)
	var room := _long_room(share, sim_exit_power)
	var trail_room := _long_room(share, sim_trail_power)
	var hold := coast / (acc + coast) * _env.throttle_pedal_at(v)   # pedal that holds the speed
	# Engine braking acts on the driven wheels alone: while cornering off the brakes the
	# throttle stays at least neutral (no torque either way at the rear tyres); any slowing
	# down beyond the air's drag is left to the brakes, which share it front to rear.
	var cornering := clampf((share - 0.25) / 0.35, 0.0, 1.0)
	var engine := _env.engine_brake_at(v)
	var coast_now := coast - engine * cornering
	var thr_want := 0.0
	var brk_want := 0.0
	if a_want < -coast_now - 0.4:
		brk_want = (-a_want - coast_now) / maxf(brk - coast, 1.0) * _env.brake_pedal_at(v)
	else:
		thr_want = maxf(0.0, (a_want + coast) / (acc + coast)) * _env.throttle_pedal_at(v)
		thr_want = maxf(thr_want, engine / (acc + coast) * _env.throttle_pedal_at(v) * cornering)
	var grip_acc := _env.traction_at(v) * sim_traction_usage * room
	thr_want = minf(thr_want, maxf(hold * 1.3, (grip_acc + coast) / (acc + coast) * _env.throttle_pedal_at(v)))
	# Arriving too fast for the corner: the brakes come first, even at the price of the line.
	var over := clampf((v_long - 1.03 * v_t) / maxf(0.08 * v_t, 0.5), 0.0, 1.0)
	var brake_room := maxf(maxf(trail_room, 0.12), 0.6 * over)
	brk_want = minf(brk_want, _env.brake_pedal_at(v) * brake_room * 1.1)
	# A slide (rear tyres well past their limit, or the body far from where the corner puts
	# it): neutral throttle and no brake until it is caught; spun round: stop.
	var rear_slip := 0.5 * (absf(_car.wheels[2].slip_angle) + absf(_car.wheels[3].slip_angle))
	if v > 8.0 and (rear_slip > 1.6 * _env.peak_slip_angle or absf(slide) > 0.12):
		_slide_hold = 0.25
	_slide_hold = maxf(0.0, _slide_hold - delta)
	if _slide_hold > 0.0:
		thr_want = minf(thr_want, hold)
		brk_want = minf(brk_want, 0.08)
	if v > 5.0 and (absf(beta) > 1.0 or v_long < -1.0):
		thr_want = 0.0
		brk_want = 0.45
	if v < 2.0:
		brk_want = minf(brk_want, 0.4)   # the gearbox takes a hard brake at rest for reverse
	thr_want = minf(thr_want, throttle_cap)
	var slip_use := _env.peak_slip_ratio * CarEnvelope.SLIP_USE
	var thr_room := maxf(room, 0.3)
	var brk_room := maxf(brake_room, 0.3)
	_throttle = CarEnvelope.govern(thr_want, _throttle, CarEnvelope.spin_of(_car, thr_room), slip_use * thr_room, delta, 4.0)
	_brake = CarEnvelope.govern(brk_want, _brake, CarEnvelope.lock_of(_car, brk_room), slip_use * brk_room, delta, 6.0)

	# ---- gears: the automatic gearbox does it; act only if it clearly has not
	_shift_cool = maxf(0.0, _shift_cool - delta)
	if _shift_cool <= 0.0:
		var shift := CarEnvelope.shift_wanted(_car)
		if shift != 0:
			_car.sim.request_shift(shift)
			_shift_cool = 0.15

	diag[0] = k_cmd
	diag[1] = e_psi
	diag[2] = beta_ref
	diag[3] = a_want
	diag[4] = room
	diag[5] = 1.0 if _slide_hold > 0.0 else 0.0
	_update_stats(s, v, err, off)

## Share (0..1) of their grip the tyres use to hold curvature k at speed v on a road banked
## `theta` rad towards the inside of the turn. On a level road the envelope's share of the
## cornering limit; on the banking gravity does g sin of the cornering and the tyres carry
## a sin more than their flat-road load, all of which counts here (this is where the car is,
## not what the plan may lean on, see CarEnvelope.BANK_LOAD_USE).
func _tyre_share(v: float, k: float, theta: float) -> float:
	if theta == 0.0:
		return _env.lateral_share(v, k)
	var a := absf(k) * v * v
	var lat := maxf(_env.lat_at(v), 0.5)
	var tyres := maxf(a * cos(theta) - G_TRACK * sin(theta), 0.0)
	var hold := maxf(lat + _env.grip_mu() * (a * sin(theta) - G_TRACK * (1.0 - cos(theta))), 0.5 * lat)
	return clampf(tyres / hold, 0.0, 1.0)

## Steering input (0..1) that holds curvature k at speed v on a road banked `theta` rad towards
## the inside of the turn. The envelope's steering map is a flat-road one: an input for a
## share of the cornering limit, i.e. for a front wheel angle = wheelbase x curvature + the slip
## angles that share takes. On the banking the same curvature takes a smaller share (less
## slip angle) but the same wheelbase x curvature; read flat, the map would turn the car in
## far too much (2 m inside its line at 18 degrees). So: the input for the share the tyres
## really have, plus the wheel angle the curvature still needs beyond that share's own,
## through the steering aid's lock and its centre shaping.
func _sim_steer_for(v: float, k: float, theta: float) -> float:
	if theta == 0.0 or _car.sim == null or v < 5.0:
		return _env.steer_for(v, k)
	var k_flat := _tyre_share(v, k, theta) * maxf(_env.lat_at(v), 0.5) / (v * v)   # the flat-road turn of that share
	var u := _env.steer_for(v, k_flat)
	var aids := _car.sim.aids
	var c := clampf(_car.sim.spec.aid_steer_center_gain, 0.0, 1.0) if aids.steering_help else 1.0
	var norm := u * (c + (1.0 - c) * u)
	norm = clampf(norm + Car.WHEELBASE * (absf(k) * cos(theta) - k_flat) / maxf(aids.steer_lock, 0.01), 0.0, 1.0)
	if c > 0.999:
		return norm
	return (sqrt(c * c + 4.0 * (1.0 - c) * norm) - c) / (2.0 * (1.0 - c))

## The Car's own full lock at speed v for a turn of curvature k (+ = left): on a banked road it
## is larger towards the low side (Car.bank_pull, + = pulls left), exactly as the Car computes it.
func _steer_max(v: float, k: float = 0.0) -> float:
	var a_lat := G_TRACK * (_car.lateral_grip_g + _car.aero_grip_g * v * v)
	if v <= 1.0:
		return _car.max_steer_angle
	a_lat = maxf(a_lat + signf(k) * _car.bank_pull, 0.0)
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
