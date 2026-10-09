shader_type spatial;
// Building walls of scenery.glb (scripts/track/scenery.gd): materials "building_wall" and,
// with other parameters, "building_glass". No textures: rows of windows are drawn from the
// wall UV, which is in metres (u along the wall, v = height above the base, negative in the
// plinth). The vertex colour is the building's tint; it also seeds the building's bay width
// and which windows are lit, so neighbours differ. Vertex alpha is the "has windows" mask:
// 0 leaves a blank wall (sheds, gable ends).
//   detail = 0   (scenery setting "low"): flat tinted walls with the average window tone
//   night  > 0   a share `lit_fraction` of the windows glows in `window_light`
// The pattern fades to its average once a window is smaller than a pixel (no shimmer).
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float detail = 1.0;
uniform float night = 0.0;
uniform float lit_fraction = 0.35;
uniform vec3 window_light : source_color = vec3(1.0, 0.80, 0.52);
uniform float light_energy = 2.2;
uniform float floor_height = 3.2;     // m
uniform float bay_width = 2.9;        // m between window centres
uniform vec2 window_min = vec2(0.22, 0.30);   // window rectangle inside its bay x floor cell
uniform vec2 window_max = vec2(0.78, 0.80);
uniform vec3 glass_color : source_color = vec3(0.07, 0.09, 0.12);
uniform float wall_tint = 1.0;        // 1 = wall in the vertex colour, 0 = in frame_color
uniform float tint_gain = 0.70;       // keeps pale walls from burning out in full sun
uniform vec3 frame_color : source_color = vec3(0.16, 0.17, 0.19);
uniform float shopfront = 1.0;        // 1 = taller, wider openings on the ground floor

varying vec3 v_tint;
varying float v_seed;
varying float v_windows;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	v_tint = COLOR.rgb;
	v_seed = fract(dot(COLOR.rgb, vec3(12.9898, 78.233, 37.719)) * 43.7585);
	v_windows = COLOR.a;
}

void fragment() {
	vec3 wall = mix(frame_color, v_tint * tint_gain, wall_tint);
	// No windows on blank surfaces or below the ground line.
	float mask = step(0.5, v_windows) * step(0.0, UV.y);
	float win_area = (window_max.x - window_min.x) * (window_max.y - window_min.y) * mask;
	float lit_avg = lit_fraction * night;
	if (detail < 0.5) {
		ALBEDO = mix(wall, glass_color, win_area * 0.8);
		ROUGHNESS = 0.8;
		SPECULAR = 0.35;
		EMISSION = window_light * light_energy * lit_avg * win_area * 0.6;
	} else {
		float bay = bay_width * (0.85 + 0.35 * v_seed);
		vec2 cell = vec2(UV.x / bay, UV.y / floor_height);
		vec2 id = floor(cell);
		vec2 f = cell - id;
		vec2 aa = max(fwidth(cell), vec2(1e-4));
		vec2 lo = window_min;
		vec2 hi = window_max;
		if (id.y < 0.5 && shopfront > 0.5) {
			lo = vec2(0.08, 0.06);
			hi = vec2(0.92, 0.84);
		}
		vec2 in_lo = smoothstep(lo - aa, lo + aa, f);
		vec2 in_hi = 1.0 - smoothstep(hi - aa, hi + aa, f);
		float win = in_lo.x * in_hi.x * in_lo.y * in_hi.y * mask;
		// Too small to resolve: the average tone of wall and windows.
		float fade = 1.0 - smoothstep(0.3, 0.8, max(aa.x, aa.y));
		win = mix(win_area, win, fade);
		float r = hash(id + v_seed * 91.7);
		float r2 = hash(id * 1.7 + v_seed * 13.1 + 5.0);
		// Storey lines and a little dirt keep big plain walls from looking flat.
		wall *= 1.0 - 0.10 * (1.0 - smoothstep(0.0, 0.05 + aa.y, f.y)) * fade;
		wall *= 0.95 + 0.07 * r2;
		// A paler surround (frame, sill) just outside every window.
		vec2 pad = vec2(0.035, 0.05);
		vec2 fr_lo = smoothstep(lo - pad - aa, lo - pad + aa, f);
		vec2 fr_hi = 1.0 - smoothstep(hi + pad - aa, hi + pad + aa, f);
		float surround = fr_lo.x * fr_hi.x * fr_lo.y * fr_hi.y * fade * wall_tint * mask;
		wall = mix(wall, wall * 1.12 + 0.04, surround * 0.6);
		// Glass: dark, paler towards the top of the pane (the sky in it), some panes with
		// blinds or curtains.
		float up = clamp((f.y - lo.y) / max(hi.y - lo.y, 1e-3), 0.0, 1.0);
		vec3 glass = glass_color * (0.7 + 1.5 * up * up);
		glass = mix(glass, glass_color * 3.2 + 0.06, step(0.72, r2) * 0.6);
		ALBEDO = mix(wall, glass, win);
		ROUGHNESS = mix(0.85, 0.2, win);
		SPECULAR = mix(0.3, 0.6, win);
		float lit = mix(lit_avg, step(1.0 - lit_fraction, r) * night, fade);
		EMISSION = window_light * light_energy * (0.55 + 0.9 * r2) * lit * win;
	}
	METALLIC = 0.0;
}
