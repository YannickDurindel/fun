class_name Track
extends Node3D
## Root of the generic track scene (scenes/tracks/track.tscn). Everything is derived from one
## track folder: the centreline (track.json -> TrackData) is loaded here and the folder is
## handed to the child slots, which load their own files from it:
##   Road      road_mesh.glb, road_profile.json, road_tarmac.tres   (scripts/track/road.gd)
##   Trackside trackside_profiles.json                              (scripts/track/trackside.gd)
##   Terrain   terrain.json + terrain_*.bin                         (scripts/track/terrain.gd)
##   Race      the RaceManager
##   Scenery   scenery.json, scenery.glb, scenery_points.bin, landmarks.json  (scripts/track/scenery.gd)
## Every file except track.json is optional: each slot has a fallback.
## The Scenery slot is not in the track scenes: it is added here in _ready, after the other
## slots, so every track scene (inherited or a standalone copy) gets it. The track's look
## (environment.json -> TrackEnvironment: time of day, sun, sky, fog, colours) is loaded in
## _enter_tree for the slots to read, and applied to the race scene's SkyEnvironment in _ready.
## Set `track_id` before the node enters the tree (a wrapper scene, or race_setup.gd).

## Catalog id of this track = folder name under assets/tracks/.
@export var track_id: String = ""
## Optional: track folder outside assets/tracks/ (test fixtures). Empty = assets/tracks/<track_id>.
@export_dir var track_dir: String = ""

## Path of the loaded centreline (derived from the folder; set it before entering the tree
## only to load a different file).
var track_json: String = ""
var data: TrackData
## The track's look: always set (the defaults when the folder has no environment.json).
var environment: TrackEnvironment
## scenery.json of the track folder as Scenery.load_meta() returns it ({} without one).
var scenery_meta: Dictionary = {}
var scenery: Scenery

func _enter_tree() -> void:
	# Loaded in _enter_tree so children can use it in their own _ready.
	add_to_group(&"track")
	if environment == null:
		environment = TrackEnvironment.new()
	if track_id.is_empty() and not track_dir.is_empty():
		track_id = track_dir.trim_suffix("/").get_file()
	if track_id.is_empty():
		push_error("Track: no track_id set (set it before the track enters the tree)")
		return
	if track_json.is_empty():
		track_json = file_path("track.json")
	if data == null:
		data = TrackData.load_track(track_json)
	environment = TrackEnvironment.load_file(scenery_path(TrackEnvironment.FILE), Bootstrap.time_override)
	scenery_meta = Scenery.load_meta(scenery_path(Scenery.META_FILE))

func _ready() -> void:
	if environment.active:
		environment.apply(find_sky(), self)
	if scenery == null:
		scenery = Scenery.new()
		scenery.name = "Scenery"
		add_child(scenery)

func _exit_tree() -> void:
	if environment != null:
		environment.restore()

## The sky scene (a node with a WorldEnvironment child, scenes/world/sky_environment.tscn)
## next to this track: its sibling in the race scene. Null when the track stands alone (tests).
func find_sky() -> Node:
	if get_parent() == null:
		return null
	for sibling in get_parent().get_children():
		for c in sibling.get_children():
			if c is WorldEnvironment:
				return sibling
	return null

## The track's asset folder.
func dir() -> String:
	if not track_dir.is_empty():
		return track_dir.trim_suffix("/")
	return "%s/%s" % [TrackCatalog.TRACKS_DIR, track_id]

## Path of a file in the track folder (it may not exist: every file but track.json is optional).
func file_path(file: String) -> String:
	return dir().path_join(file)

## Path of a scenery file (environment.json, scenery.*, landcover*.png, landmarks...): in the
## track folder, or in the folder given with --scenery-dir. Empty with --no-scenery.
func scenery_path(file: String) -> String:
	if Bootstrap.no_scenery:
		return ""
	if not Bootstrap.scenery_dir.is_empty():
		return Bootstrap.scenery_dir.path_join(file)
	return file_path(file)

## Car spawn transform at distance s: on the road surface, `lateral` metres right of centre,
## origin raised to the Car's axle height (wheel centres at local y = 0). On a track with
## declared banking the frame is the banked road plane (TrackData.sample), so the car starts
## flat on the banking; elsewhere the crossfall (at most 0.03 rad) is left to the suspension.
func spawn_transform(s: float, lateral: float = 0.0) -> Transform3D:
	var xf := data.sample(s)
	xf.origin += xf.basis.x * lateral + xf.basis.y * (Car.REAR_WHEEL_RADIUS + 0.05)
	return xf
