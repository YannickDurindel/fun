shader_type spatial;
// Skid-mark ribbon: dark, slightly glossy rubber with soft edges and faint tread grooves.
// UV.x = across the tyre (0..1), UV.y = metres along the strip, UV2.x = segment serial,
// COLOR.a = opacity from slip.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 rubber_color : source_color = vec3(0.012, 0.012, 0.014);
uniform float max_alpha = 0.92;
uniform float head_serial = 0.0;
uniform float fade_start = 1e9;
uniform float fade_end = 2e9;
// Pull vertices towards the camera by this fraction of view depth (cheap depth bias).
uniform float depth_pull = 0.0006;

varying float v_age_fade;

float hash(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

void vertex() {
	float age = head_serial - UV2.x;
	v_age_fade = 1.0 - smoothstep(fade_start, fade_end, age);
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.xyz *= (1.0 - depth_pull);
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	float u = UV.x;
	float edge = smoothstep(0.0, 0.14, u) * smoothstep(1.0, 0.86, u);
	// Longitudinal tread grooves + slow blotchy variation along the strip.
	float groove = mix(0.82, 1.0, hash(floor(u * 9.0)));
	float blotch = mix(0.88, 1.0, hash(floor(UV.y * 1.7) + floor(u * 3.0) * 13.0));
	ALBEDO = rubber_color;
	ROUGHNESS = 0.38;
	SPECULAR = 0.45;
	METALLIC = 0.0;
	ALPHA = clamp(COLOR.a * edge * groove * blotch * v_age_fade * max_alpha, 0.0, 1.0);
}
