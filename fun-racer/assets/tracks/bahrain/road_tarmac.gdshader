shader_type spatial;
// Bahrain International Circuit tarmac (generated road, cad/track/road.py).
// UV  = (s along the lap in m, lateral m, + = right)
// UV2 = (racing-line lateral offset m, road half width m)
// Texture tiling uses world-space XZ; painted markings use UV/UV2 (no decal meshes).
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D aggregate : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tarmac_color : source_color = vec3(0.23, 0.23, 0.24);
uniform vec3 paint_color : source_color = vec3(0.86, 0.86, 0.84);
uniform float rubber_strength = 0.28;
uniform float track_length = 5412.000;
uniform float start_s = 5164.366;
uniform float pole_offset = 8.0;   // pole slot is this far behind the start line (race_setup.gd)
uniform float grid_spacing = 8.0;  // staggered slots, 2 per 16 m row
uniform float grid_lateral = 2.5;  // pole on the left (-), P2 on the right (+)
uniform int grid_slots = 20;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

// 1 inside [a, b], 0 outside, antialiased over w.
float band(float x, float a, float b, float w) {
	return smoothstep(a - w, a + w, x) * (1.0 - smoothstep(b - w, b + w, x));
}

void fragment() {
	float s = UV.x;
	float lat = UV.y;
	float rl = UV2.x;
	float hw = UV2.y;
	vec2 aa = max(fwidth(UV), vec2(0.01)) * 0.75;

	float fine = texture(aggregate, world_xz * (1.0 / 3.1)).r;
	float coarse = texture(aggregate, world_xz * (1.0 / 23.0) + vec2(0.37, 0.71)).r;
	vec3 col = tarmac_color * (0.55 + 0.9 * fine) * (0.8 + 0.4 * coarse);

	// Rubbered-in racing line (darker, slightly smoother).
	float rub = 1.0 - smoothstep(0.5, 1.7, abs(lat - rl));
	col *= 1.0 - rubber_strength * rub * (0.7 + 0.6 * coarse);

	float paint = 0.0;
	// White edge lines (track limits), 0.2 m wide, 5 cm in from the edge.
	float edge = hw - abs(lat);
	paint = max(paint, band(edge, 0.05, 0.25, aa.y));

	// Finish line at s = 0: 1.2 m chequered band (0.4 m squares).
	float sf = s > track_length * 0.5 ? s - track_length : s;
	if (abs(sf) < 1.0) {
		float on = band(sf, -0.6, 0.6, aa.x);
		float chk = mod(floor(sf / 0.4) + floor(lat / 0.4), 2.0);
		paint = max(paint, on * chk);
		col = mix(col, vec3(0.03), on * (1.0 - chk));
	}
	// Start line: 0.3 m white line across the road.
	paint = max(paint, band(s, start_s - 0.15, start_s + 0.15, aa.x));

	// Grid boxes: slot k at start_s - pole_offset - k * grid_spacing, alternating sides.
	// Distance behind the start line, wrapped so slots behind s = 0 are drawn too.
	float back = start_s - s;
	if (back < -0.5 * track_length) {
		back += track_length;
	}
	float g = back - pole_offset + 3.5;
	float k = floor(g / grid_spacing);
	if (k >= 0.0 && k < float(grid_slots) && abs(sf) > 1.0) {
		float slot_s = start_s - pole_offset - k * grid_spacing;
		float lat_k = mod(k, 2.0) < 0.5 ? -grid_lateral : grid_lateral;
		float local = (start_s - back) - slot_s;
		float dl = abs(lat - lat_k);
		float front = band(local, 2.8, 3.0, aa.x) * band(dl, -1.0, 1.3, aa.y);
		float legs = band(local, 1.4, 3.0, aa.x) * band(dl, 1.1, 1.3, aa.y);
		paint = max(paint, max(front, legs));
	}

	paint *= 0.85 + 0.15 * fine;
	ALBEDO = mix(col, paint_color, paint);
	ROUGHNESS = mix(0.88 - 0.12 * rub, 0.6, paint);
	SPECULAR = 0.35;
}
