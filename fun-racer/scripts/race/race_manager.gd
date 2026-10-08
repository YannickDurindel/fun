class_name RaceManager
extends Node
## Trackmania-style race flow for a Track (lives in the Track's `Race` slot).
##   * 3-2-1-GO countdown with the car frozen (Car.simulate = false) on the grid.
##   * Checkpoints at every sector boundary plus evenly spaced extras (~450-550 m apart),
##     detected by the car's progression along s (closest_s with a hint, every physics tick).
##     All checkpoints must be passed in order, then crossing s = 0 completes the lap.
##   * Lap / split / sector times on the physics clock (crossings interpolated inside the tick).
##   * Respawn returns to the last checkpoint with the speed and heading recorded there.
##   * `restart` action (Delete / pad Back): back to the grid, new countdown, lap reset.
##   * Auto-respawn when fallen far below the road or upside down; wrong-way detection.
## Started by the race scene root via begin(car, grid_transform).

signal countdown_changed(step: int)   ## 3, 2, 1, then 0 = GO
signal race_started
signal race_restarted
## delta is vs the best lap's split at this checkpoint; has_delta false when there is none.
signal checkpoint_passed(index: int, time: float, delta: float, has_delta: bool)
## sector: 0-based; state: 0 = slower (yellow), 1 = session best (green), 2 = all-time best (purple).
signal sector_completed(sector: int, time: float, state: int)
signal lap_completed(lap: int, time: float, delta: float, has_delta: bool, is_best: bool)
signal lap_invalidated
signal wrong_way_changed(active: bool)
## Emitted once when the run ends: `target_laps` laps done (MODE_RACE) or end_session() called.
## See results() for the keys; more may be added (e.g. `standings` once there are opponents).
signal race_finished(results: Dictionary)

enum State { IDLE, COUNTDOWN, RACING, FINISHED }

const COUNTDOWN_STEP: float = 0.8
const MAX_TICK_JUMP: float = 50.0          ## s jumps above this (m/tick) never cross lines
const CHECKPOINT_SPACING: float = 500.0
const TIGHT_TURN_RADIUS: float = 40.0      ## keep checkpoints off hairpin apexes
const APEX_CLEARANCE: float = 60.0
const FALL_DEPTH: float = 30.0
const UPSIDE_DOWN_TIME: float = 2.0
const WRONG_WAY_TIME: float = 2.0
const WRONG_WAY_SPEED: float = 20.0 / 3.6
const GRID_ZONE: float = 30.0
const RESCAN_INTERVAL: int = 30            ## ticks between full-lap rescans when far off the road
const COAST_BRAKE: float = 0.3             ## gentle braking once the run is over
const COAST_STOP_SPEED: float = 1.5        ## m/s: below this the finished car is parked
const COAST_MAX_TIME: float = 25.0         ## s: parked wherever it is after this long

## Laps to complete before race_finished (0 = endless / time attack). Set from Game.config.
var target_laps: int = 0
## Lap times of this run, in order.
var lap_times: PackedFloat32Array = []
## Sector times of each completed lap of this run (one Array of floats per lap).
var lap_sectors: Array[Array] = []
## Best time per sector within this run (-1 = not set).
var run_sectors: PackedFloat32Array = []
## Best lap on record when this run started (-1 = none): what a new record has to beat.
var previous_best: float = -1.0
## Sum of the lap times once FINISHED (the clock shown when the run is over).
var finish_time: float = 0.0

@export var persist_best: bool = true
@export var countdown_enabled: bool = true

var state: State = State.IDLE
var car: Car
var track: Track
var data: TrackData

## Checkpoint distances along the lap (ascending, all in (0, length)). The finish is s = 0.
var checkpoints: PackedFloat32Array = []
## For each checkpoint: index of the sector it closes (0-based), or -1.
var checkpoint_sector: PackedInt32Array = []
var sector_count: int = 1

var race_time: float = 0.0       ## physics seconds since GO (never reset by respawns)
var lap_start_time: float = 0.0
var laps_completed: int = 0
var next_checkpoint: int = 0     ## == checkpoints.size() -> the finish line is next
var out_lap: bool = false        ## spawned mid-lap: the first lap does not count
var countdown_left: float = 0.0
var countdown_step: int = 0

var current_splits: PackedFloat32Array = []   ## lap time at each checkpoint passed this lap
var current_sectors: PackedFloat32Array = []  ## sector times this lap (filled as they close)
var last_lap: float = -1.0
var best_lap: float = -1.0
var best_splits: PackedFloat32Array = []      ## checkpoints + finish, from the best lap
var best_sectors: PackedFloat32Array = []     ## all-time best per sector (persisted)
var session_sectors: PackedFloat32Array = []  ## best per sector since the scene loaded

var wrong_way: bool = false
var s: float = 0.0               ## car's current distance along the lap

var _grid: Transform3D
var _cp_velocity: Vector3 = Vector3.ZERO
var _has_cp: bool = false
var _wrong_way_timer: float = 0.0
var _upside_timer: float = 0.0
var _respawn_gen: int = 0
var _rescan_cooldown: int = 0
var _coasting: bool = false      ## this manager holds the car's input override (run over)
var _coast_time: float = 0.0

func _enter_tree() -> void:
	# Joined before any _ready so UI can find the manager whatever the sibling order.
	add_to_group(&"race_manager")

func _ready() -> void:
	_register_restart_action()

static func _register_restart_action() -> void:
	if InputMap.has_action(&"restart"):
		return
	InputMap.add_action(&"restart")
	var k := InputEventKey.new()
	k.physical_keycode = KEY_DELETE
	InputMap.action_add_event(&"restart", k)
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_BACK
	InputMap.action_add_event(&"restart", b)

## Called by the race scene once the car sits on its grid slot.
func begin(p_car: Car, grid: Transform3D) -> void:
	car = p_car
	track = get_parent() as Track
	if track == null:
		track = get_tree().get_first_node_in_group(&"track") as Track
	data = track.data if track else null
	if car == null or data == null:
		return
	_grid = grid
	_build_checkpoints()
	if persist_best:
		_load_best()
	if not car.respawned.is_connected(_on_car_respawned):
		car.respawned.connect(_on_car_respawned)
	restart()

func _build_checkpoints() -> void:
	var bounds: Array[float] = []
	for b in data.sectors:
		if b > 0.5 and b < data.length - 0.5:
			bounds.append(b)
	bounds.sort()
	sector_count = bounds.size() + 1
	checkpoints.clear()
	checkpoint_sector.clear()
	var edges: Array[float] = [0.0]
	edges.append_array(bounds)
	edges.append(data.length)
	for k in edges.size() - 1:
		var a := edges[k]
		var b := edges[k + 1]
		var parts := maxi(1, roundi((b - a) / CHECKPOINT_SPACING))
		for p in range(1, parts):
			checkpoints.append(minf(_clear_of_hairpins(a + (b - a) * p / parts), b - APEX_CLEARANCE))
			checkpoint_sector.append(-1)
		if k < edges.size() - 2:
			checkpoints.append(b)
			checkpoint_sector.append(k)

## Moves an extra checkpoint past a tight corner's apex so a respawn never lands mid-hairpin.
func _clear_of_hairpins(cp: float) -> float:
	for t: Dictionary in data.turns:
		if float(t.get("min_radius", 999.0)) < TIGHT_TURN_RADIUS:
			var apex := float(t["s_apex"])
			if absf(cp - apex) < APEX_CLEARANCE:
				return apex + APEX_CLEARANCE
	return cp

## Full restart: grid, countdown, lap reset (best times are kept).
func restart() -> void:
	if car == null or data == null:
		return
	_respawn_gen += 1
	_release_car()
	state = State.COUNTDOWN
	race_time = 0.0
	lap_start_time = 0.0
	laps_completed = 0
	lap_times = PackedFloat32Array()
	lap_sectors = []
	run_sectors = PackedFloat32Array()
	previous_best = best_lap
	finish_time = 0.0
	last_lap = -1.0
	_has_cp = false
	_cp_velocity = Vector3.ZERO
	car.spawn_transform = _grid
	car.respawn()                    # snaps to the grid, zeroes velocities, emits respawned
	car.simulate = false             # frozen until GO
	s = data.closest_s(_grid.origin)
	# Grid (around start_s): standing-start lap 1 from GO. Just behind the line: the lap starts
	# at s = 0. Anywhere else (--spawn_s mid-lap): an out lap until the line is crossed.
	out_lap = data.delta_s(0.0, s) > 0.0 and absf(data.delta_s(data.start_s, s)) > GRID_ZONE
	_reset_lap_progress()
	_set_wrong_way(false)
	_upside_timer = 0.0
	countdown_left = COUNTDOWN_STEP * 3.0
	countdown_step = 3
	race_restarted.emit()
	if countdown_enabled and not Bootstrap.skip_countdown:
		countdown_changed.emit(3)
	else:
		start_now()

## Ends the countdown immediately (tests / no-countdown mode).
func start_now() -> void:
	if car == null:
		return
	state = State.RACING
	countdown_left = 0.0
	countdown_step = 0
	car.simulate = true
	countdown_changed.emit(0)
	race_started.emit()

func _reset_lap_progress() -> void:
	current_splits.clear()
	current_sectors.clear()
	next_checkpoint = 0
	if out_lap:
		# Checkpoints behind the spawn are already "missed": the first lap starts at s = 0.
		while next_checkpoint < checkpoints.size() and checkpoints[next_checkpoint] <= s:
			next_checkpoint += 1

func lap_time() -> float:
	if state == State.FINISHED:
		return finish_time
	return race_time - lap_start_time if state == State.RACING else 0.0

func is_finished() -> bool:
	return state == State.FINISHED

## Ends the run now with the laps done so far (time attack's "END SESSION").
func end_session() -> void:
	if state == State.RACING or state == State.COUNTDOWN:
		_finish()

## The run as a Dictionary (what race_finished carries):
##   track_id, track_name, mode, target_laps,
##   laps: Array[float], lap_sectors: Array of Array[float] (per lap), total: float,
##   best: float (-1 without a lap), best_lap_index: int (-1 without a lap),
##   sectors_best: Array[float] (best per sector in this run, -1 = none),
##   sectors_record: Array[float] (all-time best per sector),
##   previous_best: float (record before this run, -1 = none), is_record: bool.
func results() -> Dictionary:
	var laps: Array[float] = []
	var total := 0.0
	var best := -1.0
	var best_index := -1
	for i in lap_times.size():
		var lt := lap_times[i]
		laps.append(lt)
		total += lt
		if best < 0.0 or lt < best:
			best = lt
			best_index = i
	var sectors: Array[float] = []
	var record: Array[float] = []
	for i in sector_count:
		sectors.append(run_sectors[i] if i < run_sectors.size() else -1.0)
		record.append(best_sectors[i] if i < best_sectors.size() else -1.0)
	return {
		"track_id": track.track_id if track != null else "",
		"track_name": data.name if data != null else "",
		"mode": RaceConfig.MODE_RACE if target_laps > 0 else RaceConfig.MODE_TIME_ATTACK,
		"target_laps": target_laps,
		"laps": laps,
		"lap_sectors": lap_sectors.duplicate(true),
		"total": total,
		"best": best,
		"best_lap_index": best_index,
		"sectors_best": sectors,
		"sectors_record": record,
		"previous_best": previous_best,
		"is_record": best > 0.0 and (previous_best <= 0.0 or best < previous_best),
	}

func _finish() -> void:
	var was_frozen := state == State.COUNTDOWN
	state = State.FINISHED
	_respawn_gen += 1          # a pending checkpoint-speed restore must not fire now
	_set_wrong_way(false)
	var res := results()
	finish_time = float(res["total"])
	if car != null and car.simulate and not was_frozen:
		_coasting = true
		_coast_time = 0.0
		_upside_timer = 0.0
		car.set_input_override(0.0, COAST_BRAKE, 0.0)
	race_finished.emit(res)

## Freezes the finished car and leaves its published state at rest (audio, FX and HUD read it).
func _park() -> void:
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.simulate = false
	car.speed_kmh = 0.0
	car.throttle = 0.0
	car.brake_input = 0.0
	car.rpm = car.idle_rpm
	car.is_drifting = false
	for w in car.wheels:
		w.slip = 0.0

func _release_car() -> void:
	if _coasting and car != null:
		car.clear_input_override()
	_coasting = false

func _physics_process(delta: float) -> void:
	if car == null or data == null:
		return
	if Input.is_action_just_pressed(&"restart"):
		restart()
		return
	match state:
		State.COUNTDOWN:
			_tick_countdown(delta)
		State.RACING:
			_tick_race(delta)
		State.FINISHED:
			_tick_finished(delta)

## Run over: no lap counting. The car slows down along the road, then parks.
func _tick_finished(delta: float) -> void:
	if not _coasting or not car.simulate:
		return
	var pos := car.global_position
	s = data.closest_s(pos, s)
	_coast_time += delta
	if car.global_transform.basis.y.dot(Vector3.UP) < 0.0:
		_upside_timer += delta
	else:
		_upside_timer = 0.0
	if pos.y < data.position_at(s).y - FALL_DEPTH or _upside_timer > UPSIDE_DOWN_TIME:
		car.respawn()   # fell off / rolled over after the flag: back to the last checkpoint
		_park()
		return
	var speed := car.linear_velocity.length()
	if speed < COAST_STOP_SPEED or _coast_time > COAST_MAX_TIME:
		# Holding the brake at a standstill would engage reverse: park the car instead.
		_park()
		return
	var ahead := data.position_at(data.wrap_s(s + 12.0 + speed * 0.6))
	var local := car.global_transform.affine_inverse() * ahead
	var steer := clampf(atan2(local.x, -local.z) * 2.0, -1.0, 1.0)
	car.set_input_override(0.0, COAST_BRAKE, steer)

func _tick_countdown(delta: float) -> void:
	countdown_left -= delta
	var step := ceili(countdown_left / COUNTDOWN_STEP - 1e-6)
	if countdown_left <= 1e-6:
		start_now()
	elif step != countdown_step:
		countdown_step = step
		countdown_changed.emit(step)

func _tick_race(delta: float) -> void:
	var t0 := race_time
	race_time += delta
	var pos := car.global_position
	var new_s := data.closest_s(pos, s)
	if data.position_at(new_s).distance_to(pos) > 40.0:
		_rescan_cooldown -= 1
		if _rescan_cooldown <= 0:
			_rescan_cooldown = RESCAN_INTERVAL
			new_s = data.closest_s(pos)  # lost the hint (teleport / big jump): rescan the lap
	else:
		_rescan_cooldown = 0
	var d := data.delta_s(s, new_s)
	if d > 0.0 and d <= MAX_TICK_JUMP:
		_check_crossings(s, d, t0, delta)
	s = new_s
	_check_wrong_way(delta)
	_check_safety(delta, pos)

## Lines in (from, from + d] are crossed this tick, in order.
func _check_crossings(from: float, d: float, t0: float, delta: float) -> void:
	while true:
		var line := checkpoints[next_checkpoint] if next_checkpoint < checkpoints.size() else 0.0
		var ahead := fposmod(line - from, data.length)
		var crossed := ahead > 0.0 and ahead <= d
		if not crossed:
			# The finish can also be crossed with checkpoints still missing: invalid lap.
			var to_finish := fposmod(-from, data.length)
			if next_checkpoint < checkpoints.size() and to_finish > 0.0 and to_finish <= d:
				_finish_crossed(t0 + delta * to_finish / d)
			return
		var t := t0 + delta * ahead / d
		if next_checkpoint < checkpoints.size():
			_checkpoint_crossed(t)
		else:
			_finish_crossed(t)
			return

func _checkpoint_crossed(t: float) -> void:
	var i := next_checkpoint
	var lt := t - lap_start_time
	current_splits.append(lt)
	next_checkpoint += 1
	# Trackmania respawn point: the car's pose and velocity as it crossed.
	car.spawn_transform = car.global_transform
	_cp_velocity = car.linear_velocity
	_has_cp = true
	var has_delta := not out_lap and best_splits.size() == checkpoints.size() + 1
	checkpoint_passed.emit(i, lt, lt - best_splits[i] if has_delta else 0.0, has_delta)
	var sec := checkpoint_sector[i]
	if sec >= 0 and not out_lap:
		_close_sector(sec, lt, i)

## Closes sector `sec` at lap time lap_t; the previous boundary is searched in splits [0, upto).
func _close_sector(sec: int, lap_t: float, upto: int) -> void:
	var prev := 0.0   # sector 0 starts at the lap start
	for j in upto:
		if sec > 0 and checkpoint_sector[j] == sec - 1:
			prev = current_splits[j]
	var st := lap_t - prev
	while current_sectors.size() < sec:
		current_sectors.append(-1.0)
	current_sectors.append(st)
	while best_sectors.size() < sector_count:
		best_sectors.append(-1.0)
	while session_sectors.size() < sector_count:
		session_sectors.append(-1.0)
	var grade := 0
	if best_sectors[sec] < 0.0 or st < best_sectors[sec]:
		best_sectors[sec] = st
		grade = 2
		if persist_best:
			_save_best()
	elif session_sectors[sec] < 0.0 or st < session_sectors[sec]:
		grade = 1
	if session_sectors[sec] < 0.0 or st < session_sectors[sec]:
		session_sectors[sec] = st
	while run_sectors.size() < sector_count:
		run_sectors.append(-1.0)
	if run_sectors[sec] < 0.0 or st < run_sectors[sec]:
		run_sectors[sec] = st
	sector_completed.emit(sec, st, grade)

func _finish_crossed(t: float) -> void:
	var complete := next_checkpoint >= checkpoints.size() and not out_lap
	var lt := t - lap_start_time
	if complete:
		_close_sector(sector_count - 1, lt, checkpoints.size())
		current_splits.append(lt)
		laps_completed += 1
		last_lap = lt
		lap_times.append(lt)
		lap_sectors.append(Array(current_sectors))
		var has_delta := best_lap > 0.0
		var dlt := lt - best_lap if has_delta else 0.0
		var is_best := not has_delta or lt < best_lap
		if is_best:
			best_lap = lt
			best_splits = current_splits.duplicate()
			if persist_best:
				_save_best()
		lap_completed.emit(laps_completed, lt, dlt, has_delta, is_best)
		if target_laps > 0 and laps_completed >= target_laps:
			_finish()
			return
	elif not out_lap and next_checkpoint > 0:
		lap_invalidated.emit()   # crossed the line with checkpoints missing
	out_lap = false
	lap_start_time = t
	_reset_lap_progress()

func _check_wrong_way(delta: float) -> void:
	var along := car.linear_velocity.dot(data.tangent_at(s))
	if along < -WRONG_WAY_SPEED:
		_wrong_way_timer += delta
		if _wrong_way_timer > WRONG_WAY_TIME:
			_set_wrong_way(true)
	else:
		_wrong_way_timer = 0.0
		if along > WRONG_WAY_SPEED * 0.5:
			_set_wrong_way(false)

func _set_wrong_way(v: bool) -> void:
	if v == wrong_way:
		return
	wrong_way = v
	if not v:
		_wrong_way_timer = 0.0
	wrong_way_changed.emit(v)

func _check_safety(delta: float, pos: Vector3) -> void:
	if not car.simulate:
		return
	if car.global_transform.basis.y.dot(Vector3.UP) < 0.0:
		_upside_timer += delta
	else:
		_upside_timer = 0.0
	if pos.y < data.position_at(s).y - FALL_DEPTH or _upside_timer > UPSIDE_DOWN_TIME:
		_upside_timer = 0.0
		car.respawn()

## Any respawn (car's own action, safety, tests): resync progress, then give back the
## checkpoint velocity once the car's integrator has done its zero-velocity respawn tick.
func _on_car_respawned() -> void:
	_respawn_gen += 1
	_upside_timer = 0.0
	_set_wrong_way(false)
	if state != State.RACING:
		return
	s = data.closest_s(car.spawn_transform.origin)
	var gen := _respawn_gen
	var vel := _cp_velocity if _has_cp else Vector3.ZERO
	if vel == Vector3.ZERO:
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	if gen == _respawn_gen and is_instance_valid(car) and state == State.RACING:
		car.linear_velocity = vel

func clear_best() -> void:
	best_lap = -1.0
	best_splits.clear()
	best_sectors.clear()
	session_sectors.clear()

func _save_path() -> String:
	return "user://best_%s.json" % (track.track_id if track != null else "unknown")

func _save_best() -> void:
	if Bootstrap.autodrive:
		return   # the autopilot's laps are not the player's best
	var f := FileAccess.open(_save_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"track": data.name, "length": data.length, "checkpoints": Array(checkpoints),
		"best_lap": best_lap, "best_splits": Array(best_splits), "best_sectors": Array(best_sectors),
	}))

func _load_best() -> void:
	if not FileAccess.file_exists(_save_path()):
		return
	var f := FileAccess.open(_save_path(), FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text()) if f else null
	if not (d is Dictionary):
		return
	var dict: Dictionary = d
	# Only trust times recorded with the same checkpoint layout.
	var saved: Array = dict.get("checkpoints", [])
	if dict.get("track", "") != data.name or saved.size() != checkpoints.size():
		return
	for i in saved.size():
		if absf(float(saved[i]) - checkpoints[i]) > 0.01:
			return
	best_lap = float(dict.get("best_lap", -1.0))
	best_splits = PackedFloat32Array(dict.get("best_splits", []))
	best_sectors = PackedFloat32Array(dict.get("best_sectors", []))

## "-0.234" / "+0.120" (Trackmania delta format).
static func format_delta(dt: float) -> String:
	var ms := roundi(absf(dt) * 1000.0)
	@warning_ignore("integer_division")
	var txt := "%d.%03d" % [ms / 1000, ms % 1000]
	return ("-" if dt < 0.0 and ms > 0 else "+") + txt

## Trackmania colours: blue = faster, red = slower.
static func delta_color(dt: float) -> Color:
	return Color(0.25, 0.55, 1.0) if dt < 0.0 else Color(1.0, 0.25, 0.22)
