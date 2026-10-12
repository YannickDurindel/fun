class_name TrackDressing
extends RefCounted
## Trackside dressing of the realistic track look: what fills the space between the barrier
## and the horizon on a real circuit. Built once at load from a per-track section table,
## assets/tracks/_shared/look_detailed/dressing/<track_id>.json (versions of a circuit with
## the suffix "_survey" use the circuit's table, mapped by lap fraction), on the barrier line
## of the Trackside, so everything stands where the walls really are:
##   * catch fences (chain-link, CC0 Fence003, alpha blended so it hazes out with distance)
##     on posts behind every armco stretch (the concrete walls bring their own fence);
##   * tree lines and forests of billboard trees (impostors rendered from CC0 Poly Haven
##     models, cad/track/bake_impostors.gd), bushes in front;
##   * advertising boards of fictional brands on the barriers, 300/200/100 m boards before
##     the heavy braking zones, belted tyre walls along the run-off areas, marshal posts and
##     wooden utility poles on the public-road sections.
## Everything is visual only (no collision; nothing stands in front of the barrier line
## except the boards flat on it and the tyre walls, 0.8 m deep). Instanced per 300 m chunk
## (MultiMeshInstance3D) with visibility ranges, so the HD 520 keeps its frame rate.
##
## Table: {"length": lap m, "sections": [{"s": [s0, s1], "side": -1 | 1 | 0 (both),
##   "trees": none | sparse | line | forest | pines | poplars, "tree_gap": m (extra distance of
##   the trees behind the barrier, run-off areas), "boards": bool, "poles": bool}]}

const DIR := "res://assets/tracks/_shared/look_detailed"
const TABLE_DIR := DIR + "/dressing"
const TREE_SHADER := DIR + "/tree_card.gdshader"
const TREES_JSON := DIR + "/trees/trees.json"
const BOARDS_TEX := DIR + "/boards.png"
const DISTANCE_TEX := DIR + "/distance_boards.png"
const CHAINLINK_TEX := DIR + "/photo/chainlink_albedo.png"
const NODE_NAME := "LookDressing"
const CHUNK: float = 300.0
const BOARD_ROWS := 8          ## boards.png: 2 columns x 8 rows
const FENCE_HEIGHT: float = 3.4
const FENCE_POST_STEP: float = 4.0
const FENCE_BEHIND: float = 0.35   ## m behind the barrier line
const TREE_RANGE: float = 900.0    ## m, visibility range of the trees
const PROP_RANGE: float = 500.0    ## m, of the small props

## Tree species by impostor id (trees.json), with the kinds that use them.
const BROADLEAF := ["island_tree_01", "island_tree_02"]
const PINE := "tree_small_02"
const BUSH := "shrub_04"

## Rows of trees behind the barrier per kind: [distance m, step along the lap m, height min,
## height max, share of pines].
const KINDS := {
	"forest": [[5.0, 8.0, 9.0, 15.0, 0.25], [14.0, 9.5, 15.0, 24.0, 0.3]],
	"line": [[5.0, 10.0, 10.0, 18.0, 0.2], [13.0, 12.0, 12.0, 20.0, 0.2]],
	"pines": [[7.0, 9.0, 14.0, 22.0, 0.85], [16.0, 10.0, 15.0, 24.0, 0.85]],
	"poplars": [[6.0, 5.5, 20.0, 27.0, 0.0]],
	"sparse": [[12.0, 24.0, 10.0, 19.0, 0.4]],
}
## Tints of the impostors (multiplied with the photo colours): late-spring greens.
const BROADLEAF_TINTS := [Color(0.8, 0.95, 0.66), Color(0.72, 0.88, 0.6), Color(0.86, 0.95, 0.7),
		Color(0.68, 0.82, 0.56)]
const PINE_TINTS := [Color(0.8, 0.9, 0.72), Color(0.72, 0.84, 0.66)]

var _track: Node3D
var _ts: Node
var _data: TrackData
var _space: PhysicsDirectSpaceState3D
var _rng := RandomNumberGenerator.new()
var _scale := 1.0
## "kind|chunk" -> {xf: Array[Transform3D], color: Array[Color], custom: Array[Color]}
var _batches := {}
## chunk -> {"fence": SurfaceTool, "boards": SurfaceTool, "tyres": SurfaceTool}
var _tools := {}
var _trees := {}
var _root: Node3D

## Builds the dressing of `track` (a Track whose Trackside is ready) under a new child node;
## returns it, or null when the track has no table.
static func build(track: Node3D) -> Node3D:
	var d := TrackDressing.new()
	return d._build(track)

static func table_path(track_id: String) -> String:
	var path := TABLE_DIR.path_join(track_id + ".json")
	if not FileAccess.file_exists(path) and track_id.ends_with("_survey"):
		path = TABLE_DIR.path_join(track_id.trim_suffix("_survey") + ".json")
	return path

func _build(track: Node3D) -> Node3D:
	_track = track
	_ts = track.get_node_or_null(^"Trackside")
	_data = track.get("data") if track.get("data") is TrackData else null
	var id := str(track.get("track_id"))
	var path := table_path(id)
	if _ts == null or _data == null or not _ts.has_method(&"barrier_offset") \
			or not FileAccess.file_exists(path) or track.get_node_or_null(NodePath(NODE_NAME)) != null:
		return null
	var table: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not table is Dictionary:
		push_warning("TrackDressing: %s is not a JSON object" % path)
		return null
	var trees: Variant = JSON.parse_string(FileAccess.get_file_as_string(TREES_JSON)) \
			if FileAccess.file_exists(TREES_JSON) else {}
	_trees = trees if trees is Dictionary else {}
	_scale = _data.length / maxf(float((table as Dictionary).get("length", _data.length)), 1.0)
	_rng.seed = hash(id)
	_space = track.get_world_3d().direct_space_state
	_root = Node3D.new()
	_root.name = NODE_NAME
	for sec: Variant in (table as Dictionary).get("sections", []):
		if sec is Dictionary:
			_section(sec)
	_fences()
	_tyre_walls()
	_distance_boards()
	_marshal_posts()
	_commit()
	track.add_child(_root)
	return _root

# ------------------------------------------------------------------ geometry helpers
func _chunk(s: float) -> int:
	return int(_data.wrap_s(s) / CHUNK)

## World point `dist` metres from the centreline on `side` at s, on the ground.
func _point(s: float, side: float, dist: float, ground: bool = true) -> Vector3:
	var xf: Transform3D = _ts.call(&"frame_at", s)
	var p: Vector3 = _ts.call(&"lateral_point", s, side, dist, xf)
	if ground:
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 40.0, p + Vector3.DOWN * 60.0)
		var hit := _space.intersect_ray(q)
		if not hit.is_empty():
			p.y = (hit["position"] as Vector3).y
	return p

func _barrier(s: float, side: float) -> float:
	return float(_ts.call(&"barrier_offset", s, side))

## Unit vector across the road towards `side` at s (horizontal).
func _across(s: float, side: float) -> Vector3:
	var xf: Transform3D = _ts.call(&"frame_at", s)
	var r := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized()
	return r * side

func _add(kind: String, s: float, xf: Transform3D, color: Color = Color.WHITE, custom: Color = Color(0, 0, 0, 0)) -> void:
	var key := "%s|%d" % [kind, _chunk(s)]
	if not _batches.has(key):
		_batches[key] = {"xf": [], "color": [], "custom": []}
	var b: Dictionary = _batches[key]
	(b["xf"] as Array).append(xf)
	(b["color"] as Array).append(color)
	(b["custom"] as Array).append(custom)

func _st(chunk: int, what: String) -> SurfaceTool:
	if not _tools.has(chunk):
		_tools[chunk] = {}
	var d: Dictionary = _tools[chunk]
	if not d.has(what):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		d[what] = st
	return d[what]

## Quad a-b-c-d (a, b at the bottom) with UVs, both triangles facing `normal`.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, normal: Vector3) -> void:
	var cr := (b - a).cross(d - a)
	var flip := cr.dot(normal) < 0.0
	var vs := [a, b, c, a, c, d] if flip else [a, c, b, a, d, c]
	var us := [ua, ub, uc, ua, uc, ud] if flip else [ua, uc, ub, ua, ud, uc]
	for k in 6:
		st.set_normal(normal)
		st.set_uv(us[k])
		st.add_vertex(vs[k])

# ------------------------------------------------------------------ sections
func _section(sec: Dictionary) -> void:
	var r: Array = sec.get("s", [0, 0])
	var s0 := float(r[0]) * _scale
	var s1 := float(r[1]) * _scale
	var sides: Array = [-1.0, 1.0] if int(sec.get("side", 0)) == 0 else [float(sec["side"])]
	var kind := str(sec.get("trees", "none"))
	var gap := float(sec.get("tree_gap", 0.0))
	for side: float in sides:
		if KINDS.has(kind):
			for row: Array in KINDS[kind]:
				_tree_row(s0, s1, side, float(row[0]) + gap, float(row[1]), float(row[2]), float(row[3]),
						float(row[4]), kind == "poplars")
			if kind in ["forest", "line"]:
				_tree_row(s0, s1, side, 1.6 + gap, 9.0, 1.6, 2.6, 0.0, false, true)
		if bool(sec.get("boards", false)):
			_boards(s0, s1, side)
		if bool(sec.get("poles", false)) and side > 0.0:
			_poles(s0, s1, side)

func _tree_row(s0: float, s1: float, side: float, dist: float, step: float, hmin: float, hmax: float,
		pine_share: float, poplar: bool, bush: bool = false) -> void:
	var s := s0 + _rng.randf() * step
	while s < s1:
		var d := _barrier(s, side) + dist + _rng.randf_range(-0.35, 0.35) * minf(step, 6.0)
		var p := _point(s + _rng.randf_range(-0.3, 0.3) * step, side, d)
		var species: String = BUSH if bush else (PINE if _rng.randf() < pine_share else BROADLEAF[_rng.randi() % 2])
		var info: Dictionary = _trees.get(species, {})
		if not info.is_empty():
			var h := _rng.randf_range(hmin, hmax)
			var w := h * (0.38 if poplar else _rng.randf_range(0.85, 1.15))
			var xf := Transform3D(Basis.from_scale(Vector3(w, h, 1.0)), p + Vector3.DOWN * 0.2)
			var tints: Array = PINE_TINTS if species == PINE else BROADLEAF_TINTS
			var tint: Color = tints[_rng.randi() % tints.size()]
			tint = tint * _rng.randf_range(0.85, 1.1)
			tint.a = 1.0
			_add("tree:" + species, s, xf, tint, Color(float(_rng.randi() % 2), float(_rng.randi() % 2), 0, 0))
		s += step * _rng.randf_range(0.7, 1.3)

# ------------------------------------------------------------------ fences
func _fences() -> void:
	var layout: Variant = _ts.get("layout")
	for side: float in [-1.0, 1.0]:
		var prev := {}
		var s := 0.0
		var u := 0.0
		while s <= _data.length:
			var concrete: bool = layout != null and bool(layout.call(&"is_concrete", s))
			if concrete:
				prev = {}
			else:
				var d := _barrier(s, side) + FENCE_BEHIND
				var p := _point(s, side, d, false)
				var out := _across(s, side)
				_add("post", s, Transform3D(Basis(), p + Vector3.UP * FENCE_HEIGHT * 0.5))
				if not prev.is_empty():
					var a: Vector3 = prev["p"]
					u += a.distance_to(p)
					var st := _st(_chunk(s), "fence")
					var up := Vector3.UP * FENCE_HEIGHT
					var lean := out * 0.35   # the top leans out, away from the track
					_quad(st, a, p, p + up + lean, a + up + lean, Vector2(prev["u"], FENCE_HEIGHT / 2.0),
							Vector2(u / 2.0, FENCE_HEIGHT / 2.0), Vector2(u / 2.0, 0.0), Vector2(prev["u"], 0.0), -out)
				prev = {"p": p, "u": u / 2.0}
			s += FENCE_POST_STEP

# ------------------------------------------------------------------ boards
func _boards(s0: float, s1: float, side: float) -> void:
	var s := s0
	var length := 5.0
	while s + length < s1:
		var d0 := _barrier(s, side) - 0.12
		var d1 := _barrier(s + length, side) - 0.12
		if d0 < 40.0:
			var a := _point(s, side, d0, false) + Vector3.UP * 0.05
			var b := _point(s + length, side, d1, false) + Vector3.UP * 0.05
			var i := _rng.randi() % (BOARD_ROWS * 2)
			var u0 := float(i % 2) * 0.5
			var v0 := float(i / 2) / BOARD_ROWS
			var v1 := v0 + 1.0 / BOARD_ROWS
			var n := -_across(s, side)
			var st := _st(_chunk(s), "boards")
			var flip := side > 0.0   # read left to right from the road (right-side boards run against s)
			var ua := u0 + (0.5 if flip else 0.0)
			var ub := u0 + (0.0 if flip else 0.5)
			_quad(st, a, b, b + Vector3.UP, a + Vector3.UP, Vector2(ua, v1), Vector2(ub, v1),
					Vector2(ub, v0), Vector2(ua, v0), n)
		s += length

func _distance_boards() -> void:
	for t: Dictionary in _data.turns:
		var apex := float(t["s_apex"])
		var radius := float(t.get("min_radius", 100.0))
		if radius > 70.0:
			continue
		# Only after a long straight: the previous apex at least 450 m back.
		var prev_gap := INF
		for o: Dictionary in _data.turns:
			var g := _data.delta_s(float(o["s_apex"]), apex)
			if g > 1.0 and g < prev_gap:
				prev_gap = g
		if prev_gap < 450.0:
			continue
		var turn_in := apex - (radius * 0.8 + 40.0)
		for k in 3:
			var s := _data.wrap_s(turn_in - 100.0 * (k + 1))
			for side: float in [-1.0, 1.0]:
				var d := _barrier(s, side) - 0.3
				var p := _point(s, side, d, false)
				var t3: Vector3 = _data.tangent_at(s)
				var f := Vector3(t3.x, 0.0, t3.z).normalized()
				# Board facing the cars arriving: its normal is -tangent.
				var basis := Basis(f.cross(Vector3.UP).normalized() * -1.0, Vector3.UP, -f)
				_add("distance", s, Transform3D(basis, p + Vector3.UP * 1.25), Color.WHITE, Color(float(2 - k), 0, 0, 0))
				_add("dpost", s, Transform3D(Basis(), p + Vector3.UP * 0.6))

# ------------------------------------------------------------------ tyre walls, posts, poles
func _tyre_walls() -> void:
	var runoff: Variant = _ts.get("runoff")
	if not runoff is Array:
		return
	for r: Dictionary in runoff:
		var side := float(r["side"])
		var s0 := float(r["s0"])
		var length := float(r["len"])
		var prev := {}
		var t := 0.0
		while t <= length:
			var s := _data.wrap_s(s0 + t)
			var d := _barrier(s, side)
			var a := _point(s, side, d - 0.85, false)
			var b := _point(s, side, d - 0.05, false)
			var n := -_across(s, side)
			if not prev.is_empty():
				var st := _st(_chunk(s), "tyres")
				var up := Vector3.UP * 1.0
				var pa: Vector3 = prev["a"]
				var pb: Vector3 = prev["b"]
				var u1 := t / 1.2
				var u0: float = prev["u"]
				_quad(st, pa, a, a + up, pa + up, Vector2(u0, 1.0), Vector2(u1, 1.0), Vector2(u1, 0.0), Vector2(u0, 0.0), n)
				_quad(st, pa + up, a + up, b + up, pb + up, Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1, 0.0), Vector2(u0, 0.0), Vector3.UP)
			prev = {"a": a, "b": b, "u": t / 1.2}
			t += 2.0

func _marshal_posts() -> void:
	var s := 400.0
	var side := 1.0
	while s < _data.length - 200.0:
		var d := _barrier(s, side) + 2.8
		var p := _point(s, side, d)
		var n := -_across(s, side)
		var basis := Basis.looking_at(n, Vector3.UP)
		_add("hut", s, Transform3D(basis, p + Vector3.UP * 1.1))
		_add("hut_roof", s, Transform3D(basis, p + Vector3.UP * 2.3))
		s += 850.0
		side = -side

func _poles(s0: float, s1: float, side: float) -> void:
	var s := s0 + 10.0
	while s < s1:
		var p := _point(s, side, _barrier(s, side) + 6.5)
		_add("pole", s, Transform3D(Basis(), p + Vector3.UP * 4.5))
		var t3: Vector3 = _data.tangent_at(s)
		var basis := Basis.looking_at(Vector3(t3.x, 0.0, t3.z).normalized(), Vector3.UP)
		_add("crossarm", s, Transform3D(basis, p + Vector3.UP * 8.6))
		s += 45.0

# ------------------------------------------------------------------ meshes and commit
func _materials() -> Dictionary:
	var m := {}
	var tree_shader := load(TREE_SHADER) as Shader
	for id: String in _trees:
		var sm := ShaderMaterial.new()
		sm.shader = tree_shader
		sm.set_shader_parameter(&"atlas", load(str((_trees[id] as Dictionary)["file"])))
		sm.set_shader_parameter(&"crop_w", float((_trees[id] as Dictionary).get("crop_w", 1.0)))
		sm.set_shader_parameter(&"crop_h", float((_trees[id] as Dictionary).get("crop_h", 1.0)))
		m["tree:" + id] = sm
	var fence := StandardMaterial3D.new()
	fence.albedo_texture = load(CHAINLINK_TEX)
	fence.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fence.cull_mode = BaseMaterial3D.CULL_DISABLED
	fence.metallic = 0.6
	fence.roughness = 0.45
	fence.albedo_color = Color(1.25, 1.25, 1.25, 1.6)   # thicker wires once mipmapped
	fence.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	fence.disable_receive_shadows = true
	m["fence"] = fence
	var boards := StandardMaterial3D.new()
	boards.albedo_texture = load(BOARDS_TEX)
	boards.roughness = 0.55
	boards.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m["boards"] = boards
	var tyres := StandardMaterial3D.new()
	tyres.albedo_texture = _belt_texture()
	tyres.roughness = 0.75
	m["tyres"] = tyres
	return m

## Belted tyre wall: Le Mans blue / yellow conveyor belt over black tyres (UV.y 0 top .. 1).
static func _belt_texture() -> ImageTexture:
	var img := Image.create(4, 32, false, Image.FORMAT_RGB8)
	for y in 32:
		var c := Color(0.05, 0.12, 0.32)
		if y < 3:
			c = Color(0.06, 0.06, 0.07)
		elif y >= 12 and y < 19:
			c = Color(0.95, 0.78, 0.08)
		for x in 4:
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _prop_mesh(kind: String) -> Array:
	# [mesh, material]
	match kind:
		"post":
			var b := BoxMesh.new()
			b.size = Vector3(0.07, FENCE_HEIGHT, 0.07)
			return [b, _std(Color(0.55, 0.57, 0.58), 0.4, 0.7)]
		"dpost":
			var b := BoxMesh.new()
			b.size = Vector3(0.1, 1.2, 0.1)
			return [b, _std(Color(0.85, 0.85, 0.85), 0.5, 0.3)]
		"distance":
			var q := QuadMesh.new()
			q.size = Vector2(1.2, 1.2)
			var sm := ShaderMaterial.new()
			sm.shader = _distance_shader()
			sm.set_shader_parameter(&"atlas", load(DISTANCE_TEX))
			return [q, sm]
		"hut":
			var b := BoxMesh.new()
			b.size = Vector3(2.4, 2.2, 2.2)
			return [b, _std(Color(0.9, 0.9, 0.88), 0.7, 0.0)]
		"hut_roof":
			var b := BoxMesh.new()
			b.size = Vector3(2.9, 0.18, 2.7)
			return [b, _std(Color(0.95, 0.45, 0.08), 0.6, 0.0)]
		"pole":
			var c := CylinderMesh.new()
			c.top_radius = 0.11
			c.bottom_radius = 0.14
			c.height = 9.0
			c.radial_segments = 6
			c.rings = 1
			return [c, _std(Color(0.28, 0.21, 0.15), 0.9, 0.0)]
		"crossarm":
			var b := BoxMesh.new()
			b.size = Vector3(1.9, 0.12, 0.12)
			return [b, _std(Color(0.3, 0.23, 0.16), 0.9, 0.0)]
	return []

static func _std(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m

static func _distance_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
// Braking board of TrackDressing: one third of distance_boards.png per instance (INSTANCE_CUSTOM.x).
uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic;
varying float v_cell;
void vertex() { v_cell = INSTANCE_CUSTOM.x; }
void fragment() {
	ALBEDO = texture(atlas, vec2((UV.x + v_cell) / 3.0, UV.y)).rgb;
	ROUGHNESS = 0.6;
}
"""
	return sh

func _commit() -> void:
	var mats := _materials()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.center_offset = Vector3(0.0, 0.5, 0.0)
	var props := {}
	for key: String in _batches:
		var kind := key.get_slice("|", 0)
		var b: Dictionary = _batches[key]
		var xfs: Array = b["xf"]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var is_tree := kind.begins_with("tree:")
		mm.use_colors = is_tree
		mm.use_custom_data = is_tree or kind == "distance"
		var mat: Material
		if is_tree:
			mm.mesh = quad
			mat = mats.get(kind)
		else:
			if not props.has(kind):
				props[kind] = _prop_mesh(kind)
			var pm: Array = props[kind]
			if pm.is_empty():
				continue
			mm.mesh = pm[0]
			mat = pm[1]
		mm.instance_count = xfs.size()
		for i in xfs.size():
			mm.set_instance_transform(i, xfs[i])
			if mm.use_colors:
				mm.set_instance_color(i, (b["color"] as Array)[i])
			if mm.use_custom_data:
				mm.set_instance_custom_data(i, (b["custom"] as Array)[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = key.replace("|", "_").replace(":", "_")
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = TREE_RANGE if is_tree else PROP_RANGE
		mmi.visibility_range_end_margin = 60.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		_root.add_child(mmi)
	for chunk: int in _tools:
		var d: Dictionary = _tools[chunk]
		for what: String in d:
			var mesh := (d[what] as SurfaceTool).commit()
			var mi := MeshInstance3D.new()
			mi.name = "%s_%02d" % [what, chunk]
			mi.mesh = mesh
			mi.material_override = mats[what]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visibility_range_end = PROP_RANGE * 2.0
			_root.add_child(mi)
