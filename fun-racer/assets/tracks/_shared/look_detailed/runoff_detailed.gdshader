shader_type spatial;
// Run-off areas of the "realistic" track look (TrackLook gives the Trackside's run-off surfaces
// this material): `gravel` 1 = a gravel trap (photo/gravel_albedo, CC0, tinted to the local
// stone), 0 = tarmac run-off (photo/asphalt_detail pack: luminance, roughness, AO). Mapped on
// world XZ in two tile sizes blended by distance, with macro blotches, tyre ruts in the
// gravel and dust on the tarmac.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform float gravel = 1.0;
uniform sampler2D detail : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_far : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;   // the same image
uniform sampler2D detail_lin : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;   // tarmac pack (not colour)
uniform sampler2D detail_lin_far : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float tile_m = 1.5;
uniform vec3 gravel_tint : source_color = vec3(1.0, 0.9, 0.74);
uniform vec3 tarmac_color : source_color = vec3(0.21, 0.21, 0.22);

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	float dist = length(VERTEX);
	float near = 1.0 - smoothstep(8.0, 40.0, dist);
	vec2 uv1 = world_xz / tile_m;
	vec2 uv1_dx = dFdx(uv1);
	vec2 uv1_dy = dFdy(uv1);
	vec2 uv2 = world_xz / (tile_m * 3.3) + vec2(0.43, 0.19);
	vec3 m = texture(macro, world_xz * (1.0 / 160.0) + vec2(0.7, 0.3)).rgb;
	vec3 col;
	float rough;
	vec2 nt = vec2(0.0);
	if (gravel > 0.5) {
		vec4 far_px = texture(detail_far, uv2);
		vec4 px = far_px;
		if (near > 0.0) {
			px = mix(far_px, textureGrad(detail, uv1, uv1_dx, uv1_dy), near);
			nt = (textureGrad(detail_normal, uv1, uv1_dx, uv1_dy).xy * 2.0 - 1.0) * near;
		}
		col = px.rgb * gravel_tint * (0.88 + 0.24 * m.r);
		float rut = smoothstep(0.55, 0.75, texture(macro, vec2(UV.x / 30.0, UV.y * 0.9)).g);
		col *= 1.0 - 0.2 * rut;
		rough = mix(0.95, px.a, near);
	} else {
		vec4 far_px = texture(detail_lin_far, uv2);
		vec4 px = far_px;
		if (near > 0.0) {
			px = mix(far_px, textureGrad(detail_lin, uv1, uv1_dx, uv1_dy), near);
			nt = (textureGrad(detail_normal, uv1, uv1_dx, uv1_dy).xy * 2.0 - 1.0) * near;
		}
		col = tarmac_color * (px.r / 0.25) * (0.75 + 0.25 * px.b) * (0.86 + 0.24 * m.r + 0.1 * m.b);
		col = mix(col, col * vec3(1.3, 1.26, 1.18) + 0.02, smoothstep(0.45, 0.7, m.g) * 0.4);
		rough = px.g;
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = 0.4;
	// Detail mapped on world XZ: tangent = +X, map "up" = -Z.
	vec3 n_w = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 t_w = normalize(vec3(1.0, 0.0, 0.0) - n_w * n_w.x);
	vec3 b_w = normalize(cross(n_w, t_w));
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(n_w + t_w * nt.x + b_w * nt.y), 0.0)).xyz);
}
