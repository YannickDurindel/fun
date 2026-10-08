shader_type spatial;
// Billboarded tyre-smoke puff for a MultiMesh. Per-instance COLOR (rgb tint, a = opacity),
// INSTANCE_CUSTOM.x = rotation (radians), .y = random seed. Instance scale = puff size.
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

varying float v_rot;
varying float v_seed;

void vertex() {
	float s = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * s,
		INV_VIEW_MATRIX[1] * s,
		INV_VIEW_MATRIX[2] * s,
		MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_rot = INSTANCE_CUSTOM.x;
	v_seed = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec2 p = UV - 0.5;
	float c = cos(v_rot);
	float sn = sin(v_rot);
	p = vec2(c * p.x - sn * p.y, sn * p.x + c * p.y);
	float r = length(p) * 2.0;
	float ang = atan(p.y, p.x);
	// Lumpy cloud outline.
	float lobes = 0.9 + 0.05 * sin(ang * 3.0 + v_seed * 6.28) + 0.04 * sin(ang * 2.0 - v_seed * 11.0);
	float a = 1.0 - smoothstep(0.0, lobes, r);
	a = a * a * (3.0 - 2.0 * a);
	// Slightly darker core, lighter rim.
	ALBEDO = COLOR.rgb * mix(0.9, 1.05, r);
	ALPHA = clamp(a * COLOR.a, 0.0, 1.0);
}
