class_name TrackEnvironment
extends RefCounted
## Per-track look: time of day, sun, sky, fog, ground colours, kerbs, trees, floodlights.
## Read from `environment.json` in the track folder (hand-written per track); every key is
## optional. Without the file the track looks exactly as it always did and the sky scene is
## not touched.
##
## Merge order (later wins): DEFAULTS -> the preset named by "preset"
## (assets/tracks/_shared/environments/<preset>.json: temperate_day, desert, floodlit_night)
## -> the stock lighting of "time" (TIME_LIGHTING), when the file asks for another time than
## its preset has -> environment.json. A wrong key name gives a warning, so typos are noticed.
##
## Colours are [r, g, b] (0..1, as seen on screen) or "#rrggbb". The complete file:
##
##   {
##     "preset": "temperate_day",            // optional starting point, see above
##     "time": "day",                        // "day" | "dusk" | "night"
##     "sun": {"azimuth_deg": 60,            // compass bearing TO the sun: 0 north, 90 east
##             "elevation_deg": 45,          // above the horizon
##             "color": [1.0, 0.95, 0.86], "energy": 1.5},   // at night this is the moon
##     "sky": {"top": [0.24, 0.45, 0.78], "horizon": [0.74, 0.81, 0.88],
##             "stars": 0.0,                 // 0..1 star brightness
##             "glow_color": [0.9, 0.55, 0.25], "glow": 0.0}, // city glow at the horizon, 0..1
##     "ambient": {"color": [0.62, 0.64, 0.66], "energy": 1.0},   // light in the shade
##     "fog": {"color": [0.74, 0.81, 0.88], "begin": 250, "end": 2900},   // metres
##     "exposure": 1.0,
##     "glow": {"intensity": 0.35, "threshold": 1.1, "bloom": 0.03},     // bloom of bright things
##     "terrain_palette": {                  // land-cover class -> [colour a, colour b]
##       "grass": [[0.20, 0.35, 0.12], [0.29, 0.42, 0.15]],
##       "forest": [..], "water": [..], "sand": [..], "urban": [..], "farmland": [..],
##       "rock": [..], "gravel": [..], "scrub": [..], "beach": [..]},
##     "mowing_stripes": true,               // mowed bands beside the track
##     "verge": {"grass_color": [0.20, 0.36, 0.11], "dry_color": [0.33, 0.38, 0.16]},
##     "kerbs": {"a": [0.78, 0.07, 0.06], "b": [0.93, 0.93, 0.91], "sausage": [0.95, 0.78, 0.05]},
##     "trees": {"mix": {"conifer": 3, "broadleaf": 1},   // weights; {} = species from the data
##               "colors": {"conifer": [[0.07, 0.17, 0.08], [0.13, 0.26, 0.11]], ...},
##               "density": 1.0,             // 0..1 share of the baked trees that is shown
##               "scale": 1.0},              // height multiplier
##     "floodlights": {"enabled": false, "spacing_m": 60, "height_m": 28,
##                     "color": [1.0, 0.97, 0.90], "energy": 1.25, "reach_m": 90},
##     "water": {"color": [0.10, 0.26, 0.32], "deep_color": [0.03, 0.10, 0.16]},
##     "buildings": {"lit_windows": 0.35,    // share of windows lit at dusk / night
##                   "window_color": [1.0, 0.80, 0.52]},
##     "stands": {"seat_colors": [[0.10, 0.25, 0.60], [0.75, 0.10, 0.10], [0.80, 0.80, 0.82]],
##                "crowd": 0.6}              // 0..1 share of seats taken
##   }
##
## Floodlit circuits: the Mobile renderer cannot take hundreds of lights, so at night the
## scene's sun becomes one shadow-casting "floodlight key" that only lights the track corridor
## (everything but render layer LAYER_FAR) and a weak moon lights the rest; at dusk the sun
## stays and a shadowless fill does the same job. The terrain adds the same light within
## `reach_m` of the centreline in its shader (see Terrain), lamp heads are emissive (Scenery).

const FILE := "environment.json"
const PRESET_DIR := "res://assets/tracks/_shared/environments"
const SKY_SHADER_PATH := "res://shaders/scenery_sky.gdshader"
## Land-cover classes, in class-id order (landcover.png values).
const CLASSES: Array[String] = ["grass", "forest", "water", "sand", "urban", "farmland", "rock",
		"gravel", "scrub", "beach"]
## Tree species the game can draw (SceneryTrees mesh order). The baked data's species ids
## are mapped onto these by Scenery (see Scenery.DATA_SPECIES).
const SPECIES: Array[String] = ["conifer", "broadleaf", "palm", "cypress", "bush"]
const TIMES: Array[String] = ["day", "dusk", "night"]
## Render layer (bit) of everything the floodlights do not reach: terrain, water, far scenery.
const LAYER_FAR: int = 1 << 11
## Name of the light apply() adds next to the track (the moon, or the dusk floodlight fill).
const EXTRA_LIGHT := "EnvLight"
const FLOOD_KEY_ELEVATION: float = 62.0   ## degrees, the floodlight key at night
const FLOOD_DUSK_SHARE: float = 0.45      ## floodlight strength at dusk

const DEFAULTS: Dictionary = {
	"preset": "",
	"time": "day",
	"sun": {"azimuth_deg": 60.0, "elevation_deg": 45.0, "color": [1.0, 0.95, 0.86], "energy": 1.5},
	"sky": {"top": [0.24, 0.45, 0.78], "horizon": [0.74, 0.81, 0.88], "stars": 0.0,
		"glow_color": [0.90, 0.55, 0.25], "glow": 0.0},
	"ambient": {"color": [0.62, 0.64, 0.66], "energy": 1.0},
	"fog": {"color": [0.74, 0.81, 0.88], "begin": 250.0, "end": 2900.0},
	"exposure": 1.0,
	"glow": {"intensity": 0.35, "threshold": 1.1, "bloom": 0.03},
	"terrain_palette": {
		"grass": [[0.20, 0.35, 0.12], [0.29, 0.42, 0.15]],
		"forest": [[0.09, 0.17, 0.07], [0.13, 0.23, 0.09]],
		"water": [[0.08, 0.20, 0.24], [0.10, 0.24, 0.28]],
		"sand": [[0.74, 0.65, 0.46], [0.82, 0.74, 0.55]],
		"urban": [[0.40, 0.40, 0.41], [0.50, 0.49, 0.47]],
		"farmland": [[0.44, 0.47, 0.20], [0.62, 0.55, 0.30]],
		"rock": [[0.42, 0.40, 0.37], [0.55, 0.52, 0.48]],
		"gravel": [[0.52, 0.47, 0.39], [0.63, 0.58, 0.48]],
		"scrub": [[0.30, 0.35, 0.17], [0.42, 0.42, 0.24]],
		"beach": [[0.84, 0.78, 0.60], [0.90, 0.85, 0.70]],
	},
	"mowing_stripes": true,
	"verge": {"grass_color": [0.20, 0.36, 0.11], "dry_color": [0.33, 0.38, 0.16]},
	"kerbs": {"a": [0.78, 0.07, 0.06], "b": [0.93, 0.93, 0.91], "sausage": [0.95, 0.78, 0.05]},
	"trees": {
		"mix": {},
		"colors": {
			"conifer": [[0.07, 0.17, 0.08], [0.13, 0.26, 0.11]],
			"broadleaf": [[0.14, 0.28, 0.08], [0.25, 0.38, 0.12]],
			"palm": [[0.16, 0.30, 0.10], [0.26, 0.38, 0.14]],
			"cypress": [[0.06, 0.15, 0.08], [0.10, 0.21, 0.10]],
			"bush": [[0.17, 0.28, 0.10], [0.28, 0.36, 0.15]],
		},
		"density": 1.0,
		"scale": 1.0,
	},
	"floodlights": {"enabled": false, "spacing_m": 60.0, "height_m": 28.0,
		"color": [1.0, 0.97, 0.90], "energy": 1.25, "reach_m": 90.0},
	"water": {"color": [0.10, 0.26, 0.32], "deep_color": [0.03, 0.10, 0.16]},
	"buildings": {"lit_windows": 0.35, "window_color": [1.0, 0.80, 0.52]},
	"stands": {"seat_colors": [[0.10, 0.25, 0.60], [0.75, 0.10, 0.10], [0.80, 0.80, 0.82]],
		"crowd": 0.6},
}

## What a time of day changes when the file does not say otherwise. "day" is the DEFAULTS.
const TIME_LIGHTING: Dictionary = {
	"day": {},
	"dusk": {
		"sun": {"azimuth_deg": 285.0, "elevation_deg": 7.0, "color": [1.0, 0.60, 0.36], "energy": 1.1},
		"sky": {"top": [0.13, 0.20, 0.42], "horizon": [0.93, 0.56, 0.36], "stars": 0.12, "glow": 0.0},
		"ambient": {"color": [0.62, 0.54, 0.62], "energy": 0.85},
		"fog": {"color": [0.80, 0.56, 0.44]},
		"glow": {"intensity": 0.55, "threshold": 1.0, "bloom": 0.05},
	},
	"night": {
		"sun": {"azimuth_deg": 140.0, "elevation_deg": 48.0, "color": [0.62, 0.72, 1.0], "energy": 0.22},
		"sky": {"top": [0.010, 0.016, 0.040], "horizon": [0.045, 0.055, 0.095], "stars": 1.0, "glow": 0.35},
		"ambient": {"color": [0.30, 0.37, 0.58], "energy": 0.24},
		"fog": {"color": [0.045, 0.055, 0.095]},
		"glow": {"intensity": 0.8, "threshold": 0.9, "bloom": 0.08},
	},
}
## Keys TIME_LIGHTING owns: a --time override replaces these and keeps the rest of the file.
const LIGHTING_KEYS: Array[String] = ["sun", "sky", "ambient", "fog", "exposure", "glow"]

## The merged settings (same shape as DEFAULTS).
var values: Dictionary = {}
## True when the track has an environment.json (or a --time override): only then is the sky
## scene changed.
var active: bool = false
var time: String = "day"

var _world_env: WorldEnvironment
var _old_environment: Environment
var _sun: DirectionalLight3D
var _old_sun: Dictionary = {}
var _extra_light: DirectionalLight3D

## The environment of the track folder file `path` ("" or a missing file = the defaults).
## `time_override` ("day" / "dusk" / "night") forces that time's lighting.
static func load_file(path: String, time_override: String = "") -> TrackEnvironment:
	var env := TrackEnvironment.new()
	var file := {}
	if not path.is_empty() and FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			file = parsed
			env.active = true
		else:
			push_warning("TrackEnvironment: %s is not a JSON object, using the defaults" % path)
	var preset := {}
	var preset_name := str(file.get("preset", ""))
	if not preset_name.is_empty():
		var preset_path := PRESET_DIR.path_join(preset_name + ".json")
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(preset_path)) \
				if FileAccess.file_exists(preset_path) else null
		if parsed is Dictionary:
			preset = parsed
		else:
			push_warning("TrackEnvironment: unknown preset '%s' in %s" % [preset_name, path])
	_check_keys(preset, DEFAULTS, "preset " + preset_name)
	_check_keys(file, DEFAULTS, path)
	var file_time := str(file.get("time", preset.get("time", "day")))
	if not file_time in TIMES:
		push_warning("TrackEnvironment: unknown time '%s' in %s" % [file_time, path])
		file_time = "day"
	env.time = file_time
	var preset_time := str(preset.get("time", "day"))
	if not preset_time in TIMES:
		preset_time = "day"
	var v: Dictionary = DEFAULTS.duplicate(true)
	_merge(v, TIME_LIGHTING[preset_time])
	_merge(v, preset)
	if file_time != preset_time:
		# A day preset used for a dusk or night track: that time's stock lighting.
		_relight(v, file_time)
	_merge(v, file)
	if not time_override.is_empty() and not time_override in TIMES:
		push_warning("TrackEnvironment: unknown --time=%s" % time_override)
	elif not time_override.is_empty():
		env.active = true
		if time_override != file_time:
			# Another time than the file describes: that time's stock lighting, the track's
			# own ground, kerbs, trees and floodlights.
			_relight(v, time_override)
			env.time = time_override
			if time_override == "night":
				(v["floodlights"] as Dictionary)["enabled"] = true
	v["time"] = env.time
	env.values = v
	return env

## Replaces the lighting keys of `v` by the stock lighting of `time`.
static func _relight(v: Dictionary, time: String) -> void:
	for key in LIGHTING_KEYS:
		v[key] = _copy(DEFAULTS[key])
	_merge(v, TIME_LIGHTING[time])

static func _merge(into: Dictionary, from: Dictionary) -> void:
	for key: Variant in from:
		if into.get(key) is Dictionary and from[key] is Dictionary:
			_merge(into[key], from[key])
		else:
			into[key] = _copy(from[key])

static func _copy(v: Variant) -> Variant:
	if v is Dictionary:
		return (v as Dictionary).duplicate(true)
	if v is Array:
		return (v as Array).duplicate(true)
	return v

## Warns about keys DEFAULTS does not know (two levels deep; "mix" is free-form species).
static func _check_keys(d: Dictionary, known: Dictionary, where: String) -> void:
	for key: Variant in d:
		if not known.has(key):
			push_warning("TrackEnvironment: unknown key '%s' in %s" % [key, where])
		elif d[key] is Dictionary and known[key] is Dictionary and not (known[key] as Dictionary).is_empty():
			_check_keys(d[key], known[key], "%s/%s" % [where, key])
		elif key is String and key == "mix" and d[key] is Dictionary:
			for species: Variant in d[key]:
				if not species in SPECIES:
					push_warning("TrackEnvironment: unknown tree species '%s' in %s" % [species, where])

# ------------------------------------------------------------------------- typed access
## Colour of a JSON value: [r, g, b] / [r, g, b, a] or "#rrggbb".
static func to_color(v: Variant, fallback: Color = Color.MAGENTA) -> Color:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is String and Color.html_is_valid(v):
		return Color.html(v)
	return fallback

func section(key: String) -> Dictionary:
	var d: Variant = values.get(key)
	return d if d is Dictionary else {}

func color(sec: String, key: String) -> Color:
	return to_color(section(sec).get(key), to_color((DEFAULTS[sec] as Dictionary).get(key)))

func number(sec: String, key: String) -> float:
	var v: Variant = section(sec).get(key)
	if v is float or v is int:
		return float(v)
	return float((DEFAULTS[sec] as Dictionary).get(key, 0.0))

func is_night() -> bool:
	return time == "night"

## 0 by day, 0.6 at dusk, 1 at night: how much lit windows and lamps show.
func night_amount() -> float:
	return 1.0 if time == "night" else (0.6 if time == "dusk" else 0.0)

func mowing_stripes() -> bool:
	return bool(values.get("mowing_stripes", true))

## The two palette colours of every land-cover class, in class-id order.
func palette(index: int) -> PackedColorArray:
	var out := PackedColorArray()
	var pal := section("terrain_palette")
	for c in CLASSES:
		var pair: Variant = pal.get(c)
		var def: Array = (DEFAULTS["terrain_palette"] as Dictionary)[c]
		if not (pair is Array and (pair as Array).size() >= 2):
			pair = def
		out.append(to_color((pair as Array)[index], to_color(def[index])))
	return out

## The two foliage colours of a tree species.
func tree_colors(species: String) -> Array[Color]:
	var def: Array = ((DEFAULTS["trees"] as Dictionary)["colors"] as Dictionary)[species]
	var pair: Variant = (section("trees").get("colors", {}) as Dictionary).get(species)
	if not (pair is Array and (pair as Array).size() >= 2):
		pair = def
	return [to_color((pair as Array)[0], to_color(def[0])), to_color((pair as Array)[1], to_color(def[1]))]

## Species weights of "trees"/"mix" in species-id order; empty when the data's species are used.
func tree_mix() -> PackedFloat32Array:
	var mix: Variant = section("trees").get("mix")
	var out := PackedFloat32Array()
	if not (mix is Dictionary) or (mix as Dictionary).is_empty():
		return out
	var total := 0.0
	for s in SPECIES:
		var w := maxf(0.0, float((mix as Dictionary).get(s, 0.0)))
		out.append(w)
		total += w
	return out if total > 0.0 else PackedFloat32Array()

func seat_colors() -> Array[Color]:
	var out: Array[Color] = []
	var list: Variant = section("stands").get("seat_colors")
	if list is Array:
		for c: Variant in list:
			out.append(to_color(c, Color(0.5, 0.5, 0.5)))
	while out.size() < 3:
		out.append(out.back() if not out.is_empty() else Color(0.2, 0.3, 0.6))
	return out

## True when the lamps are on: floodlights enabled and it is not day.
func floodlit() -> bool:
	return bool(section("floodlights").get("enabled", false)) and time != "day"

## Colour x strength of the floodlights on the ground (black when they are off). The terrain
## shader adds it near the track; the lights apply() sets up use the same value.
func flood_light() -> Color:
	if not floodlit():
		return Color.BLACK
	var c := color("floodlights", "color")
	var e := number("floodlights", "energy") * (1.0 if is_night() else FLOOD_DUSK_SHARE)
	return Color(c.r * e, c.g * e, c.b * e)

## Unit vector towards the sun (or the moon).
func sun_direction() -> Vector3:
	return direction(number("sun", "azimuth_deg"), number("sun", "elevation_deg"))

## Unit vector for a compass bearing (0 = north = -Z, 90 = east = +X) and an elevation.
static func direction(azimuth_deg: float, elevation_deg: float) -> Vector3:
	var az := deg_to_rad(azimuth_deg)
	var el := deg_to_rad(elevation_deg)
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))

# ------------------------------------------------------------------------- sky scene
## Applies sun, sky, fog, ambient light and tone mapping to the sky scene `sky_root` (a node
## with a DirectionalLight3D and a WorldEnvironment child, scenes/world/sky_environment.tscn)
## and adds the moon / floodlight fill under `light_parent`. The Environment resource is
## duplicated first; restore() puts everything back. Either node may be null.
func apply(sky_root: Node, light_parent: Node) -> void:
	restore()
	if sky_root != null:
		for c in sky_root.get_children():
			if c is WorldEnvironment and _world_env == null:
				_world_env = c
			elif c is DirectionalLight3D and _sun == null:
				_sun = c
	var flood := floodlit()
	var night_flood := flood and is_night()
	if _sun != null:
		_old_sun = {"basis": _sun.global_basis, "color": _sun.light_color, "energy": _sun.light_energy,
			"mask": _sun.light_cull_mask, "sky_mode": _sun.sky_mode}
		if night_flood:
			# The shadow-casting light becomes the floodlights: only the track corridor.
			_aim(_sun, direction(number("sun", "azimuth_deg") + 90.0, FLOOD_KEY_ELEVATION))
			_sun.light_color = color("floodlights", "color")
			_sun.light_energy = number("floodlights", "energy")
			_sun.light_cull_mask = 0xFFFFF & ~LAYER_FAR
			_sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		else:
			_aim(_sun, sun_direction())
			_sun.light_color = color("sun", "color")
			_sun.light_energy = number("sun", "energy")
	if flood and light_parent != null:
		_extra_light = DirectionalLight3D.new()
		_extra_light.name = EXTRA_LIGHT
		_extra_light.shadow_enabled = false
		light_parent.add_child(_extra_light)
		if night_flood:
			# The moon: weak, everywhere, and the light the sky shader draws.
			_aim(_extra_light, sun_direction())
			_extra_light.light_color = color("sun", "color")
			_extra_light.light_energy = number("sun", "energy")
		else:
			_aim(_extra_light, direction(number("sun", "azimuth_deg") + 180.0, 78.0))
			_extra_light.light_color = color("floodlights", "color")
			_extra_light.light_energy = number("floodlights", "energy") * FLOOD_DUSK_SHARE
			_extra_light.light_cull_mask = 0xFFFFF & ~LAYER_FAR
			_extra_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	if _world_env != null and _world_env.environment != null:
		_old_environment = _world_env.environment
		var e := _old_environment.duplicate(true) as Environment
		_configure(e)
		_world_env.environment = e

## Undoes apply(): the sky scene gets its own Environment and sun values back.
func restore() -> void:
	if is_instance_valid(_world_env) and _old_environment != null:
		_world_env.environment = _old_environment
	if is_instance_valid(_sun) and not _old_sun.is_empty():
		if _sun.is_inside_tree():
			_sun.global_basis = _old_sun["basis"]
		_sun.light_color = _old_sun["color"]
		_sun.light_energy = _old_sun["energy"]
		_sun.light_cull_mask = _old_sun["mask"]
		_sun.sky_mode = _old_sun["sky_mode"]
	if is_instance_valid(_extra_light):
		_extra_light.queue_free()
	_world_env = null
	_old_environment = null
	_sun = null
	_old_sun = {}
	_extra_light = null

## The Environment apply() installed (null before apply or without a sky scene).
func applied_environment() -> Environment:
	return _world_env.environment if is_instance_valid(_world_env) and _old_environment != null else null

## Pushes the fog back so a camera `distance` metres away still sees the ground (--overview).
## `sky_root` as in apply(): used when nothing was applied (a track without environment.json),
## the Environment is then copied here so restore() can undo it.
func push_fog_back(distance: float, sky_root: Node = null) -> void:
	var e := applied_environment()
	if e == null and sky_root != null:
		for c in sky_root.get_children():
			if c is WorldEnvironment and (c as WorldEnvironment).environment != null:
				_world_env = c
				_old_environment = _world_env.environment
				e = _old_environment.duplicate(true) as Environment
				_world_env.environment = e
				break
	if e != null:
		e.fog_depth_begin = maxf(e.fog_depth_begin, distance * 1.3)
		e.fog_depth_end = maxf(e.fog_depth_end, distance * 4.0)

static func _aim(light: DirectionalLight3D, to_light: Vector3) -> void:
	var up := Vector3.UP if absf(to_light.y) < 0.99 else Vector3.FORWARD
	light.global_basis = Basis.looking_at(-to_light, up)

func _configure(e: Environment) -> void:
	var top := color("sky", "top")
	var horizon := color("sky", "horizon")
	if e.sky != null:
		if time == "day" and number("sky", "stars") <= 0.0 and number("sky", "glow") <= 0.0:
			var mat := e.sky.sky_material as ProceduralSkyMaterial
			if mat != null:
				mat.sky_top_color = top
				mat.sky_horizon_color = horizon
				mat.ground_bottom_color = horizon
				mat.ground_horizon_color = horizon
		else:
			var mat := ShaderMaterial.new()
			mat.shader = load(SKY_SHADER_PATH)
			mat.set_shader_parameter("top_color", top)
			mat.set_shader_parameter("horizon_color", horizon)
			mat.set_shader_parameter("stars", number("sky", "stars"))
			mat.set_shader_parameter("glow_color", color("sky", "glow_color"))
			mat.set_shader_parameter("glow", number("sky", "glow"))
			mat.set_shader_parameter("sun_glow", 1.0 if time == "dusk" else 0.25)
			e.sky.sky_material = mat
	e.ambient_light_color = color("ambient", "color")
	e.ambient_light_energy = number("ambient", "energy")
	e.fog_light_color = color("fog", "color")
	e.fog_depth_begin = number("fog", "begin")
	e.fog_depth_end = number("fog", "end")
	e.tonemap_exposure = float(values.get("exposure", 1.0))
	e.glow_intensity = number("glow", "intensity")
	e.glow_hdr_threshold = number("glow", "threshold")
	e.glow_bloom = number("glow", "bloom")
	if time != "day":
		e.fog_sun_scatter = 0.0
		# By day the ambient light is the sky scene's mix of this colour and the sky; at dusk
		# and at night it is exactly the colour asked for, whatever the sky shader shows.
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
