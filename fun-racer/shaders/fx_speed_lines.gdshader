shader_type canvas_item;
// Subtle radial speed streaks at the screen edges. The centre stays clear (HUD / road).
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float line_count = 140.0;
uniform float max_alpha = 0.22;

float hash(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 p = (SCREEN_UV - 0.5) * vec2(res.x / res.y, 1.0);
	float r = length(p);
	float lanef = (atan(p.y, p.x) / 6.2831853 + 0.5) * line_count;
	float idx = floor(lanef);
	float h = hash(idx);
	float h2 = hash(idx + 31.7);
	float on = step(0.6, h);
	float t = fract(TIME * (0.9 + h2 * 1.2) + h * 7.0);
	float head = mix(0.45, 1.25, t);
	float len = 0.10 + 0.20 * h2;
	float streak = smoothstep(head - len, head, r) * (1.0 - smoothstep(head, head + 0.015, r));
	// Thin lines: constant-ish pixel width by narrowing with radius.
	float lane = abs(fract(lanef) - 0.5);
	float thin = 1.0 - smoothstep(0.02, 0.09 / max(r, 0.3), lane);
	float edge = smoothstep(0.5, 0.95, r);
	COLOR = vec4(1.0, 1.0, 1.0, streak * thin * edge * on * intensity * max_alpha);
}
