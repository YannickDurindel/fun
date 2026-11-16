shader_type canvas_item;
// Sun flare of the "realistic" track look (TrackLook.SunFlare): a soft glow and starburst
// around the sun's screen position and a few faint ghosts along the line through the screen
// centre, added on top of the 3D view. `strength` fades it out when the sun is behind
// something or off screen.
render_mode blend_add, unshaded;

uniform vec2 sun_uv = vec2(0.5, 0.2);     // sun position, 0..1 across the screen
uniform float aspect = 1.7778;            // width / height
uniform float strength = 0.0;
uniform vec3 tint : source_color = vec3(1.0, 0.92, 0.8);

float disc(vec2 p, vec2 c, float r, float soft) {
	return 1.0 - smoothstep(r - soft, r + soft, length((p - c) * vec2(aspect, 1.0)));
}

void fragment() {
	vec2 p = UV;
	vec2 d = (p - sun_uv) * vec2(aspect, 1.0);
	float r = length(d);
	float glow = exp(-r * 9.0) * 0.55 + exp(-r * 30.0) * 0.6;
	float ang = atan(d.y, d.x);
	float rays = pow(abs(cos(ang * 6.0 + 0.3)), 24.0) * exp(-r * 14.0) * 0.35;
	vec2 axis = vec2(0.5) - sun_uv;
	float ghosts = 0.0;
	ghosts += disc(p, sun_uv + axis * 0.7, 0.035, 0.012) * 0.06;
	ghosts += disc(p, sun_uv + axis * 1.25, 0.06, 0.03) * 0.045;
	ghosts += disc(p, sun_uv + axis * 1.6, 0.02, 0.008) * 0.08;
	vec3 ghost_col = vec3(0.55, 0.75, 1.0);
	vec3 col = tint * (glow + rays) + ghost_col * ghosts;
	COLOR = vec4(col * strength, 1.0);
}
