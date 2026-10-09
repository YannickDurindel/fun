class_name SceneryTrees
extends RefCounted
## Low-poly tree meshes for Scenery, built in code (the project has no texture or model files
## for vegetation). One mesh per species (TrackEnvironment.SPECIES order: conifer, broadleaf,
## palm, cypress, bush) and level of detail: 0 = beside the track, 1 = the far copy.
## Every mesh is 1 unit tall with its base at the origin, so an instance is scaled by the
## tree's height. Vertex colour as shaders/scenery_tree.gdshader reads it: r = shade,
## g = 1 foliage / 0 trunk, b = sway weight. Triangle counts are kept small on purpose:
## thousands of instances are drawn (MultiMesh).

const LODS: int = 2

static var _cache := {}

## Mesh of species id `species` at level of detail `lod` (cached).
static func mesh(species: int, lod: int) -> ArrayMesh:
	var key := species * LODS + lod
	if not _cache.has(key):
		_cache[key] = _build(species, lod)
	return _cache[key]

## Triangles of one mesh (for budgets and tests).
static func triangle_count(species: int, lod: int) -> int:
	var m := mesh(species, lod)
	return (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3

static func _build(species: int, lod: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var far := lod > 0
	match species:
		0:   # conifer: stacked cones
			if far:
				_cone(st, 0.08, 1.0, 0.27, 5, 0.72)
			else:
				_trunk(st, 0.16, 0.035, 4)
				_cone(st, 0.12, 0.58, 0.30, 7, 0.62)
				_cone(st, 0.38, 0.80, 0.22, 7, 0.78)
				_cone(st, 0.62, 1.00, 0.14, 6, 0.95)
		1:   # broadleaf: a few lumpy crowns on a trunk
			if far:
				_trunk(st, 0.38, 0.04, 3)
				_blob(st, Vector3(0.0, 0.66, 0.0), Vector3(0.36, 0.34, 0.36), 6, 4, 1.0)
			else:
				_trunk(st, 0.42, 0.04, 5)
				_blob(st, Vector3(0.0, 0.70, 0.0), Vector3(0.30, 0.30, 0.30), 7, 4, 1.0)
				_blob(st, Vector3(0.20, 0.56, 0.08), Vector3(0.22, 0.19, 0.22), 5, 3, 2.0)
				_blob(st, Vector3(-0.17, 0.60, -0.13), Vector3(0.24, 0.20, 0.24), 5, 3, 3.0)
		2:   # palm: thin trunk, drooping fronds
			_trunk(st, 0.86, 0.022, 4 if far else 5, 0.06)
			_fronds(st, Vector3(0.06, 0.86, 0.0), 6 if far else 9, 2 if far else 4)
		3:   # cypress: a tall narrow flame
			_trunk(st, 0.08, 0.03, 3)
			_blob(st, Vector3(0.0, 0.53, 0.0), Vector3(0.11, 0.47, 0.11), 5 if far else 7, 4 if far else 6, 4.0, 0.12)
		_:   # bush
			_blob(st, Vector3(0.0, 0.42, 0.0), Vector3(0.62, 0.50, 0.62), 5 if far else 7, 3 if far else 4, 5.0)
	return st.commit()

## Trunk from the ground to `height`, `sides` faces, leaning `lean` sideways at the top.
static func _trunk(st: SurfaceTool, height: float, radius: float, sides: int, lean: float = 0.0) -> void:
	for k in sides:
		var a0 := TAU * k / sides
		var a1 := TAU * (k + 1) / sides
		var n0 := Vector3(cos(a0), 0.0, sin(a0))
		var n1 := Vector3(cos(a1), 0.0, sin(a1))
		var top := Vector3(lean, height, 0.0)
		_tri(st, n0 * radius, top + n0 * radius * 0.6, n1 * radius, n0, n0, n1, Color(0.8, 0.0, 0.0), Color(0.9, 0.0, 0.3), Color(0.8, 0.0, 0.0))
		_tri(st, n1 * radius, top + n0 * radius * 0.6, top + n1 * radius * 0.6, n1, n0, n1, Color(0.8, 0.0, 0.0), Color(0.9, 0.0, 0.3), Color(0.9, 0.0, 0.3))

## Cone of foliage from y0 (radius r) to its tip at y1; `shade` brightens upper tiers.
static func _cone(st: SurfaceTool, y0: float, y1: float, r: float, sides: int, shade: float) -> void:
	var slant := r / (y1 - y0)
	for k in sides:
		var a0 := TAU * k / sides
		var a1 := TAU * (k + 1) / sides
		var am := (a0 + a1) * 0.5
		# A ragged skirt: every other corner hangs a little lower.
		var d0 := 0.03 if k % 2 == 0 else 0.0
		var d1 := 0.03 if (k + 1) % 2 == 0 else 0.0
		var p0 := Vector3(cos(a0) * r, y0 - d0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, y0 - d1, sin(a1) * r)
		var n0 := Vector3(cos(a0), slant, sin(a0)).normalized()
		var n1 := Vector3(cos(a1), slant, sin(a1)).normalized()
		var nm := Vector3(cos(am), slant, sin(am)).normalized()
		var low := Color(shade * 0.72, 1.0, y0)
		_tri(st, p0, Vector3(0.0, y1, 0.0), p1, n0, nm, n1, low, Color(shade, 1.0, y1), low)
		# Underside, so the tier is not hollow seen from below.
		_tri(st, p0, p1, Vector3(0.0, y0 + 0.02, 0.0), Vector3.DOWN, Vector3.DOWN, Vector3.DOWN,
				Color(shade * 0.45, 1.0, y0), Color(shade * 0.45, 1.0, y0), Color(shade * 0.4, 1.0, y0))

## Lumpy ellipsoid of foliage. `seed` varies the lumps, `taper` > 0 pulls the top to a point.
static func _blob(st: SurfaceTool, centre: Vector3, radii: Vector3, segments: int, rings: int,
		seed: float, taper: float = 0.0) -> void:
	var pts: Array[PackedVector3Array] = []
	for j in rings + 1:
		var row := PackedVector3Array()
		var v := float(j) / rings
		var phi := PI * v
		for i in segments + 1:
			var a := TAU * (i % segments) / segments
			var lump := 1.0
			if j > 0 and j < rings:
				lump = 0.84 + 0.32 * absf(sin(a * 2.3 + seed * 1.7 + j * 1.9) * cos(a * 1.1 + seed + j * 0.7))
			var dir := Vector3(sin(phi) * cos(a), -cos(phi), sin(phi) * sin(a))
			var p := centre + dir * radii * lump
			if taper > 0.0:
				# Narrower towards the top (cypress).
				var k := 1.0 - taper * 4.0 * maxf(v - 0.5, 0.0)
				p.x = centre.x + (p.x - centre.x) * k
				p.z = centre.z + (p.z - centre.z) * k
			row.append(p)
		pts.append(row)
	for j in rings:
		for i in segments:
			var a := pts[j][i]
			var b := pts[j][i + 1]
			var c := pts[j + 1][i]
			var d := pts[j + 1][i + 1]
			if j > 0:
				_blob_tri(st, a, c, b, centre, radii)
			if j < rings - 1:
				_blob_tri(st, b, c, d, centre, radii)

static func _blob_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, centre: Vector3, radii: Vector3) -> void:
	var cols: Array[Color] = []
	var nrm: Array[Vector3] = []
	for p: Vector3 in [a, b, c]:
		var rel := (p - centre) / radii
		nrm.append(rel.normalized())
		# Darker underneath, brighter on top.
		cols.append(Color(0.48 + 0.52 * clampf(rel.y * 0.55 + 0.45, 0.0, 1.0), 1.0, p.y))
	_tri(st, a, b, c, nrm[0], nrm[1], nrm[2], cols[0], cols[1], cols[2])

## Palm crown: `count` fronds arching out and down from `top`, each a tapering two-sided strip.
static func _fronds(st: SurfaceTool, top: Vector3, count: int, segments: int) -> void:
	for k in count:
		var a := TAU * k / count + 0.4 * sin(k * 2.1)
		var out := Vector3(cos(a), 0.0, sin(a))
		var side := Vector3(-sin(a), 0.0, cos(a))
		var length := 0.34 + 0.06 * sin(k * 1.3)
		var lift := 0.10 + 0.05 * cos(k * 1.7)
		var prev_c := top
		var prev_w := 0.035
		for s in segments:
			var t := float(s + 1) / segments
			# Rises a little, then droops below the crown.
			var c := top + out * length * t + Vector3.UP * (lift * sin(t * PI) - 0.22 * t * t)
			var w := 0.06 * (1.0 - t) + 0.008
			var n := (Vector3.UP + out * (t - 0.3)).normalized()
			var c0 := Color(0.95 - 0.25 * t, 1.0, 0.9)
			var c1 := Color(c0.r * 0.7, 1.0, 0.9)   # underside
			for flip in 2:
				var sg := 1.0 if flip == 0 else -1.0
				var nn := n * sg
				if flip == 0:
					_tri(st, prev_c - side * prev_w, c - side * w, prev_c + side * prev_w, nn, nn, nn, c0, c0, c0)
					_tri(st, prev_c + side * prev_w, c - side * w, c + side * w, nn, nn, nn, c0, c0, c0)
				else:
					_tri(st, prev_c - side * prev_w, prev_c + side * prev_w, c - side * w, nn, nn, nn, c1, c1, c1)
					_tri(st, prev_c + side * prev_w, c + side * w, c - side * w, nn, nn, nn, c1, c1, c1)
			prev_c = c
			prev_w = w

## One triangle a-b-c with per-corner normals and colours, wound so its front faces `na`.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
		ca: Color, cb: Color, cc: Color) -> void:
	# Godot front faces wind clockwise: the visible normal is -(b-a)x(c-a).
	var flip := (b - a).cross(c - a).dot(na + nb + nc) > 0.0
	var vs := [a, c, b] if flip else [a, b, c]
	var ns := [na, nc, nb] if flip else [na, nb, nc]
	var cs := [ca, cc, cb] if flip else [ca, cb, cc]
	for k in 3:
		st.set_normal(ns[k])
		st.set_color(cs[k])
		st.add_vertex(vs[k])
