shader_type spatial;
// Menu showroom floor: dark glossy disc, slightly see-through so the mirrored car underneath
// reads as a soft reflection. Fades to opaque (and to the horizon colour) away from the car.
render_mode blend_mix, cull_back, depth_draw_opaque, specular_schlick_ggx;

uniform vec3 floor_color : source_color = vec3(0.02, 0.024, 0.034);
uniform vec3 far_color : source_color = vec3(0.05, 0.085, 0.17);
uniform vec3 ring_color : source_color = vec3(0.16, 0.45, 1.0);
uniform float reflectivity : hint_range(0.0, 1.0) = 0.17;
uniform float ring_radius = 4.6;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float r = length(world_pos.xz);
	float far = smoothstep(9.0, 34.0, r);
	ALBEDO = floor_color * (1.0 - far);
	ROUGHNESS = 0.32;
	METALLIC = 0.0;
	SPECULAR = 0.5 * (1.0 - far);
	// Thin accent ring around the car and a faint outer one.
	float w = fwidth(r) * 1.5 + 0.012;
	float ring = 1.0 - smoothstep(0.0, w, abs(r - ring_radius));
	float ring2 = 1.0 - smoothstep(0.0, w, abs(r - ring_radius * 1.9));
	EMISSION = ring_color * (ring * 1.6 + ring2 * 0.35) + far_color * far;
	// Reflection is strongest near the car and gone a few metres out.
	ALPHA = 1.0 - reflectivity * (1.0 - smoothstep(2.5, 7.5, r));
}
