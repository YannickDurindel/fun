shader_type spatial;
// Billboard trees of the realistic track look (TrackDressing): a quad (UV 0..1, base at UV.y =
// 1) turned about the vertical axis to face the camera, textured with an impostor rendered
// from a CC0 tree model (cad/track/bake_impostors.gd: two views side by side). Per instance:
// COLOR = tint, INSTANCE_CUSTOM.x = which view (0 / 1), .y = mirror (0 / 1). The normal is
// that of a sphere round the crown, so the sun shades the card as a volume, not a plane.
// No shadow receiving: sampling the sun shadow map on every leaf pixel cost several ms in
// the forests on the HD 520; the sphere normal already shades the crown.
render_mode world_vertex_coords, cull_disabled, depth_draw_opaque, diffuse_lambert_wrap, specular_disabled, shadows_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float crown = 0.62;
uniform float crop_w = 1.0;   // share of the impostor square the tree covers (trees.json)
uniform float crop_h = 1.0;          // crown centre, share of the height

varying vec2 v_uv;
varying vec3 v_tint;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float sw = length(MODEL_MATRIX[0].xyz);
	float sh = length(MODEL_MATRIX[1].xyz);
	vec3 to_cam = CAMERA_POSITION_WORLD - origin;
	to_cam.y = 0.0;
	to_cam = length(to_cam) > 0.001 ? normalize(to_cam) : vec3(0.0, 0.0, 1.0);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	float x = UV.x - 0.5;
	float y = 1.0 - UV.y;
	VERTEX = origin + right * x * sw * crop_w + vec3(0.0, 1.0, 0.0) * y * sh * crop_h;
	vec3 c = origin + vec3(0.0, crown * sh, 0.0);
	NORMAL = normalize(normalize(VERTEX - c) * 0.8 + to_cam * 0.5 + vec3(0.0, 0.3, 0.0));
	float u = 0.5 + ((INSTANCE_CUSTOM.y > 0.5 ? 1.0 - UV.x : UV.x) - 0.5) * crop_w;
	v_uv = vec2((u + (INSTANCE_CUSTOM.x > 0.5 ? 1.0 : 0.0)) * 0.5, 1.0 - (1.0 - UV.y) * crop_h);
	v_tint = COLOR.rgb;
}

void fragment() {
	vec4 t = texture(atlas, v_uv);
	ALBEDO = t.rgb * v_tint;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ROUGHNESS = 0.9;
}
