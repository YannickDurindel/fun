shader_type spatial;
// Grass verges of the "realistic" track look (TrackLook writes this code into the track's own
// road_grass.gdshader for the session; the uniforms of that shader are kept).
// UV = (s, lateral m, signed), UV2 = (racing-line offset m, road half width m).
// A photo-scanned lawn (photo/grass_albedo, CC0) in two tile sizes: the real one up close,
// a 3.7x larger one further away, blended by distance so neither repeats visibly; large
// blotches of lusher / drier grass (macro, 160 m and 900 m), mowing stripes, and a worn strip
// along the road edge where cars run wide.
render_mode cull_back, diffuse_burley;

uniform sampler2D mottle : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 grass_color : source_color = vec3(0.20, 0.36, 0.11);
uniform vec3 dry_color : source_color = vec3(0.33, 0.38, 0.16);
uniform float stripe_length = 12.0;  // mowing stripes along the track
uniform sampler2D grass_albedo : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_far : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;   // the same image
uniform sampler2D macro : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float tile_m = 1.4;           // metres per texture tile
uniform vec3 soil_color : source_color = vec3(0.30, 0.25, 0.18);
uniform vec3 tint = vec3(0.68, 0.84, 0.52);   // the photo is a pale lawn: a lusher green

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float dist = length(VERTEX);
	float near = 1.0 - smoothstep(8.0, 45.0, dist);
	vec2 uv1 = world_xz / tile_m;
	vec2 uv1_dx = dFdx(uv1);
	vec2 uv1_dy = dFdy(uv1);
	vec4 far_px = texture(grass_far, world_xz / (tile_m * 3.7) + vec2(0.21, 0.77));
	vec4 px = far_px;
	if (near > 0.0) {
		px = mix(far_px, textureGrad(grass_albedo, uv1, uv1_dx, uv1_dy), near);
	}
	vec3 m1 = texture(macro, world_xz * (1.0 / 160.0) + vec2(0.5, 0.1)).rgb;
	float m2 = texture(macro, world_xz * (1.0 / 900.0)).r;

	vec3 col = px.rgb * tint;
	float dry = clamp((m1.r - 0.5) * 1.4 + (m2 - 0.5) * 1.0 + 0.35, 0.0, 1.0);
	col = mix(col, col * vec3(1.18, 1.06, 0.62), smoothstep(0.35, 0.95, dry) * 0.7);
	col *= 0.86 + 0.28 * m1.b;

	// Mowing stripes, lighter / darker bands along the track.
	float st = UV.x / (2.0 * stripe_length);
	float aw = max(fwidth(st), 1e-4);
	float stripe = smoothstep(0.5 - aw, 0.5 + aw, fract(st)) * (1.0 - smoothstep(1.0 - aw, 1.0, fract(st)));
	float edge = abs(UV.y) - UV2.y;                  // m beyond the road edge
	col *= 1.0 + (stripe - 0.5) * 0.14 * (1.0 - smoothstep(25.0, 30.0, edge));

	// Worn strip at the road edge: soil and flattened grass, patchy.
	float worn = (1.0 - smoothstep(0.15, 0.9 + 0.8 * m1.g, edge)) * smoothstep(0.4, 0.7, m1.g + m1.b * 0.5);
	col = mix(col, soil_color * (0.7 + 0.6 * px.g / 0.36), clamp(worn, 0.0, 1.0) * 0.7);

	ALBEDO = col;
	ROUGHNESS = mix(0.95, px.a, near);
	SPECULAR = 0.3;
}
