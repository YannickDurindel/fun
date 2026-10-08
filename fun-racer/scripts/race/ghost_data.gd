class_name GhostData
extends RefCounted
## One recorded lap: the car's pose, speed and steering sampled at a fixed rate, keyed by lap
## time. Saved per track as `user://ghosts/<track_id>.ghost` (little-endian binary):
##
##   header   u32 magic "FRGH" | u16 version | u16 track id length | track id (utf-8)
##            f32 lap time (s) | f32 sample interval (s) | f32 track length (m)
##            i64 date (unix, UTC) | u32 sample count n
##   columns  n f32 lap times | 3n f32 positions (x, y, z) | 4n f32 rotations (quaternion
##            x, y, z, w) | n f32 forward speeds (m/s) | n f32 front steer angles (rad)
##
## 40 bytes per sample: a 90 s lap at 30 Hz is ~108 KB, and MAX_SAMPLES caps a file at 200 KB.
## The columns are the in-memory arrays written as they are, so saving a lap costs no
## per-sample work (it happens as the car crosses the line). Files that are truncated, of
## another version, for another track or holding nonsense values are ignored: load_for()
## returns null.

const MAGIC: int = 0x48475246   ## "FRGH"
const VERSION: int = 1
const SAMPLE_BYTES: int = 40
const HEADER_BYTES: int = 32   ## the header without the track id
const DEFAULT_DIR := "user://ghosts"
const MAX_SAMPLES: int = 5000   ## the recorder halves its rate rather than exceed this
const MAX_ID_BYTES: int = 128
const MAX_LAP_TIME: float = 3600.0
const MAX_COORD: float = 1.0e6
## Two samples further apart than this speed allows are a respawn, not driving: the pose
## jumps there instead of sliding across the map.
const TELEPORT_SPEED: float = 400.0

## Set by tests (and dev flags) to keep ghosts out of the player's user:// folder.
static var dir_override: String = ""

var track_id: String = ""
var lap_time: float = 0.0
var sample_interval: float = 1.0 / 30.0
var track_length: float = 0.0               ## centreline length the lap was driven on (0 = unknown)
var date: int = 0                           ## unix time (UTC) the lap was set
var times: PackedFloat32Array = []          ## lap time of each sample, ascending
var speeds: PackedFloat32Array = []         ## signed forward speed, m/s
var steers: PackedFloat32Array = []         ## front wheel steer angle, rad (+ = left)
var _pos: PackedFloat32Array = []           ## x, y, z per sample
var _rot: PackedFloat32Array = []           ## quaternion x, y, z, w per sample

static func dir() -> String:
	return DEFAULT_DIR if dir_override.is_empty() else dir_override

static func path_for(id: String) -> String:
	return dir().path_join(id + ".ghost")

static func is_valid_id(id: String) -> bool:
	return not id.is_empty() and id.is_valid_filename() and not id.begins_with(".") \
			and id.to_utf8_buffer().size() <= MAX_ID_BYTES

static func exists(id: String) -> bool:
	return is_valid_id(id) and FileAccess.file_exists(path_for(id))

## Removes the track's ghost file. True when no file is left.
static func delete(id: String) -> bool:
	if not exists(id):
		return true
	return DirAccess.remove_absolute(path_for(id)) == OK

## The saved ghost of a track, or null when there is none or the file cannot be trusted.
static func load_for(id: String) -> GhostData:
	if not exists(id):
		return null
	var g := from_bytes(FileAccess.get_file_as_bytes(path_for(id)))
	return g if g != null and g.track_id == id else null

## Only the header of a track's ghost (lap time, date, ...; no samples), or null when the file
## is missing or is not a ghost of that track with the size its header announces. Cheap: for
## lists.
static func load_header(id: String) -> GhostData:
	if not exists(id):
		return null
	var f := FileAccess.open(path_for(id), FileAccess.READ)
	if f == null:
		return null
	var total := f.get_length()
	var head := f.get_buffer(mini(total, HEADER_BYTES + MAX_ID_BYTES))
	var g := from_bytes(head, total)
	return g if g != null and g.track_id == id else null

func size() -> int:
	return times.size()

## Lap time of the last sample (0 when empty).
func duration() -> float:
	return times[times.size() - 1] if not times.is_empty() else 0.0

func position(i: int) -> Vector3:
	return Vector3(_pos[i * 3], _pos[i * 3 + 1], _pos[i * 3 + 2])

func rotation(i: int) -> Quaternion:
	return Quaternion(_rot[i * 4], _rot[i * 4 + 1], _rot[i * 4 + 2], _rot[i * 4 + 3]).normalized()

func add_sample(t: float, xf: Transform3D, speed: float, steer: float) -> void:
	var q := xf.basis.orthonormalized().get_rotation_quaternion()
	times.append(t)
	_pos.append(xf.origin.x)
	_pos.append(xf.origin.y)
	_pos.append(xf.origin.z)
	_rot.append(q.x)
	_rot.append(q.y)
	_rot.append(q.z)
	_rot.append(q.w)
	speeds.append(speed)
	steers.append(steer)

## Drops every other sample (keeping the first) and doubles the nominal interval.
func decimate() -> void:
	var n := size()
	var k := 0
	for i in range(0, n, 2):
		times[k] = times[i]
		speeds[k] = speeds[i]
		steers[k] = steers[i]
		for c in 3:
			_pos[k * 3 + c] = _pos[i * 3 + c]
		for c in 4:
			_rot[k * 4 + c] = _rot[i * 4 + c]
		k += 1
	times.resize(k)
	speeds.resize(k)
	steers.resize(k)
	_pos.resize(k * 3)
	_rot.resize(k * 4)
	sample_interval *= 2.0

## Index i and blend f such that lap time t lies between samples i and i + 1 (clamped).
func _locate(t: float) -> Vector2:
	var n := times.size()
	if n < 2 or t <= times[0]:
		return Vector2.ZERO
	if t >= times[n - 1]:
		return Vector2(n - 2, 1.0)
	var hi := clampi(times.bsearch(t, false), 1, n - 1)   # first sample with time > t
	var span := times[hi] - times[hi - 1]
	return Vector2(hi - 1, (t - times[hi - 1]) / span if span > 1e-6 else 1.0)

## Pose at lap time t: position lerped, rotation slerped between the two nearest samples.
func pose_at(t: float) -> Transform3D:
	var n := times.size()
	if n == 0:
		return Transform3D.IDENTITY
	if n == 1:
		return Transform3D(Basis(rotation(0)), position(0))
	var loc := _locate(t)
	var i := int(loc.x)
	var f := loc.y
	var a := position(i)
	var b := position(i + 1)
	var reach := TELEPORT_SPEED * maxf(times[i + 1] - times[i], 1e-3)
	if a.distance_squared_to(b) > reach * reach:
		f = 1.0 if f >= 1.0 else 0.0   # respawn between the two samples: no sliding across
	return Transform3D(Basis(rotation(i).slerp(rotation(i + 1), f)), a.lerp(b, f))

func speed_at(t: float) -> float:
	return _channel_at(speeds, t)

func steer_at(t: float) -> float:
	return _channel_at(steers, t)

func _channel_at(values: PackedFloat32Array, t: float) -> float:
	var n := values.size()
	if n == 0:
		return 0.0
	if n == 1:
		return values[0]
	var loc := _locate(t)
	var i := int(loc.x)
	return lerpf(values[i], values[i + 1], loc.y)

## True when the lap can be written and read back (the same limits from_bytes() enforces).
func is_saveable() -> bool:
	var n := size()
	return is_valid_id(track_id) and n >= 2 and n <= MAX_SAMPLES \
			and _pos.size() == n * 3 and _rot.size() == n * 4 and speeds.size() == n and steers.size() == n \
			and _header_ok() and duration() < MAX_LAP_TIME + 60.0

func _header_ok() -> bool:
	return is_finite(lap_time) and lap_time > 0.0 and lap_time < MAX_LAP_TIME \
			and is_finite(sample_interval) and sample_interval > 0.0 and sample_interval < 10.0 \
			and is_finite(track_length) and track_length >= 0.0

func to_bytes() -> PackedByteArray:
	var id := track_id.to_utf8_buffer()
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u32(MAGIC)
	b.put_u16(VERSION)
	b.put_u16(id.size())
	b.put_data(id)
	b.put_float(lap_time)
	b.put_float(sample_interval)
	b.put_float(track_length)
	b.put_64(date)
	b.put_u32(size())
	var out := b.data_array
	out.append_array(times.to_byte_array())
	out.append_array(_pos.to_byte_array())
	out.append_array(_rot.to_byte_array())
	out.append_array(speeds.to_byte_array())
	out.append_array(steers.to_byte_array())
	return out

## Decodes a ghost file; null unless every size and value checks out. With `total_size` >= 0
## only the header is decoded and `bytes` may stop after it: the file's real size is
## `total_size`, and it must be what the header announces.
static func from_bytes(bytes: PackedByteArray, total_size: int = -1) -> GhostData:
	var header_only := total_size >= 0
	if not header_only:
		total_size = bytes.size()
	if bytes.size() < 8:
		return null
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = bytes
	if b.get_u32() != MAGIC or b.get_u16() != VERSION:
		return null
	var id_len := b.get_u16()
	var header := HEADER_BYTES + id_len
	if id_len == 0 or id_len > MAX_ID_BYTES or bytes.size() < header:
		return null
	var g := GhostData.new()
	g.track_id = (b.get_data(id_len)[1] as PackedByteArray).get_string_from_utf8()
	g.lap_time = b.get_float()
	g.sample_interval = b.get_float()
	g.track_length = b.get_float()
	g.date = b.get_64()
	var n := b.get_u32()
	if not is_valid_id(g.track_id) or not g._header_ok() or n < 2 or n > MAX_SAMPLES:
		return null
	if total_size != header + n * SAMPLE_BYTES:
		return null
	if header_only:
		return g
	var at := header
	g.times = bytes.slice(at, at + n * 4).to_float32_array()
	at += n * 4
	g._pos = bytes.slice(at, at + n * 12).to_float32_array()
	at += n * 12
	g._rot = bytes.slice(at, at + n * 16).to_float32_array()
	at += n * 16
	g.speeds = bytes.slice(at, at + n * 4).to_float32_array()
	at += n * 4
	g.steers = bytes.slice(at, at + n * 4).to_float32_array()
	var prev_t := -1.0
	for i in n:
		var t := g.times[i]
		if not (is_finite(t) and t >= prev_t and t >= 0.0 and t < MAX_LAP_TIME + 60.0):
			return null
		prev_t = t
		var p := g.position(i)
		if not (p.is_finite() and absf(p.x) < MAX_COORD and absf(p.y) < MAX_COORD and absf(p.z) < MAX_COORD):
			return null
		var q := Quaternion(g._rot[i * 4], g._rot[i * 4 + 1], g._rot[i * 4 + 2], g._rot[i * 4 + 3])
		if not (q.is_finite() and absf(q.length_squared() - 1.0) < 0.01):
			return null
		if not (is_finite(g.speeds[i]) and is_finite(g.steers[i])):
			return null
	return g

## Writes the ghost to its track's file (through a temporary file, so a crash mid-write never
## leaves a half-written ghost behind). False on failure.
func save() -> bool:
	if not is_saveable():
		return false
	if DirAccess.make_dir_recursive_absolute(dir()) != OK:
		return false
	var path := path_for(track_id)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(to_bytes())
	var ok := f.get_error() == OK
	f.close()
	if ok and DirAccess.rename_absolute(tmp, path) != OK:
		# Where a rename cannot replace an existing file: drop the old ghost first.
		DirAccess.remove_absolute(path)
		ok = DirAccess.rename_absolute(tmp, path) == OK
	if not ok:
		DirAccess.remove_absolute(tmp)
	return ok
