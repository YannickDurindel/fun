class_name TrackLook
extends RefCounted
## The opt-in "detailed" look of a track (environment.json "look": "detailed", see
## TrackEnvironment). Tracks without the flag never reach this code, so they render exactly
## as before. TrackEnvironment.apply() calls in here once the track's children are ready:
##   * road(): the track's tarmac shader (road_tarmac.gdshader of the folder) gets the code of
##     assets/tracks/_shared/look_detailed/road_tarmac_detailed.gdshader for this session
##     (TrackEnvironment.restore() puts the original code back), and every road mesh a copy of
##     the track material with the same lap uniforms, the shared detail textures
##     (cad/track/look_textures.py) and a "lap map" built here from the centreline: braking
##     zones, corner scrub, resurfaced sections.
##   * environment() / sun(): AgX tone mapping, a deeper sky with a darker ground bounce,
##     light aerial fog, longer and finer sun shadows.
## Why the code is swapped in place instead of assigning the detailed Shader resource: the
## Mobile renderer orders opaque draws by shader, and a shader created at race time drew the
## road after the terrain beneath it, so nothing was rejected by the depth test: +3.5 ms a
## frame on the HD 520 (10 cars, pit straight), for any shader, even a one-line one. With the
## track's own shader resource the road keeps its early place and the look costs ~1 ms.
## No reflection probe either: a box probe over the pit straight cost ~2 ms a frame (every
## pixel inside it samples it); the sky radiance does the reflections.

const DIR := "res://assets/tracks/_shared/look_detailed"
const TARMAC_SHADER := DIR + "/road_tarmac_detailed.gdshader"
const DETAIL_TEX := DIR + "/asphalt_detail.png"
const NORMAL_TEX := DIR + "/asphalt_normal.png"
const MACRO_TEX := DIR + "/asphalt_macro.png"
## Metres of lap per lap-map texel (at most 16384 texels).
const LAP_MAP_STEP: float = 1.5

## Lap-map physics: a fast prototype, just enough to place the braking zones.
const LAT_ACCEL: float = 24.0     ## m/s^2 cornering
const BRAKE_DECEL: float = 28.0   ## m/s^2
const DRIVE_ACCEL: float = 7.0    ## m/s^2
const TOP_SPEED: float = 92.0     ## m/s

# ------------------------------------------------------------------------- road
## Gives every road mesh under `track` the detailed tarmac. Returns {Shader: original code}
## of the track shaders it rewrote, for unroad().
static func road(track: Node3D) -> Dictionary:
	var swapped := {}
	var road_node := track.get_node_or_null(^"Road")
	var data: TrackData = track.get("data") if track.get("data") is TrackData else null
	var detailed := load(TARMAC_SHADER) as Shader
	if road_node == null or data == null or detailed == null:
		return swapped
	var lap_map := build_lap_map(data, str(track.get("track_id")))
	var made := {}       # old material -> new material
	for node: Node in road_node.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for surf in mi.mesh.get_surface_count():
			var old := mi.get_surface_override_material(surf) as ShaderMaterial
			if old == null:
				old = mi.mesh.surface_get_material(surf) as ShaderMaterial
			if old == null or made.has(old):
				if old != null:
					mi.set_surface_override_material(surf, made[old])
				continue
			if old.shader == null or not old.shader.resource_path.ends_with("road_tarmac.gdshader"):
				continue
			made[old] = _detailed_material(old, detailed, lap_map)
			if not swapped.has(old.shader):
				swapped[old.shader] = old.shader.code
			mi.set_surface_override_material(surf, made[old])
	for sh: Shader in swapped:
		sh.code = detailed.code
	return swapped

## Puts the original code back into the shaders road() rewrote.
static func unroad(swapped: Dictionary) -> void:
	for sh: Variant in swapped:
		if is_instance_valid(sh):
			(sh as Shader).code = swapped[sh]

## A copy of the track material (see the header: the copy keeps the shader's draw order)
## carrying, as explicit parameters, every lap uniform the detailed shader shares with the
## track shader, including the track shader's own defaults (read before its code changes).
static func _detailed_material(old: ShaderMaterial, detailed: Shader, lap_map: Texture2D) -> ShaderMaterial:
	var m := old.duplicate() as ShaderMaterial
	m.resource_name = "tarmac"
	var wanted := {}
	for u: Dictionary in detailed.get_shader_uniform_list():
		wanted[u["name"]] = true
	for u: Dictionary in old.shader.get_shader_uniform_list():
		var n: String = u["name"]
		if not wanted.has(n) or int(u["type"]) == TYPE_OBJECT:
			continue
		var v: Variant = old.get_shader_parameter(n)
		if v == null:
			v = RenderingServer.shader_get_parameter_default(old.shader.get_rid(), n)
		if v != null:
			m.set_shader_parameter(n, v)
	m.set_shader_parameter(&"detail", load(DETAIL_TEX))
	m.set_shader_parameter(&"detail_far", load(DETAIL_TEX))
	m.set_shader_parameter(&"detail_normal", load(NORMAL_TEX))
	m.set_shader_parameter(&"macro", load(MACRO_TEX))
	m.set_shader_parameter(&"lap_map", lap_map)
	m.set_shader_parameter(&"lap_map_exact", lap_map)
	return m

## 1-pixel-high RGB texture along the lap, texel i covers s in [i, i+1) * length / width:
##   R tyre marks of the braking zones (heaviest just before turn-in), G cornering load
##   (wider rubber through corners), B tone of the resurfaced section (sections 60-350 m,
##   each a constant; a change is a transverse join).
static func build_lap_map(data: TrackData, seed_name: String = "") -> ImageTexture:
	var n := data.points.size()
	var w := clampi(int(ceil(data.length / LAP_MAP_STEP)), 64, 16384)
	var brake := PackedFloat32Array()
	var load_g := PackedFloat32Array()
	_speed_profile(data, brake, load_g)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_name if not seed_name.is_empty() else data.name)
	var img := Image.create(w, 1, false, Image.FORMAT_RGB8)
	var next_join := rng.randf_range(60.0, 350.0)
	var tone := rng.randf()
	for i in w:
		var s := (i + 0.5) * data.length / w
		if s > next_join:
			next_join += rng.randf_range(60.0, 350.0)
			var t := rng.randf()
			tone = t if absf(t - tone) > 0.15 else fposmod(tone + 0.4, 1.0)
		var u := s / data.step
		var a := int(floorf(u)) % n
		var b := (a + 1) % n
		var f := u - floorf(u)
		img.set_pixel(i, 0, Color(lerpf(brake[a], brake[b], f), lerpf(load_g[a], load_g[b], f), tone))
	return ImageTexture.create_from_image(img)

## Per centreline point: `brake` 0..1 (how hard cars brake here x how close to turn-in) and
## `load_g` 0..1 (lateral load), from a forward / backward speed pass on the smoothed
## curvature.
static func _speed_profile(data: TrackData, brake: PackedFloat32Array, load_g: PackedFloat32Array) -> void:
	var n := data.points.size()
	var step := data.step
	var k := PackedFloat32Array()
	k.resize(n)
	var span := maxi(1, int(round(6.0 / step)))
	for i in n:
		var p0 := data.points[(i - span + n) % n]
		var p1 := data.points[i]
		var p2 := data.points[(i + span) % n]
		var a := Vector2(p1.x - p0.x, p1.z - p0.z)
		var b := Vector2(p2.x - p1.x, p2.z - p1.z)
		k[i] = absf(a.angle_to(b)) / maxf(0.5 * (a.length() + b.length()), 0.1)
	# Smooth over +-12 m.
	var ks := PackedFloat32Array()
	ks.resize(n)
	var r := maxi(1, int(round(12.0 / step)))
	for i in n:
		var acc := 0.0
		for j in range(-r, r + 1):
			acc += k[(i + j + n) % n]
		ks[i] = acc / (2 * r + 1)
	var v := PackedFloat32Array()
	v.resize(n)
	for i in n:
		v[i] = minf(TOP_SPEED, sqrt(LAT_ACCEL / maxf(ks[i], 1e-5)))
	# Two laps of each pass so the wrap at the finish line settles.
	for _lap in 2:
		for i in n:
			var prev := v[(i - 1 + n) % n]
			v[i] = minf(v[i], sqrt(prev * prev + 2.0 * DRIVE_ACCEL * step))
	for _lap in 2:
		for i in range(n - 1, -1, -1):
			var nxt := v[(i + 1) % n]
			v[i] = minf(v[i], sqrt(nxt * nxt + 2.0 * BRAKE_DECEL * step))
	brake.resize(n)
	load_g.resize(n)
	for i in n:
		load_g[i] = clampf(v[i] * v[i] * ks[i] / LAT_ACCEL, 0.0, 1.0)
		brake[i] = 0.0
	# Braking zones: runs where the speed falls; marks grow towards the end of each zone and
	# with the speed shed (a stop from 300 km/h leaves more rubber than a lift).
	var i0 := 0
	while i0 < n and v[(i0 + 1) % n] < v[i0] - 0.01:
		i0 += 1   # start outside a zone so zones are not split at the wrap
	var idx := 0
	while idx < n:
		var i := (i0 + idx) % n
		if v[(i + 1) % n] < v[i] - 0.01:
			var zone: Array[int] = []
			var j := i
			while v[(j + 1) % n] < v[j] - 0.01 and zone.size() < n:
				zone.append(j)
				j = (j + 1) % n
			var shed := v[zone[0]] - v[j]
			var strength := clampf(shed / 45.0, 0.15, 1.0)
			for z in zone.size():
				var t := float(z + 1) / zone.size()
				brake[zone[z]] = strength * (0.25 + 0.75 * t * t)
			# Marks carry a little past turn-in.
			for z in int(15.0 / step):
				var q := (j + z) % n
				brake[q] = maxf(brake[q], strength * (1.0 - float(z) * step / 15.0))
			idx += zone.size()
		else:
			idx += 1

# ------------------------------------------------------------------------- lighting
## Environment settings of the detailed look (on the copy TrackEnvironment installs).
static func environment(e: Environment, env: TrackEnvironment) -> void:
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_white = 8.0
	e.tonemap_exposure = float(env.values.get("exposure", 1.0)) * 1.25
	e.adjustment_enabled = true
	e.adjustment_saturation = 1.1
	e.adjustment_contrast = 1.06
	e.ambient_light_sky_contribution = 0.7
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.fog_aerial_perspective = 0.6
	e.fog_sun_scatter = 0.18
	e.fog_depth_curve = 1.4
	e.fog_depth_begin = minf(e.fog_depth_begin, 180.0)
	e.glow_intensity = maxf(e.glow_intensity, 0.4)
	if env.time == "day" and e.sky != null and e.sky.sky_material is ProceduralSkyMaterial:
		var mat := (e.sky.sky_material as ProceduralSkyMaterial).duplicate() as ProceduralSkyMaterial
		var top := env.color("sky", "top")
		var horizon := env.color("sky", "horizon")
		mat.sky_top_color = top.darkened(0.08)
		mat.sky_horizon_color = horizon
		mat.sky_curve = 0.09
		mat.sky_energy_multiplier = 1.0
		# A darker, greener ground bounce than the sky colour: the shade under cars and on
		# the lower bodywork reads as ground, not as sky.
		mat.ground_horizon_color = horizon.lerp(Color(0.36, 0.38, 0.32), 0.5)
		mat.ground_bottom_color = Color(0.16, 0.18, 0.13)
		mat.ground_curve = 0.05
		mat.sun_angle_max = 18.0
		mat.sun_curve = 0.08
		e.sky.sky_material = mat
		e.sky.radiance_size = Sky.RADIANCE_SIZE_128

## Sun of the detailed look: longer, finer shadow cascades.
static func sun(light: DirectionalLight3D) -> void:
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	light.directional_shadow_max_distance = 140.0
	light.directional_shadow_split_1 = 0.14
	light.directional_shadow_blend_splits = true
	light.shadow_blur = 1.0

