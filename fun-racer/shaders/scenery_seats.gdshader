shader_type spatial;
// Grandstand seating of scenery.glb (material "stand_seats", scripts/track/scenery.gd).
// UV is in metres: u along the row, v the depth from the front of the stand (rows are
// `row_depth` deep). Blocks of seats take one of three colours, and a speckle of spectators
// sits on them (`crowd` = share of seats taken). A seat is one cell along the row and one
// step in height, so risers and sloping faces get rows too. The speckle fades to its average
// once seats are smaller than a pixel.
render_mode cull_disabled, diffuse_burley;

uniform vec3 seat_a : source_color = vec3(0.10, 0.25, 0.60);
uniform vec3 seat_b : source_color = vec3(0.75, 0.10, 0.10);
uniform vec3 seat_c : source_color = vec3(0.80, 0.80, 0.82);
uniform float crowd = 0.6;
uniform float detail = 1.0;
uniform float row_depth = 0.85;   // m
uniform float seat_width = 0.5;   // m

varying float v_stand;
varying float v_height;

float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	// One number per stand (roughly): stands differ in their block colours.
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_stand = floor(world.x / 150.0) * 7.0 + floor(world.z / 150.0) * 13.0;
	v_height = world.y;
}

void fragment() {
	// Blocks of ~9 m along the row share a seat colour.
	float block = hash(vec2(floor(UV.x / 9.0), v_stand));
	vec3 seat = block < 0.45 ? seat_a : (block < 0.8 ? seat_b : seat_c);
	vec3 crowd_avg = vec3(0.42, 0.38, 0.36);
	vec3 col = mix(seat, crowd_avg, crowd * 0.85);
	if (detail > 0.5) {
		vec2 cell = vec2(UV.x / seat_width, UV.y / row_depth);
		float level = v_height / 0.42;
		vec2 id = floor(cell) + vec2(0.0, floor(level) * 31.0);
		vec2 f = cell - floor(cell);
		vec2 aa = max(fwidth(cell), vec2(0.0, fwidth(level) * 0.5));
		float fade = 1.0 - smoothstep(0.18, 0.5, max(aa.x, aa.y));
		float r = hash(id + v_stand);
		float r2 = hash(id * 1.3 + 11.0 + v_stand);
		// A spectator: muted clothes, a few in strong colours.
		vec3 strong = 0.2 + 0.75 * vec3(hash(id + 3.1), hash(id + 7.7), hash(id + 5.3));
		vec3 shirt = mix(vec3(0.25 + 0.5 * r2), strong, 0.25 + 0.6 * step(0.8, hash(id + 9.9)));
		vec3 detailed = mix(seat * (0.85 + 0.3 * r2), shirt, step(r, crowd));
		// Gaps between seats and the darker back of every row.
		detailed *= 0.72 + 0.28 * smoothstep(0.0, 0.12, f.x) * (1.0 - smoothstep(0.88, 1.0, f.x));
		detailed *= 0.75 + 0.25 * (1.0 - smoothstep(0.7, 0.95, f.y));
		col = mix(col, detailed, fade * 0.8);
	}
	ALBEDO = col;
	ROUGHNESS = 0.8;
	SPECULAR = 0.2;
}
