shader_type canvas_item;
// Readability overlay above the menu's 3D backdrop: a dark gradient on the left (where the
// menu text sits), a vignette, and an overall `dim` that sub-screens raise.

uniform vec3 tint : source_color = vec3(0.012, 0.016, 0.03);
uniform float dim : hint_range(0.0, 1.0) = 0.0;
uniform float left_strength : hint_range(0.0, 1.0) = 0.9;
uniform float left_width : hint_range(0.1, 1.0) = 0.6;
uniform float vignette : hint_range(0.0, 1.0) = 0.55;

void fragment() {
	float left = left_strength * (1.0 - smoothstep(0.0, left_width, UV.x));
	left *= left;
	vec2 q = (UV - 0.5) * vec2(1.15, 1.0);
	float vig = vignette * smoothstep(0.35, 0.85, length(q));
	float a = 1.0 - (1.0 - left) * (1.0 - vig);
	a = mix(a, 1.0, dim);
	COLOR = vec4(tint, a);
}
