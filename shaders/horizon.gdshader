shader_type spatial;
// Distant low hills on the horizon. Applied to an open cylinder that stays
// centred on the camera (scripts/world/infinite_ground.gd), so the hills never
// get closer. Unshaded and fog-free: the colour is blended towards the horizon
// colour by hand so the base melts into the fogged ground.
render_mode unshaded, fog_disabled, cull_disabled, shadows_disabled, depth_draw_opaque;

uniform vec3 hill_color : source_color = vec3(0.50, 0.60, 0.70);
uniform vec3 horizon_color : source_color = vec3(0.72, 0.80, 0.88);
uniform float haze : hint_range(0.0, 1.0) = 0.55;
uniform float max_height = 160.0; // metres (tallest hill)

varying float v_t; // 0 at base, 1 at the silhouette top

float hash1(float n) {
	return fract(sin(n) * 43758.5453);
}

// 1D periodic value noise over the angle.
float anoise(float a, float freq) {
	float x = a * freq;
	float i = floor(x);
	float f = x - i;
	float u = f * f * (3.0 - 2.0 * f);
	return mix(hash1(mod(i, freq)), hash1(mod(i + 1.0, freq)), u);
}

void vertex() {
	float ang = atan(VERTEX.z, VERTEX.x) / 6.2831853 + 0.5; // 0..1
	float h = anoise(ang, 7.0) * 0.55 + anoise(ang, 23.0) * 0.30 + anoise(ang, 61.0) * 0.15;
	h = pow(h, 1.6);
	// CylinderMesh spans y in [-0.5, 0.5]; push the top ring to the hill height.
	float top = step(0.0, VERTEX.y);
	VERTEX.y = mix(-30.0, (0.06 + h * 0.94) * max_height, top);
	v_t = top;
}

void fragment() {
	// Hills are hazier at their base, which sits right on the fogged horizon.
	float k = mix(1.0, haze, pow(v_t, 0.6));
	ALBEDO = mix(hill_color, horizon_color, k);
}
