extends Node3D
## Engine, tyre-screech and wind audio for the Car at `car_path`.
##   * Engine: real-time procedural synth (engine_synth.gd) streamed via AudioStreamGenerator.
##     Each _process tops the buffer up to `target_latency` seconds of queued audio (never more
##     than get_frames_available()), so pitch lags the car by ~target_latency and nothing spins
##     when the buffer isn't consumed (headless / Dummy driver).
##   * Screech + wind: seamless loops generated in code at startup (audio_loops.gd), driven by
##     volume_db / pitch_scale only.
## The engine's character follows the car's handling: the arcade car keeps its V12 screamer,
## the simulation car gets the turbo-hybrid V6 (lower, with whistle, shift cut, lift-off
## crackle and limiter stutter) over its own rev range, and its tyre screech comes from each
## wheel's real slip (wheelspin, lock-up, sliding) instead of the arcade drift flag.
## Players are non-positional (the camera is always near the car); this node still follows the
## car's position so positional children could be added later.

const EngineSynth := preload("res://scripts/audio/engine_synth.gd")
const AudioLoops := preload("res://scripts/audio/audio_loops.gd")
const TyreSlip := preload("res://scripts/fx/tyre_slip.gd")
## Simulation: patch sliding speed (m/s) at which one wheel screeches at full volume.
const SIM_SCREECH_FULL_SPEED: float = 12.0

@export var car_path: NodePath
## Synth mix rate (22050..48000; GDScript cost scales with it).
@export var mix_rate: float = 24000.0
## Generator ring buffer size; headroom for frame hitches.
@export var buffer_length: float = 0.15
## Audio kept queued ahead of playback. Lower = snappier pitch response, higher = safer vs underruns.
@export var target_latency: float = 0.05
@export var engine_volume_db: float = -3.0
@export var screech_volume_db: float = -7.0
@export var wind_volume_db: float = -9.0
## Cap on frames rendered in one _process (bounds cost of the first fill / hitches).
@export var max_fill_frames: int = 4096
## Silence after a respawn before the engine fades back in.
@export var respawn_mute_seconds: float = 0.3

## Read-only values for tests / debugging.
var engine_freq_hz: float:
	get:
		return _synth.freq_hz if _synth else 0.0
var smoothed_rpm: float:
	get:
		return _synth.smoothed_rpm if _synth else 0.0
var screech_gain: float:
	get:
		return _screech_gain
var wind_gain: float:
	get:
		return _wind_gain
var engine_gain: float:
	get:
		return _master
## Microseconds spent rendering + pushing the engine buffer in the most recent fill.
var last_fill_usec: int:
	get:
		return _last_fill_usec
var frames_pushed_total: int:
	get:
		return _frames_pushed
## Cylinders of the engine being synthesised: 12 (arcade) or 6 (simulation).
var engine_cylinders: int:
	get:
		return _synth.cylinders if _synth else 0
var screech_pitch: float:
	get:
		return _screech_player.pitch_scale if _screech_player else 1.0
## Upshifts heard so far (each one cuts the simulation engine for a moment).
var shift_cuts: int = 0

var _car: Car
var _synth: EngineSynth
var _engine_player: AudioStreamPlayer
var _screech_player: AudioStreamPlayer
var _wind_player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _screech_gain: float = 0.0
var _wind_gain: float = 0.0
var _master: float = 1.0
var _mute_timer: float = 0.0
var _last_fill_usec: int = 0
var _frames_pushed: int = 0
var _capacity: int = 0
var _v6: bool = false
var _last_gear: int = 0

func _ready() -> void:
	_car = get_node_or_null(car_path) as Car
	mix_rate = clampf(mix_rate, 22050.0, 48000.0)
	_synth = EngineSynth.new(mix_rate, 12)
	_engine_player = _make_player("EnginePlayer", &"Engine")
	_screech_player = _make_player("ScreechPlayer", &"FX")
	_wind_player = _make_player("WindPlayer", &"FX")

	var gen := AudioStreamGenerator.new()
	gen.mix_rate = mix_rate
	gen.buffer_length = buffer_length
	_engine_player.stream = gen
	_engine_player.volume_db = engine_volume_db
	_engine_player.play()
	_playback = _engine_player.get_stream_playback() as AudioStreamGeneratorPlayback

	_screech_player.stream = AudioLoops.make_screech()
	_screech_player.volume_db = -80.0
	_screech_player.play()
	_wind_player.stream = AudioLoops.make_wind()
	_wind_player.volume_db = -80.0
	_wind_player.play()

	if _car:
		_car.respawned.connect(_on_respawned)
		_apply_character()
		_synth.reset(_car.rpm, _car.throttle)
		_last_gear = _car.gear

## Picks the engine from the car's handling and keeps its rev range current (the power unit
## may move the limiter). The car's model is fixed once it is in the tree, so the switch
## happens at most once.
func _apply_character() -> void:
	var sim_car := _car != null and is_instance_valid(_car) and _car.sim != null and _car.sim.spec != null
	if sim_car:
		var spec := _car.sim.spec
		if not _v6:
			_v6 = true
			_synth.use_v6_turbo(spec.rpm_idle, spec.rpm_max)
		elif _synth.limiter_rpm != spec.rpm_max or _synth.rpm_norm_low != spec.rpm_idle:
			_synth.set_rev_range(spec.rpm_idle, spec.rpm_max)
	elif _v6:
		_v6 = false
		_synth.use_v12()

## Players go to the Engine / FX buses (default_bus_layout.tres) so the audio options can set
## their volumes; a bus that does not exist falls back to Master.
func _make_player(player_name: String, bus_name: StringName) -> AudioStreamPlayer:
	var p := get_node_or_null(player_name) as AudioStreamPlayer
	if p == null:
		p = AudioStreamPlayer.new()
		p.name = player_name
		add_child(p)
	p.bus = bus_name
	return p

func _process(delta: float) -> void:
	var has_car := _car != null and is_instance_valid(_car)
	var rpm := 0.0
	var throttle := 0.0
	var pedal := -1.0
	var speed := 0.0
	if has_car:
		global_position = _car.global_position
		rpm = _car.rpm
		throttle = _car.throttle
		speed = _car.speed_kmh
		_apply_character()
		if _v6:
			# The engine sounds like what reaches it (the throttle after traction control);
			# a lift-off is what the driver's foot does. In reverse the brake pedal drives.
			var st := _car.sim.state
			pedal = throttle
			if st != null:
				pedal = st.in_brake if _car.gear < 0 else st.in_throttle
				throttle = st.in_brake if _car.gear < 0 else st.throttle
			if _car.gear > _last_gear and _last_gear >= 1:
				_synth.shift_cut()
				shift_cuts += 1
		_last_gear = _car.gear

	# Master gain: muted briefly after respawn, then a soft fade-in.
	var master_target := 1.0 if has_car else 0.0
	if _mute_timer > 0.0:
		_mute_timer -= delta
		master_target = 0.0
	var k := 1.0 - exp(-delta / (0.02 if master_target < _master else 0.12))
	_master += (master_target - _master) * k

	_synth.update(delta, rpm, throttle, pedal)
	_synth.master = _master
	_fill_engine()

	_update_screech(delta, has_car, speed)
	_update_wind(delta, speed)

func _fill_engine() -> void:
	if _playback == null:
		return
	var available := _playback.get_frames_available()
	# The largest free space ever seen is the ring capacity (it starts empty).
	_capacity = maxi(_capacity, available)
	var queued := _capacity - available
	var frames := mini(mini(available, max_fill_frames), int(target_latency * mix_rate) - queued)
	if frames <= 0:
		return
	var t0 := Time.get_ticks_usec()
	_playback.push_buffer(_synth.render(frames))
	_last_fill_usec = Time.get_ticks_usec() - t0
	_frames_pushed += frames

func _update_screech(delta: float, has_car: bool, speed: float) -> void:
	if has_car and _car.sim != null:
		_update_screech_simulation(delta, speed)
		return
	var target := 0.0
	var max_slip := 0.0
	if has_car:
		for w: WheelState in _car.wheels:
			if w != null and w.contact:
				max_slip = maxf(max_slip, w.slip)
		var slip_term := smoothstep(0.3, 0.85, max_slip)
		var drift_term := (0.65 + 0.35 * max_slip) if (_car.is_drifting and _car.is_grounded) else 0.0
		var speed_term := smoothstep(4.0, 50.0, speed) * (0.75 + 0.25 * clampf(speed / 250.0, 0.0, 1.0))
		target = maxf(slip_term, drift_term) * speed_term * _master
	_set_screech(delta, target, 0.92 + 0.14 * max_slip + 0.1 * clampf(speed / 300.0, 0.0, 1.0))

## Eases the screech towards `target` (quick attack, slower release) and sets its pitch.
func _set_screech(delta: float, target: float, pitch: float) -> void:
	var tau := 0.05 if target > _screech_gain else 0.14
	_screech_gain += (target - _screech_gain) * (1.0 - exp(-delta / tau))
	if _screech_gain < 1e-4 and target == 0.0:
		_screech_gain = 0.0
	_screech_player.volume_db = screech_volume_db + linear_to_db(maxf(_screech_gain, 1e-4))
	_screech_player.pitch_scale = pitch

## Simulation car: the loudest wheel sets the screech. A locked tyre howls lower, a spinning
## one sings higher; volume follows how hard and how fast the patch rubs.
func _update_screech_simulation(delta: float, speed: float) -> void:
	var loudest := 0.0
	var lock_part := 0.0
	var spin_part := 0.0
	for i in mini(4, _car.wheels.size()):
		var k := TyreSlip.strength(_car, i)
		if k <= 0.0:
			continue
		k *= clampf(TyreSlip.sliding_speed(_car, i) / SIM_SCREECH_FULL_SPEED, 0.0, 1.0)
		if k > loudest:
			loudest = k
			lock_part = TyreSlip.lock(_car, i)
			spin_part = TyreSlip.spin(_car, i)
	_set_screech(delta, smoothstep(0.05, 0.7, loudest) * _master,
			0.92 + 0.14 * loudest + 0.1 * clampf(speed / 300.0, 0.0, 1.0) - 0.14 * lock_part + 0.10 * spin_part)

func _update_wind(delta: float, speed: float) -> void:
	var s := clampf(speed / 320.0, 0.0, 1.0)
	var target := pow(s, 1.5) * _master
	_wind_gain += (target - _wind_gain) * (1.0 - exp(-delta / 0.2))
	_wind_player.volume_db = wind_volume_db + linear_to_db(maxf(_wind_gain, 1e-4))
	# Raising pitch_scale shifts the low-passed noise spectrum up: the cutoff rises with speed.
	_wind_player.pitch_scale = 0.45 + 1.6 * s

func _on_respawned() -> void:
	_mute_timer = respawn_mute_seconds
	_screech_gain = 0.0
	# respawned is emitted before the car republishes rpm, so snap to idle; the engine then
	# slews to the car's new rpm while still muted.
	_synth.reset(0.0, 0.0)
	_last_gear = 0
