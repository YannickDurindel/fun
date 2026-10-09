class_name CarEnvelope
extends RefCounted
## Performance envelope of a car: what it can do as functions of speed. The Autopilot (and so
## the bots) plan and drive from this object alone, whichever handling model the car runs.
##   lat_at(v)    highest steady lateral acceleration (m/s^2), steering lock included
##   grip_at(v)   the same without the lock: what the tyres can hold sideways
##   brake_at(v)  highest straight-line deceleration, drag included (m/s^2)
##   accel_at(v)  highest straight-line acceleration (m/s^2)
##   coast_at(v)  deceleration with both pedals released (m/s^2)
##
## Two kinds:
##   * ANALYTIC (arcade model): CarEnvelope.arcade(car, efficiency) evaluates the Car's tuning
##     values with the very expressions the Autopilot always used, so arcade laps are unchanged
##     to the bit. It reads the Car live: retunes carry over.
##   * MEASURED (simulation model): CarEnvelope.for_car(car). Hidden copies of the car drive
##     standard manoeuvres on a flat pad in a physics world of their own (measure()): a steering
##     ramp at each held speed, full-throttle runs through each speed, one stop from top speed.
##     Besides the limits the tables keep how the car is driven AT the limit: the steering
##     input for a given share of the cornering limit, the pedal positions that just reach the
##     traction / braking limit, and the tyre slip angles at the cornering limit.
##
## Where a measured envelope comes from, in this order:
##   1. memory (one per car spec for the whole run);
##   2. res://assets/car/envelopes/<spec>.json, written by tools/lap_grip_sweep.gd --envelope
##      and committed. It carries a key: a hash of the car spec's values and of the source of
##      every part script. If the key no longer matches, the file is stale and ignored;
##   3. user://envelope_<key>.json, written by step 4 on an earlier run;
##   4. a measurement in the background (about 5 simulated seconds, started at once). Until it
##      is ready for_car() returns a PROVISIONAL envelope of conservative constants; `revision`
##      changes when the real one arrives and the Autopilot then rebuilds its speed profile.
## So nobody has to remember to rerun the tool after a physics change: a stale file costs a
## few seconds once per machine, never a car planned from the wrong numbers. In an exported
## game the part sources cannot be read, and cannot have changed either: the file is trusted.

const VERSION: int = 4
const G: float = 9.81
const RES_DIR: String = "res://assets/car/envelopes/"
const SIM_SCRIPTS_DIR: String = "res://scripts/car/sim/"
const CAR_SCENE: String = "res://scenes/car/car.tscn"
## Besides every script of SIM_SCRIPTS_DIR, the files a measurement depends on: the Car, its
## scene (body, centre of mass, collision shape), the wheel contract and this very file.
const KEY_FILES: Array[String] = ["res://scripts/car/car.gd", "res://scripts/car/wheel_state.gd",
		"res://scenes/car/car.tscn", "res://scripts/race/car_envelope.gd"]

## Sample speeds (km/h). The first is a standstill: no cornering there by definition.
const SPEEDS_KMH: Array[float] = [0.0, 25.0, 40.0, 55.0, 70.0, 90.0, 110.0, 135.0, 160.0,
		190.0, 220.0, 250.0, 285.0, 320.0]
## Shares of the cornering limit at which the steering input is recorded.
const STEER_FRACS: Array[float] = [0.0, 0.25, 0.5, 0.75, 0.9, 1.0]
## Steering input at the cornering limit from which the car counts as limited by its lock.
const LOCK_LIMITED: float = 0.955
## Share of the tyres' peak slip ratio the pedal governors hold in a straight line.
const SLIP_USE: float = 0.95

const _HZ: int = 240
const _SETTLE_TICKS: int = 96
const _LAT_HOLD_TICKS: int = 72
const _LAT_RAMP_TICKS: int = 960
const _ACC_COAST_TICKS: int = 84
const _ACC_RUN_TICKS: int = 600
const _BRK_MAX_TICKS: int = 2160
const _MAX_TICKS: int = 2400

## Changes whenever a background measurement lands: holders of a provisional envelope ask again.
static var revision: int = 0
## Measurements run since the start (tests).
static var measurements: int = 0
static var _mem: Dictionary = {}        ## key -> CarEnvelope
static var _keys: Dictionary = {}       ## spec path -> key
static var _measuring: Dictionary = {}  ## key -> true
static var _stand_ins: Dictionary = {}  ## key -> provisional CarEnvelope, while none is known
static var _sources_readable: bool = true

var analytic: bool = false
## True for the stand-in handed out while the real envelope is being measured.
var provisional: bool = false
var key: String = ""
var speeds: PackedFloat64Array = []          ## m/s
var lat: PackedFloat64Array = []
## lat without the steering lock's limit (derived from lat and steer, see _derive()).
var grip: PackedFloat64Array = []
var brake: PackedFloat64Array = []
var accel: PackedFloat64Array = []
var coast: PackedFloat64Array = []
## Pedal positions (0..1) that just reach accel / brake at each speed.
var throttle_pedal: PackedFloat64Array = []
var brake_pedal: PackedFloat64Array = []
## Mean |slip angle| (rad) of the front / rear tyres at the cornering limit.
var slip_front: PackedFloat64Array = []
var slip_rear: PackedFloat64Array = []
## steer[i][j]: steering input (0..1) for STEER_FRACS[j] of the cornering limit at speeds[i].
var steer: Array[PackedFloat64Array] = []
## Peak slip ratio of the tyres (from the car spec): the pedal governors work against it.
var peak_slip_ratio: float = 0.09
var peak_slip_angle: float = 0.14
## Distance from the centre of mass to the rear axle (m).
var cg_to_rear: float = 1.8

var _car: Car
var _eff: float = 0.9

# ================================================================ analytic (arcade)
## The arcade car's envelope, straight from its tuning. `lateral_efficiency` is the measured /
## theoretical full-lock lateral acceleration (tools/lap_grip_sweep.gd).
static func arcade(car: Car, lateral_efficiency: float) -> CarEnvelope:
	var e := CarEnvelope.new()
	e.analytic = true
	e._car = car
	e._eff = lateral_efficiency
	e.key = "arcade"
	return e

# ================================================================ queries
func lat_at(v: float) -> float:
	if analytic:
		return _eff * G * _car.steer_grip_usage * (_car.lateral_grip_g + _car.aero_grip_g * v * v)
	var n := speeds.size()
	if n < 2:
		return 0.0
	if v <= speeds[1]:
		# Below the slowest sample the car is limited by its steering lock: constant curvature.
		var r := v / speeds[1]
		return lat[1] * r * r
	if v >= speeds[n - 1]:
		return lat[n - 1]
	var i := _seg(v)
	var t := (v - speeds[i]) / (speeds[i + 1] - speeds[i])
	# Linear in acceleration is exact where grip limits, linear in curvature where the steering
	# lock does; the lower of the two never overestimates between samples.
	var by_acc := lerpf(lat[i], lat[i + 1], t)
	var by_curv := lerpf(lat[i] / (speeds[i] * speeds[i]), lat[i + 1] / (speeds[i + 1] * speeds[i + 1]), t) * v * v
	return minf(by_acc, by_curv)

## Lateral acceleration the tyres can hold at v, whether or not the steering reaches it.
func grip_at(v: float) -> float:
	if analytic:
		return lat_at(v)
	return _table(grip, v)

## Tightest curvature (1/m) the car should be asked to drive: what it turns at the fastest
## speed where its lock, not its grip, is the limit (tighter is possible, at a crawl).
func max_curvature() -> float:
	if analytic or speeds.size() < 3:
		return INF
	var k := lat[1] / (speeds[1] * speeds[1])
	for i in range(2, speeds.size()):
		if steer[i][STEER_FRACS.size() - 1] < LOCK_LIMITED:
			break
		k = lat[i] / (speeds[i] * speeds[i])
	return k

func brake_at(v: float) -> float:
	if analytic:
		return _car.brake_decel
	return _table(brake, v)

func accel_at(v: float) -> float:
	if analytic:
		return _car._accel_at(v * Car.KMH)   # the Car's own table lookup
	return _table(accel, v)

func coast_at(v: float) -> float:
	if analytic:
		return _car.coast_decel + _car.drag_decel_coef * v * v
	return _table(coast, v)

## The part of coast_at(v) that comes through the driven wheels (engine braking): the
## coast-down less a v^2 drag term fitted between the slowest and the fastest sample.
func engine_brake_at(v: float) -> float:
	if analytic or speeds.size() < 3:
		return 0.0
	var n := speeds.size()
	var c := maxf(0.0, (coast[n - 1] - coast[1]) / (speeds[n - 1] * speeds[n - 1] - speeds[1] * speeds[1]))
	return maxf(0.0, coast_at(v) - c * v * v)

func throttle_pedal_at(v: float) -> float:
	return 1.0 if analytic else _table(throttle_pedal, v)

func brake_pedal_at(v: float) -> float:
	return 1.0 if analytic else _table(brake_pedal, v)

func slip_front_at(v: float) -> float:
	return 0.0 if analytic else _table(slip_front, maxf(v, speeds[1]))

func slip_rear_at(v: float) -> float:
	return 0.0 if analytic else _table(slip_rear, maxf(v, speeds[1]))

## Friction coefficient of the tyres without downforce: the low-speed braking limit in g.
func grip_mu() -> float:
	if analytic:
		return _car.lateral_grip_g
	return brake[1] / G if brake.size() > 1 else 1.0

## Share of the braking limit the driven wheels can put down as traction.
func traction_ratio() -> float:
	if analytic or brake.size() < 2:
		return 0.5
	return clampf(accel[1] / maxf(brake[1], 0.1), 0.25, 0.7)

## Acceleration the driven tyres could hold in a straight line at v (m/s^2). Where the
## measured run needed less than full throttle it was limited by traction, and accel_at(v) is
## that limit; where the engine was the limit, it is at least accel_at(v), estimated from the
## braking limit (which grows with downforce the same way).
func traction_at(v: float) -> float:
	var a := accel_at(v)
	if analytic or throttle_pedal_at(v) < 0.98:
		return a
	return maxf(a, traction_ratio() * brake_at(v))

## Share (0..1) of the cornering limit that curvature k (1/m) asks for at speed v.
func lateral_share(v: float, k: float) -> float:
	if analytic or speeds.size() < 2:
		return clampf(absf(k) * v * v / maxf(lat_at(v), 0.01), 0.0, 1.0)
	var vv := maxf(v, speeds[1])
	return clampf(absf(k) * vv * vv / maxf(lat_at(vv), 0.01), 0.0, 1.0)

## Steering input magnitude (0..1) that holds curvature k (1/m) at speed v (measured cars).
func steer_for(v: float, k: float) -> float:
	if analytic or speeds.size() < 2:
		return 0.0
	var share := lateral_share(v, k)
	var vv := clampf(v, speeds[1], speeds[speeds.size() - 1])
	var i := clampi(_seg(vv), 1, speeds.size() - 2)
	var t := clampf((vv - speeds[i]) / (speeds[i + 1] - speeds[i]), 0.0, 1.0)
	return lerpf(_steer_row(steer[i], share), _steer_row(steer[i + 1], share), t)

func _steer_row(row: PackedFloat64Array, share: float) -> float:
	for j in range(1, STEER_FRACS.size()):
		if share <= STEER_FRACS[j]:
			return lerpf(row[j - 1], row[j], (share - STEER_FRACS[j - 1]) / (STEER_FRACS[j] - STEER_FRACS[j - 1]))
	return row[row.size() - 1]

func _seg(v: float) -> int:
	var n := speeds.size()
	for i in range(1, n):
		if v <= speeds[i]:
			return i - 1
	return n - 2

func _table(arr: PackedFloat64Array, v: float) -> float:
	var n := speeds.size()
	if n == 0 or arr.size() != n:
		return 0.0
	if v <= speeds[0]:
		return arr[0]
	if v >= speeds[n - 1]:
		return arr[n - 1]
	var i := _seg(v)
	return lerpf(arr[i], arr[i + 1], (v - speeds[i]) / (speeds[i + 1] - speeds[i]))

## Human-readable table.
func describe() -> String:
	var lines: PackedStringArray = []
	if analytic:
		lines.append("analytic (arcade) envelope")
		lines.append(" km/h    lat  brake  accel  coast   (m/s^2)")
		for kmh: float in SPEEDS_KMH:
			var v := kmh / 3.6
			lines.append("%5.0f  %5.2f  %5.2f  %5.2f  %5.2f" % [kmh, lat_at(v), brake_at(v), accel_at(v), coast_at(v)])
		return "\n".join(lines)
	lines.append("measured envelope, key %s%s" % [key, " (PROVISIONAL constants)" if provisional else ""])
	lines.append(" km/h    lat   (g)   grip  brake   (g)  accel  coast  thr-pedal brk-pedal  steer@limit  slip F / R (deg)")
	for i in speeds.size():
		lines.append("%5.0f  %5.2f %5.2f  %5.2f  %5.2f %5.2f  %5.2f  %5.2f     %4.2f      %4.2f        %4.2f     %4.1f / %4.1f" % [
				speeds[i] * 3.6, lat[i], lat[i] / G, grip[i], brake[i], brake[i] / G, accel[i], coast[i],
				throttle_pedal[i], brake_pedal[i], steer[i][STEER_FRACS.size() - 1],
				rad_to_deg(slip_front[i]), rad_to_deg(slip_rear[i])])
	return "\n".join(lines)

# ================================================================ pedal governor
## One step of a slip-limiting pedal: moves from `prev` towards `want`, rising no faster than
## `rise` per second (slower close to the slip limit) and backing off while `slip` (the worst
## wheel's slip ratio in the pedal's direction) is beyond `limit`. Works whether or not the
## car's own traction control / anti-lock is on: it acts below their thresholds.
static func govern(want: float, prev: float, slip: float, limit: float, dt: float, rise: float = 4.0) -> float:
	if slip > limit:
		var over := minf((slip - limit) / maxf(limit, 1e-3), 3.0)
		return clampf(minf(want, prev) - 6.0 * dt * (0.4 + over), 0.0, 1.0)
	var room := clampf((limit - slip) / maxf(limit, 1e-3) * 2.5, 0.2, 1.0)
	return clampf(minf(want, prev + rise * dt * room), 0.0, 1.0)

## Worst wheelspin (slip ratio > 0) of the car's wheels. `room` (0..1) is the share of the
## slip budget left by cornering: it scales the budget of the loaded wheel of each axle. The
## unloaded (inside) wheel keeps the full budget, since with equal torque left and right it
## is the one that limits the thrust, and it carries little of the cornering force. The
## result is slip / budget for the worst wheel, as if every wheel had the budget of `room`.
static func spin_of(car: Car, room: float = 1.0) -> float:
	return _worst_slip(car, 1.0, room)

## Worst wheel locking (slip ratio < 0, as a positive number); `room` as for spin_of().
static func lock_of(car: Car, room: float = 1.0) -> float:
	return _worst_slip(car, -1.0, room)

static func _worst_slip(car: Car, direction: float, room: float) -> float:
	var worst := 0.0
	for axle in 2:
		var a := car.wheels[axle * 2]
		var b := car.wheels[axle * 2 + 1]
		for w: WheelState in [a, b]:
			if not w.contact:
				continue
			var other := b if w == a else a
			var slip := w.slip_ratio * direction
			if direction < 0.0 and w.locked:
				slip = 1.0
			# The clearly lighter wheel of the pair is not held to the cornering share.
			if room < 1.0 and other.contact and w.load < 0.8 * other.load:
				slip *= lerpf(room, 1.0, clampf((w.load / maxf(other.load, 1.0) - 0.4) / 0.4, 0.0, 1.0))
			worst = maxf(worst, slip)
	return worst

# ================================================================ lookup / cache
## The envelope of `car` in its current handling model. For a simulation car this may be a
## provisional envelope while the real one is measured: see `provisional` and `revision`.
static func for_car(car: Car, lateral_efficiency: float = 0.9) -> CarEnvelope:
	if car.sim == null:
		return arcade(car, lateral_efficiency)
	return for_spec(Car.SIM_SPEC_PATH, car.get_tree().root if car.is_inside_tree() else null)

## `host`: a node of the tree, under which the measurement rig may be built (null = never
## measure, hand out the provisional envelope).
static func for_spec(spec_path: String, host: Node) -> CarEnvelope:
	var k := spec_key(spec_path)
	if _mem.has(k):
		return _mem[k]
	if not _stand_ins.has(k):
		# First request for this car: the files are read once.
		var e := _load(res_path(spec_path))
		if e != null and e.key != k and _sources_readable:
			push_warning("CarEnvelope: %s is stale (the car spec or a part script changed): measuring again. Run tools/lap_grip_sweep.gd --envelope and commit the file." % res_path(spec_path))
			e = null
		if e == null:
			e = _load("user://envelope_%s.json" % k)
			if e != null and e.key != k:
				e = null
		if e != null:
			_mem[k] = e
			return e
		_stand_ins[k] = _provisional(spec_path, k)
	if host != null and not _measuring.has(k):
		_measuring[k] = true
		_measure_in_background(host, spec_path, k)
	return _stand_ins[k]

static func res_path(spec_path: String) -> String:
	return RES_DIR + spec_path.get_file().get_basename() + ".json"

## Makes `e` (a fresh measure() result) the envelope served for its key from now on.
static func adopt(e: CarEnvelope) -> void:
	if e == null or e.analytic or not e.is_sane():
		return
	_mem[e.key] = e
	_stand_ins.erase(e.key)
	revision += 1

## Forgets every cached envelope (tests).
static func clear_cache() -> void:
	_mem.clear()
	_keys.clear()
	_stand_ins.clear()

## Hash of everything a measured envelope depends on: the spec's values, the source of every
## simulation part, of the Car, its scene and this file, and the project's physics rate and
## gravity.
static func spec_key(spec_path: String) -> String:
	if _keys.has(spec_path):
		return _keys[spec_path]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(("v%d|%s|%s|%s|" % [VERSION, str(SPEEDS_KMH),
			str(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", _HZ)),
			str(ProjectSettings.get_setting("physics/3d/default_gravity", G))]).to_utf8_buffer())
	var spec := load(spec_path) as Resource
	if spec != null:
		for p: Dictionary in spec.get_property_list():
			if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				ctx.update(("%s=%s;" % [p["name"], var_to_str(spec.get(p["name"]))]).to_utf8_buffer())
	var files: PackedStringArray = []
	for f in DirAccess.get_files_at(SIM_SCRIPTS_DIR):
		if f.ends_with(".gd"):
			files.append(SIM_SCRIPTS_DIR + f)
	files.sort()
	files.append_array(KEY_FILES)
	var read := 0
	for f in files:
		var bytes := FileAccess.get_file_as_bytes(f) if FileAccess.file_exists(f) else PackedByteArray()
		if not bytes.is_empty():
			read += 1
			ctx.update(bytes)
	_sources_readable = read == files.size()
	var k := ctx.finish().hex_encode().left(16)
	_keys[spec_path] = k
	return k

static func _measure_in_background(host: Node, spec_path: String, k: String) -> void:
	var e: CarEnvelope = await measure(host, spec_path)
	_measuring.erase(k)
	_stand_ins.erase(k)
	if not e.is_sane():
		push_error("CarEnvelope: the measurement failed; the autopilot keeps its conservative limits.")
		var keep := _provisional(spec_path, k)
		keep.provisional = false
		_mem[k] = keep
	else:
		_mem[k] = e
		e.save("user://envelope_%s.json" % k)
	revision += 1

## Conservative constants the simulation car is known to reach with any reasonable parts:
## used only while the measurement runs.
static func _provisional(spec_path: String, k: String) -> CarEnvelope:
	var spec := load(spec_path) as CarSpec
	var e := CarEnvelope.new()
	e.provisional = true
	e.key = k
	e._alloc()
	e._read_spec(spec)
	var lock := spec.max_steer_angle if spec != null else 0.35
	for i in e.speeds.size():
		var v := e.speeds[i]
		var tyre := 0.85 * G * (1.15 + 1.6e-4 * v * v)
		var kin := v * v * tan(lock * 0.7) / Car.WHEELBASE
		e.lat[i] = minf(tyre, kin)
		e.brake[i] = 11.0
		e.accel[i] = maxf(0.3, 7.5 - 7.0 * maxf(0.0, v - 35.0) / 55.0)
		e.coast[i] = 1.0 + 3.0e-4 * v * v
		e.throttle_pedal[i] = 1.0
		e.brake_pedal[i] = 1.0
		e.slip_front[i] = e.peak_slip_angle
		e.slip_rear[i] = e.peak_slip_angle * 0.8
		for j in STEER_FRACS.size():
			e.steer[i][j] = STEER_FRACS[j] * (1.0 if kin <= tyre else 0.9)
	e._derive()
	return e

func _alloc() -> void:
	var n := SPEEDS_KMH.size()
	speeds.resize(n)
	grip.resize(n)
	for arr: PackedFloat64Array in [lat, brake, accel, coast, throttle_pedal, brake_pedal, slip_front, slip_rear]:
		arr.resize(n)
		arr.fill(0.0)
	steer.clear()
	for i in n:
		speeds[i] = SPEEDS_KMH[i] / 3.6
		var row := PackedFloat64Array()
		row.resize(STEER_FRACS.size())
		row.fill(0.0)
		steer.append(row)

## The tyres' lateral grip from the measured cornering limit: where the car ran out of lock
## before grip (steering at the limit ~ full), the nearest sample that did not stands in.
func _derive() -> void:
	var n := speeds.size()
	var last := STEER_FRACS.size() - 1
	var first_free := -1
	var last_free := -1
	for i in range(1, n):
		if steer[i][last] < LOCK_LIMITED:
			if first_free < 0:
				first_free = i
			last_free = i
	for i in n:
		grip[i] = lat[i]
		if first_free < 0:
			continue
		if i < first_free:
			grip[i] = maxf(lat[i], 0.95 * lat[first_free])
		elif i > last_free:
			grip[i] = maxf(lat[i], lat[last_free])

func _read_spec(spec: CarSpec) -> void:
	if spec == null:
		return
	peak_slip_ratio = spec.tyre_peak_slip_ratio
	peak_slip_angle = spec.tyre_peak_slip_angle
	cg_to_rear = Car.WHEELBASE * spec.weight_front

# ================================================================ files
func save(path: String) -> bool:
	var rows: Array = []
	for row in steer:
		rows.append(Array(row))
	var d := {"version": VERSION, "key": key, "speeds_kmh": SPEEDS_KMH, "lat": Array(lat),
			"brake": Array(brake), "accel": Array(accel), "coast": Array(coast),
			"throttle_pedal": Array(throttle_pedal), "brake_pedal": Array(brake_pedal),
			"slip_front": Array(slip_front), "slip_rear": Array(slip_rear),
			"steer_fracs": STEER_FRACS, "steer": rows, "peak_slip_ratio": peak_slip_ratio,
			"peak_slip_angle": peak_slip_angle, "cg_to_rear": cg_to_rear}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d, "\t") + "\n")
	return true

static func _load(path: String) -> CarEnvelope:
	if not FileAccess.file_exists(path):
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return null
	var d: Dictionary = parsed
	var n := SPEEDS_KMH.size()
	if int(d.get("version", 0)) != VERSION or (d.get("speeds_kmh", []) as Array).size() != n \
			or (d.get("steer", []) as Array).size() != n:
		return null
	var e := CarEnvelope.new()
	e._alloc()
	e.key = str(d.get("key", ""))
	var names := ["lat", "brake", "accel", "coast", "throttle_pedal", "brake_pedal", "slip_front", "slip_rear"]
	var arrays: Array[PackedFloat64Array] = [e.lat, e.brake, e.accel, e.coast, e.throttle_pedal,
			e.brake_pedal, e.slip_front, e.slip_rear]
	for a in names.size():
		var src: Array = d.get(names[a], [])
		if src.size() != n:
			return null
		for i in n:
			arrays[a][i] = float(src[i])
	for i in n:
		var row: Array = d["steer"][i]
		if row.size() != STEER_FRACS.size():
			return null
		for j in row.size():
			e.steer[i][j] = float(row[j])
	e.peak_slip_ratio = float(d.get("peak_slip_ratio", 0.09))
	e.peak_slip_angle = float(d.get("peak_slip_angle", 0.14))
	e.cg_to_rear = float(d.get("cg_to_rear", 1.8))
	e._derive()
	return e if e.is_sane() else null

## True when every limit is a usable number.
func is_sane() -> bool:
	for i in range(1, speeds.size()):
		for x: float in [lat[i], brake[i], accel[i], coast[i], throttle_pedal[i], brake_pedal[i]]:
			if is_nan(x) or is_inf(x):
				return false
		if lat[i] < 0.5 or brake[i] < 1.0 or accel[i] < 0.0 or steer[i][STEER_FRACS.size() - 1] <= 0.0:
			return false
		# A run that recorded nothing leaves its pedal at 0: the car could not be driven there.
		if throttle_pedal[i] < 0.04 or brake_pedal[i] < 0.04:
			return false
	return accel.size() > 1 and accel[1] > 0.5

# ================================================================ measurement
## One hidden car and the manoeuvre it drives.
class Run:
	var kind: StringName
	var i: int = 0
	var car: Car
	var t: int = 0
	var done: bool = false
	var pedal: float = 0.0
	var trim: float = 0.15
	var coast_v: float = 0.0
	var shift_cool: int = 0
	var v: PackedFloat64Array = []
	var a: PackedFloat64Array = []
	var p: PackedFloat64Array = []
	var sf: PackedFloat64Array = []
	var sr: PackedFloat64Array = []

## Measures the simulation car described by `spec_path`: builds a flat pad with hidden cars in
## a physics world of its own under `host`, drives them, frees everything. Takes about 6 s of
## physics time whatever the frame rate (await it). Check is_sane() on the result.
static func measure(host: Node, spec_path: String = Car.SIM_SPEC_PATH) -> CarEnvelope:
	measurements += 1
	var tree := host.get_tree()
	var spec := load(spec_path) as CarSpec
	var env := CarEnvelope.new()
	env.key = spec_key(spec_path)
	env._alloc()
	env._read_spec(spec)
	var n := env.speeds.size()

	# A world of its own: nothing here can touch, or be touched by, the race.
	var vp := SubViewport.new()
	vp.name = "CarEnvelopeRig"
	vp.own_world_3d = true
	vp.size = Vector2i(2, 2)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	host.add_child.call_deferred(vp)
	await tree.physics_frame
	if not vp.is_inside_tree():
		await tree.physics_frame
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	ground.add_child(shape)
	vp.add_child(ground)
	var scene := load(CAR_SCENE) as PackedScene
	var runs: Array[Run] = []
	for i in range(1, n):
		runs.append(_run(&"lat", i))
		runs.append(_run(&"acc", i))
	runs.append(_run(&"brk", 0))
	for k in runs.size():
		var car := scene.instantiate() as Car
		car.handling = Car.HANDLING_SIMULATION
		car.position = Vector3(k * 30.0, 0.40, 0.0)
		car.collision_layer = 0   # the cars pass through each other
		vp.add_child(car)
		car.set_input_override(0.0, 0.0, 0.0)
		# Nobody sees these cars: their visuals (wheels, body) need not run.
		for child in car.get_children():
			if not child is CollisionShape3D:
				child.process_mode = Node.PROCESS_MODE_DISABLED
		runs[k].car = car
	# Ticks are counted on the tree's physics frames, which keep coming while the game is
	# paused and the cars stand frozen: those do not count.
	var settled := 0
	while settled < _SETTLE_TICKS:
		await tree.physics_frame
		if not tree.paused:
			settled += 1
	var active := runs.size()
	var tick := 0
	var dt := 1.0 / _HZ
	while active > 0 and tick < _MAX_TICKS:
		if tree.paused:
			await tree.physics_frame
			continue
		for r in runs:
			if r.done:
				continue
			match r.kind:
				&"lat": _step_lat(r, env, dt)
				&"acc": _step_acc(r, env, dt)
				_: _step_brk(r, env, dt)
			_shift_backup(r)
			r.t += 1
			if r.done:
				active -= 1
				var c := r.car
				c.set_input_override(0.0, 0.0, 0.0)
				c.simulate = false
				c.freeze = true
		await tree.physics_frame
		tick += 1
	for r in runs:
		match r.kind:
			&"lat": _finish_lat(r, env)
			&"acc": _finish_acc(r, env)
			_: _finish_brk(r, env)
	vp.queue_free()
	# The standstill sample copies its neighbour (a launch is driven by slip feedback anyway).
	env.lat[0] = 0.0
	env.accel[0] = env.accel[1]
	env.brake[0] = env.brake[1]
	env.coast[0] = env.coast[1]
	env.throttle_pedal[0] = env.throttle_pedal[1]
	env.brake_pedal[0] = env.brake_pedal[1]
	env.slip_front[0] = env.slip_front[1]
	env.slip_rear[0] = env.slip_rear[1]
	env.steer[0] = env.steer[1].duplicate()
	env._derive()
	return env

## Backup gear changes for a car whose automatic gearbox is switched off: only beyond the
## thresholds an automatic box would already have acted on.
static func _shift_backup(r: Run) -> void:
	if r.shift_cool > 0:
		r.shift_cool -= 1
		return
	var d := shift_wanted(r.car)
	if d != 0:
		r.car.sim.request_shift(d)
		r.shift_cool = 36

## +1 / -1 when the engine is past the spec's shift points by a margin that an automatic
## gearbox never lets it reach, else 0.
static func shift_wanted(car: Car) -> int:
	if car.sim == null or car.gear < 1:
		return 0
	var spec := car.sim.spec
	if car.rpm > spec.rpm_shift_up + 0.4 * (spec.rpm_max - spec.rpm_shift_up) and car.gear < spec.gear_ratios.size() and car.throttle > 0.1:
		return 1
	if car.rpm < spec.rpm_shift_down - 600.0 and car.gear > 1 and car.forward_speed > 3.0:
		return -1
	return 0

static func _speed(car: Car) -> float:
	return car.linear_velocity.length()

static func _axle_slip(car: Car, a: int, b: int) -> float:
	return 0.5 * (absf(car.wheels[a].slip_angle) + absf(car.wheels[b].slip_angle))

## Steering ramp at a held speed.
static func _step_lat(r: Run, env: CarEnvelope, dt: float) -> void:
	var car := r.car
	var t := r.t
	var target := env.speeds[r.i]
	if t == 0:
		car.sim.set_speed(target)
	var v := _speed(car)
	var xf := car.global_transform
	var yaw := car.angular_velocity.dot(xf.basis.y)
	var beta := atan2(car.linear_velocity.dot(xf.basis.x), maxf(absf(car.linear_velocity.dot(-xf.basis.z)), 1.0))
	var steer_in := 0.0
	if t >= _LAT_HOLD_TICKS:
		steer_in = float(t - _LAT_HOLD_TICKS) / _LAT_RAMP_TICKS
		r.v.append(v)
		r.a.append(absf(v * yaw))
		r.p.append(steer_in)
		r.sf.append(_axle_slip(car, 0, 1))
		r.sr.append(_axle_slip(car, 2, 3))
	# Hold the speed: PI on the throttle, kept well inside the driven tyres' slip budget so
	# they keep their cornering force.
	var err := target - v
	r.trim = clampf(r.trim + 0.8 * err * dt, 0.0, 1.0)
	var want := clampf(r.trim + 0.35 * err, 0.0, 1.0)
	r.pedal = govern(want, r.pedal, spin_of(car), env.peak_slip_ratio * 0.5, dt)
	car.set_input_override(r.pedal, 0.0, steer_in)
	if t >= _LAT_HOLD_TICKS + _LAT_RAMP_TICKS or absf(beta) > 0.6 or v < target * 0.6:
		r.done = true

static func _finish_lat(r: Run, env: CarEnvelope) -> void:
	var i := r.i
	var a := r.a
	var p := r.p
	var n := a.size()
	var w := 24   # half window: 0.2 s centred mean
	if n < 4 * w:
		return
	var sm := PackedFloat64Array()
	sm.resize(n)
	var acc := 0.0
	for k in n:
		acc += a[k]
		if k >= 2 * w + 1:
			acc -= a[k - 2 * w - 1]
		if k >= 2 * w:
			sm[k - w] = acc / (2 * w + 1)
	var peak := 0.0
	var at := w
	for k in range(w, n - w):
		if sm[k] > peak:
			peak = sm[k]
			at = k
	env.lat[i] = peak
	var sf := r.sf
	var sr := r.sr
	var f_sum := 0.0
	var r_sum := 0.0
	for k in range(at - w, at + w + 1):
		f_sum += sf[k]
		r_sum += sr[k]
	env.slip_front[i] = f_sum / (2 * w + 1)
	env.slip_rear[i] = r_sum / (2 * w + 1)
	var row := env.steer[i]
	row[0] = 0.0
	for j in range(1, STEER_FRACS.size()):
		var need := STEER_FRACS[j] * peak
		row[j] = p[at]
		for k in range(w, at + 1):
			if sm[k] >= need:
				row[j] = p[k]
				break
		row[j] = maxf(row[j], row[j - 1] + 1e-4)

## Coast-down at the sample speed, then a governed full-throttle run through it.
static func _step_acc(r: Run, env: CarEnvelope, dt: float) -> void:
	var car := r.car
	var t := r.t
	var i := r.i
	var target := env.speeds[i]
	var v := _speed(car)
	if t == 0:
		car.sim.set_speed(target)
	if t < _ACC_COAST_TICKS:
		if t == 24:
			r.coast_v = v
		car.set_input_override(0.0, 0.0, 0.0)
		return
	if t == _ACC_COAST_TICKS:
		env.coast[i] = maxf(0.0, (r.coast_v - v) / (float(_ACC_COAST_TICKS - 24) * dt))
		var lead := 6.0 if target < 50.0 else (3.0 if target < 70.0 else 1.5)
		car.sim.set_speed(maxf(target - lead, 0.0))
		r.pedal = 0.0
		return
	r.pedal = govern(1.0, r.pedal, spin_of(car), env.peak_slip_ratio * SLIP_USE, dt, 6.0)
	car.set_input_override(r.pedal, 0.0, 0.0)
	r.v.append(v)
	r.p.append(r.pedal)
	if v > target + 2.5 or t > _ACC_COAST_TICKS + _ACC_RUN_TICKS:
		r.done = true

static func _finish_acc(r: Run, env: CarEnvelope) -> void:
	var i := r.i
	var v := r.v
	var p := r.p
	var n := v.size()
	if n < 60:
		return
	var target := env.speeds[i]
	var d := 1.5
	var k0 := -1
	var k1 := -1
	for k in n:
		if k0 < 0 and v[k] >= target - d:
			k0 = k
		if v[k] >= target + d:
			k1 = k
			break
	if k0 < 0 or k1 <= k0 + 4:
		# Too little acceleration to cross the window: the mean after the pedal has come on.
		k0 = mini(96, n / 2)
		k1 = n - 1
	env.accel[i] = maxf(0.0, (v[k1] - v[k0]) * _HZ / float(k1 - k0))
	var sum := 0.0
	for k in range(k0, k1 + 1):
		sum += p[k]
	env.throttle_pedal[i] = clampf(sum / float(k1 - k0 + 1), 0.05, 1.0)

## One governed stop from beyond the fastest sample.
static func _step_brk(r: Run, env: CarEnvelope, dt: float) -> void:
	var car := r.car
	var t := r.t
	if t == 0:
		car.sim.set_speed(env.speeds[env.speeds.size() - 1] + 12.0)
	var v := _speed(car)
	if t < 24:
		car.set_input_override(0.0, 0.0, 0.0)
		return
	r.pedal = govern(1.0, r.pedal, lock_of(car), env.peak_slip_ratio * SLIP_USE, dt, 8.0)
	car.set_input_override(0.0, r.pedal, 0.0)
	r.v.append(v)
	r.p.append(r.pedal)
	if v < 2.5 or t > _BRK_MAX_TICKS:
		r.done = true

static func _finish_brk(r: Run, env: CarEnvelope) -> void:
	var v := r.v
	var p := r.p
	var n := v.size()
	for i in range(1, env.speeds.size()):
		var target := env.speeds[i]
		var d := minf(2.5, 0.3 * target)
		var k0 := -1
		var k1 := -1
		for k in n:
			if k0 < 0 and v[k] <= target + d:
				k0 = k
			if v[k] <= target - d:
				k1 = k
				break
		if k0 < 0 or k1 <= k0:
			continue
		env.brake[i] = (v[k0] - v[k1]) * _HZ / float(k1 - k0)
		var sum := 0.0
		for k in range(k0, k1 + 1):
			sum += p[k]
		env.brake_pedal[i] = clampf(sum / float(k1 - k0 + 1), 0.05, 1.0)

static func _run(kind: StringName, i: int) -> Run:
	var r := Run.new()
	r.kind = kind
	r.i = i
	return r
