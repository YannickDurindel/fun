class_name SimTelemetry
extends Node
## Telemetry recorder for a simulation car. Add it under a Car (or use attach()); it samples
## `car.sim.state` on the physics clock into one preallocated buffer and writes CSV.
##
##     var rec := SimTelemetry.attach(car, 60.0, 120.0)   # 60 Hz, room for 120 s
##     ... drive ...
##     rec.write_csv("user://run.csv")
##
## Nothing is allocated per tick: a sample is one write per column into the buffer, in the
## order of BODY_COLUMNS then WHEEL_COLUMNS for each wheel (keep sample() in that order). When the
## buffer is full the recorder stops and sets `full`. Distance is integrated every tick,
## whatever the sample rate. It records nothing for an arcade car (car.sim == null).

const G: float = 9.81
const WHEEL_NAMES: PackedStringArray = ["fl", "fr", "rl", "rr"]
## Columns before the per-wheel blocks. Units are in the names; angles in degrees, forces in N.
const BODY_COLUMNS: PackedStringArray = [
	"time_s", "marker", "distance_m", "pos_x_m", "pos_z_m", "speed_kmh", "gear", "rpm",
	"throttle_in", "brake_in", "steer_in", "throttle", "brake", "steer_angle_deg",
	"accel_long_g", "accel_lat_g", "yaw_rate_dps", "body_slip_deg",
	"downforce_front_n", "downforce_rear_n", "drag_n", "drs_open", "ers_mj", "fuel_kg", "mass_kg",
]
## Per-wheel columns, written as <name>_<fl|fr|rl|rr>.
const WHEEL_COLUMNS: PackedStringArray = [
	"load_n", "slip_ratio", "slip_angle_deg", "fx_n", "fy_n", "tyre_temp_c", "brake_temp_c",
	"compression_mm", "wear",
]

## Samples per second. Rounded to a whole number of physics ticks per sample.
@export var rate_hz: float = 60.0
## Room reserved, in seconds of recording at rate_hz.
@export var max_seconds: float = 120.0
## Record as soon as the node is ready.
@export var autostart: bool = true

var car: Car
## A number the caller sets to tag the following samples (a manoeuvre id, a lap number...).
var marker: float = 0.0
var recording: bool = false
## True once the buffer filled up and recording stopped.
var full: bool = false
## Seconds and metres since start() (or clear()).
var time: float = 0.0
var distance: float = 0.0

var _columns: PackedStringArray = []
var _data: PackedFloat32Array = []
var _rows: int = 0
var _capacity: int = 0
var _every: int = 4
var _tick: int = 0
var _cursor: int = 0

## Creates a recorder under `car` and starts it.
static func attach(p_car: Car, p_rate_hz: float = 60.0, p_max_seconds: float = 120.0) -> SimTelemetry:
	var rec := SimTelemetry.new()
	rec.name = "SimTelemetry"
	rec.rate_hz = p_rate_hz
	rec.max_seconds = p_max_seconds
	p_car.add_child(rec)
	return rec

## Every column name, in file order.
static func all_columns() -> PackedStringArray:
	var out := PackedStringArray(BODY_COLUMNS)
	for w: String in WHEEL_NAMES:
		for c: String in WHEEL_COLUMNS:
			out.append("%s_%s" % [c, w])
	return out

func _ready() -> void:
	# After the car in the tick, so a sample reads the state the last integration left.
	process_physics_priority = 100
	if car == null:
		car = get_parent() as Car
	_columns = all_columns()
	_allocate()
	if autostart:
		start()
	else:
		set_physics_process(false)

func _allocate() -> void:
	var hz := float(Engine.physics_ticks_per_second)
	_every = maxi(1, roundi(hz / maxf(rate_hz, 0.001)))
	_capacity = maxi(1, ceili(max_seconds * hz / _every) + 1)
	_data.resize(_capacity * _columns.size())
	_rows = 0

## Starts (or resumes) recording. The buffer is kept; call clear() for a fresh run.
func start() -> void:
	recording = not full
	set_physics_process(recording)

func stop() -> void:
	recording = false
	set_physics_process(false)

## Empties the buffer and restarts the clock and the distance.
func clear() -> void:
	_rows = 0
	_tick = 0
	time = 0.0
	distance = 0.0
	full = false

## The rate actually used (the physics rate divided by a whole number).
func actual_rate_hz() -> float:
	return float(Engine.physics_ticks_per_second) / _every

func row_count() -> int:
	return _rows

func capacity() -> int:
	return _capacity

func columns() -> PackedStringArray:
	return _columns

func column_index(column: String) -> int:
	return _columns.find(column)

## One recorded value; NAN for an unknown column or row.
func value(row: int, column: String) -> float:
	var c := _columns.find(column)
	if c < 0 or row < 0 or row >= _rows:
		return NAN
	return _data[row * _columns.size() + c]

func _physics_process(delta: float) -> void:
	if car == null or car.sim == null:
		return
	time += delta
	distance += car.sim.state.speed * delta
	_tick += 1
	if _tick >= _every:
		_tick = 0
		sample()

## Appends one row now. Called by the physics clock; public for a manual sample.
func sample() -> void:
	if car == null or car.sim == null:
		return
	if _rows >= _capacity:
		full = true
		stop()
		return
	var s := car.sim.state
	_cursor = _rows * _columns.size()
	var pos := car.global_position
	_put(time)
	_put(marker)
	_put(distance)
	_put(pos.x)
	_put(pos.z)
	_put(s.speed * 3.6)
	_put(s.gear)
	_put(s.rpm)
	_put(s.in_throttle)
	_put(s.in_brake)
	_put(s.in_steer)
	_put(s.throttle)
	_put(s.brake)
	_put(rad_to_deg(s.steer_angle))
	_put(s.accel_long / G)
	_put(s.accel_lat / G)
	_put(rad_to_deg(s.yaw_rate))
	_put(rad_to_deg(s.body_slip))
	_put(s.downforce_front)
	_put(s.downforce_rear)
	_put(s.drag)
	_put(1.0 if s.drs_open else 0.0)
	_put(s.ers_energy * 1.0e-6)
	_put(s.fuel)
	_put(s.mass)
	for i in 4:
		_put(s.load[i])
		_put(s.slip_ratio[i])
		_put(rad_to_deg(s.slip_angle[i]))
		_put(s.tyre_fx[i])
		_put(s.tyre_fy[i])
		_put(s.tyre_temp[i])
		_put(s.brake_temp[i])
		_put(s.compression[i] * 1000.0)
		_put(s.tyre_wear[i])
	# A column added to the lists but not written here (or the reverse) would shift every
	# later value under the wrong name.
	assert(_cursor == (_rows + 1) * _columns.size(), "SimTelemetry: sample() and the column lists disagree")
	_rows += 1

## Writes the next cell of the row being sampled, in column order.
func _put(v: float) -> void:
	_data[_cursor] = v
	_cursor += 1

## Writes the header and every recorded row. Returns OK or the file error.
func write_csv(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_line(",".join(_columns))
	var n := _columns.size()
	var cells := PackedStringArray()
	cells.resize(n)
	for r in _rows:
		var k := r * n
		for c in n:
			cells[c] = String.num(_data[k + c], 4)
		f.store_line(",".join(cells))
	f.close()
	return OK
