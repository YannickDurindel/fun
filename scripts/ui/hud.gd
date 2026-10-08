extends Control
## Trackmania-style HUD: race timer (top centre), speedometer with RPM arc and
## gear (bottom right), input display (bottom left). Reads only the Car contract.
## Every group is authored at 1080p and scaled to the viewport height.

const RaceTimer := preload("res://scripts/ui/race_timer.gd")
const RpmGauge := preload("res://scripts/ui/rpm_gauge.gd")
const InputDisplay := preload("res://scripts/ui/input_display.gd")

const REF_HEIGHT: float = 1080.0
const MARGIN := Vector2(44.0, 34.0)
## Below this, an analog driver input does not count as "moving" for the clock.
const INPUT_THRESHOLD: float = 0.05
## Exponential smoothing rate for the displayed speed (1/s).
const SPEED_SMOOTH_RATE: float = 20.0
## The shown integer only changes once the smoothed value is this far from it,
## so the readout never flickers between two numbers.
const SPEED_HYSTERESIS: float = 0.55
const DRIFT_FADE_RATE: float = 8.0
const SHIFT_FLASH_HZ: float = 12.0

const COL_TIME_WAITING := Color(1, 1, 1, 0.55)
const COL_TIME_RUNNING := Color(1, 1, 1, 1)
const COL_GEAR := Color(1, 1, 1, 1)
const COL_GEAR_SHIFT := Color(1.0, 0.25, 0.18)

@export var car_path: NodePath

var timer: RaceTimer = RaceTimer.new()
var display_speed: float = 0.0
var shown_speed: int = 0

var _car: Car
var _shown_ms: int = -1
var _shown_gear: int = -999
var _shown_running: bool = true
var _drift_amount: float = 0.0
var _flash_clock: float = 0.0
var _shown_flash: bool = false
## Physics ticks left during which the car's telemetry is stale after a respawn
## (Car.respawn() returns before recomputing speed/rpm/gear on that tick).
var _respawn_hold: int = 0

@onready var _timer_group: Control = $TimerGroup
@onready var _time_label: Label = $TimerGroup/Time
@onready var _hint: Label = $Hint
@onready var _speedo: RpmGauge = $Speedo
@onready var _speed_label: Label = $Speedo/Speed
@onready var _gear_label: Label = $Speedo/Gear
@onready var _drift_label: Label = $Speedo/Drift
@onready var _inputs: InputDisplay = $Inputs

func _ready() -> void:
	_car = get_node_or_null(car_path) as Car
	if _car:
		_car.respawned.connect(_on_car_respawned)
	resized.connect(_layout)
	_layout()
	_refresh_timer_label()

func _on_car_respawned() -> void:
	timer.reset()
	_respawn_hold = 2
	display_speed = 0.0
	shown_speed = 0
	_speed_label.text = "0"
	_drift_amount = 0.0
	_speedo.drift = 0.0
	_speedo.value = 0.0
	_drift_label.modulate.a = 0.0
	_refresh_timer_label()

## True while the driver is giving any input (the clock starts on the first one).
## Uses the same Bootstrap source the car reads, so autodrive counts too; not the
## car's own fields, which a physics model may smooth or let decay after release.
func _has_driver_input() -> bool:
	return Bootstrap.get_throttle() > INPUT_THRESHOLD \
		or Bootstrap.get_brake() > INPUT_THRESHOLD \
		or absf(Bootstrap.get_steer()) > INPUT_THRESHOLD \
		or Input.is_action_pressed(&"steer_left") or Input.is_action_pressed(&"steer_right")

func _physics_process(delta: float) -> void:
	if _respawn_hold > 0:
		_respawn_hold -= 1
		if _respawn_hold == 1:
			return  # the respawn tick itself: the car has not moved, don't count it
	timer.step(delta, _has_driver_input())

func _process(delta: float) -> void:
	_refresh_timer_label()
	if not _car or _respawn_hold > 0:
		return
	# Speed: frame-rate independent exponential smoothing + hysteresis.
	var target := absf(_car.speed_kmh)
	display_speed = lerpf(display_speed, target, 1.0 - exp(-SPEED_SMOOTH_RATE * delta))
	if absf(display_speed - shown_speed) >= SPEED_HYSTERESIS:
		shown_speed = roundi(display_speed)
		_speed_label.text = str(shown_speed)
	# RPM arc + shift flash near the limiter.
	var rpm_frac := clampf(_car.rpm / Car.MAX_RPM, 0.0, 1.0)
	_speedo.value = rpm_frac
	_flash_clock = fmod(_flash_clock + delta * SHIFT_FLASH_HZ, 2.0)
	var flash := rpm_frac >= RpmGauge.SHIFT_FLASH_FROM and _flash_clock < 1.0
	_speedo.flash_on = flash
	# Gear (0 = neutral, negative = reverse).
	if _car.gear != _shown_gear:
		_shown_gear = _car.gear
		_gear_label.text = str(_car.gear) if _car.gear > 0 else ("R" if _car.gear < 0 else "N")
	if flash != _shown_flash:
		_shown_flash = flash
		_gear_label.add_theme_color_override(&"font_color", COL_GEAR_SHIFT if flash else COL_GEAR)
	# Drift indicator fades in/out.
	var drift_target := 1.0 if _car.is_drifting else 0.0
	_drift_amount = move_toward(_drift_amount, drift_target, DRIFT_FADE_RATE * delta)
	_speedo.drift = _drift_amount
	_drift_label.modulate.a = _drift_amount
	# Input display mirrors what the car actually receives.
	_inputs.accelerate = _car.throttle
	_inputs.brake = _car.brake_input
	_inputs.left = maxf(0.0, -_car.steer)
	_inputs.right = maxf(0.0, _car.steer)

func _refresh_timer_label() -> void:
	var ms := RaceTimer.to_ms(timer.elapsed)
	var running := timer.is_running()
	if ms == _shown_ms and running == _shown_running:
		return
	_shown_ms = ms
	if running != _shown_running:
		_shown_running = running
		_time_label.add_theme_color_override(&"font_color", COL_TIME_RUNNING if running else COL_TIME_WAITING)
	_time_label.text = RaceTimer.format_time(timer.elapsed)

## Race mode: a race panel owns timing, so the free-run clock and its hint are hidden.
func set_free_timer_visible(v: bool) -> void:
	_timer_group.visible = v
	_hint.visible = v

func get_time_text() -> String:
	return _time_label.text

func get_speed_text() -> String:
	return _speed_label.text

func _layout() -> void:
	var s := clampf(size.y / REF_HEIGHT, 0.4, 4.0)
	var sv := Vector2(s, s)
	var m := MARGIN * s
	_speedo.scale = sv
	_speedo.position = size - _speedo.size * s - m
	_timer_group.scale = sv
	_timer_group.position = Vector2((size.x - _timer_group.size.x * s) * 0.5, m.y * 0.8)
	_hint.scale = sv
	_hint.position = Vector2((size.x - _hint.size.x * s) * 0.5, _timer_group.position.y + (_timer_group.size.y + 6.0) * s)
	_inputs.scale = sv
	_inputs.position = Vector2(m.x, size.y - _inputs.size.y * s - m.y)
