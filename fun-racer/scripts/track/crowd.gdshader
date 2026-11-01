shader_type spatial;
// Spectators on the grandstands (scripts/track/scenery_crowd.gd): MultiMesh instances of a
// blocky seated figure or a flat card. UV.x tags the part (0 legs, 1 torso, 2 head, 3 arm),
// UV.y the arm's side. INSTANCE_CUSTOM: rgb = shirt colour (linear), a = seed. Everyone sways
// and leans a little, out of step; now and then a few raise their arms and wave.
render_mode diffuse_burley;

uniform float motion = 1.0;   // 0 freezes everyone (tests, screenshots)

varying vec3 v_col;

float h1(float n) {
	return fract(sin(n * 91.3458) * 47453.5453);
}

mat2 rot(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(vec2(c, s), vec2(-s, c));
}

void vertex() {
	float seed = INSTANCE_CUSTOM.a;
	float part = UV.x;
	float side = UV.y;
	float t = TIME * motion;
	float ph = seed * 6.2831 * 7.0;
	vec3 v = VERTEX;
	// One in three sometimes cheers: arms up for a few seconds every half minute or so.
	float cycle = sin(t * (0.17 + 0.08 * h1(seed + 1.0)) + ph);
	float cheer = smoothstep(0.86, 0.96, cycle) * step(0.66, h1(seed + 2.0)) * motion;
	if (part > 2.5) {
		vec2 shoulder = vec2(side * 0.22, 0.95);
		float ang = side * cheer * (2.6 + 0.35 * sin(t * 7.0 + ph));
		v.xy = shoulder + rot(ang) * (v.xy - shoulder);
	}
	if (part > 0.5) {
		// Sway sideways and lean about the hips, more when cheering.
		float sway = 0.04 * sin(t * 0.8 + ph) + cheer * 0.06 * sin(t * 5.0 + ph);
		float lean = 0.05 * sin(t * 0.47 + ph * 1.7) - cheer * 0.08;
		v.xy = vec2(0.0, 0.42) + rot(sway) * (v.xy - vec2(0.0, 0.42));
		v.zy = vec2(0.0, 0.42) + rot(lean) * (v.zy - vec2(0.0, 0.42));
	}
	VERTEX = v;

	vec3 shirt = INSTANCE_CUSTOM.rgb;
	float r1 = h1(seed + 3.0);
	float r2 = h1(seed + 4.0);
	float r3 = h1(seed + 5.0);
	vec3 trousers = r1 < 0.45 ? vec3(0.03, 0.05, 0.10) : (r1 < 0.75 ? vec3(0.04, 0.04, 0.045) : vec3(0.30, 0.25, 0.17));
	vec3 skin = mix(vec3(0.62, 0.38, 0.25), vec3(0.10, 0.05, 0.03), r2 * r2);
	vec3 hair = r3 < 0.5 ? vec3(0.02, 0.015, 0.01) : (r3 < 0.7 ? vec3(0.20, 0.12, 0.05) : shirt * 0.8);   // the last: a cap
	vec3 col = trousers;
	if (part > 0.5) col = shirt;
	if (part > 1.5) col = (VERTEX.y > 1.19 || NORMAL.z > 0.5) ? hair : skin;
	if (part > 2.5) col = h1(seed + 6.0) < 0.5 ? skin : shirt;
	// A little variation in brightness, so neighbours in the same colour differ.
	v_col = col * (0.85 + 0.3 * h1(seed + 7.0));
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;
}
