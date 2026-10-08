extends Node3D
## Race scene root (scenes/race.tscn). Builds the race the player chose:
##   1. instances the track scene of `track_id` (default: Game.config.track_id) as child "Track",
##   2. places the car on the grid (or at --spawn_s),
##   3. hands the car to the Track's RaceManager (`Race` slot) with the race options,
##   4. tells Game the race is ready.
## Other systems find things by node name (Track, Car, ChaseCamera, UI, FX) or by group
## ("track", "race_manager").

## Leave empty to use Game.config.track_id (set by the menus or --track=ID).
@export var track_id: String = ""
@export var car_path: NodePath = ^"Car"
@export var grid_lateral: float = -2.5   ## pole position sits left of centre

var track: Track

func _enter_tree() -> void:
	# The track must exist before the other children run _ready (they look it up by group).
	if get_node_or_null(^"Track") != null:
		track = get_node(^"Track") as Track
		return
	var id := track_id if not track_id.is_empty() else Game.config.track_id
	var info := TrackCatalog.find(id)
	if info == null or not info.available:
		push_error("Race: track '%s' is not available" % id)
		return
	if track_id.is_empty():
		track_id = id
	else:
		Game.config.track_id = id   # scene opened directly for one track (alias scenes, tests)
	track = (load(info.scene) as PackedScene).instantiate() as Track
	if track.track_id.is_empty():
		# The generic track scene: tell it which folder to build, before it enters the tree.
		track.track_id = info.id
		track.track_dir = info.dir()
		track.track_json = info.track_json
	track.name = "Track"
	add_child(track)
	move_child(track, 1)

func _ready() -> void:
	var car := get_node_or_null(car_path) as Car
	if car == null or track == null or track.data == null:
		return
	var s := track.data.start_s - 8.0 if Bootstrap.spawn_s < 0.0 else Bootstrap.spawn_s
	var xf := track.spawn_transform(s, grid_lateral if Bootstrap.spawn_s < 0.0 else 0.0)
	car.global_transform = xf
	car.spawn_transform = xf
	car.reset_physics_interpolation()
	var cfg := Game.config
	var cam := get_node_or_null(^"ChaseCamera")
	if cam != null and cam.has_method(&"set_mode") and not _has_flag("--camera="):
		cam.call(&"set_mode", cfg.camera)
	var race := track.get_node_or_null(^"Race")
	if race != null and race.has_method(&"begin"):
		if &"countdown_enabled" in race:
			race.set(&"countdown_enabled", cfg.countdown)
		if &"target_laps" in race:
			race.set(&"target_laps", cfg.laps if cfg.mode == RaceConfig.MODE_RACE else 0)
		race.call(&"begin", car, xf)
	Game.notify_race_ready()

func _has_flag(prefix: String) -> bool:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return true
	return false

func _unhandled_input(event: InputEvent) -> void:
	# Until a pause menu exists (group "pause_menu"), Esc goes back to the track list.
	if event.is_action_pressed(&"ui_cancel") and get_tree().get_first_node_in_group(&"pause_menu") == null \
			and get_tree().current_scene == self:
		get_viewport().set_input_as_handled()
		Game.quit_to_menu("tracks")
