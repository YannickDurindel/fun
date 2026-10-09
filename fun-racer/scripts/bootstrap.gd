extends Node
## Global bootstrap: registers input actions and handles dev command-line flags.
##   --autodrive          scripted full throttle with a gentle weave (for screenshots/tests)
##   --screenshot=PATH    save the viewport to PATH after --frames frames, then quit
##   --frames=N           frame count for --screenshot (default 120)
##   --screen=NAME        open the menu on this screen (see scripts/menu/menu_router.gd)
##   --track=ID           skip the menu and race this track (see scripts/game.gd for more)
##   --handling=MODEL     arcade or simulation car physics for this run
##   --no-countdown       race scene starts immediately (no 3-2-1-GO)
##   --spawn_s=METRES     on a track, spawn the car this far around the lap (race scene)

var autodrive: bool = false
var screenshot_path: String = ""
## True for automated runs (--screenshot, --autodrive, --no-save, or the test runner): nothing
## is written to the player's save data (settings, last race, best laps, ghosts).
var dev_run: bool = false
var screenshot_frames: int = 120
var _frame: int = 0
var spawn_s: float = -1.0
## --screen=NAME: menu screen to open directly (main, tracks, race_options, settings, controls, records).
var start_screen: String = ""
## When true the race starts immediately (no 3-2-1 countdown). Set by --no-countdown and by
## the test runner so race-scene tests can drive straight away.
var skip_countdown: bool = false
## Optional driver used by --autodrive instead of the fixed weave. Any object with
## get_throttle() / get_brake() / get_steer() -> float (e.g. a track follower / autopilot).
var autodrive_provider: Object = null

func _ready() -> void:
	_register_inputs()
	if Settings.is_node_ready():
		_on_settings_ready()
	else:
		Settings.ready.connect(_on_settings_ready, CONNECT_ONE_SHOT)
	# Run as a main-loop script (-s: the test runner and the tools): never the player's session.
	if OS.get_cmdline_args().has("-s") or OS.get_cmdline_args().has("--script"):
		dev_run = true
	for arg: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg == "--no-save":
			dev_run = true
		if arg == "--autodrive":
			autodrive = true
			dev_run = true
		elif arg.begins_with("--screenshot="):
			screenshot_path = arg.get_slice("=", 1)
			dev_run = true
		elif arg.begins_with("--frames="):
			screenshot_frames = int(arg.get_slice("=", 1))
		elif arg.begins_with("--screen="):
			start_screen = arg.get_slice("=", 1)
		elif arg == "--no-countdown":
			skip_countdown = true
		elif arg.begins_with("--handling="):
			handling_override = StringName(arg.get_slice("=", 1))
		elif arg.begins_with("--spawn_s="):
			spawn_s = float(arg.get_slice("=", 1))

## Input actions come from InputBindings (default table + the player's rebinds in Settings).
## Bootstrap loads before Settings, so the defaults go in first and the saved bindings and
## gamepad dead zone follow as soon as Settings is ready, then on every change.
func _register_inputs() -> void:
	InputBindings.apply_overrides({})

func _on_settings_ready() -> void:
	InputBindings.apply()
	if not Settings.changed.is_connected(_on_setting_changed):
		Settings.changed.connect(_on_setting_changed)

func _on_setting_changed(section: String, key: String) -> void:
	if section == InputBindings.SECTION and (key == InputBindings.KEY or key == "gamepad_deadzone"):
		InputBindings.apply()

## Driver inputs, overridden by autodrive. Car reads these instead of Input directly.
## --handling=arcade|simulation: forces the car's handling model for this run.
var handling_override: StringName = &""
## An external analog controller (the phone): any object with
##   is_active() -> bool, get_throttle() -> float, get_brake() -> float, get_steer() -> float,
##   take_button(name: StringName) -> bool   (true once per press),
##   is_button_down(name: StringName) -> bool
## While it is active its values are combined with the keyboard / gamepad (the larger wins).
var external_input: Object = null

func _external() -> Object:
	if is_instance_valid(external_input) and external_input.call(&"is_active"):
		return external_input
	return null

## One-shot button of the external controller (shift_up, shift_down, respawn, pause ...).
func take_button(button: StringName) -> bool:
	var e := _external()
	return e != null and bool(e.call(&"take_button", button))

func is_button_down(button: StringName) -> bool:
	var e := _external()
	return e != null and bool(e.call(&"is_button_down", button))

func get_throttle() -> float:
	if autodrive:
		return _provider().get_throttle() if _provider() else 1.0
	var e := _external()
	return maxf(Input.get_action_strength("accelerate"), float(e.call(&"get_throttle")) if e else 0.0)

func get_brake() -> float:
	if autodrive:
		return _provider().get_brake() if _provider() else 0.0
	var e := _external()
	return maxf(Input.get_action_strength("brake"), float(e.call(&"get_brake")) if e else 0.0)

## -1 = full left, +1 = full right.
func get_steer() -> float:
	if autodrive:
		return _provider().get_steer() if _provider() else sin(Time.get_ticks_msec() / 1500.0) * 0.3
	var local := Input.get_axis("steer_left", "steer_right")
	var e := _external()
	if e != null:
		var ext := float(e.call(&"get_steer"))
		return ext if absf(ext) > absf(local) else local
	return local

## True when steering comes from keys (all-or-nothing), so the car can ramp it progressively.
## A gamepad stick or the autodrive provider is analog and is followed directly.
func is_steer_digital() -> bool:
	if autodrive:
		return false
	if _external() != null and absf(float(_external().call(&"get_steer"))) > 0.001:
		return false
	var l := Input.get_action_strength("steer_left")
	var r := Input.get_action_strength("steer_right")
	return (l == 0.0 or l == 1.0) and (r == 0.0 or r == 1.0)

func _provider() -> Object:
	return autodrive_provider if is_instance_valid(autodrive_provider) else null

func _process(_delta: float) -> void:
	if screenshot_path.is_empty():
		return
	_frame += 1
	if _frame == screenshot_frames:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(screenshot_path)
		print("Screenshot saved to %s (err=%d)" % [screenshot_path, err])
		get_tree().quit()
