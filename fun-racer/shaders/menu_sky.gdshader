shader_type sky;
// Menu showroom sky: dark navy gradient with a faint horizon glow, plus soft "studio light"
// panels overhead that only show up as reflections on the car's clearcoat. Static, so the
// radiance map is baked once.

uniform vec3 top_color : source_color = vec3(0.012, 0.018, 0.04);
uniform vec3 horizon_color : source_color = vec3(0.05, 0.085, 0.17);
uniform vec3 ground_color : source_color = vec3(0.008, 0.01, 0.018);
uniform vec3 key_color : source_color = vec3(1.0, 0.97, 0.92);
uniform vec3 blue_color : source_color = vec3(0.16, 0.45, 1.0);
uniform vec3 red_color : source_color = vec3(0.93, 0.16, 0.16);
uniform float panel_energy = 5.0;

// Soft rectangle on the ceiling plane y = 1 (p = EYEDIR.xz / EYEDIR.y).
float panel(vec2 p, vec2 centre, vec2 half_size, float soft) {
	vec2 d = abs(p - centre) - half_size;
	return (1.0 - smoothstep(0.0, soft, d.x)) * (1.0 - smoothstep(0.0, soft, d.y));
}

void sky() {
	float y = EYEDIR.y;
	vec3 c = mix(horizon_color, top_color, smoothstep(0.0, 0.45, y));
	c = mix(c, ground_color, smoothstep(0.0, -0.12, y));
	if (y > 0.15) {
		vec2 p = EYEDIR.xz / y;
		float up = smoothstep(0.15, 0.3, y);
		c += key_color * panel_energy * up * panel(p, vec2(0.0, 0.0), vec2(0.35, 1.6), 0.25);
		c += blue_color * panel_energy * 0.6 * up * panel(p, vec2(-1.6, 0.0), vec2(0.18, 2.2), 0.3);
		c += red_color * panel_energy * 0.45 * up * panel(p, vec2(1.6, 0.0), vec2(0.18, 2.2), 0.3);
	}
	COLOR = c;
}
