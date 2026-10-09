shader_type sky;
// Dusk and night sky of a track (scripts/track/track_environment.gd): a top-to-horizon
// gradient like the day sky's, stars, a city glow along the horizon, the sun / moon disc and
// a warm band around a low sun. Stars are left out of the radiance pass so the ambient light
// stays smooth.

uniform vec3 top_color : source_color = vec3(0.010, 0.016, 0.040);
uniform vec3 horizon_color : source_color = vec3(0.045, 0.055, 0.095);
uniform float curve = 0.12;
uniform float stars = 1.0;
uniform vec3 glow_color : source_color = vec3(0.90, 0.55, 0.25);
uniform float glow = 0.35;
uniform float sun_glow = 0.25;

float hash3(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	float h = clamp(EYEDIR.y, 0.0, 1.0);
	float c = 1.0 - acos(h) / (PI * 0.5);
	vec3 col = mix(horizon_color, top_color, clamp(1.0 - pow(1.0 - c, 1.0 / curve), 0.0, 1.0));
	// City glow: a band hugging the horizon.
	float band = pow(1.0 - abs(EYEDIR.y), 10.0);
	col += glow_color * glow * band * 0.35;
	if (LIGHT0_ENABLED) {
		float d = max(dot(EYEDIR, LIGHT0_DIRECTION), 0.0);
		// Warm scattering around a low sun, strongest near the horizon.
		col += LIGHT0_COLOR * sun_glow * (pow(d, 6.0) * 0.35 + pow(d, 60.0) * 0.5) * (0.25 + 0.75 * pow(1.0 - h, 3.0));
		if (!AT_CUBEMAP_PASS) {
			col += LIGHT0_COLOR * LIGHT0_ENERGY * smoothstep(0.99985, 0.99992, d) * 2.5;
		}
	}
	if (!AT_CUBEMAP_PASS && stars > 0.0 && EYEDIR.y > 0.0) {
		// One star at most per cell of a 3D lattice on the view sphere: a small round dot.
		vec3 q = EYEDIR * 120.0;
		vec3 cell = floor(q);
		float r = hash3(cell);
		vec3 centre = vec3(hash3(cell + 3.0), hash3(cell + 5.0), hash3(cell + 9.0)) * 0.6 + 0.2;
		float dot_size = 0.16 + 0.16 * hash3(cell + 7.0);
		float star = step(0.94, r) * (1.0 - smoothstep(dot_size * 0.4, dot_size, length(q - cell - centre)))
				* (0.35 + 0.65 * hash3(cell + 7.0));
		col += vec3(0.85, 0.9, 1.0) * star * stars * smoothstep(0.02, 0.25, EYEDIR.y) * 2.2;
	}
	COLOR = col;
}
