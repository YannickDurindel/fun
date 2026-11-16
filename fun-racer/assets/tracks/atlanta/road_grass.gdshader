shader_type spatial;
// Grass verges of the generated road (cad/track/road.py). UV = (s, lateral m).
render_mode cull_back, diffuse_burley;

uniform sampler2D mottle : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 grass_color : source_color = vec3(0.20, 0.36, 0.11);
uniform vec3 dry_color : source_color = vec3(0.33, 0.38, 0.16);
uniform float stripe_length = 12.0;  // mowing stripes along the track

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float fine = texture(mottle, world_xz * (1.0 / 2.3)).r;
	float coarse = texture(mottle, world_xz * (1.0 / 41.0) + vec2(0.13, 0.57)).r;
	vec3 col = mix(grass_color, dry_color, smoothstep(0.35, 0.75, coarse));
	col *= 0.7 + 0.6 * fine;
	float stripe = step(0.5, fract(UV.x / (2.0 * stripe_length)));
	col *= 0.92 + 0.12 * stripe;
	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
}
