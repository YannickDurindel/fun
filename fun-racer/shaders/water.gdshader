shader_type spatial;
// Water bodies of a track (scripts/track/scenery.gd, polygons of scenery.json). Opaque and
// cheap: a few travelling sine ripples tilt the normal, the sky reflection and the sun
// glint come from the ordinary specular lighting, the colour deepens when looked at from
// above. Ripples fade out in the distance so the surface does not shimmer.
render_mode world_vertex_coords, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 color : source_color = vec3(0.10, 0.26, 0.32);
uniform vec3 deep_color : source_color = vec3(0.03, 0.10, 0.16);
uniform float ripple = 1.0;

varying vec3 v_world;

void vertex() {
	v_world = VERTEX;
}

void fragment() {
	vec2 p = v_world.xz;
	float px = max(length(dFdx(p)), length(dFdy(p)));
	float t = TIME;
	// Four ripple trains: (direction, wavelength in m, speed).
	vec2 slope = vec2(0.0);
	vec2 d0 = vec2(0.80, 0.60);
	vec2 d1 = vec2(-0.35, 0.94);
	vec2 d2 = vec2(0.97, -0.26);
	vec2 d3 = vec2(-0.71, -0.71);
	slope += d0 * cos(dot(p, d0) * 0.85 + t * 1.1) * 0.050;
	slope += d1 * cos(dot(p, d1) * 1.70 + t * 1.7) * 0.040;
	slope += d2 * cos(dot(p, d2) * 3.90 - t * 2.3) * 0.030 * (1.0 - smoothstep(0.3, 1.2, px));
	slope += d3 * cos(dot(p, d3) * 0.21 + t * 0.5) * 0.030;
	slope *= ripple * (1.0 - smoothstep(1.5, 9.0, px));
	vec3 n_world = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	vec3 to_eye = normalize(CAMERA_POSITION_WORLD - v_world);
	float facing = clamp(to_eye.y, 0.0, 1.0);
	// Long swells as slow patches of lighter water.
	float swell = 0.5 + 0.5 * sin(dot(p, d3) * 0.035 + t * 0.2) * sin(dot(p, d1) * 0.027 - t * 0.13);
	ALBEDO = mix(color, deep_color, facing * 0.8) * (0.9 + 0.2 * swell);
	ROUGHNESS = 0.07;
	SPECULAR = 0.75;
	METALLIC = 0.0;
}
