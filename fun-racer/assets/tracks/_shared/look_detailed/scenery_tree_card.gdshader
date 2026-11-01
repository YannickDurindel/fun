shader_type spatial;
// The scenery's own trees (scripts/track/scenery.gd, from the map data) as photo impostors in
// the realistic track look: TrackLook swaps the low-poly meshes of its tree MultiMeshes for a
// quad and this material. Same billboard as tree_card.gdshader, fed with Scenery's instance
// data: the basis gives the height (the quad is as wide as `aspect` x height), INSTANCE_CUSTOM
// = (palette colour, random) - the colour tints the photo a little, the random picks the view.
// No shadow receiving: sampling the sun shadow map on every leaf pixel cost several ms in
// the forests on the HD 520; the sphere normal already shades the crown.
render_mode world_vertex_coords, cull_disabled, depth_draw_opaque, diffuse_lambert_wrap, specular_disabled, shadows_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float aspect = 1.0;
uniform float crown = 0.62;
uniform float crop_w = 1.0;   // share of the impostor square the tree covers (trees.json)
uniform float crop_h = 1.0;
uniform vec3 palette_mean = vec3(0.04, 0.09, 0.025);   // linear; the custom colour / this tints
uniform float tint_amount = 0.35;
uniform vec3 base_tint = vec3(0.8, 0.9, 0.7);

varying vec2 v_uv;
varying vec3 v_tint;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float sh = length(MODEL_MATRIX[1].xyz);
	float sw = sh * aspect;
	vec3 to_cam = CAMERA_POSITION_WORLD - origin;
	to_cam.y = 0.0;
	to_cam = length(to_cam) > 0.001 ? normalize(to_cam) : vec3(0.0, 0.0, 1.0);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	VERTEX = origin + right * (UV.x - 0.5) * sw * crop_w + vec3(0.0, 1.0, 0.0) * (1.0 - UV.y) * sh * crop_h;
	vec3 c = origin + vec3(0.0, crown * sh, 0.0);
	NORMAL = normalize(normalize(VERTEX - c) * 0.8 + to_cam * 0.5 + vec3(0.0, 0.3, 0.0));
	float r = INSTANCE_CUSTOM.a;
	float u = 0.5 + ((fract(r * 7.13) > 0.5 ? 1.0 - UV.x : UV.x) - 0.5) * crop_w;
	v_uv = vec2((u + (fract(r * 3.7) > 0.5 ? 1.0 : 0.0)) * 0.5, 1.0 - (1.0 - UV.y) * crop_h);
	vec3 rel = clamp(INSTANCE_CUSTOM.rgb / palette_mean, vec3(0.5), vec3(1.6));
	v_tint = base_tint * mix(vec3(1.0), rel, tint_amount);
}

void fragment() {
	vec4 t = texture(atlas, v_uv);
	ALBEDO = t.rgb * v_tint;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ROUGHNESS = 0.9;
}
