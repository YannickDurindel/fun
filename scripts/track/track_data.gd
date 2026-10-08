class_name TrackData
extends RefCounted
## Track centreline contract, loaded from a track.json (see tools/track/fetch_red_bull_ring.py).
## Frame: Godot metres, x = east, y = up, z = -north. s = distance along the lap from the
## finish line in race direction, wrapping at `length`.
## sample(s) basis: -Z = forward along the track, +Y = road normal (includes banking),
## +X = right-hand side of the road when driving.

var name: String = ""
var length: float = 0.0
var step: float = 2.0
var start_s: float = 0.0
var sectors: PackedFloat32Array = []
var turns: Array[Dictionary] = []   ## {id, name, direction, s_apex, min_radius}
var points: PackedVector3Array = []
var widths: PackedFloat32Array = []
var banks: PackedFloat32Array = []  ## radians, + = road rolls so its left edge is higher (right-hand corner banking)
var grades: PackedFloat32Array = []

static func load_track(path: String) -> TrackData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("TrackData: cannot open %s" % path)
		return null
	var d: Dictionary = JSON.parse_string(f.get_as_text())
	var t := TrackData.new()
	t.name = d.get("name", "")
	t.length = float(d["length"])
	t.step = float(d["step"])
	t.start_s = float(d.get("start_s", 0.0))
	for s: Variant in d.get("sectors", []):
		t.sectors.append(float(s))
	for turn: Dictionary in d.get("turns", []):
		t.turns.append(turn)
	for p: Dictionary in d["points"]:
		var a: Array = p["p"]
		t.points.append(Vector3(a[0], a[1], a[2]))
		t.widths.append(float(p.get("width", 13.0)))
		t.banks.append(float(p.get("bank", 0.0)))
		t.grades.append(float(p.get("grade", 0.0)))
	return t

func wrap_s(s: float) -> float:
	return fposmod(s, length)

func _idx(s: float) -> Array:
	var u := wrap_s(s) / step
	var i := int(floor(u)) % points.size()
	return [i, (i + 1) % points.size(), u - floor(u)]

func position_at(s: float) -> Vector3:
	var r := _idx(s)
	return points[r[0]].lerp(points[r[1]], r[2])

func width_at(s: float) -> float:
	var r := _idx(s)
	return lerpf(widths[r[0]], widths[r[1]], r[2])

func bank_at(s: float) -> float:
	var r := _idx(s)
	return lerpf(banks[r[0]], banks[r[1]], r[2])

func grade_at(s: float) -> float:
	var r := _idx(s)
	return lerpf(grades[r[0]], grades[r[1]], r[2])

func tangent_at(s: float) -> Vector3:
	return (position_at(s + step) - position_at(s - step)).normalized()

## Frame on the road centreline at s. Origin on the road surface.
func sample(s: float) -> Transform3D:
	var fwd := tangent_at(s)
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd).normalized()
	var b := Basis(right, up, -fwd)
	b = b.rotated(fwd, -bank_at(s)) if absf(bank_at(s)) > 1e-5 else b
	return Transform3D(b.orthonormalized(), position_at(s))

## Closest centreline distance to a world position. Pass `hint_s` (last known s) for an O(1)
## local search; without it the whole lap is scanned.
func closest_s(world_pos: Vector3, hint_s: float = -1.0) -> float:
	var n := points.size()
	var best_i := 0
	var best_d := INF
	if hint_s >= 0.0:
		var c := int(wrap_s(hint_s) / step)
		for k in range(-60, 61):
			var i := (c + k + n) % n
			var d := points[i].distance_squared_to(world_pos)
			if d < best_d:
				best_d = d
				best_i = i
	else:
		for i in n:
			var d := points[i].distance_squared_to(world_pos)
			if d < best_d:
				best_d = d
				best_i = i
	# Refine on the two neighbouring segments.
	var best_s := best_i * step
	for j: int in [best_i - 1, best_i]:
		var a := points[(j + n) % n]
		var b := points[(j + 1) % n]
		var ab := b - a
		var t := clampf((world_pos - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		var d := (a + ab * t).distance_squared_to(world_pos)
		if d <= best_d:
			best_d = d
			best_s = ((j + n) % n + t) * step
	return wrap_s(best_s)

## Signed lateral distance from the centreline (+ = right of the centreline in race direction).
func lateral_offset(world_pos: Vector3, hint_s: float = -1.0) -> float:
	var s := closest_s(world_pos, hint_s)
	var xf := sample(s)
	return (world_pos - xf.origin).dot(xf.basis.x)

## Signed distance from a to b along the lap, in (-length/2, length/2].
func delta_s(a: float, b: float) -> float:
	var d := fposmod(b - a, length)
	return d - length if d > length * 0.5 else d
