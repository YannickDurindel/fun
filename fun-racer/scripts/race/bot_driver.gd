class_name BotDriver
extends Autopilot
## One AI opponent's brain: an Autopilot in DIRECT mode (it drives its own Car through
## Car.set_input_override) with a difficulty-dependent pace, a personal line and, on Easy,
## the occasional small mistake. Also keeps the bot's race progress and puts it back on the
## road when it is stuck.
##
## Far from the player a bot goes "on rails" (set_on_rails): its Car stops simulating (the
## raycast physics at 240 Hz is most of a bot's cost) and the driver simply moves it along its
## line at the speed the profile allows, with the same acceleration, braking margin, pace
## scale and throttle ceiling. Back near the player it is handed to the physics again, at speed.
##
## Pace (see PACE): the speed profile is built per difficulty (lateral grip usage and braking
## margin; cached and shared by all bots of that difficulty), then every bot gets a seeded
## personal `speed_scale`, throttle ceiling and lateral line shift so the field spreads out
## instead of driving in single file.
##
## Either handling model: the pace settings scale the car's CarEnvelope (see Autopilot), so a
## simulation bot uses the same fractions of the simulation car's measured limits, and drives
## it with the Autopilot's simulation controller. Bots never wait for a measurement: if the
## envelope is still being measured when the race starts they set off on the provisional
## (conservative) one and switch when it arrives.

const EASY := 0
const MEDIUM := 1
const HARD := 2

## Per difficulty: lateral = fraction of the full-lock lateral acceleration used in corners,
## brake = fraction of the brake deceleration used to place braking points, throttle = pedal
## ceiling, scale = target-speed multiplier (best bot .. slowest bot), shift = max |line shift|
## (m), mistakes = mean seconds between small mistakes (0 = never).
## Measured flying laps on the Red Bull Ring, 7 bots (the Autopilot's own best is 1:16.72):
##   Easy 1:26.9-1:27.8 (+13.3..14.4 %), Medium 1:21.1-1:21.9 (+5.7..6.8 %),
##   Hard 1:17.5-1:18.2 (+1.0..1.9 %).
## The same settings on the simulation car (skeleton parts, 3 bots; the Autopilot does 1:20.0):
##   Easy 1:37.3-1:38.5, Medium 1:28.9-1:29.7, Hard 1:22.0-1:22.2.
const PACE: Array[Dictionary] = [
	{"lateral": 0.66, "brake": 0.60, "throttle": 0.86, "scale": Vector2(0.985, 0.965), "shift": 1.6, "mistakes": 14.0},
	{"lateral": 0.77, "brake": 0.72, "throttle": 0.94, "scale": Vector2(0.995, 0.98), "shift": 1.2, "mistakes": 0.0},
	{"lateral": 0.88, "brake": 0.86, "throttle": 1.0, "scale": Vector2(0.998, 0.986), "shift": 0.5, "mistakes": 0.0},
]

const STUCK_SPEED: float = 2.0          ## m/s: slower than this counts as not moving
const STUCK_TIME: float = 3.0           ## s barely moving / off the road before a respawn
const UPSIDE_DOWN_TIME: float = 2.0
const FALL_DEPTH: float = 30.0          ## m below the road = fallen off the world
const OFF_ROAD_MARGIN: float = 6.0      ## m beyond the road edge that counts as off-track
const MISTAKE_WIDE: float = 1.5         ## m of extra line shift in a "wide exit"
const MISTAKE_WIDE_OVERRUN: float = 0.6 ## m past the racing-line bound a wide exit may reach
const MISTAKE_LIFT_THROTTLE: float = 0.3
## On rails the car covers this much more ground than its profile speed says: the simulated
## car beats the profile by about that much (measured: rails laps were 1.6-2.0 % slower), so
## a bot keeps the same lap time whichever way it is moved.
const RAIL_GAIN: float = 1.018
## The simulation car does not quite reach its profile out of the corners (measured: laps on
## rails at the profile's speed were 3 % quicker than simulated ones), hence a gain below 1.
const RAIL_GAIN_SIM: float = 0.97

var difficulty: int = MEDIUM
var bot_index: int = 0
## Distance raced, as laps * track length + s (the finish line is s = 0). Starts at the grid s.
var progress: float = 0.0
var respawns: int = 0
## True while the car is moved along its line instead of simulated.
var on_rails: bool = false
## On rails: move the car every physics tick (smooth on screen) or only on think ticks
## (cheaper; for cars the camera cannot see).
var rail_smooth: bool = true
## Profile speed on rails (m/s); the car moves at rail_speed * RAIL_GAIN, see speed().
var rail_speed: float = 0.0

var _rng := RandomNumberGenerator.new()
var _base_shift: float = 0.0
var _base_throttle: float = 1.0
var _mistake_gap: float = 0.0     ## mean s between mistakes (0 = none)
var _mistake_in: float = 0.0      ## s until the next mistake
var _mistake_left: float = 0.0    ## s the current mistake still lasts
var _mistake_shift: float = 0.0   ## line shift target of the current mistake
var _mistake_lift: bool = false
var _shift_now: float = 0.0
var _stuck: float = 0.0
var _upside: float = 0.0
var _progress_s: float = -1.0
var _rail_s: float = 0.0
var _rail_lateral_error: float = 0.0   ## m off its line when it went on rails; eased out
var _respawn_tick: int = -1000

## Pace settings of a difficulty (clamped to EASY..HARD).
static func pace_of(p_difficulty: int) -> Dictionary:
	return PACE[clampi(p_difficulty, EASY, HARD)]

## Sets the bot up. `index` (0-based) and `p_seed` make its personal variation deterministic.
func configure(p_car: Car, p_track: Track, p_difficulty: int, index: int, p_seed: int = 0) -> void:
	mode = Mode.DIRECT
	collect_stats = false
	wait_for_envelope = false
	difficulty = clampi(p_difficulty, EASY, HARD)
	bot_index = index
	set_car(p_car)
	track = p_track
	var p := pace_of(difficulty)
	lateral_usage = p["lateral"]
	brake_usage = p["brake"]
	_rng.seed = hash([p_seed, index, difficulty])
	var spread: Vector2 = p["scale"]
	# Field spread: the first bots are the quickest, with a little seeded noise on top.
	var rank := clampf(index / 6.0 + _rng.randf_range(-0.08, 0.08), 0.0, 1.0)
	speed_scale = lerpf(spread.x, spread.y, rank)
	_base_throttle = clampf(float(p["throttle"]) - _rng.randf_range(0.0, 0.03), 0.3, 1.0)
	throttle_cap = _base_throttle
	# Alternate sides, growing outwards, so neighbours on the grid take different lines.
	var side := -1.0 if index % 2 == 0 else 1.0
	_base_shift = side * float(p["shift"]) * (0.35 + 0.65 * _rng.randf())
	_shift_now = _base_shift
	line_shift = _base_shift
	_mistake_gap = p["mistakes"]
	_schedule_mistake()

## Back to the start of a race: `grid_progress` is the bot's grid slot as race progress
## (laps * length + s; negative for a slot behind the finish line).
func reset_run(grid_progress: float) -> void:
	on_rails = false
	if _car != null:
		_car.freeze = false
	rail_speed = 0.0
	_respawn_tick = -1000
	_tick = 0
	progress = grid_progress
	var grid_s := fposmod(grid_progress, _track.data.length) if _track != null and _track.data != null else grid_progress
	_progress_s = grid_s
	current_s = grid_s   # after the Car's respawn (which clears it): keeps closest_s local
	_stuck = 0.0
	_upside = 0.0
	_mistake_left = 0.0
	_mistake_lift = false
	_shift_now = _base_shift
	line_shift = _base_shift
	line_shift_overrun = 0.0
	throttle_cap = _base_throttle
	_throttle = 0.0
	_brake = 0.0
	_steer = 0.0
	reset_stats()
	if _car != null:
		_car.set_input_override(0.0, 0.0, 0.0)

func is_mistaking() -> bool:
	return _mistake_left > 0.0

func _schedule_mistake() -> void:
	_mistake_in = _rng.randf_range(0.5, 1.5) * _mistake_gap if _mistake_gap > 0.0 else INF

func _before_think(dt: float) -> void:
	_track_progress()
	_check_stuck(dt)
	_update_mistake(dt)

func _track_progress() -> void:
	if current_s < 0.0 or _data == null:
		return
	if _progress_s >= 0.0:
		var d := _data.delta_s(_progress_s, current_s)
		if absf(d) < 50.0:
			progress += d
	_progress_s = current_s

func _update_mistake(dt: float) -> void:
	if _mistake_left > 0.0:
		_mistake_left -= dt
		if _mistake_left <= 0.0:
			_mistake_lift = false
			_mistake_shift = 0.0
			_schedule_mistake()
	elif _mistake_gap > 0.0 and current_s >= 0.0:
		_mistake_in -= dt
		if _mistake_in <= 0.0:
			_start_mistake()
	throttle_cap = MISTAKE_LIFT_THROTTLE if _mistake_lift else _base_throttle
	# The line moves over smoothly (about 2 m/s), never as a step.
	_shift_now = move_toward(_shift_now, _base_shift + _mistake_shift, 2.0 * dt)
	line_shift = _shift_now
	# The overrun allowance stays until the line has eased back, so it never snaps inwards.
	line_shift_overrun = MISTAKE_WIDE_OVERRUN if absf(_shift_now - _base_shift) > 0.01 else 0.0

## In a corner: run wide (the line drifts to the outside). On a straight: a lazy throttle.
func _start_mistake() -> void:
	var k := line_curvature_at(current_s + 20.0)
	if absf(k) > 1.0 / 200.0:
		_mistake_shift = MISTAKE_WIDE * (1.0 if k > 0.0 else -1.0)   # k > 0 turns left: outside = right
		_mistake_left = _rng.randf_range(1.2, 2.0)
		_mistake_lift = _rng.randf() < 0.5                             # and late on the throttle
	else:
		_mistake_shift = 0.0
		_mistake_lift = true
		_mistake_left = _rng.randf_range(0.5, 0.9)

func _check_stuck(dt: float) -> void:
	if current_s < 0.0 or _data == null:
		return
	var pos := _car.global_position
	var centre := _data.sample(current_s)
	var off := absf((pos - centre.origin).dot(centre.basis.x))
	var off_road := off > _data.width_at(current_s) * 0.5 + OFF_ROAD_MARGIN
	if _car.linear_velocity.length() < STUCK_SPEED or off_road:
		_stuck += dt
	else:
		_stuck = 0.0
	if _car.global_transform.basis.y.dot(Vector3.UP) < 0.0:
		_upside += dt
	else:
		_upside = 0.0
	if _stuck > STUCK_TIME or _upside > UPSIDE_DOWN_TIME or pos.y < centre.origin.y - FALL_DEPTH:
		respawn_on_track()

## Puts the car back on the road at its last known s, on its own line, standing still.
func respawn_on_track() -> void:
	if _car == null or _track == null or _track.data == null:
		return
	var s := current_s if current_s >= 0.0 else maxf(_progress_s, 0.0)
	var lateral := line_offset_at(s) if _data != null else 0.0
	_stuck = 0.0
	_upside = 0.0
	respawns += 1
	_respawn_tick = _tick
	_car.spawn_transform = _track.spawn_transform(s, lateral)
	_car.respawn()   # emits respawned -> Autopilot forgets its s hint
	_progress_s = s
	current_s = s

# ================================================================ on rails
func _rail_gain() -> float:
	return RAIL_GAIN_SIM if _car != null and _car.sim != null else RAIL_GAIN

## Current speed (m/s), whichever way the car is moved.
func speed() -> float:
	return rail_speed * _rail_gain() if on_rails else (_car.linear_velocity.length() if _car != null else 0.0)

## Switches between the simulated Car and the cheap on-rails motion, keeping place and speed.
## Only meant for bots nobody can see closely: the hand-over is not perfectly smooth.
func set_on_rails(rails: bool) -> void:
	if rails == on_rails or _car == null:
		return
	if rails:
		if not _car.simulate or not prepare() or current_s < 0.0:
			return   # frozen on the grid, or not driving yet
		if _tick - _respawn_tick < 4 * maxi(think_every, 1):
			return   # a respawn is still being applied by the Car's integrator
		_rail_s = current_s
		var centre := _data.sample(current_s)
		_rail_lateral_error = clampf((_car.global_position - centre.origin).dot(centre.basis.x)
				- line_offset_at(current_s), -3.0, 3.0)
		rail_speed = maxf(_car.forward_speed, 0.0) / _rail_gain()
		_car.simulate = false
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		# Static while on rails: the physics server stops testing it against the world.
		_car.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		_car.freeze = true
		on_rails = true
	else:
		var v := speed()
		on_rails = false
		_car.freeze = false
		var xf := _rail_transform()
		_car.global_transform = xf
		_car.linear_velocity = -xf.basis.z * v
		_car.angular_velocity = Vector3.ZERO
		if _car.sim != null:
			_car.sim.set_speed(v)   # wheels turning at road speed, in the right gear
		_car.forward_speed = v
		_car.speed_kmh = v * Car.KMH
		_car.simulate = true
		current_s = _rail_s
		_have_prev_err = false
		if _sim:
			# Neutral inputs until the next think: the last ones are from before the rails.
			_reset_sim_controller()
			_car.set_input_override(0.0, 0.0, 0.0)
		_stuck = 0.0
		_upside = 0.0

## On the bot's line, heading along it, wheels on the road.
func _rail_transform() -> Transform3D:
	var xf := _track.spawn_transform(_rail_s, line_offset_at(_rail_s) + _rail_lateral_error)
	xf.origin -= xf.basis.y * 0.05   # spawn_transform drops the car from 5 cm
	var forward := line_direction_at(_rail_s)
	var right := forward.cross(xf.basis.y)
	if right.length_squared() > 0.25:
		right = right.normalized()
		xf.basis = Basis(right, right.cross(forward).normalized(), -forward)
	return xf

func _physics_process(delta: float) -> void:
	if not on_rails:
		super(delta)
		return
	if _envelope_arrived():
		_setup()   # the measured envelope has arrived: the rails follow its profile
	_clock += delta
	_tick += 1
	var every := maxi(think_every, 1)
	var thinking := (_tick + think_phase) % every == 0
	if thinking:
		_rail_think(delta * every)
	_rail_s = _data.wrap_s(_rail_s + rail_speed * _rail_gain() * delta * line_s_rate_at(_rail_s))
	if thinking or rail_smooth:
		_car.global_transform = _rail_transform()

## Speed along the line: the same envelope the simulated car follows (profile * speed_scale,
## reached with the Car's acceleration under the throttle ceiling and its braking margin).
func _rail_think(dt: float) -> void:
	current_s = _rail_s
	_track_progress()
	_update_mistake(dt)
	var s := _rail_s
	var v := rail_speed
	var v_t := _target_speed(s, v)
	var slope := _g_eff() * _data.grade_at(s)
	var gain := _rail_gain()
	if v < v_t:
		v = minf(v_t, v + maxf(0.0, _accel_at(v) * throttle_cap - slope) * dt)
	else:
		v = maxf(v_t, v - maxf(1.0, _env.brake_at(v) * brake_usage + slope) * dt)
	rail_speed = v
	_rail_lateral_error = move_toward(_rail_lateral_error, 0.0, 1.5 * dt)
	if rail_smooth:
		for i in _car.wheels.size():   # seen: keep the wheels turning
			_car.wheels[i].spin_angle = fmod(_car.wheels[i].spin_angle + v * gain / _car.wheel_radius(i) * dt, TAU * 1000.0)
	_car.speed_kmh = v * gain * Car.KMH
	_car.forward_speed = v * gain
	_update_lap_timing(s, v > 0.5)
