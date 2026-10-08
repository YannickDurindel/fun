extends CanvasLayer
## Autoload `Transitions`: fades between scenes and the loading screen, on top of everything.
##   await Transitions.fade_out(0.2)        fade to black
##   await Transitions.fade_in(0.3)         fade back in
##   Transitions.change_scene(path, info)   fade out -> [loading screen for `info`: TrackInfo]
##                                          -> threaded load -> swap -> wait for Game.race_ready
##                                          -> fade in.  A request made while one runs is ignored.
## The SceneTree is paused from the request until the fade-in starts (this node keeps running).
## `Game` routes every scene change through change_scene() (unless Game.scene_changer is set).
##
## Instant rule (is_instant()): no fades, no threads, no loading screen, and the scene changes
## with a plain deferred change_scene_to_file, when
##   * the display driver is "headless" (tests, CI, --headless runs), or
##   * --screenshot=PATH is active with --frames below SCREENSHOT_INSTANT_BELOW (240), so
##     short screenshot runs capture the requested scene and not a fade.
## Longer screenshot runs (e.g. --frames=400 --track=ID) go through the real flow.
## `instant_override` (0 = animated, 1 = instant) forces either mode (tests).
##
## Dev flag (after `--`): --loading-demo (or --loading-demo=TIP_INDEX) shows the loading screen
## (for --track=ID, default the Red Bull Ring) at 60 % and holds it there, for screenshots.

signal started(path: String)
signal finished(path: String)

const LOADING_SCENE: PackedScene = preload("res://scenes/ui/loading.tscn")
const Loading := preload("res://scripts/ui/loading.gd")
const SCREENSHOT_INSTANT_BELOW: int = 240
## Share of the progress bar used by the threaded resource load; the rest is "building track".
const LOAD_SHARE: float = 0.8
const BUILD_PROGRESS: float = 0.88
## A frame quicker than this counts as "the scene runs smoothly now" (20 fps).
const SETTLE_FRAME_USEC: int = 50000

var fade_out_time: float = 0.18
var fade_in_time: float = 0.30
## Fade between black and the loading screen.
var cross_time: float = 0.14
## The loading screen stays at least this long so it never flashes by.
var min_loading_time: float = 0.8
## Give up waiting for Game.race_ready after this long (a scene that never reports ready).
var ready_timeout: float = 5.0
## Frames rendered under the cover after the new scene is ready (see _settle).
var settle_frames: int = 3
var settle_timeout: float = 2.0
## -1 = automatic (see the instant rule above), 0 = always animated, 1 = always instant.
var instant_override: int = -1

## True while a scene change is running.
var busy: bool = false
## The loading screen while it is shown, else null.
var loading: Loading
## Wall-clock duration of the last animated change_scene, in ms (-1 before the first).
var last_change_msec: int = -1

var _fade: ColorRect
var _holder: Control
var _fade_id: int = 0
var _ready_seen: bool = false
var _froze: bool = false
var _held: Array[Resource] = []   # keeps thread-loaded resources cached until the swap

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_holder = Control.new()
	_holder.name = "LoadingHolder"
	_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_holder)
	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.color = Color.BLACK
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_fade)
	_set_alpha(0.0)
	Game.race_ready.connect(func() -> void: _ready_seen = true)
	var demo_tip := -1
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--loading-demo" or arg.begins_with("--loading-demo="):
			demo_tip = maxi(0, int(arg.get_slice("=", 1)))
	if demo_tip >= 0:
		busy = true
		_loading_demo.call_deferred(demo_tip)
	elif Game.skip_menu and not is_instant():
		# --track=ID: go from black straight to the loading screen, without a menu flash.
		_set_alpha(1.0)
		_boot_guard()

func is_instant() -> bool:
	if instant_override >= 0:
		return instant_override == 1
	if DisplayServer.get_name() == "headless":
		return true
	return not Bootstrap.screenshot_path.is_empty() and Bootstrap.screenshot_frames < SCREENSHOT_INSTANT_BELOW

## Fades the screen to black. Instant when is_instant() or duration <= 0.
func fade_out(duration: float = 0.2) -> void:
	await _fade_to(1.0, duration)

## Fades from black back to the scene.
func fade_in(duration: float = 0.3) -> void:
	await _fade_to(0.0, duration)

## Changes to the scene at `path`. With `loading_info` (a TrackInfo) the loading screen is shown
## while the scene and the track load and until the race reports ready.
## Returns false, and does nothing, when a change is already running.
func change_scene(path: String, loading_info: TrackInfo = null) -> bool:
	if busy:
		return false
	started.emit(path)
	if is_instant():
		# No lock: as with a plain deferred change, the last request of a frame wins.
		_change_instant.call_deferred(path)
	else:
		busy = true
		_change_animated(path, loading_info)
	return true

func _change_instant(path: String) -> void:
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("Transitions: cannot change to %s (error %d)" % [path, err])
	finished.emit(path)

func _change_animated(path: String, info: TrackInfo) -> void:
	var t0 := Time.get_ticks_msec()
	var tree := get_tree()
	# The outgoing scene stops here (no more laps, records or engine sound under the cover) and
	# the incoming one starts only when the fade-in does, so the countdown is seen in full.
	_freeze(true)
	await _fade_to(1.0, fade_out_time)
	var paths: Array[String] = [path]
	if info != null:
		_show_loading(info)
		if not info.scene.is_empty() and info.scene != path and ResourceLoader.exists(info.scene):
			paths.append(info.scene)   # the race scene instances it in _enter_tree
	# Always at least one frame between the request and the swap (a scene's _ready may ask).
	await tree.process_frame
	if info != null:
		await _fade_to(0.0, cross_time)
	var packed := await _load_threaded(paths)
	_log("loaded", t0)
	if packed == null:
		push_error("Transitions: cannot load %s" % path)
		await _finish(path, t0)
		return
	if loading != null:
		loading.set_phase("BUILDING TRACK")
		loading.set_progress(BUILD_PROGRESS)
		await tree.process_frame   # let the caption draw before the swap blocks this thread
		await tree.process_frame
	_ready_seen = false
	if tree.change_scene_to_packed(packed) != OK:
		push_error("Transitions: cannot instantiate %s" % path)
		await _finish(path, t0)
		return
	await tree.scene_changed
	_log("swapped", t0)
	if info != null:
		# Game.race_ready: track meshes and collision built, car on the grid.
		var deadline := Time.get_ticks_msec() + int(ready_timeout * 1000.0)
		while not _ready_seen and Time.get_ticks_msec() < deadline:
			await tree.process_frame
		if not _ready_seen:
			push_warning("Transitions: %s never reported Game.race_ready" % path)
	_log("ready", t0)
	if loading != null:
		loading.set_progress(1.0, true)
	await _settle(info != null)
	_log("settled", t0)
	await _finish(path, t0)

## The first frames of a new scene are slow (pipeline compiles, uploads): they render under the
## cover, with the tree still paused. Waits `settle_frames` frames; for a race (`adaptive`) it
## then waits until 3 frames in a row are quick, at most `settle_timeout` seconds. "Quick" is
## under SETTLE_FRAME_USEC, or within 1.5x of the quickest frame seen, so a machine that simply
## runs slowly is not made to wait.
func _settle(adaptive: bool) -> void:
	var tree := get_tree()
	var deadline := Time.get_ticks_msec() + int(settle_timeout * 1000.0)
	var last := Time.get_ticks_usec()
	var best := 1 << 62
	var quick := 0
	var n := 0
	while n < settle_frames or (adaptive and quick < 3 and Time.get_ticks_msec() < deadline):
		await tree.process_frame
		var now := Time.get_ticks_usec()
		var dt := now - last
		last = now
		best = mini(best, dt)
		quick = quick + 1 if dt < maxi(SETTLE_FRAME_USEC, best * 3 / 2) else 0
		n += 1

## Common tail: drop the loading screen behind black, fade in, release the lock.
func _finish(path: String, t0: int) -> void:
	if loading != null:
		await _fade_to(1.0, cross_time)
		_hide_loading()
	_held.clear()
	_freeze(false)
	await _fade_to(0.0, fade_in_time)
	last_change_msec = Time.get_ticks_msec() - t0
	_log("done: %s" % path, t0)
	busy = false
	finished.emit(path)

## Loads `paths` on the resource loader threads and returns the first one as a PackedScene
## (null on failure). Updates the loading screen; honours min_loading_time while it is shown.
func _load_threaded(paths: Array[String]) -> PackedScene:
	for p in paths:
		if ResourceLoader.load_threaded_request(p, "", true) != OK:
			return null
	var shown_at := Time.get_ticks_msec()
	var tree := get_tree()
	while true:
		var total := 0.0
		var done := true
		for p in paths:
			var prog: Array = []
			match ResourceLoader.load_threaded_get_status(p, prog):
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					done = false
					total += float(prog[0]) if not prog.is_empty() else 0.0
				ResourceLoader.THREAD_LOAD_LOADED:
					total += 1.0
				_:
					return null
		var frac := total / paths.size()
		var waited := (Time.get_ticks_msec() - shown_at) / 1000.0
		if loading != null:
			# Never ahead of the minimum display time, so the bar does not jump and then sit.
			if min_loading_time > 0.0:
				frac = minf(frac, waited / min_loading_time)
			loading.set_progress(frac * LOAD_SHARE)
			if done and waited >= min_loading_time:
				break
		elif done:
			break
		await tree.process_frame
	for p in paths:
		_held.append(ResourceLoader.load_threaded_get(p))
	return _held[0] as PackedScene

func _show_loading(info: TrackInfo, first_tip: int = -1) -> void:
	_hide_loading()
	loading = LOADING_SCENE.instantiate() as Loading
	loading.setup(info, first_tip)
	loading.set_phase("LOADING TRACK")
	_holder.add_child(loading)

func _hide_loading() -> void:
	if loading != null:
		loading.queue_free()
		loading = null

func _loading_demo(tip: int) -> void:
	var info := TrackCatalog.find(Game.pending.track_id) if Game.skip_menu else null
	if info == null:
		info = TrackCatalog.find("red_bull_ring")
	_show_loading(info, tip)
	loading.rotate_tips = false
	loading.set_progress(0.6, true)
	_set_alpha(0.0)

## If the boot-time black cover is not picked up by a scene change, lift it.
func _boot_guard() -> void:
	await get_tree().create_timer(1.0).timeout
	if not busy:
		_fade_to(0.0, fade_in_time)

## Phase timings, with --verbose.
func _log(what: String, t0: int) -> void:
	if OS.is_stdout_verbose():
		print("Transitions: +%d ms %s (frame %d)" % [Time.get_ticks_msec() - t0, what, Engine.get_process_frames()])

## Pauses the SceneTree for the duration of the cover. Bypasses Game.set_paused on purpose:
## no pause_changed, so no pause menu opens. Only lifts a pause it set itself.
func _freeze(on: bool) -> void:
	var tree := get_tree()
	if on and not tree.paused:
		tree.paused = true
		_froze = true
	elif not on and _froze:
		tree.paused = false
		_froze = false

func _set_alpha(a: float) -> void:
	_fade.color.a = a
	_fade.visible = a > 0.0

## Hitch-proof fade: advances by the frame time, capped, so a long frame cannot skip it.
## A newer fade takes over from the current value.
func _fade_to(target: float, duration: float) -> void:
	_fade_id += 1
	var id := _fade_id
	var from := _fade.color.a
	if not is_instant() and duration > 0.0 and not is_equal_approx(from, target):
		var t := 0.0
		while t < duration:
			await get_tree().process_frame
			if id != _fade_id:
				return
			t += minf(get_process_delta_time(), 1.0 / 30.0)
			_set_alpha(lerpf(from, target, smoothstep(0.0, 1.0, t / duration)))
	_set_alpha(target)

## Nothing reaches the scene (keys, pad, mouse) while a transition covers it.
func _input(_event: InputEvent) -> void:
	if busy and not is_instant():
		get_viewport().set_input_as_handled()
