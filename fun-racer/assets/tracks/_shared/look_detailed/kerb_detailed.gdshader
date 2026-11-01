shader_type spatial;
// Kerbs of the "realistic" track look: the stripes of shaders/kerb.gdshader (same uniforms)
// painted on photo-scanned concrete (photo/concrete_albedo, CC0): the paint follows
// the concrete's grain and pores, is worn where tyres run (the inner edge) and gets a film of
// rubber and dust. UV.x = metres along the kerb, UV.y = metres across it.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 color_a : source_color = vec4(0.78, 0.07, 0.06, 1.0);
uniform vec4 color_b : source_color = vec4(0.93, 0.93, 0.91, 1.0);
uniform float stripe = 1.0;
uniform sampler2D concrete : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float tile_m = 1.1;

void fragment() {
	float t = 0.0;
	if (stripe > 0.0) {
		float x = UV.x / (2.0 * stripe);
		float w = max(fwidth(x), 1e-4);
		float f = fract(x);
		t = smoothstep(0.5 - w, 0.5 + w, f) * (1.0 - smoothstep(1.0 - w, 1.0, f));
	}
	vec2 uv = UV / tile_m;
	vec4 c = texture(concrete, uv);
	vec3 m = texture(macro, UV * vec2(1.0 / 40.0, 0.2)).rgb;
	float grain = c.r / 0.72;                          // the photo's mean is ~0.72
	vec3 paint = mix(color_a.rgb, color_b.rgb, t);
	// Rubber and dust: heavier towards the track side of the kerb (UV.y small), streaky.
	float rubber = (1.0 - smoothstep(0.0, 0.9, UV.y)) * smoothstep(0.35, 0.7, m.g) * 0.55;
	vec3 col = paint * mix(1.0, grain, 0.6);
	col = mix(col, vec3(0.07, 0.07, 0.075), rubber);
	col = mix(col, c.rgb * 0.8, smoothstep(0.62, 0.8, m.b) * 0.35);   // paint worn to concrete
	ALBEDO = col;
	ROUGHNESS = mix(0.55, c.a, 0.5) + rubber * 0.2;
	SPECULAR = 0.4;
}
