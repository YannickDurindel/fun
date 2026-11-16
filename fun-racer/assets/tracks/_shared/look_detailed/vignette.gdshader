shader_type canvas_item;
// Lens vignette of the "realistic" track look (TrackLook.SunFlare layer): the corners of the
// view darken a little, as through a camera lens. Multiplied over the 3D view.
render_mode blend_mul, unshaded;

uniform float strength = 0.22;
uniform float aspect = 1.7778;

void fragment() {
	vec2 d = (UV - 0.5) * vec2(aspect / 1.7778, 1.0) * 1.15;
	float v = 1.0 - strength * smoothstep(0.35, 0.85, length(d) * 1.2);
	COLOR = vec4(vec3(v), 1.0);
}
