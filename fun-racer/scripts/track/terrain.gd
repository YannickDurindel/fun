class_name Terrain
extends Node3D
## Terrain around a track (the Track's `Terrain` slot), built at startup.
##
## With terrain.json in the track folder (heightmaps baked by tools/track/fetch_terrain.py):
##   * near grid (10 m, corridor-conformed under the road) -> chunked ArrayMeshes, each with a
##     trimesh StaticBody3D (meta surface = "grass");
##   * far grid (200 m, out to ~6 km) -> one low-poly hills mesh with a hole where the near
##     grid is (their shared edge matches exactly), plus coarse collision.
## Without one (a track whose terrain is not built yet): a plain ground grid that follows the
## centreline heights and stays just below the road and its verges (see _build_fallback_grid).
## Everything uses shaders/terrain.gdshader. Terrain does not cast shadows (cheap on HD 520).
##
## Ground types: with landcover.png / landcover_far.png in the track folder (8-bit class id per
## cell, grids described by scenery.json, see Scenery) the shader paints every class with the
## track's palette (TrackEnvironment "terrain_palette") instead of plain grass. Vertices on
## water cells are lowered below the water level of the body they lie in, so the water planes
## Scenery draws are what shows; the collision keeps the baked heights. Without the files the
## terrain looks exactly as before.

const TERRAIN_FILE := "terrain.json"
## Fallback ground: grid step, margin around the lap, how far from the centreline the road
## corridor reaches (road + full verge + a cell diagonal) and how far below the lowest point
## of the road and its verges the ground sits.
const FALLBACK_STEP: float = 20.0
const FALLBACK_MARGIN: float = 400.0
const FALLBACK_REACH: float = 70.0
const FALLBACK_CLEARANCE: float = 0.35
const FALLBACK_VERGE_DROP: float = 0.25   ## assumed when the Road slot cannot be asked
const LANDCOVER_FILE := "landcover.png"
const LANDCOVER_FAR_FILE := "landcover_far.png"
const CLASS_WATER: int = 2
## Water cells: the visible ground ends up this far below the water level (or, for a cell in
## no water body of scenery.json, this far below its own height).
const WATER_DEPTH: float = 2.0
## Coarsest mip of the near land cover the shader uses (2.5 m cells -> 40 m).
const LANDCOVER_MAX_LOD: int = 4
## Where a vertex looks for water cells: itself, then 4 m around it.
const WATER_PROBES: Array[Vector2] = [Vector2.ZERO, Vector2(4.0, 0.0), Vector2(-4.0, 0.0),
		Vector2(0.0, 4.0), Vector2(0.0, -4.0)]

## Leave empty to use terrain.json of the parent Track's folder.
@export_file("*.json") var terrain_json: String = ""
@export var chunk_cells: int = 40   ## near grid cells per chunk side (400 m)
@export var collision: bool = true

## True when no terrain.json was found and the plain fallback ground was built instead.
var is_fallback: bool = false

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
## terrain.json "origin_latlon" (lat, lon of the frame origin) and "plan_scale": what turns a
## latitude / longitude into track metres (see latlon_to_xz). `has_origin` false = not baked.
var origin_latlon: Vector2 = Vector2.ZERO
var plan_scale: float = 1.0
var has_origin: bool = false
## True when land-cover textures are in use.
var has_landcover: bool = false
## Number of mesh vertices lowered because they lie on water cells.
var sunk_vertices: int = 0

var _lc_near := {}   ## {bytes, x0, z0, step, nx, nz} of landcover.png, empty without one
var _lc_far := {}
var _water: Array[Dictionary] = []   ## {level, polygon: PackedVector2Array, rect: Rect2}
var _layers: int = 1

func _ready() -> void:
	var track := get_parent() as Track
	if terrain_json.is_empty() and track != null:
		terrain_json = track.file_path(TERRAIN_FILE)
	material = ShaderMaterial.new()
	material.shader = SHADER
	if track != null:
		_setup_look(track)
	if not terrain_json.is_empty() and FileAccess.file_exists(terrain_json):
		if _load():
			_build_near()
			_build_far()
			return
		_clear_grids()   # a broken bake: fall through to the plain ground
	if track != null and track.data != null \
			and _build_fallback_grid(track.data, track.get_node_or_null(^"Road") as RoadSurface):
		is_fallback = true
		_build_near()

func _clear_grids() -> void:
	near_h = PackedFloat32Array()
	near_d = PackedInt32Array()
	far_h = PackedFloat32Array()

## Plain ground for a track without baked terrain, as a near grid (so _build_near() and
## height_at() work unchanged). Every node within FALLBACK_REACH of the lap takes the lowest
## road height in that radius minus FALLBACK_CLEARANCE, where the road height of a
## cross-section is its lowest point (banked edges and verge ends, asked from the Road slot
## `road` when it is a RoadSurface). The reach covers the road, a full verge and a cell
## diagonal, so the ground stays below them. Nodes further out continue the nearest ground
## outward (each ring = mean of the ring before).
func _build_fallback_grid(d: TrackData, road: RoadSurface = null) -> bool:
	if d.points.is_empty():
		return false
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in d.points:
		lo = lo.min(Vector2(p.x, p.z))
		hi = hi.max(Vector2(p.x, p.z))
	near_step = FALLBACK_STEP
	near_x0 = floorf((lo.x - FALLBACK_MARGIN) / near_step) * near_step
	near_z0 = floorf((lo.y - FALLBACK_MARGIN) / near_step) * near_step
	near_nx = ceili((hi.x + FALLBACK_MARGIN - near_x0) / near_step) + 1
	near_nz = ceili((hi.y + FALLBACK_MARGIN - near_z0) / near_step) + 1
	var count := near_nx * near_nz
	near_h = PackedFloat32Array()
	near_h.resize(count)
	near_h.fill(INF)
	var dist := PackedFloat32Array()
	dist.resize(count)
	dist.fill(INF)
	# Stamp the corridor.
	var stride := maxi(1, int(5.0 / maxf(d.step, 0.01)))
	var reach_cells := ceili(FALLBACK_REACH / near_step)
	var ring: PackedInt32Array = []
	var ask_road := road != null and road.data == d and road.widths.size() == d.points.size()
	for k in range(0, d.points.size(), stride):
		var p := d.points[k]
		var low := p.y - FALLBACK_VERGE_DROP - FALLBACK_CLEARANCE
		if ask_road:
			var s := k * d.step
			var hw := road.half_width_at(s)
			low = minf(p.y, minf(road.surface_point(s, -hw - road.verge_at(s, -1.0)).y,
					road.surface_point(s, hw + road.verge_at(s, 1.0)).y)) - FALLBACK_CLEARANCE
		var ci := roundi((p.x - near_x0) / near_step)
		var cj := roundi((p.z - near_z0) / near_step)
		for j in range(maxi(cj - reach_cells, 0), mini(cj + reach_cells, near_nz - 1) + 1):
			for i in range(maxi(ci - reach_cells, 0), mini(ci + reach_cells, near_nx - 1) + 1):
				var dx := near_x0 + i * near_step - p.x
				var dz := near_z0 + j * near_step - p.z
				var r := sqrt(dx * dx + dz * dz)
				if r > FALLBACK_REACH:
					continue
				var g := j * near_nx + i
				if near_h[g] == INF:
					ring.append(g)
				near_h[g] = minf(near_h[g], low)
				dist[g] = minf(dist[g], r)
	# Grow outward ring by ring.
	var ring_dist := FALLBACK_REACH
	while not ring.is_empty():
		ring_dist += near_step
		var sums := {}   # node -> Vector2(sum of heights, count) from the rings before
		for g in ring:
			var gi := g % near_nx
			var gj := g / near_nx
			for oj in range(-1, 2):
				for oi in range(-1, 2):
					var i := gi + oi
					var j := gj + oj
					if i < 0 or j < 0 or i >= near_nx or j >= near_nz:
						continue
					var q := j * near_nx + i
					if near_h[q] != INF:
						continue
					var acc: Vector2 = sums.get(q, Vector2.ZERO)
					sums[q] = acc + Vector2(near_h[g], 1.0)
		ring = PackedInt32Array()
		for q: int in sums:
			var acc: Vector2 = sums[q]
			near_h[q] = acc.x / acc.y
			dist[q] = ring_dist
			ring.append(q)
	near_d = PackedInt32Array()
	near_d.resize(count)
	for g in count:
		near_d[g] = mini(int(dist[g] * 10.0), 65535)
	return true

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
	var origin: Variant = meta.get("origin_latlon")
	if origin is Array and (origin as Array).size() >= 2:
		origin_latlon = Vector2(float(origin[0]), float(origin[1]))
		plan_scale = float(meta.get("plan_scale", 1.0))
		has_origin = true
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

## Track-frame (x, z) of a latitude / longitude, with the origin and plan scale of terrain.json.
func latlon_to_xz(lat: float, lon: float) -> Vector2:
	var m := 111320.0 * plan_scale
	return Vector2((lon - origin_latlon.y) * m * cos(deg_to_rad(origin_latlon.x)), -(lat - origin_latlon.x) * m)

## Land-cover class id at world (x, z) (TrackEnvironment.CLASSES), -1 where there is no data.
func class_at(x: float, z: float) -> int:
	for grid: Dictionary in [_lc_near, _lc_far]:
		if grid.is_empty():
			continue
		var i := floori((x - float(grid["x0"])) / float(grid["step"]))
		var j := floori((z - float(grid["z0"])) / float(grid["step"]))
		if i >= 0 and j >= 0 and i < int(grid["nx"]) and j < int(grid["nz"]):
			return (grid["bytes"] as PackedByteArray)[j * int(grid["nx"]) + i]
	return -1

# ------------------------------------------------------------------------- look
## Palette, land-cover textures, water bodies and floodlight term for the shader, from the
## Track's environment and scenery files. Nothing is set when the track has none of them.
func _setup_look(track: Track) -> void:
	var env := track.environment
	if env == null:
		return
	_lc_near = _load_landcover(track.scenery_path(LANDCOVER_FILE), track.scenery_meta.get("near", {}), true)
	_lc_far = _load_landcover(track.scenery_path(LANDCOVER_FAR_FILE), track.scenery_meta.get("far", {}), false)
	has_landcover = not _lc_near.is_empty() or not _lc_far.is_empty()
	if has_landcover:
		material.set_shader_parameter("has_landcover", true)
		material.set_shader_parameter("pal_a", env.palette(0))
		material.set_shader_parameter("pal_b", env.palette(1))
		for body: Dictionary in track.scenery_meta.get("water", []):
			var poly: PackedVector2Array = body["polygon"]
			var rect := Rect2(poly[0], Vector2.ZERO)
			for p in poly:
				rect = rect.expand(p)
			_water.append({"level": float(body["level"]), "polygon": poly, "rect": rect})
	if env.active:
		material.set_shader_parameter("grass_a", env.palette(0)[0])
		material.set_shader_parameter("grass_b", env.palette(1)[0])
		if not env.mowing_stripes():
			material.set_shader_parameter("stripe_strength", 0.0)
		if env.floodlit():
			# The floodlights do not light the terrain (see TrackEnvironment): the shader adds
			# them near the track instead.
			_layers = TrackEnvironment.LAYER_FAR
			var flood := env.flood_light().srgb_to_linear()
			material.set_shader_parameter("flood", Vector3(flood.r, flood.g, flood.b))
			material.set_shader_parameter("flood_reach", env.number("floodlights", "reach_m"))

## One land-cover grid: the class bytes (for class_at and the water cells) and its texture on
## the shader. `grid` = {x0, z0, step, nx, nz} of scenery.json. Empty when there is no file.
func _load_landcover(path: String, grid: Variant, near: bool) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	# Read as raw PNG, never as an imported texture: the values are class ids, not colours.
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK or img.is_empty():
		push_warning("Terrain: cannot read %s" % path)
		return {}
	if not (grid is Dictionary and (grid as Dictionary).has("step")):
		push_warning("Terrain: %s has no grid in scenery.json, ignored" % path.get_file())
		return {}
	img.convert(Image.FORMAT_R8)
	var g: Dictionary = grid
	var out := {"bytes": img.get_data(), "x0": float(g["x0"]), "z0": float(g["z0"]),
		"step": float(g["step"]), "nx": img.get_width(), "nz": img.get_height()}
	var prefix := "lc_near" if near else "lc_far"
	var lods := LANDCOVER_MAX_LOD if near else 0
	material.set_shader_parameter(prefix, _class_texture(img, lods))
	material.set_shader_parameter(prefix + "_rect", Vector4(out["x0"], out["z0"], 1.0 / float(out["step"]), float(lods)))
	material.set_shader_parameter(prefix + "_size", Vector2(img.get_width(), img.get_height()))
	return out

## Texture of class ids with point-sampled mipmaps (averaged ids would be other classes).
static func _class_texture(img: Image, lods: int) -> ImageTexture:
	if lods <= 0:
		return ImageTexture.create_from_image(img)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var level := 1
	while true:
		var lw := maxi(1, w >> level)
		var lh := maxi(1, h >> level)
		var mip := img.duplicate() as Image
		mip.resize(lw, lh, Image.INTERPOLATE_NEAREST)
		data.append_array(mip.get_data())
		if lw == 1 and lh == 1:
			break
		level += 1
	return ImageTexture.create_from_image(Image.create_from_data(w, h, true, Image.FORMAT_R8, data))

## Visible height of a vertex at (x, z) with baked height h: lowered when it lies on or
## right beside a water cell (so a stream narrower than the mesh grid still gets a bed).
func _visible_height(x: float, z: float, h: float) -> float:
	if not has_landcover:
		return h
	var p := Vector2(INF, INF)
	for o: Vector2 in WATER_PROBES:
		if class_at(x + o.x, z + o.y) == CLASS_WATER:
			p = Vector2(x + o.x, z + o.y)
			break
	if p.x == INF:
		return h
	sunk_vertices += 1
	for body in _water:
		if (body["rect"] as Rect2).has_point(p) and Geometry2D.is_point_in_polygon(p, body["polygon"]):
			return minf(h, float(body["level"]) - WATER_DEPTH)
	return h - WATER_DEPTH

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
	var solid := PackedVector3Array()   # baked heights for the collision, when water lowers any
	if has_landcover:
		solid.resize(verts.size())
	var lowered := false
	var k := 0
	for j in range(cj, cj + h + 1):
		for i in range(ci, ci + w + 1):
			var g := j * near_nx + i
			verts[k] = Vector3(near_x0 + i * near_step, near_h[g], near_z0 + j * near_step)
			normals[k] = _grid_normal(near_h, near_nx, near_nz, near_step, i, j)
			uvs[k] = Vector2(near_d[g] * 0.1, 0.0)
			if has_landcover:
				solid[k] = verts[k]
				verts[k].y = _visible_height(verts[k].x, verts[k].z, verts[k].y)
				lowered = lowered or verts[k].y != solid[k].y
			k += 1
	_grid_indices(idx, w, h, PackedByteArray())
	_add_mesh("Near_%d_%d" % [ci, cj], verts, normals, uvs, idx, solid if lowered else PackedVector3Array())

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
	var solid := PackedVector3Array()   # as in _build_near_chunk
	if has_landcover:
		solid.resize(verts.size())
	var lowered := false
	for j in far_nz:
		for i in far_nx:
			var g := j * far_nx + i
			var fx := far_x0 + i * far_step
			var fz := far_z0 + j * far_step
			verts[g] = Vector3(fx, far_h[g], fz)
			if has_landcover:
				solid[g] = verts[g]
				verts[g].y = _visible_height(fx, fz, far_h[g])
				lowered = lowered or verts[g].y != far_h[g]
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
	_add_mesh("FarHills", verts, normals, uvs, idx, solid if lowered else PackedVector3Array())

## `solid`: the vertices the collision is built from when they differ from the visible ones
## (water cells), empty = the same.
func _add_mesh(node_name: String, verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, idx: PackedInt32Array, solid := PackedVector3Array()) -> void:
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
	mi.layers = _layers
	add_child(mi)
	if not collision:
		return
	var shape: ConcavePolygonShape3D
	if solid.is_empty():
		shape = mesh.create_trimesh_shape()
	else:
		var faces := PackedVector3Array()
		faces.resize(idx.size())
		for n in idx.size():
			faces[n] = solid[idx[n]]
		shape = ConcavePolygonShape3D.new()
		shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = node_name + "_Body"
	body.set_meta("surface", "grass")
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
