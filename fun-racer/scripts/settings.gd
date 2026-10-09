extends Node
## Autoload `Settings`: persistent player settings (user://settings.cfg).
## Every key has a typed default below; unknown keys are rejected so typos fail loudly.
## Systems read with get_value(), react to `changed`, and never touch the file themselves.

signal changed(section: String, key: String)

const PATH := "user://settings.cfg"

const DEFAULTS: Dictionary = {
	"graphics": {
		"fullscreen": false,
		"resolution": "1600x900",   # window size when not fullscreen
		"vsync": true,
		"fps_cap": 0,               # 0 = uncapped
		"msaa": 2,                  # Viewport.MSAA_*: 0 off, 1 2x, 2 4x, 3 8x
		"shadows": 2,               # 0 off, 1 low, 2 medium, 3 high
		"render_scale": 1.0,        # 3D resolution scale, 0.5 .. 1.0
	},
	"audio": {
		"master": 1.0,              # linear 0..1 per bus
		"engine": 0.8,
		"fx": 0.8,                  # tyres, wind
		"ui": 0.7,
	},
	"controls": {
		"key_steer_in_time": 0.40,  # s for keyboard steering to reach full lock
		"key_steer_out_time": 0.12, # s to recentre
		"gamepad_deadzone": 0.15,
		"bindings": {},             # action -> Array of serialized events (empty = defaults)
		# Phone as a controller (scripts/phone/phone_controller.gd). Nothing listens while off.
		"phone_enabled": false,
		"phone_port": 8080,         # HTTP + WebSocket
		"phone_https_port": 8443,   # same page over TLS (iPhone tilt); 0 = no HTTPS
		"phone_tilt_degrees": 40.0, # tilt for full lock, 15 .. 60
		"phone_deadzone": 0.04,     # steering ignored around the centre, 0 .. 0.3
		"phone_smoothing": 0.2,     # 0 = raw tilt, 1 = heavily filtered
	},
	"gameplay": {
		"speed_unit": "kmh",        # "kmh" or "mph"
		"show_input_display": true,
		"handling": "arcade",       # car physics: "arcade" or "simulation"
		"last_race": {},            # RaceConfig.to_dict() of the last started race
	},
}

## When false nothing is read from or written to disk (tests).
var persist: bool = true

var _values: Dictionary = {}

func _ready() -> void:
	_values = DEFAULTS.duplicate(true)
	if Bootstrap.dev_run:
		persist = false   # automated run: neither read nor write the player's settings
	load_from_disk()

func has_key(section: String, key: String) -> bool:
	return DEFAULTS.has(section) and (DEFAULTS[section] as Dictionary).has(key)

func get_value(section: String, key: String) -> Variant:
	if not has_key(section, key):
		push_error("Settings: unknown key %s/%s" % [section, key])
		return null
	return _values[section][key]

func default_value(section: String, key: String) -> Variant:
	return DEFAULTS[section][key] if has_key(section, key) else null

## Sets a value, emits `changed` if it differs. Call save() to persist.
func set_value(section: String, key: String, value: Variant) -> void:
	if not has_key(section, key):
		push_error("Settings: unknown key %s/%s" % [section, key])
		return
	if typeof(value) != typeof(DEFAULTS[section][key]) and not (value is float and DEFAULTS[section][key] is int) \
			and not (value is int and DEFAULTS[section][key] is float):
		push_error("Settings: wrong type for %s/%s" % [section, key])
		return
	if _values[section][key] == value:
		return
	_values[section][key] = value
	changed.emit(section, key)

## Restores a whole section to its defaults.
func reset(section: String) -> void:
	if not DEFAULTS.has(section):
		return
	for key: String in DEFAULTS[section]:
		var d: Variant = DEFAULTS[section][key]
		if d is Dictionary:
			d = (d as Dictionary).duplicate(true)
		elif d is Array:
			d = (d as Array).duplicate(true)
		set_value(section, key, d)

func save() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	for section: String in _values:
		for key: String in _values[section]:
			cf.set_value(section, key, _values[section][key])
	cf.save(PATH)

func load_from_disk() -> void:
	if not persist:
		return
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return
	for section: String in DEFAULTS:
		for key: String in DEFAULTS[section]:
			if cf.has_section_key(section, key):
				var v: Variant = cf.get_value(section, key)
				if typeof(v) == typeof(DEFAULTS[section][key]) or (v is float and DEFAULTS[section][key] is int) \
						or (v is int and DEFAULTS[section][key] is float):
					_values[section][key] = v
