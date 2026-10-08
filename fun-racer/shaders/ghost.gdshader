shader_type spatial;
// Ghost car: one flat, tinted, translucent layer with a brighter fresnel rim. No lighting, no
// shadows. Fades out close to the camera so the ghost never blocks the player's view.
//
// Used as two materials on every ghost mesh (see scripts/race/ghost_player.gd):
//   1. depth_only = true  (render_priority 0): lays down the ghost's depth, draws no colour;
//   2. depth_only = false (render_priority 1): colours only the front-most surface.
// That way the car reads as a single clean shell instead of a pile of overlapping see-through
// parts (wheels through bodywork, far side through near side).
render_mode unshaded, blend_mix, cull_back, depth_draw_always, shadows_disabled, fog_disabled;

uniform bool depth_only = false;
uniform vec3 tint : source_color = vec3(0.45, 0.8, 1.0);
uniform float body_alpha : hint_range(0.0, 1.0) = 0.16;
uniform float rim_alpha : hint_range(0.0, 1.0) = 0.62;
uniform float rim_power : hint_range(0.5, 8.0) = 2.6;
// Distance from the camera (m) where the ghost is invisible / fully shown.
uniform float fade_near = 3.0;
uniform float fade_far = 7.0;
// Overall opacity, driven by the player (fade in at the lap start, out at the end).
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float fade = smoothstep(fade_near, fade_far, length(VERTEX)) * opacity;
	if (fade < 0.01) {
		discard;
	}
	if (depth_only) {
		ALBEDO = vec3(0.0);
		ALPHA = 0.0;
	} else {
		float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
		float rim = pow(1.0 - facing, rim_power);
		ALBEDO = mix(tint, vec3(1.0), rim * 0.55);
		ALPHA = mix(body_alpha, rim_alpha, rim) * fade;
	}
}
