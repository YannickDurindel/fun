class_name GhostRecorder
extends Node
## Records the player's current lap as a GhostData buffer and keeps the best one per track.
##   * Samples the car every `sample_ticks` physics ticks (30 Hz at 240 Hz physics), keyed by
##     the RaceManager's lap clock. A new buffer starts whenever a lap starts (GO, or the line).
##   * On lap_completed(is_best = true) the buffer becomes the track's ghost: `best_recorded`
##     is emitted and the lap is written to user://ghosts/<track_id>.ghost.
##   * Never kept: autopilot laps (Bootstrap.autodrive) and out laps. Nothing is written when
##     the RaceManager does not persist its best times (tests), unless `force_save` is set.
## Set up by the ghost system (ghost_player.gd) with setup(race).

## A lap that beat the best was recorded (saved to disk or not).
signal best_recorded(ghost: GhostData)

## Physics ticks between samples.
@export var sample_ticks: int = 8
## Save even when the RaceManager has persist_best off (tests with a temporary ghost folder).
var force_save: bool = false

var race: RaceManager
var buffer: GhostData        ## the lap being recorded, null when not recording
var last_saved_path: String = ""

var _tick: int = 0
var _stride: int = 8         ## current ticks per sample (doubles when the buffer fills up)
var _lap_start: float = -1.0
var _lap_recordable: bool = false

func setup(p_race: RaceManager) -> void:
	race = p_race
	if race == null:
		return
	race.race_started.connect(_on_race_started)
	race.race_restarted.connect(_on_race_restarted)
	race.lap_completed.connect(_on_lap_completed)
	if race.state == RaceManager.State.RACING:
		_begin_lap()

func is_recording() -> bool:
	return buffer != null

func _on_race_started() -> void:
	_begin_lap()

func _on_race_restarted() -> void:
	buffer = null

func _begin_lap() -> void:
	buffer = GhostData.new()
	buffer.track_id = race.track.track_id if race.track != null else ""
	buffer.track_length = race.data.length if race.data != null else 0.0
	_stride = maxi(1, sample_ticks)
	buffer.sample_interval = _stride / float(Engine.physics_ticks_per_second)
	_lap_start = race.lap_start_time
	_lap_recordable = not race.out_lap
	_tick = 0

func _physics_process(_delta: float) -> void:
	if race == null or race.state != RaceManager.State.RACING or not is_instance_valid(race.car):
		return
	if buffer == null or race.lap_start_time != _lap_start:
		_begin_lap()   # the line was crossed (lap completed or not): a new lap starts
	if _tick % _stride == 0:
		_sample()
	_tick += 1

func _sample() -> void:
	var car := race.car
	var xf := car.global_transform
	var steer := car.wheels[0].steer_angle if not car.wheels.is_empty() else 0.0
	buffer.add_sample(race.race_time - _lap_start, xf, car.linear_velocity.dot(-xf.basis.z), steer)
	if buffer.size() >= GhostData.MAX_SAMPLES - 1:
		# A very long lap: halve the rate instead of growing past the file budget.
		buffer.decimate()
		_stride *= 2
		_tick = 0

func _on_lap_completed(_lap: int, time: float, _delta: float, _has_delta: bool, is_best: bool) -> void:
	# Emitted from the RaceManager's tick; a new buffer only starts in our own tick, so
	# `buffer` (started at _lap_start) is still the lap that just ended.
	if buffer == null:
		return
	var lap := buffer
	buffer = null
	if not is_best or not _lap_recordable or Bootstrap.autodrive or lap.size() < 1:
		return
	if not is_instance_valid(race.car) or not GhostData.is_valid_id(lap.track_id):
		return
	# Close the lap with the pose at this tick (at or just past the line).
	var t_now := race.race_time - _lap_start
	if t_now > lap.duration():
		var xf := race.car.global_transform
		lap.add_sample(t_now, xf, race.car.linear_velocity.dot(-xf.basis.z), lap.steers[lap.size() - 1])
	if lap.size() < 2:
		return
	lap.lap_time = time
	lap.date = int(Time.get_unix_time_from_system())
	if race.persist_best or force_save:
		if lap.save():
			last_saved_path = GhostData.path_for(lap.track_id)
		else:
			push_warning("GhostRecorder: could not save the ghost for '%s'" % lap.track_id)
	best_recorded.emit(lap)
