shader_type spatial;
// Trackmania Stadium-style tarmac for the infinite ground.
//
// Everything is computed in a "pattern space" that equals world XZ modulo
// PATTERN_PERIOD (1024 m). The mesh follows the camera snapped to 32 m and
// `pattern_offset` = fposmod(mesh_origin.xz, 1024) is supplied by
// scripts/world/infinite_ground.gd. Pattern coordinates near the camera
// therefore stay below ~1100 m no matter how far the car drives, so
// fract()/hash()/fwidth() never lose precision (no jitter at 10+ km).
// Every pattern below is 1024-periodic so the wrap is invisible.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

const float PATTERN_PERIOD = 1024.0;

uniform vec2 pattern_offset = vec2(0.0);

group_uniforms colours;
uniform vec3 asphalt_color : source_color = vec3(0.34, 0.345, 0.35);
uniform vec3 asphalt_dark : source_color = vec3(0.25, 0.255, 0.26);
uniform vec3 asphalt_light : source_color = vec3(0.40, 0.405, 0.41);
uniform vec3 line_color : source_color = vec3(0.86, 0.87, 0.88);
uniform vec3 marking_color : source_color = vec3(0.92, 0.92, 0.90);
group_uniforms;

group_uniforms grid;
uniform float tile_size = 32.0;     // must divide PATTERN_PERIOD
uniform float sub_size = 8.0;       // must divide tile_size
uniform float major_width = 0.16;   // metres
uniform float minor_width = 0.06;   // metres
uniform float major_strength : hint_range(0.0, 1.0) = 0.75;
uniform float minor_strength : hint_range(0.0, 1.0) = 0.42;
uniform float grid_fade_start = 250.0;
uniform float grid_fade_end = 1400.0;
group_uniforms;

group_uniforms surface;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.82;
uniform float grain_strength : hint_range(0.0, 1.0) = 0.55;
group_uniforms;

varying vec2 v_p;

// ---------------------------------------------------------------- noise ----
float hash_u(uvec2 q) {
	uint h = q.x * 1597334677u ^ q.y * 3812015801u;
	h ^= h >> 16u;
	h *= 0x7feb352du;
	h ^= h >> 15u;
	h *= 0x846ca68bu;
	h ^= h >> 16u;
	return float(h) * (1.0 / 4294967295.0);
}

// Hash of an integer cell, wrapped to `period` cells.
float cell_hash(vec2 cell, float period) {
	vec2 c = mod(cell, period);
	return hash_u(uvec2(c));
}

// Value noise with cells of `cell` metres, periodic in PATTERN_PERIOD.
float vnoise(vec2 p, float cell) {
	float period = PATTERN_PERIOD / cell;
	vec2 q = p / cell;
	vec2 i = floor(q);
	vec2 f = q - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = cell_hash(i, period);
	float b = cell_hash(i + vec2(1.0, 0.0), period);
	float c = cell_hash(i + vec2(0.0, 1.0), period);
	float d = cell_hash(i + vec2(1.0, 1.0), period);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fades an octave of noise out once its cell gets smaller than ~2 pixels.
float octave_fade(float cell, float px) {
	return 1.0 - smoothstep(cell * 0.25, cell * 0.7, px);
}

// ----------------------------------------------------------------- grid ----
// Anti-aliased grid ("pristine grid", B. Golus). `uv` in grid cells,
// `width` in cell units. Converges to the average coverage when lines get
// thinner than a pixel, so there is no moire at grazing angles.
float grid(vec2 uv, float width) {
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	vec2 deriv = vec2(length(vec2(dx.x, dy.x)), length(vec2(dx.y, dy.y)));
	vec2 target = vec2(width);
	vec2 draw = clamp(target, deriv, vec2(0.5));
	vec2 aa = deriv * 1.5;
	vec2 g = 1.0 - abs(fract(uv) * 2.0 - 1.0);
	vec2 l = smoothstep(draw + aa, draw - aa, g);
	l *= clamp(target / draw, 0.0, 1.0);
	l = mix(l, target, clamp(deriv * 2.0 - 1.0, 0.0, 1.0));
	return mix(l.x, 1.0, l.y);
}

// Coverage of an axis-aligned box [lo, hi] with a soft, AA'd edge.
float box(vec2 p, vec2 lo, vec2 hi, float soft) {
	vec2 a = smoothstep(lo - soft, lo + soft, p) * (1.0 - smoothstep(hi - soft, hi + soft, p));
	return a.x * a.y;
}

void vertex() {
	// The mesh is never rotated or scaled, so local XZ = world XZ - origin.
	v_p = VERTEX.xz + pattern_offset;
}

void fragment() {
	vec2 p = v_p;
	float dist = length(VERTEX);
	// Size of a pixel in metres on the ground.
	float px = max(length(dFdx(p)), length(dFdy(p)));

	// --- base asphalt: large mottling + fine grain -------------------------
	float big = vnoise(p, 128.0) * 0.6 + vnoise(p, 32.0) * 0.4;
	float mid = vnoise(p, 4.0) * 0.6 + vnoise(p, 1.0) * 0.4;
	float grain = 0.0;
	float f1 = octave_fade(0.25, px);
	float f2 = octave_fade(0.0625, px);
	grain += (vnoise(p, 0.25) - 0.5) * f1;
	grain += (vnoise(p, 0.0625) - 0.5) * f2 * 1.3;

	vec3 col = mix(asphalt_dark, asphalt_light, smoothstep(0.15, 0.85, big));
	col = mix(col, asphalt_color, 0.45);
	col *= 1.0 + (mid - 0.5) * 0.06 * octave_fade(1.0, px);
	col *= 1.0 + grain * 0.45 * grain_strength;

	// --- per-tile tint (each 32 m "block" slightly different) --------------
	vec2 tile = floor(p / tile_size);
	float tile_period = PATTERN_PERIOD / tile_size;
	float th = cell_hash(tile, tile_period);
	col *= 0.965 + 0.07 * th;

	// --- occasional darker repair patches and markings ---------------------
	vec2 tp = p - tile * tile_size; // 0..tile_size inside the tile
	float th2 = cell_hash(tile + vec2(17.0, 31.0), tile_period);
	float th3 = cell_hash(tile + vec2(53.0, 7.0), tile_period);
	float soft = max(px, 0.05);
	if (th2 < 0.16) {
		// A patch aligned on the 8 m sub-grid, 1 to 3 sub-cells wide.
		vec2 cells = floor(vec2(th3, fract(th3 * 7.31)) * 3.0) + 1.0;
		vec2 lo = floor(vec2(fract(th3 * 3.7), fract(th3 * 11.3)) * (4.0 - cells)) * sub_size;
		vec2 hi = lo + cells * sub_size;
		float patch = box(tp, lo + 0.6, hi - 0.6, soft);
		col = mix(col, col * 0.72, patch * (0.75 + 0.25 * vnoise(p, 2.0)));
	} else if (th2 > 0.93) {
		// Dashed centre marking running along the tile (like a road block).
		bool along_x = th3 > 0.5;
		vec2 q = along_x ? tp : tp.yx;
		float dash = box(vec2(mod(q.x, 4.0), q.y), vec2(0.5, tile_size * 0.5 - 0.15),
				vec2(2.5, tile_size * 0.5 + 0.15), soft);
		col = mix(col, marking_color, dash * 0.8);
	} else if (th2 > 0.89) {
		// Chevron arrow pair, Trackmania style.
		vec2 c = tp - vec2(tile_size * 0.5);
		bool along_x = th3 > 0.5;
		vec2 q = along_x ? c : c.yx;
		float arrow = 0.0;
		for (int k = 0; k < 2; k++) {
			float ox = float(k) * 2.4 - 1.2;
			float d = abs(q.x - ox - (2.2 - abs(q.y) * 0.9));
			float inside = 1.0 - smoothstep(2.4 - soft, 2.4 + soft, abs(q.y));
			arrow = max(arrow, (1.0 - smoothstep(0.35 - soft, 0.35 + soft, d)) * inside);
		}
		col = mix(col, marking_color, arrow * 0.75);
	}

	// --- grid lines ---------------------------------------------------------
	float major = grid(p / tile_size, major_width / tile_size);
	float minor = grid(p / sub_size, minor_width / sub_size);
	float grid_fade = 1.0 - smoothstep(grid_fade_start, grid_fade_end, dist);
	float lines = max(major * major_strength, minor * minor_strength) * grid_fade;
	col = mix(col, line_color, lines);

	// Far away, blend everything to the average tone (no shimmer).
	float far_fade = smoothstep(600.0, 2200.0, dist);
	col = mix(col, asphalt_color * 0.98, far_fade);

	ALBEDO = col;
	ROUGHNESS = mix(roughness_base + grain * 0.15, 0.6, lines);
	SPECULAR = 0.35;
	METALLIC = 0.0;
}
