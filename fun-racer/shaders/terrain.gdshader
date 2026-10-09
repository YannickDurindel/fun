shader_type spatial;
// Ground around a track (scripts/track/terrain.gd).
// UV.x = distance to the track centreline in metres (1000 = far hills), baked per vertex.
// Vertices further than `max_view` from the camera are pulled towards it onto a sphere of
// that radius: same silhouette on screen (fully fogged anyway), but never past the camera's
// far plane (default 4000 m), so the far hills are never clipped.
//
// Without land cover (has_landcover = false): cheap grass. World-space value noise for colour
// variation, mowed stripes parallel to the track, darker / drier tint on steep slopes, noise
// patches of woodland and a flat average tone in the distance (no shimmer).
//
// With land cover: lc_near / lc_far hold one class id per cell (see TrackEnvironment.CLASSES)
// and every class has two palette colours. The id textures are read with a hand-made
// bilinear blend of four cells at a noise-jittered position, at a mip that follows the pixel
// footprint, so class borders are soft, wobbly lines instead of 2.5 m squares. Forest gets a
// canopy mottle, farmland a patchwork of fields, paved ground a faint block pattern.
//
// flood: floodlight colour x energy added within flood_reach of the centreline (the terrain is
// outside the floodlights' light mask, see TrackEnvironment).
render_mode world_vertex_coords, blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 grass_a : source_color = vec3(0.20, 0.35, 0.12);
uniform vec3 grass_b : source_color = vec3(0.29, 0.42, 0.15);
uniform vec3 grass_dry : source_color = vec3(0.42, 0.44, 0.24);
uniform vec3 slope_color : source_color = vec3(0.16, 0.25, 0.10);
uniform vec3 forest_color : source_color = vec3(0.10, 0.18, 0.08);
uniform float stripe_width = 7.0;     // m, mowing bands parallel to the track
uniform float stripe_reach = 75.0;    // m from the centreline
uniform float stripe_strength = 0.10;
uniform float max_view = 3800.0;

uniform bool has_landcover = false;
uniform sampler2D lc_near : filter_nearest, repeat_disable;
uniform sampler2D lc_far : filter_nearest, repeat_disable;
uniform vec4 lc_near_rect = vec4(0.0, 0.0, 0.0, 0.0);   // x0, z0, 1 / step, coarsest mip
uniform vec2 lc_near_size = vec2(0.0);                  // cells; 0 = no texture
uniform vec4 lc_far_rect = vec4(0.0, 0.0, 0.0, 0.0);
uniform vec2 lc_far_size = vec2(0.0);
uniform vec3 pal_a[10] : source_color;
uniform vec3 pal_b[10] : source_color;
uniform vec3 flood = vec3(0.0);
uniform float flood_reach = 90.0;

varying vec3 v_world;
varying vec3 v_wnormal;
varying float v_track;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// One cell of a class texture: adds its palette colour and class masks with weight w.
// mixes: x = smooth a/b mix, y = per-field a/b mix (farmland).
// masks: x forest, y water, z paved, w grass.
void lc_tap(sampler2D tex, ivec2 cell, ivec2 size, int lod, float w, vec2 mixes,
		inout vec3 col, inout vec4 masks) {
	int id = clamp(int(texelFetch(tex, clamp(cell, ivec2(0), size - 1), lod).r * 255.0 + 0.5), 0, 9);
	col += w * mix(pal_a[id], pal_b[id], id == 5 ? mixes.y : mixes.x);
	masks += w * vec4(float(id == 1), float(id == 2), float(id == 4), float(id == 0));
}

// Blended palette colour and masks at world position p. px = pixel footprint in metres,
// jitter = offset in metres that makes the class borders wobble.
vec3 landcover(sampler2D tex, vec4 rect, vec2 size, vec2 p, float px, vec2 jitter, vec2 mixes,
		out vec4 masks) {
	float lod = clamp(floor(log2(max(px * rect.z * 0.7, 1.0))), 0.0, rect.w);
	ivec2 lsize = max(ivec2(size) >> int(lod), ivec2(1));
	vec2 g = (p + jitter - rect.xy) * rect.z * (vec2(lsize) / size) - 0.5;
	ivec2 c = ivec2(floor(g));
	vec2 f = smoothstep(0.0, 1.0, g - floor(g));
	vec3 col = vec3(0.0);
	masks = vec4(0.0);
	int l = int(lod);
	lc_tap(tex, c, lsize, l, (1.0 - f.x) * (1.0 - f.y), mixes, col, masks);
	lc_tap(tex, c + ivec2(1, 0), lsize, l, f.x * (1.0 - f.y), mixes, col, masks);
	lc_tap(tex, c + ivec2(0, 1), lsize, l, (1.0 - f.x) * f.y, mixes, col, masks);
	lc_tap(tex, c + ivec2(1, 1), lsize, l, f.x * f.y, mixes, col, masks);
	return col;
}

void vertex() {
	// world_vertex_coords: VERTEX / NORMAL are in world space here.
	// The colour is looked up at the real position, not the pulled-in one.
	v_world = VERTEX;
	vec3 rel = VERTEX - CAMERA_POSITION_WORLD;
	float r = length(rel);
	if (r > max_view) {
		VERTEX = CAMERA_POSITION_WORLD + rel * (max_view / r);
	}
	v_wnormal = normalize(NORMAL);
	v_track = UV.x;
}

void fragment() {
	vec2 p = v_world.xz;
	float dist = length(VERTEX);
	float px = max(length(dFdx(p)), length(dFdy(p)));

	float big = vnoise(p / 180.0) * 0.6 + vnoise(p / 55.0) * 0.4;
	float mid = vnoise(p / 9.0);
	float fine = vnoise(p / 1.3) * (1.0 - smoothstep(0.3, 1.0, px));
	float slope = 1.0 - clamp(v_wnormal.y, 0.0, 1.0);

	vec3 col;
	float stripes = 1.0;
	float rough = 0.95;
	float spec = 0.2;
	if (has_landcover) {
		// Fields: one a/b mix per ~70 m patch, with wobbly borders.
		vec2 fp = p / 70.0 + vec2(mid, vnoise(p / 11.0 + 3.7)) * 0.12;
		vec2 mixes = vec2(smoothstep(0.25, 0.75, big), hash(floor(fp)));
		// Border wobble: a couple of metres of fine noise near the camera (it would alias
		// further away), half a far cell of slow noise on the far grid.
		vec2 jitter = (vec2(mid, vnoise(p / 7.0 + 19.1)) * 2.0 - 1.0) * 2.5 * (1.0 - smoothstep(2.0, 6.0, px));
		vec2 gn = (p - lc_near_rect.xy) * lc_near_rect.z;
		vec4 masks;
		if (lc_near_size.x > 0.0 && gn.x > 1.0 && gn.y > 1.0 && gn.x < lc_near_size.x - 1.0 && gn.y < lc_near_size.y - 1.0) {
			col = landcover(lc_near, lc_near_rect, lc_near_size, p, px, jitter, mixes, masks);
		} else if (lc_far_size.x > 0.0) {
			vec2 slow = vec2(vnoise(p / 140.0 + 3.3), vnoise(p / 140.0 + 41.7)) * 2.0 - 1.0;
			col = landcover(lc_far, lc_far_rect, lc_far_size, p, px, slow * 0.5 / lc_far_rect.z, mixes, masks);
		} else {
			col = mix(pal_a[0], pal_b[0], mixes.x);
			masks = vec4(0.0, 0.0, 0.0, 1.0);
		}
		float soft = 1.0 - masks.z;   // paved ground has no vegetation mottle
		col *= 1.0 - soft * (0.08 - 0.16 * mid * (1.0 - smoothstep(4.0, 12.0, px)));
		col *= 0.94 + 0.12 * fine;
		// Forest canopy: crowns as a dark mottle, fading to the average with distance.
		float crowns = vnoise(p / 5.0) * 0.6 + vnoise(p / 2.2) * 0.4;
		col *= 1.0 - masks.x * (0.12 + 0.34 * (crowns - 0.5) * (1.0 - smoothstep(2.0, 9.0, px)));
		// Paved ground: plots and yards as a faint block pattern.
		col *= 1.0 + masks.z * (hash(floor(p / 16.0)) - 0.5) * 0.14 * (1.0 - smoothstep(6.0, 24.0, px));
		// Steep ground is darker (shaded gullies, denser growth); water is flat and glossy.
		col *= 1.0 - smoothstep(0.05, 0.3, slope) * 0.22 * (1.0 - masks.y);
		rough = mix(rough, 0.2, masks.y);
		spec = mix(spec, 0.6, masks.y);
		stripes = masks.w;
	} else {
		col = mix(grass_a, grass_b, smoothstep(0.25, 0.75, big));
		col = mix(col, grass_dry, smoothstep(0.62, 0.9, vnoise(p / 120.0 + 17.0)) * 0.45);
		col *= 0.92 + 0.16 * mid * (1.0 - smoothstep(4.0, 12.0, px));
		col *= 0.94 + 0.12 * fine;

		// Steeper slopes: darker, denser vegetation; patches of woodland on the far hills.
		col = mix(col, slope_color, smoothstep(0.05, 0.3, slope) * 0.7);
		// Woods: noise patches away from the circuit, denser on steep hillsides (the wooded
		// slopes north of the Mur valley).
		float woods = smoothstep(0.5 - slope * 1.5, 0.65 - slope * 1.5, vnoise(p / 260.0 + 5.0));
		woods *= smoothstep(150.0, 300.0, v_track);
		col = mix(col, forest_color, woods * 0.85);
	}

	// Mowed stripes parallel to the track, close to it only (on grass).
	float sw = fract(v_track / stripe_width);
	float aa = max(fwidth(v_track / stripe_width), 1e-4);
	float band = smoothstep(0.5 - aa, 0.5 + aa, sw) * (1.0 - smoothstep(1.0 - aa, 1.0, sw));
	float near_track = 1.0 - smoothstep(stripe_reach - 15.0, stripe_reach, v_track);
	float stripe_fade = 1.0 - smoothstep(150.0, 400.0, dist);
	col *= 1.0 + (band - 0.5) * 2.0 * stripe_strength * near_track * stripe_fade * stripes;

	if (!has_landcover) {
		// Far away: settle to the average tone.
		col = mix(col, mix(grass_a, slope_color, 0.3), smoothstep(1500.0, 3500.0, dist) * 0.5);
	}

	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = spec;
	METALLIC = 0.0;
	// Floodlights: light from above on the ground beside the track.
	EMISSION = col * flood * 0.85 * (1.0 - smoothstep(flood_reach * 0.45, flood_reach, v_track));
}
