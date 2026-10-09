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
## Scenery / screenshot flags (read by Track, Scenery, TrackEnvironment and the chase camera):
##   --cam-pos=x,y,z      fixed free camera at this world position ...
##   --cam-look=x,y,z     ... looking at this point (default: the car)
##   --overview           camera high above the circuit centre looking down at ~55 degrees,
##                        framing the whole lap; fog is pushed back for that shot
##   --time=day|dusk|night  lighting override, to compare one track at different times
##   --scenery-dir=PATH   read the scenery files (landcover, scenery.*, environment.json,
##                        landmarks) from this folder instead of the track folder
##   --no-scenery         ignore every scenery file (the plain look, for comparisons)
##   --tour=S1,S2,...     with --screenshot: one run, many pictures. After the --frames warm-up
##                        the car is put at each distance in turn and a picture is saved as
##                        PATH with "_<metres>" before the extension. --tour=every:400 takes
##                        one every 400 m round the lap. --tour-frames=N settles N frames
##                        (default 70) at each stop. Far quicker than one run per picture.
##   --bench=N            after the --frames warm-up, print the average frame time over N
##                        frames ("FRAMETIME ...") and quit (use with --disable-vsync)

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

## --cam-pos / --cam-look: a fixed free camera (see scripts/camera/chase_camera.gd).
var free_cam: bool = false
var cam_pos: Vector3 = Vector3.ZERO
var cam_look: Vector3 = Vector3.ZERO
var cam_has_look: bool = false
## --overview: the whole lap from above.
var overview: bool = false
## --time=day|dusk|night: lighting override ("" = what the track's environment.json says).
var time_override: String = ""
## --scenery-dir=PATH: folder the scenery files are read from instead of the track folder.
var scenery_dir: String = ""
## --no-scenery: no scenery file is read at all.
var no_scenery: bool = false
## --bench=N: frames to time after the warm-up (0 = off).
var bench_frames: int = 0
var _bench_start_usec: int = 0
## --tour: distances round the lap to photograph in one run; "every:N" is expanded on the track.
var tour: PackedFloat32Array = PackedFloat32Array()
var tour_every: float = 0.0
var tour_frames: int = 70
var _tour_i: int = -1
var _tour_wait: int = 0

func _ready() -> void:
	_register_inputs()
	if Settings.is_node_ready():
		_on_settings_ready()
	else:
		Settings.ready.connect(_on_settings_ready, CONNECT_ONE_SHOT)

## The flags are read in _init: the main scene enters the tree (and the race scene builds its
## track there) before any autoload's _ready runs.
func _init() -> void:
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
		elif arg.begins_with("--cam-pos="):
			cam_pos = _parse_vec3(arg.get_slice("=", 1))
			free_cam = true
		elif arg.begins_with("--cam-look="):
			cam_look = _parse_vec3(arg.get_slice("=", 1))
			cam_has_look = true
		elif arg == "--overview":
			overview = true
		elif arg.begins_with("--time="):
			time_override = arg.get_slice("=", 1)
		elif arg.begins_with("--scenery-dir="):
			scenery_dir = arg.get_slice("=", 1)
		elif arg == "--no-scenery":
			no_scenery = true
		elif arg.begins_with("--tour="):
			var spec := arg.get_slice("=", 1)
			if spec.begins_with("every:"):
				tour_every = maxf(float(spec.get_slice(":", 1)), 10.0)
			else:
				for part in spec.split(",", false):
					tour.append(float(part))
		elif arg.begins_with("--tour-frames="):
			tour_frames = maxi(5, int(arg.get_slice("=", 1)))
		elif arg.begins_with("--bench="):
			bench_frames = maxi(0, int(arg.get_slice("=", 1)))
			dev_run = true

## "x,y,z" -> Vector3 (missing or malformed parts are 0).
static func _parse_vec3(text: String) -> Vector3:
	var parts := text.split(",")
	var v := Vector3.ZERO
	for i in mini(parts.size(), 3):
		v[i] = float(parts[i])
	return v

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
	if screenshot_path.is_empty() and bench_frames == 0:
		return
	_frame += 1
	if (tour.size() > 0 or tour_every > 0.0) and not screenshot_path.is_empty():
		if _frame >= screenshot_frames:
			_tour_step()
		return
	if _frame == screenshot_frames:
		if not screenshot_path.is_empty():
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var err := img.save_png(screenshot_path)
			print("Screenshot saved to %s (err=%d)" % [screenshot_path, err])
		if bench_frames == 0:
			get_tree().quit()
		_bench_start_usec = Time.get_ticks_usec()   # after the screenshot, when both are asked for
	elif bench_frames > 0 and _frame == screenshot_frames + bench_frames:
		var ms := float(Time.get_ticks_usec() - _bench_start_usec) / 1000.0 / bench_frames
		print("FRAMETIME avg=%.2f ms (%.1f fps) over %d frames" % [ms, 1000.0 / maxf(ms, 1e-3), bench_frames])
		get_tree().quit()

## One step of --tour: move the car to the next stop, let the camera settle, save the picture.
func _tour_step() -> void:
	var track := get_tree().get_first_node_in_group(&"track") as Track
	var car := get_tree().get_first_node_in_group(&"car") as Car
	if car == null:
		car = get_tree().current_scene.find_child("Car", true, false) as Car
	if track == null or track.data == null or car == null:
		push_error("--tour needs a race scene with a track and a car")
		get_tree().quit(1)
		return
	if tour.is_empty():
		var s := 0.0
		while s < track.data.length:
			tour.append(s)
			s += tour_every
	if _tour_wait > 0:
		_tour_wait -= 1
		if _tour_wait > 0:
			return
		set_process(false)
		await RenderingServer.frame_post_draw
		var path := "%s_%05d.%s" % [screenshot_path.get_basename(), int(round(tour[_tour_i])), screenshot_path.get_extension()]
		var err := get_viewport().get_texture().get_image().save_png(path)
		print("Screenshot saved to %s (err=%d)" % [path, err])
		set_process(true)
	_tour_i += 1
	if _tour_i >= tour.size():
		get_tree().quit()
		return
	var xf := track.spawn_transform(fposmod(tour[_tour_i], track.data.length), 0.0)
	car.spawn_transform = xf
	car.respawn()
	_tour_wait = tour_frames
