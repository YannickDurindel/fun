shader_type spatial;
// Red/white (or single-colour) kerb stripes. UV.x = metres along the kerb, UV.y = metres
// across it. Stripes are `stripe` metres long; stripe <= 0 gives a plain color_a kerb.

uniform vec4 color_a : source_color = vec4(0.78, 0.07, 0.06, 1.0);
uniform vec4 color_b : source_color = vec4(0.93, 0.93, 0.91, 1.0);
uniform float stripe = 1.0;

void fragment() {
	float t = 0.0;
	if (stripe > 0.0) {
		float x = UV.x / (2.0 * stripe);
		float w = max(fwidth(x), 1e-4);
		// Antialiased square wave: colour B on the second half of every period.
		float f = fract(x);
		t = smoothstep(0.5 - w, 0.5 + w, f) * (1.0 - smoothstep(1.0 - w, 1.0, f));
	}
	ALBEDO = mix(color_a.rgb, color_b.rgb, t);
	ROUGHNESS = 0.65;
	SPECULAR = 0.35;
}
