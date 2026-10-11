shader_type spatial;
// Tarmac of the opt-in "detailed" look (environment.json "look": "detailed"; TrackLook swaps it
// in for the track's own road_tarmac.gdshader at load time, copying the lap uniforms).
// UV  = (s along the lap in m, lateral m, + = right)
// UV2 = (racing-line lateral offset m, road half width m)
// Close up: aggregate albedo / roughness / normal (asphalt_detail, 1.6 m and 4.3 m tiles).
// Far: colour drift (asphalt_macro, world XZ), resurfaced sections and joins (lap_map B),
// saw-cut repair patches (hashed per 47 m cell), a dusty strip along the edges.
// On the lap: rubbered racing line, tyre marks in braking zones (lap_map R), worn paint.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D detail : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_far : hint_default_white, filter_linear_mipmap, repeat_enable;   // the same image
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro : hint_default_white, filter_linear_mipmap, repeat_enable;
// One texel per lap_map_px metres of s: R braking-zone tyre marks 0..1, G corner scrub 0..1,
// B resurfacing tone 0..1 (constant per section; a change of B is a transverse join).
uniform sampler2D lap_map : hint_default_black, filter_linear, repeat_enable;
uniform sampler2D lap_map_exact : hint_default_black, filter_nearest, repeat_enable;  // the same image
uniform vec3 tarmac_color : source_color = vec3(0.23, 0.23, 0.24);
uniform vec3 paint_color : source_color = vec3(0.86, 0.86, 0.84);
uniform float rubber_strength = 0.28;
uniform float track_length = 13626.000;
uniform float start_s = 144.042;
uniform float pole_offset = 8.0;
uniform float grid_spacing = 8.0;
uniform float grid_lateral = 2.5;
uniform int grid_slots = 20;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;   // 0 dry .. 1 standing water (not used yet)
uniform float normal_strength = 0.8;
uniform float agg_contrast = 0.45;   // aggregate albedo contrast (1 = the texture's)
uniform float patch_seed = 0.0;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

float band(float x, float a, float b, float w) {
	return smoothstep(a - w, a + w, x) * (1.0 - smoothstep(b - w, b + w, x));
}

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void fragment() {
	float s = UV.x;
	float lat = UV.y;
	float rl = UV2.x;
	float hw = UV2.y;
	vec2 aa = max(fwidth(UV), vec2(0.004)) * 0.75;
	float dist = length(VERTEX);
	float near = 1.0 - smoothstep(12.0, 45.0, dist);

	// --- aggregate: the 1.6 m tile up close only (branch: the GPU skips it for distant
	// pixels), the 4.3 m tile everywhere so the near tile does not repeat visibly.
	vec2 uv1 = world_xz * 0.625;
	vec2 uv1_dx = dFdx(uv1);
	vec2 uv1_dy = dFdy(uv1);
	vec4 d1 = vec4(0.25, 0.86, 0.8, 0.5);              // the tile's mean
	vec2 n1 = vec2(0.0);
	if (near > 0.0) {
		d1 = textureGrad(detail, uv1, uv1_dx, uv1_dy);
		n1 = textureGrad(detail_normal, uv1, uv1_dx, uv1_dy).xy * 2.0 - 1.0;
	}
	vec4 d2 = texture(detail_far, world_xz * 0.231 + vec2(0.31, 0.67));
	vec3 mac = texture(macro, world_xz * (1.0 / 160.0)).rgb;
	vec3 lm = texture(lap_map, vec2(s / track_length, 0.5)).rgb;
	float agg = 1.0 + (mix(d1.r, d2.r, 0.3) / 0.25 - 1.0) * agg_contrast;   // ~1 on average
	float cav = mix(d1.b, d2.b, 0.3);

	// --- surface condition along the lap
	float tone = texture(lap_map_exact, vec2(s / track_length, 0.5)).b;   // per resurfaced section
	float drift = (mac.r - 0.5) * 2.0;                 // large blotches, -1..1
	float mottle = (mac.b - 0.5) * 2.0;
	vec3 base = tarmac_color * (0.84 + 0.16 * tone + 0.07 * drift + 0.04 * mottle);
	base = mix(base, base * vec3(1.05, 1.0, 0.93), smoothstep(0.55, 1.0, tone) * 0.6);  // older, browner

	// Repair patches: saw-cut rectangles, one cell in three carries one.
	float cell_len = 47.0;
	float cell = floor(s / cell_len);
	float h0 = hash11(cell + patch_seed * 17.0);
	float patch = 0.0;
	float seam = 0.0;
	if (h0 < 0.33) {
		float h1 = hash11(cell * 1.7 + 3.1);
		float h2 = hash11(cell * 2.3 + 7.7);
		float h3 = hash11(cell * 3.9 + 1.3);
		float p0 = cell * cell_len + h1 * 20.0;
		float p1 = p0 + 4.0 + h2 * 18.0;
		float l0;
		float l1;
		if (h3 < 0.35) {          // a full-width strip (trench across the road)
			l0 = -hw - 1.0; l1 = hw + 1.0; p1 = p0 + 1.2 + h2 * 2.5;
		} else if (h3 < 0.7) {    // one half
			l0 = h3 < 0.52 ? -hw + 0.3 : 0.1; l1 = h3 < 0.52 ? -0.1 : hw - 0.3;
		} else {                   // a 2.5-4 m wide square-ish patch
			float c = (h1 - 0.5) * hw;
			float w = 1.2 + h2;
			l0 = c - w; l1 = c + w;
		}
		patch = band(s, p0, p1, aa.x) * band(lat, l0, l1, aa.y);
		float edge_s = min(abs(s - p0), abs(s - p1));
		float edge_l = min(abs(lat - l0), abs(lat - l1));
		bool inside = s > p0 - 0.05 && s < p1 + 0.05 && lat > l0 - 0.05 && lat < l1 + 0.05;
		if (inside) {
			seam = max(1.0 - smoothstep(0.015, 0.05, edge_s), 1.0 - smoothstep(0.015, 0.05, edge_l));
		}
		float fresh = hash11(cell * 5.1 + 2.2);
		base = mix(base, base * (fresh < 0.5 ? 0.72 : 1.12), patch);
	}
	// Transverse joins where the resurfacing tone changes, and a lane joint along the centre.
	if (near > 0.0) {
		float tone_prev = textureLod(lap_map_exact, vec2((s - 0.04) / track_length, 0.5), 0.0).b;
		float tone_next = textureLod(lap_map_exact, vec2((s + 0.04) / track_length, 0.5), 0.0).b;
		seam = max(seam, step(0.02, abs(tone_next - tone_prev)) * near);
	}
	seam = max(seam, (1.0 - smoothstep(0.012, 0.04, abs(lat - 0.0))) * smoothstep(0.45, 0.6, mac.g) * near);

	// Dust and loose grit along the edges, where cars do not run.
	float edge_dust = smoothstep(hw - 1.6, hw - 0.1, abs(lat)) * (0.6 + 0.4 * mac.b);

	// --- racing line: rubber laid down, wavy edges, wider where cars scrub through corners
	float wob = (mac.g - 0.5) * 0.9;
	float rl_w = 1.5 + 0.9 * lm.g;
	float rub = 1.0 - smoothstep(rl_w * 0.45, rl_w * 1.25, abs(lat - rl + wob));
	rub *= 0.85 + 0.3 * mac.b;
	// Tyre marks in braking zones: two wheel tracks either side of the line, streaky.
	vec2 suv = vec2(s / 70.0, lat / 2.2);
	vec2 suv_dx = dFdx(suv);
	vec2 suv_dy = dFdy(suv);
	float streak = 0.0;
	if (lm.r > 0.004) {
		streak = smoothstep(0.42, 0.7, textureGrad(macro, suv, suv_dx, suv_dy).g);
	}
	float wheels = max(1.0 - smoothstep(0.15, 0.6, abs(abs(lat - rl + wob * 0.5) - 0.82)), 0.4 * rub);
	float marks = lm.r * wheels * (0.35 + 0.65 * streak);

	vec3 col = base * mix(1.0, agg, mix(1.0, 0.55, rub)) ;
	col *= 1.0 - rubber_strength * mix(1.25, 0.9, 1.0 - near) * rub;
	col *= 1.0 - 0.7 * clamp(marks * 1.3, 0.0, 1.0);
	col = mix(col, col * vec3(1.25, 1.22, 1.15) + vec3(0.02), edge_dust * (1.0 - rub) * 0.55);
	col *= 1.0 - 0.45 * seam;
	col *= mix(1.0, 0.88 + 0.12 * cav, near);

	// --- painted lines (as the track shader: edges, finish, start, grid), worn
	float paint = 0.0;
	float edge = hw - abs(lat);
	paint = max(paint, band(edge, 0.05, 0.25, aa.y));
	float sf = s > track_length * 0.5 ? s - track_length : s;
	if (abs(sf) < 1.0) {
		float on = band(sf, -0.6, 0.6, aa.x);
		float chk = mod(floor(sf / 0.4) + floor(lat / 0.4), 2.0);
		paint = max(paint, on * chk);
		col = mix(col, vec3(0.03), on * (1.0 - chk));
	}
	paint = max(paint, band(s, start_s - 0.15, start_s + 0.15, aa.x));
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
	// Wear: the pores of the aggregate show through, worn blotches, more where cars cross.
	float wear = smoothstep(0.30, 0.62, mac.b + 0.25 * (d1.a - 0.5)) * 0.5 + 0.5 * rub + 0.4 * marks;
	paint *= mix(1.0, smoothstep(0.35, 0.8, cav), near * 0.8);
	paint *= 1.0 - 0.55 * clamp(wear, 0.0, 1.0);
	vec3 pcol = paint_color * (0.9 + 0.1 * d1.r / 0.25) * (1.0 - 0.18 * edge_dust);

	ALBEDO = mix(col, pcol, paint);

	// --- roughness and normal
	float rough = mix(0.9, mix(d1.g, d2.g, 0.3), near * 0.8 + 0.2);
	rough = mix(rough, 0.68, rub * 0.7);                   // rubber polishes the line
	rough = mix(rough, 0.72, seam);                        // bitumen sealant, a little glossier
	rough = mix(rough, 0.97, edge_dust * 0.6);
	rough = mix(rough, 0.55, paint);
	rough = mix(rough, 0.12, wetness);
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	SPECULAR = 0.42;
	ALBEDO *= 1.0 - 0.45 * wetness;

	vec2 nt = n1 * normal_strength * near * (1.0 - 0.6 * rub) * (1.0 - paint * 0.7) * (1.0 - wetness);
	// Detail is mapped on world XZ: tangent = +X, map "up" = -Z (see cad/track/look_textures.py).
	vec3 n_w = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 t_w = normalize(vec3(1.0, 0.0, 0.0) - n_w * n_w.x);
	vec3 b_w = normalize(cross(n_w, t_w));                 // = -Z on a flat road
	vec3 pn = normalize(n_w + t_w * nt.x + b_w * nt.y);
	NORMAL = normalize((VIEW_MATRIX * vec4(pn, 0.0)).xyz);
}
