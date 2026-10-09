class_name Scenery
extends Node3D
## Surroundings of a track: buildings and grandstands, trees, water, landmarks and floodlight
## masts. The Track adds this node in code (after Road, Trackside, Terrain and Race) and it
## builds everything in _ready, so a track is complete when Game.race_ready fires.
## All files are optional and live in the track folder (Track.scenery_path); with none of
## them this node stays empty and the track looks as it did before scenery existed.
##
##   scenery.json        what the baked files contain (written by the `surroundings` step of
##                       tools/track/build_track.py; its README is the authority). Read here:
##     {
##       "landcover": {
##         "near": {"x0": -600, "z0": -1200, "step": 2.5, "nx": 720, "nz": 800},  // landcover.png
##         "far":  {"x0": -5600, "z0": -6200, "step": 50, "nx": 240, "nz": 240}}, // landcover_far.png
##       "trees": {"file": "scenery_points.bin", "count": 1234,
##                 "record": ["x", "y", "z", "height", "species"],                // float32 each
##                 "species": ["broadleaved", "needleleaved", "palm", "bush"]},   // names of the ids
##       "water": [{"level": -2.5, "kind": "sea",            // level = y in the track frame
##                  "polygon": [[x, z], [x, z], ...],
##                  "triangles": [0, 1, 2, ...]}]            // optional: indices into polygon
##     }
##     Cell (i, j) of a land-cover grid covers x0 + i * step .. x0 + (i + 1) * step (row = z).
##     Also accepted: "near" / "far" at the top level, "points" for "trees".
##   landcover.png, landcover_far.png   ground classes, painted by Terrain (see there)
##   scenery.glb         nodes chunk_<i>_<j> (400 m grid), one surface per material name:
##                       building_wall, building_roof, building_glass, stand_seats,
##                       stand_structure, concrete, metal, emissive_window, emissive_light
##                       (only the ones a track uses). UVs are metres: on walls u along the
##                       wall and v the height above the building's base (negative in the
##                       plinth), on grandstand treads u along the row and v the depth from
##                       the front. Vertex colour: rgb = the building's tint (linear),
##                       a = 1 on facades with windows, 0 on blank surfaces. The materials
##                       are replaced by name with the procedural ones made here.
##   scenery_points.bin  trees: float32 records x, y, z, height, species id; the ids are
##                       named by scenery.json "trees"/"species" (default: 0 broadleaved,
##                       1 needleleaved, 2 palm, 3 bush; anything else is a broadleaf).
##                       environment.json "trees" can replace the species by a per-track mix
##                       (which may add cypress) and sets the colours.
##   environment.json    the look (see TrackEnvironment): here it gives the tree mix, window
##                       lights, seat colours, water colours and the floodlight masts.
##   landmarks.json      hand-placed models, landmarks/<model>.glb in the track folder:
##     [
##       {"model": "casino",                      // landmarks/casino.glb
##        "at": {"latlon": [43.7392, 7.4277]},    // or {"xz": [x, z]}: sits on the terrain;
##                                                // or {"s": 1200, "side": 1, "dist": 35}:
##                                                // s metres round the lap, side +1 right /
##                                                // -1 left, dist metres from the centreline,
##                                                // at road height
##        "y_offset": 0.0,                        // metres, added to the height
##        "yaw_deg": 90.0,                        // turn about the vertical; for an "s"
##                                                // placement 0 = facing along the track
##        "scale": 1.0}
##     ]
##     latlon -> metres uses "origin_latlon" and "plan_scale" of terrain.json (Terrain.latlon_to_xz).
##     Surfaces of a landmark named like the scenery materials above get those materials
##     (they take their colour from the vertex colour, as in scenery.glb: white without one);
##     any other material is kept as the model has it.
##
## Budget (Intel HD 520): buildings stay merged per chunk as baked, trees are one MultiMesh
## per 400 m chunk, species and level of detail, lamps one MultiMesh; nothing here adds real
## lights. Collision: only scenery faces within COLLISION_REACH of the road edge, one trimesh
## body per chunk with meta surface = "asphalt" (like the barriers).
## Graphics setting `scenery` (0 low / 1 medium / 2 high), live: low shows half the trees and
## none beyond TREE_RANGE[0], hides far skyline chunks and draws flat facades.

signal built

const META_FILE := "scenery.json"
const GLB_FILE := "scenery.glb"
const POINTS_FILE := "scenery_points.bin"
const LANDMARKS_FILE := "landmarks.json"
const LANDMARKS_DIR := "landmarks"
const FACADE_SHADER := preload("res://shaders/scenery_facade.gdshader")
const SEATS_SHADER := preload("res://shaders/scenery_seats.gdshader")
const TREE_SHADER := preload("res://shaders/scenery_tree.gdshader")
const WATER_SHADER := preload("res://shaders/water.gdshader")

const CHUNK: float = 400.0                 ## tree chunk size (and the baked building grid)
const COLLISION_REACH: float = 12.0        ## m beyond the road edge that gets collision
const COLLISION_CELL: float = 4.0
## Surfaces that are solid (when close enough to the road).
const SOLID: Array[String] = ["building_wall", "building_glass", "stand_structure", "stand_seats", "concrete"]
## Per `scenery` setting: trees are not drawn beyond this (m), and the detailed tree meshes
## are used for chunks whose centre is nearer than TREE_LOD.
const TREE_RANGE: Array[float] = [300.0, 900.0, 1600.0]
const TREE_LOD: Array[float] = [230.0, 330.0, 420.0]
const TREE_DENSITY: Array[float] = [0.5, 1.0, 1.0]
const TREE_LIMIT: int = 120000             ## instances; a denser bake is thinned out
const TREE_SINK: float = 0.15              ## m the base goes into the ground (slopes)
## Setting "low": building chunks further than this from the lap are hidden (skyline).
const SKYLINE_DISTANCE: float = 600.0
## Floodlit tracks: scenery nearer than this to the lap is lit by the floodlights.
const FLOOD_NEAR: float = 160.0
## Chunks further than this from the lap cast no shadow (sun shadows reach 100 m).
const SHADOW_NEAR: float = 140.0
const LAMP_SETBACK: float = 2.5            ## m behind the barrier line
## Species names the baked data uses -> TrackEnvironment.SPECIES name. DATA_SPECIES_ORDER is
## the id order assumed when scenery.json does not name the ids.
const DATA_SPECIES := {"broadleaved": "broadleaf", "broadleaf": "broadleaf", "needleleaved": "conifer",
	"conifer": "conifer", "palm": "palm", "cypress": "cypress", "bush": "bush"}
const DATA_SPECIES_ORDER: Array[String] = ["broadleaved", "needleleaved", "palm", "bush"]

var is_built: bool = false
var quality: int = 1
var build_msec: int = 0
## What was built (also what the tests look at).
var building_chunks: int = 0
var hidden_chunks: int = 0
var collision_bodies: int = 0
var collision_faces: int = 0
var tree_total: int = 0        ## trees in scenery_points.bin
var tree_instances: int = 0    ## trees shown with the current setting
var tree_multimeshes: int = 0
var water_bodies: int = 0
var landmark_count: int = 0
var lamp_count: int = 0
var materials := {}            ## material name -> Material

var _track: Track
var _env: TrackEnvironment
var _terrain: Terrain
var _trackside: Trackside
var _line := PackedVector2Array()     ## centreline, thinned, for distance queries
var _near_cells := {}                 ## Vector2i cell -> true: within reach of the road
var _chunks: Array[Dictionary] = []   ## {node: MeshInstance3D, near: float}
var _tree_floats := PackedFloat32Array()
var _tree_fields := PackedInt32Array([0, 1, 2, 3, 4])
## Species id in the data -> index in TrackEnvironment.SPECIES (see DATA_SPECIES).
var _tree_species := PackedInt32Array()
var _tree_stride: int = 5
var _tree_root: Node3D
var _tree_material: ShaderMaterial
var _tree_lod0: Array[MultiMeshInstance3D] = []
var _tree_range_bonus: float = 0.0
var _bodies: Array[StaticBody3D] = []   ## added once Trackside has ray-snapped its geometry
var _reach: float = -1.0

## Parsed scenery.json of `path`, normalised: {near, far: grid dictionaries (or absent),
## water: [{level, polygon: PackedVector2Array}], points: {file, record: [names], count}}.
## Empty without a file.
static func load_meta(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_warning("Scenery: %s is not a JSON object" % path)
		return {}
	var raw: Dictionary = parsed
	var out := {}
	var landcover: Variant = raw.get("landcover")
	var grids: Dictionary = landcover if landcover is Dictionary else raw
	for key: String in ["near", "far"]:
		var g: Variant = grids.get(key)
		if g is Dictionary and (g as Dictionary).has_all(["x0", "z0", "step"]):
			out[key] = g
	var water: Array[Dictionary] = []
	var bodies: Variant = raw.get("water", raw.get("water_bodies", []))
	if bodies is Array:
		for b: Variant in bodies:
			if not (b is Dictionary and (b as Dictionary).get("polygon") is Array):
				continue
			var poly := PackedVector2Array()
			for p: Variant in (b as Dictionary)["polygon"]:
				if p is Array and (p as Array).size() >= 2:
					poly.append(Vector2(float(p[0]), float(p[1])))
			if poly.size() < 3:
				continue
			# "triangles": a flat index list into the polygon (holes already bridged in).
			var tris := PackedInt32Array()
			var listed: Variant = (b as Dictionary).get("triangles")
			if listed is Array and (listed as Array).size() % 3 == 0:
				for t: Variant in listed:
					if int(t) < 0 or int(t) >= poly.size():
						tris = PackedInt32Array()
						break
					tris.append(int(t))
			water.append({"level": float((b as Dictionary).get("level", 0.0)), "polygon": poly,
				"triangles": tris, "kind": str((b as Dictionary).get("kind", ""))})
	out["water"] = water
	var points: Variant = raw.get("trees", raw.get("points", {}))
	var pd: Dictionary = points if points is Dictionary else {}
	var record: Variant = pd.get("record", [])
	var species: Variant = pd.get("species", [])
	out["points"] = {"file": str(pd.get("file", POINTS_FILE)), "record": record if record is Array else [],
		"species": species if species is Array else [], "count": int(pd.get("count", -1))}
	return out

func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_track = get_parent() as Track
	if _track == null:
		_track = get_tree().get_first_node_in_group(&"track") as Track
	if _track != null and _track.data != null and _track.environment != null:
		_env = _track.environment
		_terrain = _track.get_node_or_null(^"Terrain") as Terrain
		_trackside = _track.get_node_or_null(^"Trackside") as Trackside
		quality = _quality()
		var d := _track.data
		var stride := maxi(1, int(16.0 / maxf(d.step, 0.01)))
		for i in range(0, d.points.size(), stride):
			_line.append(Vector2(d.points[i].x, d.points[i].z))
		_make_materials()
		_build_buildings()
		_build_water()
		_load_trees()
		_build_trees()
		_build_landmarks()
		_build_floodlights()
		_apply_verge()
		# Trackside ray-casts the ground under its kerbs and walls two physics frames after
		# its _ready: the scenery bodies must not be in the way of those rays.
		if _trackside != null and _trackside.layout != null and not _trackside.is_built:
			_trackside.built.connect(_add_bodies, CONNECT_ONE_SHOT)
		else:
			_add_bodies()
		if not Settings.changed.is_connected(_on_setting_changed):
			Settings.changed.connect(_on_setting_changed)
	build_msec = Time.get_ticks_msec() - t0
	is_built = true
	built.emit()

func _add_bodies() -> void:
	for body in _bodies:
		add_child(body)
	_bodies.clear()

## Draws trees `metres` further out than the setting allows (the --overview camera).
func set_tree_range_bonus(metres: float) -> void:
	_tree_range_bonus = maxf(metres, 0.0)
	if _env != null:
		_apply_material_quality()
		_build_trees()

func _quality() -> int:
	return clampi(int(SettingsApply.value("graphics", "scenery")), 0, 2)

func _on_setting_changed(section: String, key: String) -> void:
	if section != "graphics" or _env == null:
		return
	if key == "scenery":
		quality = _quality()
		_apply_quality()
		_build_trees()
	elif key == "shadows":
		_apply_tree_shadows()

# ------------------------------------------------------------------------- helpers
## Distance (m, within ~8 m) from a ground position to the lap's centreline.
func track_distance(p: Vector2) -> float:
	var best := INF
	for q in _line:
		best = minf(best, q.distance_squared_to(p))
	return sqrt(best)

## A .glb as a scene: the imported resource when there is one, else parsed here (a scenery
## folder outside the project, --scenery-dir). Null when the file is missing or broken.
static func load_glb(path: String) -> Node3D:
	if path.is_empty():
		return null
	if path.begins_with("res://") and ResourceLoader.exists(path, "PackedScene"):
		var scene := load(path) as PackedScene
		if scene != null:
			return scene.instantiate() as Node3D
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("Scenery: cannot read %s" % path)
		return null
	return doc.generate_scene(state) as Node3D

## Every MeshInstance3D below `root` (itself included).
static func mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append(n)
		stack.append_array(n.get_children())
	return out

## Material name of a surface as baked: the glTF material's name, else the surface's.
static func surface_name(mesh: Mesh, surf: int) -> String:
	var mat := mesh.surface_get_material(surf)
	if mat != null and not mat.resource_name.is_empty():
		return mat.resource_name
	return (mesh as ArrayMesh).surface_get_name(surf) if mesh is ArrayMesh else ""

## Gives every surface with a known material name the material made here.
func _assign_materials(mi: MeshInstance3D) -> void:
	for surf in mi.mesh.get_surface_count():
		var mat: Material = materials.get(surface_name(mi.mesh, surf))
		if mat != null:
			mi.set_surface_override_material(surf, mat)

# ------------------------------------------------------------------------- materials
func _make_materials() -> void:
	var night := _env.night_amount()
	var lit := _env.number("buildings", "lit_windows")
	var window := _env.color("buildings", "window_color")
	var wall := ShaderMaterial.new()
	wall.shader = FACADE_SHADER
	var glass := ShaderMaterial.new()
	glass.shader = FACADE_SHADER
	# Curtain wall: almost all glass, thin dark frames, more of it lit (offices).
	glass.set_shader_parameter("window_min", Vector2(0.04, 0.05))
	glass.set_shader_parameter("window_max", Vector2(0.96, 0.93))
	glass.set_shader_parameter("bay_width", 1.8)
	glass.set_shader_parameter("floor_height", 3.6)
	glass.set_shader_parameter("wall_tint", 0.0)
	glass.set_shader_parameter("shopfront", 0.0)
	glass.set_shader_parameter("glass_color", Color(0.06, 0.10, 0.14))
	for m: ShaderMaterial in [wall, glass]:
		m.set_shader_parameter("night", night)
		m.set_shader_parameter("lit_fraction", lit)
		m.set_shader_parameter("window_light", window)
	materials["building_wall"] = wall
	materials["building_glass"] = glass
	# Roofs, structure, concrete and metal take the baked tint as their colour.
	materials["building_roof"] = _std(Color.WHITE, 0.9, true)
	var seats := ShaderMaterial.new()
	seats.shader = SEATS_SHADER
	var seat_colors := _env.seat_colors()
	seats.set_shader_parameter("seat_a", seat_colors[0])
	seats.set_shader_parameter("seat_b", seat_colors[1])
	seats.set_shader_parameter("seat_c", seat_colors[2])
	seats.set_shader_parameter("crowd", _env.number("stands", "crowd"))
	materials["stand_seats"] = seats
	materials["stand_structure"] = _std(Color.WHITE, 0.8, true)
	materials["concrete"] = _std(Color.WHITE, 0.9, true)
	var metal := _std(Color.WHITE, 0.4, true)
	metal.metallic = 0.7
	materials["metal"] = metal
	# Lit windows and lamps as geometry: glowing once it gets dark, plain glass / white by day.
	var lit_window := _std(Color(0.10, 0.12, 0.15), 0.2, false)
	var lamp := _std(Color(0.92, 0.92, 0.90), 0.5, false)
	if night > 0.0:
		lit_window.emission_enabled = true
		lit_window.emission = window
		lit_window.emission_energy_multiplier = 2.4 * night
		lamp.emission_enabled = true
		lamp.emission = _env.color("floodlights", "color")
		lamp.emission_energy_multiplier = 7.0 * night
	materials["emissive_window"] = lit_window
	materials["emissive_light"] = lamp
	var water := ShaderMaterial.new()
	water.shader = WATER_SHADER
	water.set_shader_parameter("color", _env.color("water", "color"))
	water.set_shader_parameter("deep_color", _env.color("water", "deep_color"))
	materials["water"] = water
	_tree_material = ShaderMaterial.new()
	_tree_material.shader = TREE_SHADER
	materials["tree"] = _tree_material
	_apply_material_quality()

static func _std(c: Color, rough: float, vertex_tint: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	# The baked per-building tint multiplies the base colour (white when the mesh has none).
	m.vertex_color_use_as_albedo = vertex_tint
	return m

func _apply_material_quality() -> void:
	var detail := 0.0 if quality == 0 else 1.0
	for key: String in ["building_wall", "building_glass", "stand_seats"]:
		(materials[key] as ShaderMaterial).set_shader_parameter("detail", detail)
	_tree_material.set_shader_parameter("fade_end", TREE_RANGE[quality] + _tree_range_bonus)

func _apply_quality() -> void:
	_apply_material_quality()
	hidden_chunks = 0
	for c in _chunks:
		var hide := quality == 0 and float(c["near"]) > SKYLINE_DISTANCE
		(c["node"] as MeshInstance3D).visible = not hide
		if hide:
			hidden_chunks += 1

# ------------------------------------------------------------------------- buildings
func _build_buildings() -> void:
	var root := load_glb(_track.scenery_path(GLB_FILE))
	if root == null:
		return
	root.name = "Buildings"
	add_child(root)
	var flood := _env.floodlit()
	for mi in mesh_instances(root):
		_assign_materials(mi)
		var box := mi.global_transform * mi.get_aabb()
		var centre := box.get_center()
		var radius := Vector2(box.size.x, box.size.z).length() * 0.5
		var near := maxf(track_distance(Vector2(centre.x, centre.z)) - radius, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near < SHADOW_NEAR \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if flood and near > FLOOD_NEAR:
			mi.layers = TrackEnvironment.LAYER_FAR
		_chunks.append({"node": mi, "near": near})
		building_chunks += 1
		if near < _collision_reach() + 8.0:
			_chunk_collision(mi)
	_apply_quality()

## Widest reach of the collision band from the centreline.
func _collision_reach() -> float:
	if _reach < 0.0:
		var widest := 0.0
		for w in _track.data.widths:
			widest = maxf(widest, w)
		_reach = widest * 0.5 + COLLISION_REACH
	return _reach

## Marks the ground cells within COLLISION_REACH of the road edge (once).
func _stamp_near_cells() -> void:
	var d := _track.data
	var stride := maxi(1, int(COLLISION_CELL / maxf(d.step, 0.01)))
	for i in range(0, d.points.size(), stride):
		var s := i * d.step
		var half := _trackside.edge_at(s) if _trackside != null and _trackside.layout != null \
				else d.widths[i] * 0.5
		var reach := half + COLLISION_REACH
		var p := d.points[i]
		var r := ceili(reach / COLLISION_CELL)
		var ci := floori(p.x / COLLISION_CELL)
		var cj := floori(p.z / COLLISION_CELL)
		for oj in range(-r, r + 1):
			for oi in range(-r, r + 1):
				if Vector2(oi, oj).length() * COLLISION_CELL <= reach + COLLISION_CELL:
					_near_cells[Vector2i(ci + oi, cj + oj)] = true

## Trimesh body from the solid faces of one chunk that are close to the road.
func _chunk_collision(mi: MeshInstance3D) -> void:
	if _near_cells.is_empty():
		_stamp_near_cells()
	var xf := mi.global_transform
	var faces := PackedVector3Array()
	for surf in mi.mesh.get_surface_count():
		if not surface_name(mi.mesh, surf) in SOLID:
			continue
		var arrays := mi.mesh.surface_get_arrays(surf)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		var count: int = (idx as PackedInt32Array).size() if idx != null else verts.size()
		for t in range(0, count - 2, 3):
			var a := xf * (verts[idx[t]] if idx != null else verts[t])
			var b := xf * (verts[idx[t + 1]] if idx != null else verts[t + 1])
			var c := xf * (verts[idx[t + 2]] if idx != null else verts[t + 2])
			# Corners, edge midpoints and the centre: a long wall counts when any is close.
			for p: Vector3 in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
				if _near_cells.has(Vector2i(floori(p.x / COLLISION_CELL), floori(p.z / COLLISION_CELL))):
					faces.append_array([a, b, c])
					break
	if faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = String(mi.name) + "_Body"
	body.set_meta("surface", "asphalt")
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	_bodies.append(body)
	collision_bodies += 1
	collision_faces += faces.size() / 3

# ------------------------------------------------------------------------- water
func _build_water() -> void:
	var bodies: Array = _track.scenery_meta.get("water", [])
	if bodies.is_empty():
		return
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for body: Dictionary in bodies:
		var poly: PackedVector2Array = body["polygon"]
		var tris: PackedInt32Array = body.get("triangles", PackedInt32Array())
		if tris.is_empty():
			tris = Geometry2D.triangulate_polygon(poly)
		if tris.is_empty():
			push_warning("Scenery: water polygon with %d points cannot be triangulated" % poly.size())
			continue
		var y := float(body["level"])
		for t in range(0, tris.size(), 3):
			var a := poly[tris[t]]
			var b := poly[tris[t + 1]]
			var c := poly[tris[t + 2]]
			# Front faces wind clockwise seen from above.
			if (b - a).cross(c - a) < 0.0:
				var tmp := b
				b = c
				c = tmp
			for p: Vector2 in [a, b, c]:
				verts.append(Vector3(p.x, y, p.y))
				normals.append(Vector3.UP)
		water_bodies += 1
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, materials["water"])
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _env.floodlit():
		mi.layers = TrackEnvironment.LAYER_FAR
	add_child(mi)

# ------------------------------------------------------------------------- trees
func _load_trees() -> void:
	var points: Dictionary = _track.scenery_meta.get("points", {})
	var path := _track.scenery_path(str(points.get("file", POINTS_FILE)))
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var record: Array = points.get("record", [])
	if not record.is_empty():
		# A field the record does not have gets -1: a default is used (height, species).
		_tree_stride = record.size()
		var names: Array[String] = ["x", "y", "z", "height", "species"]
		for f in names.size():
			_tree_fields[f] = record.find(names[f])
		if _tree_fields[0] < 0 or _tree_fields[1] < 0 or _tree_fields[2] < 0:
			push_warning("Scenery: the tree record of scenery.json has no x / y / z, trees ignored")
			return
	var listed: Array = points.get("species", [])
	if listed.is_empty():
		listed = DATA_SPECIES_ORDER
	for species_name: Variant in listed:
		_tree_species.append(TrackEnvironment.SPECIES.find(DATA_SPECIES.get(str(species_name), "broadleaf")))
	_tree_floats = FileAccess.get_file_as_bytes(path).to_float32_array()
	tree_total = _tree_floats.size() / _tree_stride

## (Re)builds the tree MultiMeshes for the current `scenery` setting.
func _build_trees() -> void:
	if is_instance_valid(_tree_root):
		_tree_root.free()
	_tree_root = null
	_tree_lod0.clear()
	tree_instances = 0
	tree_multimeshes = 0
	if tree_total == 0:
		return
	_tree_root = Node3D.new()
	_tree_root.name = "Trees"
	add_child(_tree_root)
	var density := clampf(_env.number("trees", "density"), 0.0, 1.0) * TREE_DENSITY[quality]
	density = minf(density, float(TREE_LIMIT) / tree_total)
	var keep := int(density * 65536.0)
	var height_scale := _env.number("trees", "scale")
	var mix := _env.tree_mix()
	var mix_total := 0.0
	for w in mix:
		mix_total += w
	var colours: Array = []
	for s in TrackEnvironment.SPECIES:
		colours.append(_env.tree_colors(s))
	var species_count := TrackEnvironment.SPECIES.size()
	var fx := _tree_fields[0]
	var fy := _tree_fields[1]
	var fz := _tree_fields[2]
	var fh := _tree_fields[3]
	var fs := _tree_fields[4]
	var data_species := _tree_species.size()
	var broadleaf := TrackEnvironment.SPECIES.find("broadleaf")
	var buffers := {}   # Vector3i(chunk i, chunk j, species) -> PackedFloat32Array
	for n in tree_total:
		# Independent hashes of the tree's index: kept or not, turn, size, colour, species.
		var h1 := (n * 2654435761) & 0xFFFFFFFF
		if (h1 >> 16) >= keep:
			continue
		var o := n * _tree_stride
		var x := _tree_floats[o + fx]
		var z := _tree_floats[o + fz]
		var r1 := float(h1 & 0xFFFF) / 65536.0
		var h2 := ((n + 7919) * 2246822519) & 0xFFFFFFFF
		var r2 := float(h2 >> 16) / 65536.0
		var r3 := float(h2 & 0xFFFF) / 65536.0
		var id := int(_tree_floats[o + fs]) if fs >= 0 else -1
		var species := _tree_species[id] if id >= 0 and id < data_species else broadleaf
		if mix_total > 0.0:
			var pick := float(((n + 104729) * 3266489917) & 0xFFFF) / 65536.0 * mix_total
			species = 0
			while species < species_count - 1 and pick >= mix[species]:
				pick -= mix[species]
				species += 1
		var key := Vector3i(floori(x / CHUNK), floori(z / CHUNK), species)
		var buf: PackedFloat32Array = buffers.get(key, PackedFloat32Array())
		var height := (_tree_floats[o + fh] if fh >= 0 else 10.0) * height_scale
		var wide := height * (0.85 + 0.3 * r2)
		var yaw := r1 * TAU
		var c := cos(yaw) * wide
		var s := sin(yaw) * wide
		var pair: Array[Color] = colours[species]
		# The shader takes the custom data as it is: linear colour.
		var col := pair[0].lerp(pair[1], r3).srgb_to_linear()
		# MultiMesh buffer: a 3x4 transform (rows), then the custom data.
		buf.append_array(PackedFloat32Array([
			c, 0.0, s, x,
			0.0, height, 0.0, _tree_floats[o + fy] - TREE_SINK,
			-s, 0.0, c, z,
			col.r, col.g, col.b, r2]))
		buffers[key] = buf
		tree_instances += 1
	var flood := _env.floodlit()
	for key: Vector3i in buffers:
		var buf: PackedFloat32Array = buffers[key]
		var centre := Vector2((key.x + 0.5) * CHUNK, (key.y + 0.5) * CHUNK)
		var near := maxf(track_distance(centre) - CHUNK * 0.71, 0.0)
		for lod in SceneryTrees.LODS:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = SceneryTrees.mesh(key.z, lod)
			mm.instance_count = buf.size() / 16
			mm.buffer = buf
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "trees_%d_%d_%s_lod%d" % [key.x, key.y, TrackEnvironment.SPECIES[key.z], lod]
			mmi.multimesh = mm
			mmi.material_override = _tree_material
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if lod == 0:
				mmi.visibility_range_end = TREE_LOD[quality]
				_tree_lod0.append(mmi)
			else:
				mmi.visibility_range_begin = TREE_LOD[quality]
				mmi.visibility_range_end = TREE_RANGE[quality] + _tree_range_bonus + CHUNK * 0.75
			if flood and near > FLOOD_NEAR:
				mmi.layers = TrackEnvironment.LAYER_FAR
			_tree_root.add_child(mmi)
			tree_multimeshes += 1
	_apply_tree_shadows()

## Trees cast shadows only with the `shadows` setting on high (and only the near copies).
func _apply_tree_shadows() -> void:
	var on := SettingsApply.shadow_level() >= 3
	for mmi in _tree_lod0:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# ------------------------------------------------------------------------- landmarks
func _build_landmarks() -> void:
	var path := _track.scenery_path(LANDMARKS_FILE)
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Array:
		push_warning("Scenery: %s is not a JSON list" % path)
		return
	var root := Node3D.new()
	root.name = "Landmarks"
	add_child(root)
	for entry: Variant in parsed:
		if not (entry is Dictionary and (entry as Dictionary).get("at") is Dictionary):
			push_warning("Scenery: landmark without \"at\" in %s" % path)
			continue
		var e: Dictionary = entry
		var model := str(e.get("model", ""))
		if model.get_extension().is_empty():
			model += ".glb"
		var node := load_glb(_track.scenery_path(LANDMARKS_DIR.path_join(model)))
		if node == null:
			push_warning("Scenery: landmark model %s not found" % model)
			continue
		var xf: Variant = _landmark_transform(e)
		if xf == null:
			push_warning("Scenery: landmark %s has no usable position" % model)
			node.free()
			continue
		node.name = "%s_%d" % [model.get_basename().validate_node_name(), landmark_count]
		root.add_child(node)
		node.global_transform = xf
		for mi in mesh_instances(node):
			_assign_materials(mi)
		landmark_count += 1

## World transform of a landmarks.json entry, null when its "at" cannot be resolved.
func _landmark_transform(e: Dictionary) -> Variant:
	var at: Dictionary = e["at"]
	var yaw := deg_to_rad(float(e.get("yaw_deg", 0.0)))
	var basis := Basis(Vector3.UP, yaw)
	var origin: Vector3
	if at.has("s"):
		var s := float(at["s"])
		var side := 1.0 if float(at.get("side", 1.0)) >= 0.0 else -1.0
		var dist := float(at.get("dist", 0.0))
		var frame := _track.data.sample(s)
		if _trackside != null and _trackside.layout != null:
			frame = _trackside.frame_at(s)
			origin = _trackside.lateral_point(s, side, dist, frame)
		else:
			origin = frame.origin + frame.basis.x * side * dist
		# Upright, turned with the track: yaw 0 looks along the lap.
		var fwd := -frame.basis.z
		basis = Basis(Vector3.UP, atan2(-fwd.x, -fwd.z) + yaw)
	else:
		var p: Vector2
		if at.get("latlon") is Array and (at["latlon"] as Array).size() >= 2:
			if _terrain == null or not _terrain.has_origin:
				return null
			p = _terrain.latlon_to_xz(float(at["latlon"][0]), float(at["latlon"][1]))
		elif at.get("xz") is Array and (at["xz"] as Array).size() >= 2:
			p = Vector2(float(at["xz"][0]), float(at["xz"][1]))
		else:
			return null
		var y := _terrain.height_at(p.x, p.y) if _terrain != null else NAN
		origin = Vector3(p.x, 0.0 if is_nan(y) else y, p.y)
	origin.y += float(e.get("y_offset", 0.0))
	return Transform3D(basis.scaled(Vector3.ONE * float(e.get("scale", 1.0))), origin)

# ------------------------------------------------------------------------- floodlights
## Masts with a lamp head every `spacing_m` on alternating sides, just behind the barrier
## line. They only glow: the light on the road comes from TrackEnvironment's floodlight key.
func _build_floodlights() -> void:
	if not bool(_env.section("floodlights").get("enabled", false)):
		return
	var spacing := maxf(_env.number("floodlights", "spacing_m"), 10.0)
	var height := maxf(_env.number("floodlights", "height_m"), 4.0)
	var d := _track.data
	var use_trackside := _trackside != null and _trackside.layout != null
	var xforms: Array[Transform3D] = []
	var count := maxi(1, int(d.length / spacing))
	for k in count:
		var s := d.length * k / count
		var side := 1.0 if k % 2 == 0 else -1.0
		var frame := d.sample(s)
		var off := d.width_at(s) * 0.5 + 8.0
		var p: Vector3
		if use_trackside:
			frame = _trackside.frame_at(s)
			off = _trackside.barrier_offset(s, side) + LAMP_SETBACK
			p = _trackside.lateral_point(s, side, off, frame)
		else:
			p = frame.origin + frame.basis.x * side * off
		# Not where another part of the lap passes closer than this mast's own road.
		if track_distance(Vector2(p.x, p.z)) < off - 9.0:
			continue
		var ground := _terrain.height_at(p.x, p.z) if _terrain != null else NAN
		if not is_nan(ground):
			p.y = minf(p.y, ground)
		# Local +Z of the mast points at the track.
		var to_track := -frame.basis.x * side
		var z := Vector3(to_track.x, 0.0, to_track.z).normalized()
		xforms.append(Transform3D(Basis(Vector3.UP.cross(z), Vector3.UP, z), p - Vector3.UP * 0.3))
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _mast_mesh(height)
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Floodlights"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	lamp_count = xforms.size()

## A mast `height` m tall with a lamp head leaning over towards +Z: surface 0 the structure,
## surface 1 the lamps.
func _mast_mesh(height: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var pole := BoxMesh.new()
	pole.size = Vector3(0.45, height + 0.3, 0.45)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(pole, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, (height + 0.3) * 0.5, 0.0)))
	var frame := BoxMesh.new()
	frame.size = Vector3(4.4, 2.2, 0.3)
	var tilt := Basis(Vector3.RIGHT, deg_to_rad(28.0))
	st.append_from(frame, 0, Transform3D(tilt, Vector3(0.0, height, 0.25)))
	st.commit(mesh)
	mesh.surface_set_material(0, materials["metal"])
	var lamps := BoxMesh.new()
	lamps.size = Vector3(4.0, 1.8, 0.1)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(lamps, 0, Transform3D(tilt, Vector3(0.0, height, 0.25) + tilt * Vector3(0.0, 0.0, 0.18)))
	st.commit(mesh)
	mesh.surface_set_material(1, materials["emissive_light"])
	return mesh

# ------------------------------------------------------------------------- verges
## Per-track colours for the grass verges of the road mesh (environment.json "verge"), set
## as surface overrides on copies: the generated road_grass.tres files are not touched.
func _apply_verge() -> void:
	if not _env.active:
		return
	var road := _track.get_node_or_null(^"Road")
	if road == null:
		return
	var grass := _env.color("verge", "grass_color")
	var dry := _env.color("verge", "dry_color")
	var copies := {}
	for mi in mesh_instances(road):
		for surf in mi.mesh.get_surface_count():
			if surface_name(mi.mesh, surf) != "grass":
				continue
			var mat := mi.mesh.surface_get_material(surf)
			if mat == null:
				continue
			if not copies.has(mat):
				var copy := mat.duplicate() as Material
				if copy is ShaderMaterial:
					(copy as ShaderMaterial).set_shader_parameter("grass_color", grass)
					(copy as ShaderMaterial).set_shader_parameter("dry_color", dry)
					if not _env.mowing_stripes():
						(copy as ShaderMaterial).set_shader_parameter("stripe_length", 1.0e7)
				elif copy is BaseMaterial3D:
					(copy as BaseMaterial3D).albedo_color = grass
				copies[mat] = copy
			mi.set_surface_override_material(surf, copies[mat])
