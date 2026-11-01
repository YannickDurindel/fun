class_name TerrainOrtho
extends RefCounted
## The real ground pattern of a survey track in the realistic look: the IGN orthophoto,
## baked by tools/track/lib/landscape.py as land-cover RATIOS (terrain_ortho.jpg over the near
## terrain, terrain_ortho_far.jpg over the far hills, described by landscape.json), multiplies
## the terrain's palette colour. The palette stays the average, so the track keeps its look;
## the photograph adds what it shows: field patchwork, hedgerows, clearings, farm tracks, town
## blocks. It is faded out on the verges (the road mesh's own grass is there) and weakened
## near the camera, where the procedural ground and the photographed lawn carry the detail.
##
## Opt-in per track: only a track folder with landscape.json gets it, and only in the
## realistic style (TrackLook.terrain() calls splice() on the code it is already rewriting, so
## every other track and look keeps its terrain shader exactly).

const META_FILE := "landscape.json"
## Line of the rewritten terrain code (TrackLook.terrain) the ground pass goes in front of.
const HOOK := "\tcol = look_ground(col, p, dist);\n"
const UNIFORM_HOOK := "uniform float flood_reach = 90.0;\n"
const FRAGMENT_HOOK := "void fragment() {\n"
const UNIFORMS := """uniform sampler2D ortho_near : filter_linear_mipmap, repeat_disable;
uniform sampler2D ortho_far : filter_linear_mipmap, repeat_disable;
uniform vec4 ortho_near_rect = vec4(0.0);   // x0, z0, 1 / width, 1 / depth (m)
uniform vec4 ortho_far_rect = vec4(0.0);
uniform vec2 ortho_log = vec2(-2.0, 4.0);   // log2 ratio at texel 0, range
uniform float ortho_strength = 0.75;        // exponent of the ratio far from the camera
uniform float ortho_near_share = 0.35;      // ... of that within ortho_fade.x of the camera
uniform vec2 ortho_fade = vec2(30.0, 260.0);
uniform vec2 ortho_verge = vec2(20.0, 48.0);  // m from the centreline: none / full
"""
const FUNCTION := """// Orthophoto ratios (TerrainOrtho): the real ground pattern over the palette colour.
vec3 ortho_ground(vec3 col, vec2 p, float dist, float track_d) {
	vec2 un = (p - ortho_near_rect.xy) * ortho_near_rect.zw;
	vec2 uf = (p - ortho_far_rect.xy) * ortho_far_rect.zw;
	vec2 dn = dFdx(un);
	vec2 dn2 = dFdy(un);
	vec2 df = dFdx(uf);
	vec2 df2 = dFdy(uf);
	vec3 t;
	if (un.x > 0.0 && un.y > 0.0 && un.x < 1.0 && un.y < 1.0) {
		t = textureGrad(ortho_near, un, dn, dn2).rgb;
	} else if (uf.x > 0.0 && uf.y > 0.0 && uf.x < 1.0 && uf.y < 1.0) {
		t = textureGrad(ortho_far, uf, df, df2).rgb;
	} else {
		return col;
	}
	float w = ortho_strength * mix(ortho_near_share, 1.0, smoothstep(ortho_fade.x, ortho_fade.y, dist))
			* smoothstep(ortho_verge.x, ortho_verge.y, track_d);
	return col * exp2((t * ortho_log.y + ortho_log.x) * w);
}

"""

## Returns `code` (the terrain code TrackLook.terrain() is writing) with the orthophoto pass,
## and gives `mat` its textures; `code` unchanged when the track has no landscape.json.
static func splice(track: Node3D, mat: ShaderMaterial, code: String) -> String:
	var path: String = track.call("scenery_path", META_FILE) if track.has_method("scenery_path") else ""
	if path.is_empty() or not FileAccess.file_exists(path):
		return code
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var ortho: Variant = (meta as Dictionary).get("ortho") if meta is Dictionary else null
	if not (ortho is Dictionary and (ortho as Dictionary).has("near") and (ortho as Dictionary).has("far")):
		push_warning("TerrainOrtho: malformed %s" % path)
		return code
	if not (code.contains(HOOK) and code.contains(UNIFORM_HOOK) and code.contains(FRAGMENT_HOOK)):
		push_warning("TerrainOrtho: the terrain code changed, no orthophoto")
		return code
	var o: Dictionary = ortho
	var dir := path.get_base_dir()
	for key: String in ["near", "far"]:
		var g: Dictionary = o[key]
		var tex := load(dir.path_join(str(g["file"]))) as Texture2D
		if tex == null:
			push_warning("TerrainOrtho: cannot load %s" % g["file"])
			return code
		var w := float(g["step"]) * float(g["nx"])
		var d := float(g["step"]) * float(g["nz"])
		mat.set_shader_parameter("ortho_" + key, tex)
		mat.set_shader_parameter("ortho_%s_rect" % key, Vector4(float(g["x0"]), float(g["z0"]), 1.0 / w, 1.0 / d))
	var lo := float(o.get("log_min", -2.0))
	mat.set_shader_parameter("ortho_log", Vector2(lo, float(o.get("log_max", 2.0)) - lo))
	code = code.replace(UNIFORM_HOOK, UNIFORM_HOOK + UNIFORMS)
	code = code.replace(FRAGMENT_HOOK, FUNCTION + FRAGMENT_HOOK)
	return code.replace(HOOK, "\tcol = ortho_ground(col, p, dist, v_track);\n" + HOOK)
