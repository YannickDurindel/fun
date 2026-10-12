class_name TrackLook
extends RefCounted
## The opt-in "detailed" look of a track (environment.json "look": "detailed", see
## TrackEnvironment). Tracks without the flag never reach this code, so they render exactly
## as before. TrackEnvironment.apply() calls in here once the track's children are ready:
##   * road(): the track's tarmac shader (road_tarmac.gdshader of the folder) gets the code of
##     assets/tracks/_shared/look_detailed/road_tarmac_detailed.gdshader for this session
##     (TrackEnvironment.restore() puts the original code back), and every road mesh a copy of
##     the track material with the same lap uniforms, the shared detail textures
##     (cad/track/look_textures.py) and a "lap map" built here from the centreline: braking
##     zones, corner scrub, resurfaced sections.
##   * environment() / sun(): AgX tone mapping, a deeper sky with a darker ground bounce,
##     light aerial fog, longer and finer sun shadows.
## Why the code is swapped in place instead of assigning the detailed Shader resource: the
## Mobile renderer orders opaque draws by shader, and a shader created at race time drew the
## road after the terrain beneath it, so nothing was rejected by the depth test: +3.5 ms a
## frame on the HD 520 (10 cars, pit straight), for any shader, even a one-line one. With the
## track's own shader resource the road keeps its early place and the look costs ~1 ms.
## No reflection probe either: a box probe over the pit straight cost ~2 ms a frame (every
## pixel inside it samples it); the sky radiance does the reflections.

const GENERATED := "generated"
const REALISTIC := "realistic"
const DIR := "res://assets/tracks/_shared/look_detailed"
const TARMAC_SHADER := DIR + "/road_tarmac_detailed.gdshader"
const DETAIL_TEX := DIR + "/asphalt_detail.png"
const NORMAL_TEX := DIR + "/asphalt_normal.png"
const MACRO_TEX := DIR + "/asphalt_macro.png"
## CC0 sky panoramas (cad/track/fetch_cc0_assets.py): id -> {file, sun_azimuth_deg,
## sun_elevation_deg, sun_color}, the sun as found in the unrotated panorama.
const SKIES_FILE := DIR + "/sky/skies.json"
const DEFAULT_HDRI := "kloofendal_48d_partly_cloudy_puresky"
const GRASS_SHADER := DIR + "/road_grass_detailed.gdshader"
const RUNOFF_SHADER := DIR + "/runoff_detailed.gdshader"
const KERB_SHADER := DIR + "/kerb_detailed.gdshader"
const FLARE_SHADER := DIR + "/sun_flare.gdshader"
const VIGNETTE_SHADER := DIR + "/vignette.gdshader"
## Shared scenery shaders that scenery_ao() splices ambient occlusion into (realistic style).
const FACADE_SHADER_PATH := "res://shaders/scenery_facade.gdshader"
const SEATS_SHADER_PATH := "res://shaders/scenery_seats.gdshader"
const FRAGMENT_HOOK := "void fragment() {\n"
## Baked-lighting stand-in (LightmapGI cannot be baked from a script in Godot 4.7 and the
## scenery is built at load time, see scenery_ao()): ambient occlusion by position.
const FACADE_AO := "\t// TrackLook ambient occlusion: walls darker near the ground (contact with it).\n\tAO = mix(0.42, 1.0, smoothstep(-0.3, 3.5, UV.y));\n\tAO_LIGHT_AFFECT = 0.3;\n"
const SEATS_AO := "\t// TrackLook ambient occlusion: the back rows sit under the roof.\n\tAO = mix(1.0, 0.55, smoothstep(4.0, 22.0, UV.y));\n\tAO_LIGHT_AFFECT = 0.2;\n"
## Photo-scanned CC0 materials of the realistic style (cad/track/fetch_cc0_assets.py):
## photo/<name>_detail|albedo.webp + <name>_normal.webp, tile sizes in materials.json.
const PHOTO_DIR := DIR + "/photo"
## Lines of shaders/terrain.gdshader that terrain() hooks into (it warns and leaves the
## terrain alone when one is missing).
const TERRAIN_UNIFORM_HOOK := "uniform float flood_reach = 90.0;\n"
const TERRAIN_FRAGMENT_HOOK := "void fragment() {\n"
const TERRAIN_ALBEDO_HOOK := "\tALBEDO = col;\n"
const TERRAIN_ADDITIONS := """uniform sampler2D look_macro : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D look_grass : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 look_grass_mean = vec3(0.27, 0.36, 0.16);
uniform float look_grass_tile = 1.4;
"""
const TERRAIN_FUNCTION := """// Realistic look (TrackLook): large brightness / dryness blotches so the far land is not
// flat, and the photographed lawn's grain within ~60 m of the camera.
vec3 look_ground(vec3 col, vec2 p, float dist) {
	float m1 = texture(look_macro, p / 900.0).r;
	vec3 m2 = texture(look_macro, p / 230.0 + vec2(0.3, 0.6)).rgb;
	col *= 0.84 + 0.32 * m1;
	col = mix(col, col * vec3(1.1, 1.04, 0.8), smoothstep(0.45, 0.75, m2.b) * 0.55);
	col *= 0.94 + 0.12 * m2.g;
	float near = 1.0 - smoothstep(15.0, 60.0, dist);
	vec2 gp = p / look_grass_tile;
	vec2 gdx = dFdx(gp);
	vec2 gdy = dFdy(gp);
	if (near > 0.0) {
		vec3 g = textureGrad(look_grass, gp, gdx, gdy).rgb;
		col *= mix(vec3(1.0), clamp(g / look_grass_mean, vec3(0.3), vec3(2.5)), near * 0.8);
	}
	return col;
}

"""
## Metres of lap per lap-map texel (at most 16384 texels).
const LAP_MAP_STEP: float = 1.5

## Lap-map physics: a fast prototype, just enough to place the braking zones.
const LAT_ACCEL: float = 24.0     ## m/s^2 cornering
const BRAKE_DECEL: float = 28.0   ## m/s^2
const DRIVE_ACCEL: float = 7.0    ## m/s^2
const TOP_SPEED: float = 92.0     ## m/s

# ------------------------------------------------------------------------- road
## Gives every road mesh under `track` the detailed tarmac: procedural aggregate (GENERATED)
## or the photo-scanned asphalt (REALISTIC). Returns {Shader: original code} of the track
## shaders it rewrote, for unroad().
static func road(track: Node3D, realistic: bool = false) -> Dictionary:
	var swapped := {}
	var road_node := track.get_node_or_null(^"Road")
	var data: TrackData = track.get("data") if track.get("data") is TrackData else null
	var detailed := load(TARMAC_SHADER) as Shader
	if road_node == null or data == null or detailed == null:
		return swapped
	var lap_map := build_lap_map(data, str(track.get("track_id")))
	var made := {}       # old material -> new material
	for node: Node in road_node.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for surf in mi.mesh.get_surface_count():
			var old := mi.get_surface_override_material(surf) as ShaderMaterial
			if old == null:
				old = mi.mesh.surface_get_material(surf) as ShaderMaterial
			if old == null or made.has(old):
				if old != null:
					mi.set_surface_override_material(surf, made[old])
				continue
			if old.shader == null or not old.shader.resource_path.ends_with("road_tarmac.gdshader"):
				continue
			made[old] = _detailed_material(old, detailed, lap_map)
			if realistic:
				_photo_asphalt(made[old])
			if not swapped.has(old.shader):
				swapped[old.shader] = old.shader.code
			mi.set_surface_override_material(surf, made[old])
	for sh: Shader in swapped:
		sh.code = detailed.code
	return swapped

## The grass verges of the road mesh: the track's road_grass.gdshader gets the detailed code
## (draw order kept, as for the road) and its material the detail textures. The material is
## the shared one on purpose: Scenery copies it for the track's verge colours afterwards.
## Adds the rewritten shaders to `swapped` ({Shader: original code}).
static func grass(track: Node3D, swapped: Dictionary) -> void:
	var road_node := track.get_node_or_null(^"Road")
	var detailed := load(GRASS_SHADER) as Shader
	if road_node == null or detailed == null:
		return
	var done := {}
	for node: Node in road_node.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for surf in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(surf) as ShaderMaterial
			if mat == null or done.has(mat) or mat.shader == null \
					or not mat.shader.resource_path.ends_with("road_grass.gdshader"):
				continue
			done[mat] = true
			mat.set_shader_parameter(&"grass_albedo", photo_tex("grass_albedo"))
			mat.set_shader_parameter(&"grass_far", photo_tex("grass_albedo"))
			mat.set_shader_parameter(&"macro", load(MACRO_TEX))
			mat.set_shader_parameter(&"tile_m", photo_tile("grass"))
			if not swapped.has(mat.shader):
				swapped[mat.shader] = mat.shader.code
				mat.shader.code = detailed.code

## The terrain: shaders/terrain.gdshader (shared by every track, restored with the others)
## gets look_ground() spliced in before its albedo is written.
static func terrain(track: Node3D, swapped: Dictionary) -> void:
	var t := track.get_node_or_null(^"Terrain")
	var mat: ShaderMaterial = t.get("material") if t != null and t.get("material") is ShaderMaterial else null
	if mat == null or mat.shader == null or swapped.has(mat.shader):
		return
	var code := mat.shader.code
	if not (code.contains(TERRAIN_UNIFORM_HOOK) and code.contains(TERRAIN_FRAGMENT_HOOK)
			and code.contains(TERRAIN_ALBEDO_HOOK)):
		push_warning("TrackLook: shaders/terrain.gdshader changed, the terrain keeps its plain look")
		return
	mat.set_shader_parameter(&"look_macro", load(MACRO_TEX))
	mat.set_shader_parameter(&"look_grass", photo_tex("grass_albedo"))
	mat.set_shader_parameter(&"look_grass_tile", photo_tile("grass"))
	var mean: Variant = photo_info("grass").get("mean_rgb")
	if mean is Array and (mean as Array).size() == 3:
		# The texture is sampled as sRGB colour: the mean, stored as encoded values, is linearised.
		var c := Color(float(mean[0]), float(mean[1]), float(mean[2])).srgb_to_linear()
		mat.set_shader_parameter(&"look_grass_mean", Vector3(c.r, c.g, c.b))
	swapped[mat.shader] = code
	code = code.replace(TERRAIN_UNIFORM_HOOK, TERRAIN_UNIFORM_HOOK + TERRAIN_ADDITIONS)
	code = code.replace(TERRAIN_FRAGMENT_HOOK, TERRAIN_FUNCTION + TERRAIN_FRAGMENT_HOOK)
	code = code.replace(TERRAIN_ALBEDO_HOOK, "\tcol = look_ground(col, p, dist);\n" + TERRAIN_ALBEDO_HOOK)
	mat.shader.code = code

## Run-off areas of the Trackside: its plain gravel and tarmac materials are replaced on the
## chunk meshes by runoff_detailed.gdshader materials (a small area of the screen, so the
## new shader's late draw order costs little).
static func runoff(track: Node3D) -> void:
	var ts := track.get_node_or_null(^"Trackside")
	if ts == null or not (ts.get("_mats") is Array):
		return
	var mats: Array = ts.get("_mats")
	if mats.size() <= maxi(Trackside.Mat.GRAVEL, Trackside.Mat.TARMAC):
		return
	var shader := load(RUNOFF_SHADER) as Shader
	if shader == null:
		return
	var gravel := ShaderMaterial.new()
	gravel.shader = shader
	gravel.set_shader_parameter(&"gravel", 1.0)
	gravel.set_shader_parameter(&"detail", photo_tex("gravel_albedo"))
	gravel.set_shader_parameter(&"detail_far", photo_tex("gravel_albedo"))
	gravel.set_shader_parameter(&"detail_normal", photo_tex("gravel_normal"))
	gravel.set_shader_parameter(&"macro", load(MACRO_TEX))
	gravel.set_shader_parameter(&"tile_m", photo_tile("gravel"))
	var tarmac := ShaderMaterial.new()
	tarmac.shader = shader
	tarmac.set_shader_parameter(&"gravel", 0.0)
	tarmac.set_shader_parameter(&"detail_lin", photo_tex("asphalt_detail"))
	tarmac.set_shader_parameter(&"detail_lin_far", photo_tex("asphalt_detail"))
	tarmac.set_shader_parameter(&"detail_normal", photo_tex("asphalt_normal"))
	tarmac.set_shader_parameter(&"macro", load(MACRO_TEX))
	tarmac.set_shader_parameter(&"tile_m", photo_tile("asphalt"))
	_swap_materials(ts, {mats[Trackside.Mat.GRAVEL]: gravel, mats[Trackside.Mat.TARMAC]: tarmac})

## Photo-scanned asphalt on a detailed tarmac material: the same shader, the pack holds the
## photo's luminance, roughness and AO instead of the procedural aggregate.
static func _photo_asphalt(m: ShaderMaterial) -> void:
	var tile := photo_tile("asphalt")
	m.set_shader_parameter(&"detail", photo_tex("asphalt_detail"))
	m.set_shader_parameter(&"detail_far", photo_tex("asphalt_detail"))
	m.set_shader_parameter(&"detail_normal", photo_tex("asphalt_normal"))
	m.set_shader_parameter(&"detail_scale", 1.0 / tile)
	m.set_shader_parameter(&"detail_far_scale", 1.0 / (tile * 3.55))
	m.set_shader_parameter(&"agg_contrast", 0.8)
	m.set_shader_parameter(&"normal_strength", 1.0)

## A photo texture of PHOTO_DIR: "asphalt_detail", "grass_albedo", "metal_normal"...
static func photo_tex(name: String) -> Texture2D:
	return load(PHOTO_DIR.path_join(name + ".webp")) as Texture2D

## materials.json entry of a photo material ({} when missing).
static func photo_info(name: String) -> Dictionary:
	var path := PHOTO_DIR.path_join("materials.json")
	if not FileAccess.file_exists(path):
		return {}
	var t: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var e: Variant = (t as Dictionary).get(name) if t is Dictionary else null
	return e if e is Dictionary else {}

## Metres per texture tile of a photo material (2 m when unknown).
static func photo_tile(name: String) -> float:
	return float(photo_info(name).get("tile_m", 2.0))

## Kerbs, concrete walls and armco of the Trackside: photo-scanned concrete under the kerb
## paint (kerb_detailed.gdshader), concrete and galvanised steel on the barriers
## (StandardMaterial3D, world-triplanar so no UVs are needed). Small areas of the screen.
static func barriers(track: Node3D) -> void:
	var ts := track.get_node_or_null(^"Trackside")
	if ts == null or not (ts.get("_mats") is Array):
		return
	var mats: Array = ts.get("_mats")
	if mats.size() < Trackside.Mat.size():
		return
	var swap := {}
	var kerb_shader := load(KERB_SHADER) as Shader
	for k: int in [Trackside.Mat.KERB_RW, Trackside.Mat.KERB_YELLOW]:
		var old := mats[k] as ShaderMaterial
		if old == null or kerb_shader == null:
			continue
		var m := ShaderMaterial.new()
		m.shader = kerb_shader
		for key: StringName in [&"color_a", &"color_b", &"stripe"]:
			m.set_shader_parameter(key, old.get_shader_parameter(key))
		m.set_shader_parameter(&"concrete", photo_tex("concrete_albedo"))
		m.set_shader_parameter(&"macro", load(MACRO_TEX))
		m.set_shader_parameter(&"tile_m", photo_tile("concrete"))
		swap[old] = m
	var conc := _photo_standard("concrete", 0.0)
	conc.albedo_color = Color(0.92, 0.91, 0.88)
	swap[mats[Trackside.Mat.CONCRETE]] = conc
	var beam := _photo_standard("metal", 0.85)
	beam.cull_mode = BaseMaterial3D.CULL_DISABLED
	swap[mats[Trackside.Mat.BEAM]] = beam
	_swap_materials(ts, swap)

## A triplanar StandardMaterial3D of a photo material (colour + roughness in alpha + normal).
static func _photo_standard(name: String, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = photo_tex(name + "_albedo")
	m.roughness_texture = m.albedo_texture
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_ALPHA
	m.roughness = 1.0
	m.metallic = metallic
	m.normal_enabled = true
	m.normal_texture = photo_tex(name + "_normal")
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	var k := 1.0 / photo_tile(name)
	m.uv1_scale = Vector3(k, k, k)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m

## Overrides every surface of the meshes (and multimeshes) under `root` whose material is a
## key of `swap` with its value.
static func _swap_materials(root: Node, swap: Dictionary) -> void:
	for node: Node in root.find_children("*", "GeometryInstance3D", true, false):
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			for surf in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(surf)
				if swap.has(m):
					mi.set_surface_override_material(surf, swap[m])
		elif node is MultiMeshInstance3D:
			var mmi := node as MultiMeshInstance3D
			var mesh := mmi.multimesh.mesh if mmi.multimesh != null else null
			if mesh != null and mesh.get_surface_count() == 1 and swap.has(mesh.surface_get_material(0)):
				mmi.material_override = swap[mesh.surface_get_material(0)]

## Baked-lighting stand-in for the static scenery: building walls darken towards the ground
## and grandstand rows towards the back, in the shared scenery shaders (rewritten for the
## session, restored by unroad() with the others). A LightmapGI bake is not possible here:
## LightmapGI has no bake method a script can call (only the editor's Bake button), and the
## scenery is generated at load time, so there is no saved scene to bake.
static func scenery_ao(swapped: Dictionary) -> void:
	for pair: Array in [[FACADE_SHADER_PATH, FACADE_AO], [SEATS_SHADER_PATH, SEATS_AO]]:
		var sh := load(pair[0]) as Shader
		if sh == null or swapped.has(sh) or not sh.code.contains(FRAGMENT_HOOK):
			continue
		swapped[sh] = sh.code
		sh.code = sh.code.replace(FRAGMENT_HOOK, FRAGMENT_HOOK + str(pair[1]))

## The scenery's own trees (Scenery, from the map data) as photo impostors: every tree
## MultiMesh gets a quad and scenery_tree_card.gdshader with the impostor of its species
## (trees/trees.json, cad/track/bake_impostors.gd), so the landscape near the track matches
## the trackside dressing. Only the near copies (lod0): alpha-tested cards cost overdraw, and
## far away the low-poly copies (lod1) read the same. Call it once Scenery has built its
## trees (deferred from apply).
const SCENERY_TREE_SHADER := DIR + "/scenery_tree_card.gdshader"
const TREE_IMPOSTOR := {"conifer": "tree_small_02", "broadleaf": "island_tree_01", "palm": "island_tree_02",
		"cypress": "tree_small_02", "bush": "shrub_04"}

static func scenery_trees(track: Node) -> void:
	if not is_instance_valid(track):
		return
	var scenery := track.get_node_or_null(^"Scenery")
	var path := DIR + "/trees/trees.json"
	if scenery == null or not FileAccess.file_exists(path):
		return
	var trees: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not trees is Dictionary:
		return
	var shader := load(SCENERY_TREE_SHADER) as Shader
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.center_offset = Vector3(0.0, 0.5, 0.0)
	var mats := {}
	for node: Node in scenery.find_children("trees_*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		var species := ""
		for sp: String in TREE_IMPOSTOR:
			if String(mmi.name).contains("_%s_lod" % sp):
				species = sp
		if species.is_empty() or mmi.multimesh == null or not String(mmi.name).ends_with("_lod0"):
			continue
		var id: String = TREE_IMPOSTOR[species]
		if not (trees as Dictionary).has(id):
			continue
		if not mats.has(species):
			var m := ShaderMaterial.new()
			m.shader = shader
			m.set_shader_parameter(&"atlas", load(str((trees[id] as Dictionary)["file"])))
			m.set_shader_parameter(&"aspect", 0.75 if species == "cypress" else (1.3 if species == "bush" else 1.0))
			m.set_shader_parameter(&"crop_w", float((trees[id] as Dictionary).get("crop_w", 1.0)))
			m.set_shader_parameter(&"crop_h", float((trees[id] as Dictionary).get("crop_h", 1.0)))
			mats[species] = m
		mmi.multimesh.mesh = quad
		mmi.material_override = mats[species]

## Sun flare over the 3D view (sun_flare.gdshader), following `light` (the sun); added under
## `track`, so it goes with it.
static func sun_flare(track: Node, light: DirectionalLight3D, color: Color) -> void:
	# (also the lens vignette, see SunFlare)
	if light == null or track.get_node_or_null(^"LookSunFlare") != null:
		return
	var flare := SunFlare.new()
	flare.name = "LookSunFlare"
	flare.sun = light
	flare.tint = color
	track.add_child(flare)

## The flare layer: a full-screen additive quad whose shader draws the glow at the sun's
## screen position. One ray per frame from the camera towards the sun hides it behind
## buildings, bridges and terrain (things with collision); it fades in and out. A second
## quad multiplies a light lens vignette over the view.
class SunFlare extends CanvasLayer:
	var sun: DirectionalLight3D
	var tint := Color(1.0, 0.92, 0.8)
	var _rect: ColorRect
	var _mat: ShaderMaterial
	var _vis := 0.0

	func _ready() -> void:
		layer = -1   # under the HUD
		_mat = ShaderMaterial.new()
		_mat.shader = load(FLARE_SHADER)
		_mat.set_shader_parameter(&"tint", tint)
		_rect = ColorRect.new()
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_rect.material = _mat
		add_child(_rect)
		var vig := ColorRect.new()
		vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vig.set_anchors_preset(Control.PRESET_FULL_RECT)
		var vm := ShaderMaterial.new()
		vm.shader = load(VIGNETTE_SHADER)
		vig.material = vm
		add_child(vig)

	func _process(delta: float) -> void:
		var cam := get_viewport().get_camera_3d()
		var want := 0.0
		if cam != null and is_instance_valid(sun) and sun.visible:
			var to_sun := sun.global_basis.z.normalized()   # the light shines along -Z
			var far := cam.global_position + to_sun * 3000.0
			if not cam.is_position_behind(far):
				var px := cam.unproject_position(far)
				var size := get_viewport().get_visible_rect().size
				var uv := px / size
				var facing := clampf(to_sun.dot(-cam.global_basis.z), 0.0, 1.0)
				want = facing * facing * (1.0 - smoothstep(0.45, 0.8, (uv - Vector2(0.5, 0.5)).length()))
				_mat.set_shader_parameter(&"sun_uv", uv)
				_mat.set_shader_parameter(&"aspect", size.x / maxf(size.y, 1.0))
				if want > 0.0:
					var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + to_sun * 2000.0)
					if not cam.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
						want = 0.0
		_vis = move_toward(_vis, want, delta * 4.0)
		_mat.set_shader_parameter(&"strength", _vis)
		_rect.visible = _vis > 0.001

## Puts the original code back into the shaders road() rewrote.
static func unroad(swapped: Dictionary) -> void:
	for sh: Variant in swapped:
		if is_instance_valid(sh):
			(sh as Shader).code = swapped[sh]

## A copy of the track material (see the header: the copy keeps the shader's draw order)
## carrying, as explicit parameters, every lap uniform the detailed shader shares with the
## track shader, including the track shader's own defaults (read before its code changes).
static func _detailed_material(old: ShaderMaterial, detailed: Shader, lap_map: Texture2D) -> ShaderMaterial:
	var m := old.duplicate() as ShaderMaterial
	m.resource_name = "tarmac"
	var wanted := {}
	for u: Dictionary in detailed.get_shader_uniform_list():
		wanted[u["name"]] = true
	for u: Dictionary in old.shader.get_shader_uniform_list():
		var n: String = u["name"]
		if not wanted.has(n) or int(u["type"]) == TYPE_OBJECT:
			continue
		var v: Variant = old.get_shader_parameter(n)
		if v == null:
			v = RenderingServer.shader_get_parameter_default(old.shader.get_rid(), n)
		if v != null:
			m.set_shader_parameter(n, v)
	m.set_shader_parameter(&"detail", load(DETAIL_TEX))
	m.set_shader_parameter(&"detail_far", load(DETAIL_TEX))
	m.set_shader_parameter(&"detail_normal", load(NORMAL_TEX))
	m.set_shader_parameter(&"macro", load(MACRO_TEX))
	m.set_shader_parameter(&"lap_map", lap_map)
	m.set_shader_parameter(&"lap_map_exact", lap_map)
	return m

## 1-pixel-high RGB texture along the lap, texel i covers s in [i, i+1) * length / width:
##   R tyre marks of the braking zones (heaviest just before turn-in), G cornering load
##   (wider rubber through corners), B tone of the resurfaced section (sections 60-350 m,
##   each a constant; a change is a transverse join).
static func build_lap_map(data: TrackData, seed_name: String = "") -> ImageTexture:
	var n := data.points.size()
	var w := clampi(int(ceil(data.length / LAP_MAP_STEP)), 64, 16384)
	var brake := PackedFloat32Array()
	var load_g := PackedFloat32Array()
	_speed_profile(data, brake, load_g)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_name if not seed_name.is_empty() else data.name)
	var img := Image.create(w, 1, false, Image.FORMAT_RGB8)
	var next_join := rng.randf_range(60.0, 350.0)
	var tone := rng.randf()
	for i in w:
		var s := (i + 0.5) * data.length / w
		if s > next_join:
			next_join += rng.randf_range(60.0, 350.0)
			var t := rng.randf()
			tone = t if absf(t - tone) > 0.15 else fposmod(tone + 0.4, 1.0)
		var u := s / data.step
		var a := int(floorf(u)) % n
		var b := (a + 1) % n
		var f := u - floorf(u)
		img.set_pixel(i, 0, Color(lerpf(brake[a], brake[b], f), lerpf(load_g[a], load_g[b], f), tone))
	return ImageTexture.create_from_image(img)

## Per centreline point: `brake` 0..1 (how hard cars brake here x how close to turn-in) and
## `load_g` 0..1 (lateral load), from a forward / backward speed pass on the smoothed
## curvature.
static func _speed_profile(data: TrackData, brake: PackedFloat32Array, load_g: PackedFloat32Array) -> void:
	var n := data.points.size()
	var step := data.step
	var k := PackedFloat32Array()
	k.resize(n)
	var span := maxi(1, int(round(6.0 / step)))
	for i in n:
		var p0 := data.points[(i - span + n) % n]
		var p1 := data.points[i]
		var p2 := data.points[(i + span) % n]
		var a := Vector2(p1.x - p0.x, p1.z - p0.z)
		var b := Vector2(p2.x - p1.x, p2.z - p1.z)
		k[i] = absf(a.angle_to(b)) / maxf(0.5 * (a.length() + b.length()), 0.1)
	# Smooth over +-12 m.
	var ks := PackedFloat32Array()
	ks.resize(n)
	var r := maxi(1, int(round(12.0 / step)))
	for i in n:
		var acc := 0.0
		for j in range(-r, r + 1):
			acc += k[(i + j + n) % n]
		ks[i] = acc / (2 * r + 1)
	var v := PackedFloat32Array()
	v.resize(n)
	for i in n:
		v[i] = minf(TOP_SPEED, sqrt(LAT_ACCEL / maxf(ks[i], 1e-5)))
	# Two laps of each pass so the wrap at the finish line settles.
	for _lap in 2:
		for i in n:
			var prev := v[(i - 1 + n) % n]
			v[i] = minf(v[i], sqrt(prev * prev + 2.0 * DRIVE_ACCEL * step))
	for _lap in 2:
		for i in range(n - 1, -1, -1):
			var nxt := v[(i + 1) % n]
			v[i] = minf(v[i], sqrt(nxt * nxt + 2.0 * BRAKE_DECEL * step))
	brake.resize(n)
	load_g.resize(n)
	for i in n:
		load_g[i] = clampf(v[i] * v[i] * ks[i] / LAT_ACCEL, 0.0, 1.0)
		brake[i] = 0.0
	# Braking zones: runs where the speed falls; marks grow towards the end of each zone and
	# with the speed shed (a stop from 300 km/h leaves more rubber than a lift).
	var i0 := 0
	while i0 < n and v[(i0 + 1) % n] < v[i0] - 0.01:
		i0 += 1   # start outside a zone so zones are not split at the wrap
	var idx := 0
	while idx < n:
		var i := (i0 + idx) % n
		if v[(i + 1) % n] < v[i] - 0.01:
			var zone: Array[int] = []
			var j := i
			while v[(j + 1) % n] < v[j] - 0.01 and zone.size() < n:
				zone.append(j)
				j = (j + 1) % n
			var shed := v[zone[0]] - v[j]
			var strength := clampf(shed / 45.0, 0.15, 1.0)
			for z in zone.size():
				var t := float(z + 1) / zone.size()
				brake[zone[z]] = strength * (0.25 + 0.75 * t * t)
			# Marks carry a little past turn-in.
			for z in int(15.0 / step):
				var q := (j + z) % n
				brake[q] = maxf(brake[q], strength * (1.0 - float(z) * step / 15.0))
			idx += zone.size()
		else:
			idx += 1

# ------------------------------------------------------------------------- lighting
## Environment settings of the detailed look (on the copy TrackEnvironment installs).
## The style the player picked (Settings graphics/track_look): GENERATED or REALISTIC. Dev
## flag (after `--`): --track-look=generated|realistic overrides it for this run.
static func style() -> String:
	var v := str(Settings.get_value("graphics", "track_look"))
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--track-look="):
			v = arg.get_slice("=", 1)
	return v if v == GENERATED else REALISTIC

## The colour grade of the realistic style: a per-channel curve (Environment colour
## correction reads each channel through the gradient): shadows lifted towards blue,
## highlights rolled warm.
static func grade_texture() -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, Color(0.0, 0.006, 0.022))
	g.set_color(1, Color(1.0, 0.985, 0.95))
	g.add_point(0.25, Color(0.24, 0.25, 0.265))
	g.add_point(0.75, Color(0.765, 0.75, 0.73))
	var t := GradientTexture1D.new()
	t.gradient = g
	t.width = 256
	return t

## The sky panorama `id` of skies.json ("" = DEFAULT_HDRI), {} when it is not there.
static func hdri(id: String) -> Dictionary:
	if not FileAccess.file_exists(SKIES_FILE):
		return {}
	var skies: Variant = JSON.parse_string(FileAccess.get_file_as_string(SKIES_FILE))
	if not skies is Dictionary:
		return {}
	var entry: Variant = (skies as Dictionary).get(id if not id.is_empty() else DEFAULT_HDRI)
	if not entry is Dictionary or not ResourceLoader.exists(str((entry as Dictionary).get("file", ""))):
		push_warning("TrackLook: no sky panorama '%s'" % id)
		return {}
	return entry

## The day sky of the detailed look: environment.json "sky"/"hdri" (default DEFAULT_HDRI),
## turned so its sun stands at the track's sun azimuth. {} at dusk / night or without it.
static func day_sky(env: TrackEnvironment) -> Dictionary:
	if env.time != "day" or env.look_style() != REALISTIC:
		return {}
	return hdri(str(env.section("sky").get("hdri", "")))

static func environment(e: Environment, env: TrackEnvironment) -> void:
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_white = 8.0
	e.tonemap_exposure = float(env.values.get("exposure", 1.0)) * 1.25
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.1
	e.adjustment_contrast = 1.06
	e.ambient_light_sky_contribution = 0.7
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.fog_aerial_perspective = 0.6
	e.fog_sun_scatter = 0.18
	e.fog_depth_curve = 1.4
	e.fog_depth_begin = minf(e.fog_depth_begin, 180.0)
	e.glow_intensity = maxf(e.glow_intensity, 0.4)
	var pano_sky := day_sky(env)
	if e.sky != null and not pano_sky.is_empty():
		# A photographed sky: background, ambient light and reflections all come from it.
		var pano := PanoramaSkyMaterial.new()
		pano.panorama = load(str(pano_sky["file"]))
		pano.energy_multiplier = env.number("sky", "hdri_energy")
		e.sky.sky_material = pano
		e.sky.radiance_size = Sky.RADIANCE_SIZE_256
		e.sky_rotation = Vector3(0.0, deg_to_rad(float(pano_sky["sun_azimuth_deg"])
				- env.number("sun", "azimuth_deg")), 0.0)
		e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		e.ambient_light_sky_contribution = 1.0
		e.fog_aerial_perspective = 0.85  # distant ground fades into the photographed horizon
		# A photographed sky lights the scene more evenly: less haze, a little more contrast.
		e.fog_depth_begin = maxf(e.fog_depth_begin, 450.0)
		e.fog_depth_end = maxf(e.fog_depth_end, 5000.0)
		e.tonemap_exposure = float(env.values.get("exposure", 1.0)) * 1.1
		e.adjustment_contrast = 1.14
		e.adjustment_saturation = 1.12
		# Bloom: only what is really bright (sun glints on paint and glass, the sky near the
		# sun), soft and wide, as a camera lens does.
		e.glow_enabled = true
		e.glow_intensity = 0.55
		e.glow_strength = 1.0
		e.glow_bloom = 0.02
		e.glow_hdr_threshold = 1.15
		e.glow_hdr_scale = 2.0
		e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
		for i in 7:
			e.set_glow_level(i, 1.0 if i in [1, 3, 4] else 0.0)
		# Colour grade: a touch of warmth in the highlights, cooler lifted shadows.
		e.adjustment_color_correction = grade_texture()
	elif env.time == "day" and e.sky != null and e.sky.sky_material is ProceduralSkyMaterial:
		var mat := (e.sky.sky_material as ProceduralSkyMaterial).duplicate() as ProceduralSkyMaterial
		var top := env.color("sky", "top")
		var horizon := env.color("sky", "horizon")
		mat.sky_top_color = top.darkened(0.08)
		mat.sky_horizon_color = horizon
		mat.sky_curve = 0.09
		mat.sky_energy_multiplier = 1.0
		# A darker, greener ground bounce than the sky colour: the shade under cars and on
		# the lower bodywork reads as ground, not as sky.
		mat.ground_horizon_color = horizon.lerp(Color(0.36, 0.38, 0.32), 0.5)
		mat.ground_bottom_color = Color(0.16, 0.18, 0.13)
		mat.ground_curve = 0.05
		mat.sun_angle_max = 18.0
		mat.sun_curve = 0.08
		e.sky.sky_material = mat
		e.sky.radiance_size = Sky.RADIANCE_SIZE_128

## Sun of the detailed look: longer, finer shadow cascades.
static func sun(light: DirectionalLight3D) -> void:
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	light.directional_shadow_max_distance = 140.0
	light.directional_shadow_split_1 = 0.14
	light.directional_shadow_blend_splits = true
	light.shadow_blur = 1.0
	# Flat trackside meshes (run-off, lines) cast shadows: with the longer cascades their own
	# shadow showed as ripples (acne) on the run-off; a little more bias hides it.
	light.shadow_bias = 0.06
	light.shadow_normal_bias = 2.0

# ------------------------------------------------------------------------- car reflections
## Render layer of the cars' meshes on a detailed track (instead of layer 1): the reflection
## probe below shows only on this layer and does not capture it.
const LAYER_CARS: int = 1 << 12
const PROBE_NAME := "LookCarReflections"
## Where the probe looks from: this far round the lap, this high above the road.
const PROBE_S: float = 450.0
const PROBE_HEIGHT: float = 1.5

## One reflection probe for the cars' paint, captured once from the start / finish straight
## (stands, pits, trees, the road and the sky) and used all round the lap (no box
## projection): RR3-style glossy bodywork for the cost of one capture at load. Its
## reflection_mask is LAYER_CARS, so only car pixels sample it (a probe over the road cost
## ~2 ms a frame on the HD 520). A CarTagger moves every car mesh that enters the tree to
## LAYER_CARS.
static func car_reflections(track: Node3D, intensity: float = 1.0) -> ReflectionProbe:
	var data: TrackData = track.get("data") if track.get("data") is TrackData else null
	if data == null or track.get_node_or_null(NodePath(PROBE_NAME)) != null:
		return null
	var box := AABB(data.points[0], Vector3.ZERO)
	for p in data.points:
		box = box.expand(p)
	box = box.grow(600.0)
	var probe := ReflectionProbe.new()
	probe.name = PROBE_NAME
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.size = box.size
	probe.box_projection = false
	probe.max_distance = 1500.0
	probe.intensity = intensity
	probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
	probe.cull_mask = 0xFFFFF & ~LAYER_CARS
	probe.reflection_mask = LAYER_CARS
	var eye := data.sample(data.wrap_s(PROBE_S)).origin + Vector3.UP * PROBE_HEIGHT
	probe.position = box.get_center()
	probe.origin_offset = eye - box.get_center()
	track.add_child(probe)
	var tagger := CarTagger.new()
	tagger.name = "LookCarTagger"
	track.add_child(tagger)
	for car: Node in track.get_tree().get_nodes_in_group(&"car"):
		tagger.tag(car)
	return probe

## Paint of the car bodies on a detailed track (by material name, see
## scenes/car/endurance_body_visual.tscn): sharper, more metallic reflections of the
## photographed sky. Applied to copies, the scene's materials stay as they are.
const CAR_PAINT := {
	"Livery": {"metallic": 0.2, "roughness": 0.22, "clearcoat": 1.0, "clearcoat_roughness": 0.02},
	"LiveryWhite": {"metallic": 0.05, "roughness": 0.24, "clearcoat": 1.0, "clearcoat_roughness": 0.03},
	"Accent": {"metallic": 0.2, "roughness": 0.24, "clearcoat": 1.0, "clearcoat_roughness": 0.03},
	"Helmet": {"roughness": 0.2, "clearcoat": 1.0, "clearcoat_roughness": 0.02},
	"Glass": {"metallic": 0.0, "roughness": 0.02, "clearcoat": 1.0, "clearcoat_roughness": 0.0},
	"Carbon": {"roughness": 0.3, "clearcoat": 0.6, "clearcoat_roughness": 0.08},
}

## Puts the meshes of every car (a Car and everything under it) on LAYER_CARS as they enter
## the tree, while this node is in it, and gives their paint the CAR_PAINT values. The paint
## is changed in place on the materials the car scenes share (bots copy them when they are
## dressed, so they get it too) and put back when this node leaves the tree. Swapping in
## copies instead left stale material RIDs in the renderer ("Parameter material is null").
class CarTagger extends Node:
	var _saved := {}   # Material -> {property: original value}

	func _enter_tree() -> void:
		get_tree().node_added.connect(_on_node_added)

	func _exit_tree() -> void:
		if get_tree().node_added.is_connected(_on_node_added):
			get_tree().node_added.disconnect(_on_node_added)
		for m: Variant in _saved:
			if is_instance_valid(m):
				var orig: Dictionary = _saved[m]
				for key: String in orig:
					(m as Material).set(key, orig[key])
		_saved.clear()

	func _on_node_added(node: Node) -> void:
		if node is GeometryInstance3D and _in_car(node):
			_tag_one(node as GeometryInstance3D)

	func tag(root: Node) -> void:
		for n: Node in root.find_children("*", "GeometryInstance3D", true, false):
			_tag_one(n as GeometryInstance3D)

	static func _in_car(node: Node) -> bool:
		var p := node.get_parent()
		for _i in 8:
			if p == null:
				return false
			if p is Car:
				return true
			p = p.get_parent()
		return false

	func _tag_one(g: GeometryInstance3D) -> void:
		if g.layers & 1:
			g.layers = (g.layers & ~1) | LAYER_CARS
		var mi := g as MeshInstance3D
		if mi == null or mi.mesh == null:
			return
		for surf in mi.mesh.get_surface_count():
			var m := mi.get_active_material(surf) as StandardMaterial3D
			# A car scene that brings its own clear-coat paint (the 499P-style endurance body)
			# keeps it: only plain paints get the CAR_PAINT values.
			if m == null or _saved.has(m) or not CAR_PAINT.has(m.resource_name) or m.clearcoat_enabled:
				continue
			var p: Dictionary = CAR_PAINT[m.resource_name]
			var orig := {"clearcoat_enabled": m.clearcoat_enabled}
			for key: String in p:
				orig[key] = m.get(key)
			_saved[m] = orig
			for key: String in p:
				m.set(key, p[key])
			if float(p.get("clearcoat", 0.0)) > 0.0:
				m.clearcoat_enabled = true
