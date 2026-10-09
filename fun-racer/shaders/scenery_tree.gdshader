shader_type spatial;
// Low-poly trees (scripts/track/scenery_trees.gd), drawn as MultiMeshes by Scenery.
// Vertex colour: r = shade (dark inside / below the crown), g = 1 foliage / 0 trunk,
// b = how much the vertex sways. Instance custom data: rgb = foliage colour of this tree,
// a = random phase. Opaque (no alpha: cheap on integrated graphics). Instead of fading out,
// a tree shrinks into the ground over the last `fade_margin` metres before `fade_end`, the
// MultiMesh's visibility range end.
render_mode cull_back, diffuse_lambert_wrap, specular_disabled;

uniform vec3 trunk_color : source_color = vec3(0.24, 0.18, 0.13);
uniform float fade_end = 900.0;
uniform float fade_margin = 80.0;
uniform float sway = 0.035;      // fraction of the tree height the top moves

varying vec3 v_color;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float phase = INSTANCE_CUSTOM.a * 6.2832;
	// Wind: the crown leans a little, each tree in its own rhythm.
	float w = sin(TIME * 1.3 + phase + origin.x * 0.05) + 0.5 * sin(TIME * 2.9 + phase * 1.7 + origin.z * 0.08);
	VERTEX.xz += vec2(0.8, 0.6) * w * sway * COLOR.b * VERTEX.y;
	float d = distance(origin, CAMERA_POSITION_WORLD);
	VERTEX *= 1.0 - smoothstep(fade_end - fade_margin, fade_end, d);
	v_color = mix(trunk_color, INSTANCE_CUSTOM.rgb, COLOR.g) * COLOR.r;
}

void fragment() {
	ALBEDO = v_color;
	ROUGHNESS = 0.9;
}
