shader_type spatial;
// Flag cloth on the grandstands (scripts/track/scenery_crowd.gd flag_mesh, surface 1): UV
// 0..1, u = 0 at the pole. Waves travel from the pole to the free end, which moves most.
// Designs: 0 vertical tricolour, 1 horizontal tricolour, 2 chequered (c1 / c2),
// 3 diagonal band (c2 on c1), 4 disc (c2 on c1), 5 Nordic cross (c2 on c1).
render_mode cull_disabled, diffuse_burley;

uniform float wind = 1.0;            // 0 freezes the cloth
uniform float length_m = 2.4;   // SceneryCrowd.FLAG_SIZE.x
instance uniform int design = 0;
instance uniform vec3 c1 : source_color = vec3(0.0, 0.33, 0.64);
instance uniform vec3 c2 : source_color = vec3(0.95);
instance uniform vec3 c3 : source_color = vec3(0.94, 0.25, 0.21);
instance uniform float phase = 0.0;

void vertex() {
	float x = UV.x;
	float t = TIME * wind;
	float k1 = 6.5, w1 = 5.5, k2 = 13.0, w2 = 9.0;
	float a1 = 0.16 * length_m, a2 = 0.04 * length_m;
	float s1 = sin(k1 * x - w1 * t + phase + UV.y * 0.8);
	float s2 = sin(k2 * x - w2 * t + phase * 1.7);
	float amp = x * (0.35 + 0.65 * wind);
	VERTEX.z += amp * (a1 * s1 + a2 * s2);
	VERTEX.x -= x * x * 0.05 * length_m * (1.0 - 0.5 * wind);
	VERTEX.y -= x * x * 0.12 * (1.2 - wind);
	// Slope of the cloth along x for the normal.
	float dz = (0.35 + 0.65 * wind) * (a1 * s1 + a2 * s2)
			+ amp * (a1 * k1 * cos(k1 * x - w1 * t + phase + UV.y * 0.8) + a2 * k2 * cos(k2 * x - w2 * t + phase * 1.7));
	NORMAL = normalize(vec3(-dz / length_m, 0.0, 1.0));
}

void fragment() {
	vec2 uv = UV;
	vec3 col = c1;
	if (design == 0) {
		col = uv.x < 0.3333 ? c1 : (uv.x < 0.6667 ? c2 : c3);
	} else if (design == 1) {
		col = uv.y < 0.3333 ? c1 : (uv.y < 0.6667 ? c2 : c3);
	} else if (design == 2) {
		vec2 cell = floor(uv * vec2(8.0, 5.0));
		col = mod(cell.x + cell.y, 2.0) < 0.5 ? c1 : c2;
	} else if (design == 3) {
		float d = abs(uv.x * 0.65 - (1.0 - uv.y) * 0.65 + 0.0);
		col = d < 0.12 ? c2 : c1;
	} else if (design == 4) {
		col = length((uv - 0.5) * vec2(1.55, 1.0)) < 0.3 ? c2 : c1;
	} else {
		bool cross = abs(uv.x - 0.36) < 0.08 || abs(uv.y - 0.5) < 0.1;
		col = cross ? c2 : c1;
	}
	// Folds catch the light a little differently on either face.
	ALBEDO = col;
	ROUGHNESS = 0.75;
	SPECULAR = 0.3;
	BACKLIGHT = col * 0.35;
}
