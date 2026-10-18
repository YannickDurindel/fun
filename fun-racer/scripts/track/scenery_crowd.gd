class_name SceneryCrowd
extends RefCounted
## Spectators and flags for the grandstands of Scenery, built in code.
##
## Spectators sit on the treads of every "stand_seats" surface (scenery.glb chunks and
## landmarks alike): a tread is a horizontal stand_seats triangle whose UV is in metres, u along
## the row and v the depth from the front (cad/track/scenery_glb.py grandstand), so -grad(v)
## is the way the row faces. One seat every SEAT_WIDTH along the row, in the middle of the
## row's depth; a seat is taken with probability `crowd`, varied per block of the stand.
## They are MultiMesh instances of two tiny meshes (a blocky seated figure near, a flat card
## further out) drawn with crowd.gdshader: the custom data is the shirt colour (linear) and a
## seed for everything else (trousers, skin, hair, idle motion, the odd cheer).
## Flags (flag.gdshader, cloth moved in the vertex shader) stand on whatever is highest over
## the top row of each stretch of stand: the roof of a covered stand, else the top row.
##
## Mesh conventions (both meshes): the origin is on the tread, -Z faces the track, +Y up.
## UV.x tags the part (0 legs, 1 torso, 2 head, 3 arm), UV.y the arm's side (-1 / +1).

const CROWD_SHADER := preload("res://scripts/track/crowd.gdshader")
const FLAG_SHADER := preload("res://scripts/track/flag.gdshader")

const SEAT_WIDTH: float = 0.55        ## m along the row per seat
const ROW_DEPTH: float = 0.85         ## m, as baked (scenery_glb.ROW_DEPTH)
const CELL: float = 48.0              ## m: spectators are grouped in cells this size (visibility)
const NEAR_RANGE: float = 75.0        ## m: the blocky figures up to here, cards beyond
const FAR_RANGE: float = 320.0        ## m: no spectators beyond (the seat shader's speckle stays)
const LIMIT: int = 150000             ## spectators per track at most
const FLAG_CELL: float = 42.0         ## m: at most one flag per cell of stand
const FLAG_RANGE: float = 700.0
const FLAG_LIMIT: int = 48
const FLAG_POLE: float = 5.5          ## m above the roof
const FLAG_SIZE := Vector2(2.4, 1.55) ## m, the cloth
## Flag designs of flag.gdshader: [design, colour 1, colour 2, colour 3] (sRGB). National
## flags and fictional ones, no brands.
const FLAGS: Array = [
	[0, Color(0.0, 0.33, 0.64), Color(0.95, 0.95, 0.95), Color(0.94, 0.25, 0.21)],   # France
	[0, Color(0.0, 0.33, 0.64), Color(0.95, 0.95, 0.95), Color(0.94, 0.25, 0.21)],
	[2, Color(0.05, 0.05, 0.05), Color(0.95, 0.95, 0.95), Color(0.0, 0.0, 0.0)],     # chequered
	[2, Color(0.05, 0.05, 0.05), Color(0.95, 0.95, 0.95), Color(0.0, 0.0, 0.0)],
	[0, Color(0.0, 0.57, 0.27), Color(0.95, 0.95, 0.95), Color(0.81, 0.17, 0.22)],   # Italy
	[0, Color(0.05, 0.05, 0.05), Color(0.99, 0.85, 0.14), Color(0.94, 0.20, 0.25)],  # Belgium
	[1, Color(0.05, 0.05, 0.05), Color(0.87, 0.0, 0.0), Color(1.0, 0.81, 0.0)],      # Germany
	[1, Color(0.68, 0.11, 0.16), Color(0.95, 0.95, 0.95), Color(0.13, 0.27, 0.55)],  # Netherlands
	[4, Color(0.95, 0.95, 0.95), Color(0.74, 0.0, 0.18), Color(0.0, 0.0, 0.0)],      # Japan
	[5, Color(0.0, 0.42, 0.66), Color(1.0, 0.8, 0.0), Color(0.0, 0.0, 0.0)],         # Sweden
	[3, Color(0.10, 0.45, 0.30), Color(0.96, 0.78, 0.20), Color(0.0, 0.0, 0.0)],     # fictional
	[3, Color(0.55, 0.10, 0.45), Color(0.95, 0.95, 0.95), Color(0.0, 0.0, 0.0)],     # fictional
]
## Shirt colours (sRGB): mostly white, grey, black and navy, some colour; weights by
## repetition.
const SHIRTS: Array[Color] = [
	Color(0.90, 0.90, 0.88), Color(0.90, 0.90, 0.88), Color(0.82, 0.83, 0.85), Color(0.82, 0.83, 0.85),
	Color(0.12, 0.12, 0.13), Color(0.12, 0.12, 0.13), Color(0.16, 0.18, 0.25), Color(0.16, 0.18, 0.25),
	Color(0.24, 0.28, 0.40), Color(0.45, 0.47, 0.50), Color(0.45, 0.47, 0.50), Color(0.60, 0.56, 0.48),
	Color(0.68, 0.62, 0.52), Color(0.30, 0.36, 0.30), Color(0.40, 0.48, 0.60),
	Color(0.70, 0.20, 0.17), Color(0.75, 0.38, 0.18), Color(0.85, 0.70, 0.25),
	Color(0.22, 0.42, 0.68), Color(0.30, 0.52, 0.35), Color(0.48, 0.25, 0.42), Color(0.80, 0.55, 0.60),
]

static var _meshes := {}

## Deterministic hash of three numbers, 0..1.
static func rand3(a: float, b: float, c: float) -> float:
	var h := hash(Vector3(snappedf(a, 0.01), snappedf(b, 0.01), snappedf(c, 0.01)))
	return float(h & 0xFFFF) / 65536.0

## Seats of the stand_seats surfaces of `mi` (world space). Returns
## {spots: Array of [origin: Vector3, facing: Vector3]}: every seat, taken or not.
static func seat_spots(mi: MeshInstance3D, xf: Transform3D) -> Array:
	var out: Array = []
	var seen := {}
	for surf in mi.mesh.get_surface_count():
		if Scenery.surface_name(mi.mesh, surf) != "stand_seats":
			continue
		var arrays := mi.mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
		if uvs == null or (uvs as PackedVector2Array).size() != verts.size():
			continue
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		var count: int = (idx as PackedInt32Array).size() if idx != null else verts.size()
		for t in range(0, count - 2, 3):
			var i0: int = idx[t] if idx != null else t
			var i1: int = idx[t + 1] if idx != null else t + 1
			var i2: int = idx[t + 2] if idx != null else t + 2
			var a := xf * verts[i0]
			var b := xf * verts[i1]
			var c := xf * verts[i2]
			var n := (b - a).cross(c - a)
			if n.length_squared() < 1e-6 or absf(n.normalized().y) < 0.97:
				continue    # risers and sloping faces: no one sits there
			var ua: Vector2 = uvs[i0]
			var ub: Vector2 = uvs[i1]
			var uc: Vector2 = uvs[i2]
			# UV -> world xz is affine on the triangle: P = a + E * inverse(D) * (uv - ua).
			var d1 := ub - ua
			var d2 := uc - ua
			var det := d1.x * d2.y - d1.y * d2.x
			if absf(det) < 1e-8:
				continue
			var e1 := b - a
			var e2 := c - a
			# World offset per unit of v (its column of E * inverse(D)), then the facing.
			var dv := (e2 * d1.x - e1 * d2.x) / det
			var facing := Vector3(-dv.x, 0.0, -dv.z)
			if facing.length_squared() < 1e-8:
				continue
			facing = facing.normalized()
			var vmin := minf(ua.y, minf(ub.y, uc.y))
			var vmax := maxf(ua.y, maxf(ub.y, uc.y))
			var umin := minf(ua.x, minf(ub.x, uc.x))
			var umax := maxf(ua.x, maxf(ub.x, uc.x))
			var rows: Array[float] = []
			if vmax - vmin < ROW_DEPTH * 1.6:
				rows.append((vmin + vmax) * 0.5)
			else:
				var v := vmin + ROW_DEPTH * 0.5
				while v < vmax:
					rows.append(v)
					v += ROW_DEPTH
			for v in rows:
				for k in range(floori(umin / SEAT_WIDTH), ceili(umax / SEAT_WIDTH)):
					var p := Vector2((k + 0.5) * SEAT_WIDTH, v)
					# Barycentric in UV space.
					var q := p - ua
					var s := (q.x * d2.y - q.y * d2.x) / det
					var r := (d1.x * q.y - d1.y * q.x) / det
					if s < -1e-4 or r < -1e-4 or s + r > 1.0001:
						continue
					var pos := a + e1 * s + e2 * r
					var key := Vector3i(roundi(pos.x * 5.0), roundi(pos.y * 5.0), roundi(pos.z * 5.0))
					if seen.has(key):
						continue
					seen[key] = true
					out.append([pos, facing, k])
	return out

## MultiMesh buffer rows (3x4 transform + custom) for the taken seats among `spots`.
static func spectators(spots: Array, crowd: float) -> Dictionary:
	var cells := {}   # Vector2i -> PackedFloat32Array
	var shirts: Array[Color] = []
	for c in SHIRTS:
		shirts.append(c.srgb_to_linear())
	for spot: Array in spots:
		var pos: Vector3 = spot[0]
		var facing: Vector3 = spot[1]
		# Blocks of ~8 seats across a few rows are fuller or emptier than the average.
		var block := rand3(floorf(float(spot[2]) / 14.0), roundf(pos.y / 1.5), 3.0)
		var fill := clampf(crowd * (0.45 + 1.1 * block), 0.0, 0.97)
		var r := rand3(pos.x, pos.y, pos.z)
		if r >= fill:
			continue
		var r2 := rand3(pos.z, pos.x, pos.y + 1.0)
		var r3 := rand3(pos.y, pos.z + 2.0, pos.x)
		var yaw := atan2(-facing.x, -facing.z) + (r2 - 0.5) * 0.35
		var size := 0.92 + 0.16 * r3
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * size)
		var side := basis.x.normalized()
		var o := pos + side * (r3 - 0.5) * 0.12
		var shirt := shirts[int(r2 * 7919.0) % shirts.size()]
		var key := Vector2i(floori(pos.x / CELL), floori(pos.z / CELL))
		var buf: PackedFloat32Array = cells.get(key, PackedFloat32Array())
		buf.append_array(PackedFloat32Array([
			basis.x.x, basis.y.x, basis.z.x, o.x,
			basis.x.y, basis.y.y, basis.z.y, o.y,
			basis.x.z, basis.y.z, basis.z.z, o.z,
			shirt.r, shirt.g, shirt.b, fmod(r * 13.37 + r2, 1.0)]))
		cells[key] = buf
	return cells

## One flag spot per FLAG_CELL of stand: [top, facing, front] where top is the highest seat
## there and front the lowest (a covered stand flies its flags on the front of the roof).
static func flag_spots(spots: Array) -> Array:
	var best := {}
	for spot: Array in spots:
		var pos: Vector3 = spot[0]
		var key := Vector2i(floori(pos.x / FLAG_CELL), floori(pos.z / FLAG_CELL))
		if not best.has(key):
			best[key] = [pos, spot[1], pos]
		elif (best[key][0] as Vector3).y < pos.y:
			best[key][0] = pos
			best[key][1] = spot[1]
		elif (best[key][2] as Vector3).y > pos.y:
			best[key][2] = pos
	return best.values()

## Height (world y) of the highest face of `mi` over each of `points` (xz): a roof when there
## is one. Points with nothing above keep their own height.
static func highest_over(mi: MeshInstance3D, xf: Transform3D, points: Array[Vector3]) -> Array[float]:
	var out: Array[float] = []
	for p in points:
		out.append(p.y)
	if points.is_empty():
		return out
	for surf in mi.mesh.get_surface_count():
		var arrays := mi.mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		var count: int = (idx as PackedInt32Array).size() if idx != null else verts.size()
		for t in range(0, count - 2, 3):
			var a := xf * verts[idx[t] if idx != null else t]
			var b := xf * verts[idx[t + 1] if idx != null else t + 1]
			var c := xf * verts[idx[t + 2] if idx != null else t + 2]
			var lo := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
			var hi := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
			var top := maxf(a.y, maxf(b.y, c.y))
			for i in points.size():
				var p := points[i]
				if top <= out[i] or p.x < lo.x or p.x > hi.x or p.z < lo.y or p.z > hi.y:
					continue
				# Height of the triangle's plane at p, when p is inside it (xz).
				var v0 := Vector2(b.x - a.x, b.z - a.z)
				var v1 := Vector2(c.x - a.x, c.z - a.z)
				var v2 := Vector2(p.x - a.x, p.z - a.z)
				var den := v0.x * v1.y - v1.x * v0.y
				if absf(den) < 1e-6:
					continue
				var s := (v2.x * v1.y - v1.x * v2.y) / den
				var r := (v0.x * v2.y - v2.x * v0.y) / den
				if s < 0.0 or r < 0.0 or s + r > 1.0:
					continue
				out[i] = maxf(out[i], a.y + (b.y - a.y) * s + (c.y - a.y) * r)
	return out

# ------------------------------------------------------------------------- meshes
## The spectator mesh: 0 = blocky seated figure, 1 = flat card.
static func spectator_mesh(lod: int) -> ArrayMesh:
	var key := "person%d" % lod
	if not _meshes.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		if lod == 0:
			# Thighs forward from the seat, torso, head, two arms (no back or bottom faces:
			# the rows behind hide them).
			_box(st, Vector3(-0.17, 0.0, -0.36), Vector3(0.17, 0.42, 0.02), 0.0, 0.0, false)
			_box(st, Vector3(-0.20, 0.42, -0.02), Vector3(0.20, 0.98, 0.22), 1.0, 0.0, true)
			_box(st, Vector3(-0.10, 1.01, -0.05), Vector3(0.10, 1.25, 0.15), 2.0, 0.0, true)
			_box(st, Vector3(-0.29, 0.50, 0.0), Vector3(-0.20, 0.96, 0.14), 3.0, -1.0, false)
			_box(st, Vector3(0.20, 0.50, 0.0), Vector3(0.29, 0.96, 0.14), 3.0, 1.0, false)
		else:
			_card(st, Vector3(-0.18, 0.0, -0.25), Vector3(0.18, 0.45, -0.25), 0.0)
			_card(st, Vector3(-0.22, 0.42, 0.0), Vector3(0.22, 0.98, 0.0), 1.0)
			_card(st, Vector3(-0.10, 1.0, 0.0), Vector3(0.10, 1.24, 0.0), 2.0)
		_meshes[key] = st.commit()
	return _meshes[key]

## Front, top, two sides and (with `back`) the back of an axis-aligned box.
static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3, part: float, side: float, back: bool) -> void:
	var c := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z),
			Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	var faces := [[0, 1, 2, 3], [3, 2, 6, 7], [0, 3, 7, 4], [1, 5, 6, 2]]   # front (-z), top, left, right
	if back:
		faces.append([4, 7, 6, 5])
	var centre := (lo + hi) * 0.5
	for f: Array in faces:
		var mid: Vector3 = (c[f[0]] + c[f[1]] + c[f[2]] + c[f[3]]) * 0.25
		_quad(st, c[f[0]], c[f[1]], c[f[2]], c[f[3]], (mid - centre).normalized(), part, side)

static func _card(st: SurfaceTool, lo: Vector3, hi: Vector3, part: float) -> void:
	_quad(st, Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
			Vector3(0.0, 0.25, -1.0).normalized(), part, 0.0)

## Quad a-b-c-d (a convex loop either way round) facing `out`: wound so that it is a front
## face seen from that side (Godot: clockwise), with that flat normal.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, out: Vector3,
		part: float, side: float) -> void:
	var pts: Array[Vector3] = [a, b, c, a, c, d]
	if (c - a).cross(b - a).dot(out) < 0.0:
		pts = [a, c, b, a, d, c]
	st.set_uv(Vector2(part, side))
	st.set_normal(out)
	for p in pts:
		st.add_vertex(p)

## Pole and cloth of a flag: surface 0 the pole, surface 1 the cloth (UV 0..1, u = 0 at the
## pole), FLAG_POLE tall, the cloth FLAG_SIZE flying along +X.
static func flag_mesh() -> ArrayMesh:
	if _meshes.has("flag"):
		return _meshes["flag"]
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := 0.035
	for k in 4:
		var a0 := TAU * k / 4.0 + PI / 4.0
		var a1 := TAU * (k + 1) / 4.0 + PI / 4.0
		var p0 := Vector3(cos(a0) * r, 0.0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0.0, sin(a1) * r)
		var up := Vector3(0.0, FLAG_POLE + 0.1, 0.0)
		_quad(st, p0, p1, p1 + up, p0 + up, (p0 + p1).normalized(), 0.0, 0.0)
	st.commit(mesh)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nx := 12
	var ny := 4
	var w := FLAG_SIZE.x
	var h := FLAG_SIZE.y
	for j in ny:
		for i in nx:
			var corners: Array[Vector2] = [Vector2(i, j), Vector2(i, j + 1), Vector2(i + 1, j + 1),
					Vector2(i, j), Vector2(i + 1, j + 1), Vector2(i + 1, j)]
			for g in corners:
				var uv := Vector2(g.x / nx, g.y / ny)
				st.set_uv(uv)
				st.set_normal(Vector3(0.0, 0.0, 1.0))
				st.add_vertex(Vector3(0.04 + uv.x * w, FLAG_POLE - uv.y * h, 0.0))
	st.commit(mesh)
	_meshes["flag"] = mesh
	return mesh
