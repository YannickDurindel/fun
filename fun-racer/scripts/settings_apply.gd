extends Node
## Autoload `SettingsApply`: makes the `graphics` and `audio` settings real. Everything is applied
## once at startup and again whenever `Settings.changed` fires, so the options screen is live.
##   Display   fullscreen / window size (centred) / vsync / FPS cap
##   3D        MSAA, render scale, shadow quality (atlas size, filter, sun shadows on/off)
##   Audio     Master / Engine / FX / UI bus volumes (linear 0..1 -> dB, 0 = muted)
## Window calls are skipped when headless; a `--screenshot` run and an explicit `--resolution`
## keep the window they asked for.
## Dev flag (after `--`): --quality=low|medium|high renders with that preset without touching
## the saved settings.

## What each quality preset sets (graphics keys). Anything else is "custom".
const PRESETS: Dictionary = {
	"low": {"render_scale": 0.7, "msaa": 0, "shadows": 1},     # Intel HD 520 class GPUs
	"medium": {"render_scale": 1.0, "msaa": 2, "shadows": 2},  # the defaults
	"high": {"render_scale": 1.0, "msaa": 3, "shadows": 3},
}
const PRESET_ORDER: Array[String] = ["low", "medium", "high"]
const PRESET_CUSTOM := "custom"

## Settings `audio` key -> audio bus (default_bus_layout.tres).
const BUSES: Dictionary = {"master": &"Master", "engine": &"Engine", "fx": &"FX", "ui": &"UI"}
const MUTE_DB: float = -80.0

## Per shadow level (0 off, 1 low, 2 medium, 3 high): directional atlas size and filter quality.
const SHADOW_ATLAS: Array[int] = [1024, 1024, 2048, 4096]
const SHADOW_FILTER: Array[int] = [
	RenderingServer.SHADOW_QUALITY_HARD,
	RenderingServer.SHADOW_QUALITY_HARD,   # one tap; the dithered soft filters look noisy when upscaled
	RenderingServer.SHADOW_QUALITY_SOFT_LOW,
	RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
]
## Group the applier puts every DirectionalLight3D in, and where it remembers that the light
## casts shadows when the setting allows it (a light that never had shadows never gains them).
const SUN_GROUP := &"sun"
const META_WANTS_SHADOW := &"settings_apply_shadow"
const RENDER_SCALE_MIN: float = 0.5

## "section/key" -> value used instead of the stored setting (dev flags, tests).
var overrides: Dictionary = {}

var _headless: bool = false
## The command line asked for a window (--resolution, --fullscreen, ...), a vsync mode or an
## FPS cap: startup leaves that alone. Changing the option in the menu still applies.
var _cli_window: bool = false
var _cli_vsync: bool = false
var _cli_fps: bool = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_headless = DisplayServer.get_name() == "headless"
	for arg: String in OS.get_cmdline_args():
		if arg in ["--resolution", "--position", "-f", "--fullscreen", "-m", "--maximized", "-w", "--windowed"]:
			_cli_window = true
		elif arg == "--disable-vsync":
			_cli_vsync = true
		elif arg == "--max-fps" or arg == "--fixed-fps":
			_cli_fps = true
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			var preset := arg.get_slice("=", 1)
			if PRESETS.has(preset):
				for key: String in PRESETS[preset]:
					overrides["graphics/" + key] = PRESETS[preset][key]
			else:
				push_warning("SettingsApply: unknown --quality=%s" % preset)
	_ensure_buses()
	get_tree().node_added.connect(_on_node_added)
	Settings.changed.connect(_on_setting_changed)
	apply_all(true)

## The setting as it is applied: an override if there is one, else the stored value.
func value(section: String, key: String) -> Variant:
	var id := section + "/" + key
	if overrides.has(id):
		return overrides[id]
	return Settings.get_value(section, key)

func apply_all(startup: bool = false) -> void:
	apply_window(startup)
	apply_frame_pacing(startup)
	apply_quality()
	apply_audio()

# --- presets ---

## Name of the preset the current graphics settings match, or PRESET_CUSTOM.
func current_preset() -> String:
	for preset: String in PRESET_ORDER:
		var matches := true
		for key: String in PRESETS[preset]:
			if not is_equal_approx(float(Settings.get_value("graphics", key)), float(PRESETS[preset][key])):
				matches = false
				break
		if matches:
			return preset
	return PRESET_CUSTOM

func apply_preset(preset: String) -> void:
	if not PRESETS.has(preset):
		return
	for key: String in PRESETS[preset]:
		Settings.set_value("graphics", key, PRESETS[preset][key])

# --- display ---

## "1600x900" -> Vector2i(1600, 900); anything malformed gives the default resolution.
static func parse_resolution(text: String) -> Vector2i:
	var parts := text.to_lower().split("x")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		var size := Vector2i(int(parts[0]), int(parts[1]))
		if size.x >= 320 and size.y >= 200:
			return size
	return Vector2i(1600, 900)

func apply_window(startup: bool = false) -> void:
	if _headless or not Bootstrap.screenshot_path.is_empty() or (startup and _cli_window):
		return
	var mode := DisplayServer.window_get_mode()
	var is_full := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if value("graphics", "fullscreen"):
		if not is_full:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if mode != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# Sized on the next idle step: a window that just left fullscreen ignores an immediate resize.
	_apply_window_size.call_deferred()

func _apply_window_size() -> void:
	if value("graphics", "fullscreen") or DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var size := parse_resolution(value("graphics", "resolution"))
	var screen := DisplayServer.window_get_current_screen()
	var screen_size := DisplayServer.screen_get_size(screen)
	if screen_size.x > 0 and screen_size.y > 0:
		size = size.min(screen_size)
	if DisplayServer.window_get_size() == size:
		return
	DisplayServer.window_set_size(size)
	if screen_size.x > 0 and screen_size.y > 0:
		DisplayServer.window_set_position(DisplayServer.screen_get_position(screen) + (screen_size - size) / 2)

func apply_frame_pacing(startup: bool = false) -> void:
	if not (startup and _cli_fps):
		Engine.max_fps = maxi(0, int(value("graphics", "fps_cap")))
	if _headless or (startup and _cli_vsync):
		return
	var vsync: bool = value("graphics", "vsync")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)

# --- 3D quality ---

func apply_quality() -> void:
	var vp := get_tree().root
	vp.msaa_3d = clampi(int(value("graphics", "msaa")), Viewport.MSAA_DISABLED, Viewport.MSAA_8X) as Viewport.MSAA
	vp.scaling_3d_scale = clampf(float(value("graphics", "render_scale")), RENDER_SCALE_MIN, 1.0)
	var level := shadow_level()
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_ATLAS[level], true)
	RenderingServer.directional_soft_shadow_filter_set_quality(SHADOW_FILTER[level] as RenderingServer.ShadowQuality)
	for node: Node in get_tree().get_nodes_in_group(SUN_GROUP):
		_apply_light(node as DirectionalLight3D, level)

func shadow_level() -> int:
	return clampi(int(value("graphics", "shadows")), 0, SHADOW_ATLAS.size() - 1)

## Every directional light joins the `sun` group as it enters the tree (world scenes are not
## edited for this) and gets the current shadow setting.
func _on_node_added(node: Node) -> void:
	if node is DirectionalLight3D:
		var light := node as DirectionalLight3D
		light.add_to_group(SUN_GROUP)
		_apply_light(light, shadow_level())

func _apply_light(light: DirectionalLight3D, level: int) -> void:
	if light == null:
		return
	# Remembered once seen casting shadows (also when a script enables them later), so "off"
	# can be undone; a light that never cast shadows is left without them.
	var wants: bool = light.shadow_enabled or light.get_meta(META_WANTS_SHADOW, false)
	light.set_meta(META_WANTS_SHADOW, wants)
	light.shadow_enabled = wants and level > 0

# --- audio ---

## Linear slider value (0..1) -> bus volume in dB. 0 maps to MUTE_DB (and the bus is muted).
static func linear_to_bus_db(linear: float) -> float:
	if linear <= 0.0:
		return MUTE_DB
	return maxf(MUTE_DB, linear_to_db(minf(linear, 1.0)))

func apply_audio() -> void:
	for key: String in BUSES:
		var idx := AudioServer.get_bus_index(BUSES[key])
		if idx < 0:
			continue
		var linear := float(value("audio", key))
		AudioServer.set_bus_volume_db(idx, linear_to_bus_db(linear))
		AudioServer.set_bus_mute(idx, linear <= 0.0)

## The buses normally come from default_bus_layout.tres; create any that are missing so volume
## changes never hit a bus that is not there.
func _ensure_buses() -> void:
	for key: String in BUSES:
		var bus: StringName = BUSES[key]
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus)
			AudioServer.set_bus_send(idx, &"Master")

func _on_setting_changed(section: String, key: String) -> void:
	# A setting changed by hand wins over a dev override of the same key.
	overrides.erase(section + "/" + key)
	if section == "audio":
		apply_audio()
	elif section == "graphics":
		match key:
			"fullscreen", "resolution":
				apply_window()
			"vsync", "fps_cap":
				apply_frame_pacing()
			_:
				apply_quality()
