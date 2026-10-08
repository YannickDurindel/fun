extends Node
## Autoload `Game`: the flow between the menus and a race.
##   Game.pending   the RaceConfig the menus are editing (remembered between sessions)
##   Game.config    the RaceConfig of the race being loaded / running
##   start_race(cfg) / restart_race() / quit_to_menu()
## Dev flags (after `--`): --track=ID skips the menu; --mode=race|time_attack, --laps=N,
## --bots=N, --difficulty=0..2, --ghost=0|1, --camera=1..3 fill the config.

signal race_loading(track: TrackInfo)   ## start_race() called, scene about to change
signal race_ready                                    ## race scene built, car on the grid
signal returned_to_menu
signal pause_changed(paused: bool)

const MENU_SCENE := "res://scenes/menu/menu.tscn"
const RACE_SCENE := "res://scenes/race.tscn"

var config: RaceConfig = RaceConfig.new()
var pending: RaceConfig = RaceConfig.new()
## True when --track=ID was given: boot straight into the race.
var skip_menu: bool = false
## Screen the menu opens on next time it loads (e.g. "tracks" after a race).
var menu_start_screen: String = ""
## Replaceable for tests: called with the scene path instead of changing scene.
var scene_changer: Callable = Callable()

func _enter_tree() -> void:
	# A scene opened from the command line (godot res://scenes/race.tscn -- --track=ID, as
	# tools/screenshot.sh does) enters the tree before _ready() runs here, and the race scene
	# picks its track in _enter_tree: the id has to be known by then.
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--track=") and not arg.get_slice("=", 1).is_empty():
			config.track_id = arg.get_slice("=", 1)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	pending.apply_dict(Settings.get_value("gameplay", "last_race"))
	if TrackCatalog.find(pending.track_id) == null or not TrackCatalog.find(pending.track_id).available:
		var playable := TrackCatalog.playable()
		if not playable.is_empty():
			pending.track_id = playable[0].id
	var flags := {}
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			flags[arg.get_slice("=", 0).trim_prefix("--")] = arg.get_slice("=", 1)
	if flags.has("track"):
		pending.track_id = flags["track"]
		skip_menu = true
	var d := {}
	if flags.has("mode"): d["mode"] = flags["mode"]
	if flags.has("laps"): d["laps"] = int(flags["laps"])
	if flags.has("bots"): d["bots"] = int(flags["bots"])
	if flags.has("difficulty"): d["bot_difficulty"] = int(flags["difficulty"])
	if flags.has("ghost"): d["ghost"] = flags["ghost"] != "0"
	if flags.has("camera"): d["camera"] = int(flags["camera"])
	pending.apply_dict(d)
	config = pending.copy()

func current_track() -> TrackInfo:
	return TrackCatalog.find(config.track_id)

## Starts a race with `cfg` (default: Game.pending). Remembers it as the last race.
func start_race(cfg: RaceConfig = null) -> void:
	if cfg != null:
		pending = cfg.copy()
	var info := TrackCatalog.find(pending.track_id)
	if info == null or not info.available:
		push_error("Game: track '%s' is not available" % pending.track_id)
		return
	if not _can_change_scene():
		return
	config = pending.copy()
	Settings.set_value("gameplay", "last_race", config.to_dict())
	Settings.save()
	set_paused(false)
	race_loading.emit(info)
	_change_scene(RACE_SCENE, info)

func restart_race() -> void:
	if not _can_change_scene():
		return
	set_paused(false)
	race_loading.emit(current_track())
	_change_scene(RACE_SCENE, current_track())

func quit_to_menu(screen: String = "") -> void:
	if not _can_change_scene():
		return
	set_paused(false)
	menu_start_screen = screen
	_change_scene(MENU_SCENE)
	returned_to_menu.emit()

func set_paused(paused: bool) -> void:
	if get_tree().paused == paused:
		return
	get_tree().paused = paused
	pause_changed.emit(paused)

## Called by the race scene once the track is built and the car is on the grid.
## The loading screen (Transitions) stays up until this, plus a few rendered frames.
func notify_race_ready() -> void:
	race_ready.emit()

## False while a scene transition is running: requests made then are dropped as a whole (no
## config change, no signals), since Transitions would ignore the scene change anyway.
func _can_change_scene() -> bool:
	return scene_changer.is_valid() or not Transitions.busy

## Scene changes go through the `Transitions` autoload: fade, loading screen when
## `loading_info` is given, threaded load. Instant when headless (see Transitions.is_instant).
func _change_scene(path: String, loading_info: TrackInfo = null) -> void:
	if scene_changer.is_valid():
		scene_changer.call(path)
	else:
		Transitions.change_scene(path, loading_info)
