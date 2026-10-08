class_name Terrain
extends Node3D
## Valley terrain around the Red Bull Ring, built at startup from the heightmaps baked by
## tools/track/fetch_terrain.py:
##   * near grid (10 m, corridor-conformed under the road) -> chunked ArrayMeshes, each with a
##     trimesh StaticBody3D (meta surface = "grass");
##   * far grid (200 m, out to ~6 km) -> one low-poly hills mesh with a hole where the near
##     grid is (their shared edge matches exactly), plus coarse collision.
## Everything uses shaders/terrain.gdshader. Terrain does not cast shadows (cheap on HD 520).

@export_file("*.json") var terrain_json: String = "res://assets/tracks/red_bull_ring/terrain.json"
@export var chunk_cells: int = 40   ## near grid cells per chunk side (400 m)
@export var collision: bool = true

const SHADER := preload("res://shaders/terrain.gdshader")

var near_x0: float
var near_z0: float
var near_step: float
var near_nx: int
var near_nz: int
var near_h: PackedFloat32Array
var near_d: PackedInt32Array  ## distance to the centreline, decimetres
var far_x0: float
var far_z0: float
var far_step: float
var far_nx: int
var far_nz: int
var far_h: PackedFloat32Array
var material: ShaderMaterial

func _ready() -> void:
	if not _load():
		return
	material = ShaderMaterial.new()
	material.shader = SHADER
	_build_near()
	_build_far()

func _load() -> bool:
	var f := FileAccess.open(terrain_json, FileAccess.READ)
	if f == null:
		push_error("Terrain: cannot open %s" % terrain_json)
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary and parsed.has("near") and parsed.has("far")):
		push_error("Terrain: malformed %s" % terrain_json)
		return false
	var meta: Dictionary = parsed
	var dir := terrain_json.get_base_dir()
	var near: Dictionary = meta["near"]
	near_x0 = float(near["x0"])
	near_z0 = float(near["z0"])
	near_step = float(near["step"])
	near_nx = int(near["nx"])
	near_nz = int(near["nz"])
	near_h = FileAccess.get_file_as_bytes(dir.path_join(near["file"])).to_float32_array()
	near_d = _u16(FileAccess.get_file_as_bytes(dir.path_join(near["dist_file"])))
	var far: Dictionary = meta["far"]
	far_x0 = float(far["x0"])
	far_z0 = float(far["z0"])
	far_step = float(far["step"])
	far_nx = int(far["nx"])
	far_nz = int(far["nz"])
	far_h = FileAccess.get_file_as_bytes(dir.path_join(far["file"])).to_float32_array()
	if near_h.size() != near_nx * near_nz or near_d.size() != near_h.size() or far_h.size() != far_nx * far_nz:
		push_error("Terrain: heightmap sizes do not match %s" % terrain_json)
		return false
	return true

## Terrain height at world (x, z) from the near grid (bilinear; matches the mesh within cm).
## Returns NAN outside the near grid.
func height_at(x: float, z: float) -> float:
	if near_h.is_empty():
		return NAN
	var u := (x - near_x0) / near_step
	var v := (z - near_z0) / near_step
	if u < 0.0 or v < 0.0 or u > near_nx - 1 or v > near_nz - 1:
		return NAN
	var i := mini(int(u), near_nx - 2)
	var j := mini(int(v), near_nz - 2)
	var tu := u - i
	var tv := v - j
	var a := lerpf(near_h[j * near_nx + i], near_h[j * near_nx + i + 1], tu)
	var b := lerpf(near_h[(j + 1) * near_nx + i], near_h[(j + 1) * near_nx + i + 1], tu)
	return lerpf(a, b, tv)

static func _u16(bytes: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(bytes.size() / 2)
	for n in out.size():
		out[n] = bytes.decode_u16(n * 2)
	return out

## Central-difference normal of grid `h` (nx columns, nz rows, `step` m) at column i, row j.
static func _grid_normal(h: PackedFloat32Array, nx: int, nz: int, step: float, i: int, j: int) -> Vector3:
	var il := maxi(i - 1, 0)
	var ir := mini(i + 1, nx - 1)
	var jd := maxi(j - 1, 0)
	var ju := mini(j + 1, nz - 1)
	var dx := (h[j * nx + ir] - h[j * nx + il]) / ((ir - il) * step)
	var dz := (h[ju * nx + i] - h[jd * nx + i]) / ((ju - jd) * step)
	return Vector3(-dx, 1.0, -dz).normalized()

func _build_near() -> void:
	var cells_x := near_nx - 1
	var cells_z := near_nz - 1
	for cj in range(0, cells_z, chunk_cells):
		for ci in range(0, cells_x, chunk_cells):
			var w := mini(chunk_cells, cells_x - ci)
			var h := mini(chunk_cells, cells_z - cj)
			_build_near_chunk(ci, cj, w, h)

func _build_near_chunk(ci: int, cj: int, w: int, h: int) -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	verts.resize((w + 1) * (h + 1))
	normals.resize(verts.size())
	uvs.resize(verts.size())
	var k := 0
	for j in range(cj, cj + h + 1):
		for i in range(ci, ci + w + 1):
			var g := j * near_nx + i
			verts[k] = Vector3(near_x0 + i * near_step, near_h[g], near_z0 + j * near_step)
			normals[k] = _grid_normal(near_h, near_nx, near_nz, near_step, i, j)
			uvs[k] = Vector2(near_d[g] * 0.1, 0.0)
			k += 1
	_grid_indices(idx, w, h, PackedByteArray())
	_add_mesh("Near_%d_%d" % [ci, cj], verts, normals, uvs, idx)

## Two triangles per cell (clockwise seen from above = Godot front face up). `skip[c]` != 0 omits a cell.
func _grid_indices(idx: PackedInt32Array, w: int, h: int, skip: PackedByteArray) -> void:
	for j in h:
		for i in w:
			if not skip.is_empty() and skip[j * w + i] != 0:
				continue
			var a := j * (w + 1) + i
			var b := a + 1
			var c := a + (w + 1)
			var d := c + 1
			idx.append_array(PackedInt32Array([a, b, c, b, d, c]))

func _build_far() -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(far_nx * far_nz)
	normals.resize(verts.size())
	uvs.resize(verts.size())
	for j in far_nz:
		for i in far_nx:
			var g := j * far_nx + i
			verts[g] = Vector3(far_x0 + i * far_step, far_h[g], far_z0 + j * far_step)
			normals[g] = _grid_normal(far_h, far_nx, far_nz, far_step, i, j)
			uvs[g] = Vector2(1000.0, 0.0)
	# Hole: skip far cells covered by the near grid.
	var near_x1 := near_x0 + (near_nx - 1) * near_step
	var near_z1 := near_z0 + (near_nz - 1) * near_step
	var skip := PackedByteArray()
	skip.resize((far_nx - 1) * (far_nz - 1))
	for j in far_nz - 1:
		for i in far_nx - 1:
			var cx := far_x0 + (i + 0.5) * far_step
			var cz := far_z0 + (j + 0.5) * far_step
			skip[j * (far_nx - 1) + i] = 1 if (cx > near_x0 and cx < near_x1 and cz > near_z0 and cz < near_z1) else 0
	var idx := PackedInt32Array()
	_grid_indices(idx, far_nx - 1, far_nz - 1, skip)
	_add_mesh("FarHills", verts, normals, uvs, idx)

func _add_mesh(node_name: String, verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, idx: PackedInt32Array) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	if not collision:
		return
	var shape := mesh.create_trimesh_shape()
	var body := StaticBody3D.new()
	body.name = node_name + "_Body"
	body.set_meta("surface", "grass")
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
