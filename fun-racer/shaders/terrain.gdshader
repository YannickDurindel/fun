shader_type spatial;
// Cheap grass for the valley terrain (scripts/track/terrain.gd).
// UV.x = distance to the track centreline in metres (1000 = far hills), baked per vertex.
// Vertices further than `max_view` from the camera are pulled towards it onto a sphere of
// that radius: same silhouette on screen (fully fogged anyway), but never past the camera's
// far plane (default 4000 m), so the far hills are never clipped.
// World-space value noise for colour variation, mowed stripes parallel to the track,
// darker / drier tint on steep slopes, and a flat average tone in the distance (no shimmer).
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

void vertex() {
	// world_vertex_coords: VERTEX / NORMAL are in world space here.
	vec3 rel = VERTEX - CAMERA_POSITION_WORLD;
	float r = length(rel);
	if (r > max_view) {
		VERTEX = CAMERA_POSITION_WORLD + rel * (max_view / r);
	}
	v_world = VERTEX;
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

	vec3 col = mix(grass_a, grass_b, smoothstep(0.25, 0.75, big));
	col = mix(col, grass_dry, smoothstep(0.62, 0.9, vnoise(p / 120.0 + 17.0)) * 0.45);
	col *= 0.92 + 0.16 * mid * (1.0 - smoothstep(4.0, 12.0, px));
	col *= 0.94 + 0.12 * fine;

	// Steeper slopes: darker, denser vegetation; patches of woodland on the far hills.
	float slope = 1.0 - clamp(v_wnormal.y, 0.0, 1.0);
	col = mix(col, slope_color, smoothstep(0.05, 0.3, slope) * 0.7);
	// Woods: noise patches away from the circuit, denser on steep hillsides (the wooded
	// slopes north of the Mur valley).
	float woods = smoothstep(0.5 - slope * 1.5, 0.65 - slope * 1.5, vnoise(p / 260.0 + 5.0));
	woods *= smoothstep(150.0, 300.0, v_track);
	col = mix(col, forest_color, woods * 0.85);

	// Mowed stripes parallel to the track, close to it only.
	float sw = fract(v_track / stripe_width);
	float aa = max(fwidth(v_track / stripe_width), 1e-4);
	float band = smoothstep(0.5 - aa, 0.5 + aa, sw) * (1.0 - smoothstep(1.0 - aa, 1.0, sw));
	float near_track = 1.0 - smoothstep(stripe_reach - 15.0, stripe_reach, v_track);
	float stripe_fade = 1.0 - smoothstep(150.0, 400.0, dist);
	col *= 1.0 + (band - 0.5) * 2.0 * stripe_strength * near_track * stripe_fade;

	// Far away: settle to the average tone.
	col = mix(col, mix(grass_a, slope_color, 0.3), smoothstep(1500.0, 3500.0, dist) * 0.5);

	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
	METALLIC = 0.0;
}
