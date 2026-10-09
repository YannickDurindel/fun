class_name Track
extends Node3D
## Root of the generic track scene (scenes/tracks/track.tscn). Everything is derived from one
## track folder: the centreline (track.json -> TrackData) is loaded here and the folder is
## handed to the child slots, which load their own files from it:
##   Road      road_mesh.glb, road_profile.json, road_tarmac.tres   (scripts/track/road.gd)
##   Trackside trackside_profiles.json                              (scripts/track/trackside.gd)
##   Terrain   terrain.json + terrain_*.bin                         (scripts/track/terrain.gd)
##   Race      the RaceManager
## Every file except track.json is optional: each slot has a fallback.
## Set `track_id` before the node enters the tree (a wrapper scene, or race_setup.gd).

## Catalog id of this track = folder name under assets/tracks/.
@export var track_id: String = ""
## Optional: track folder outside assets/tracks/ (test fixtures). Empty = assets/tracks/<track_id>.
@export_dir var track_dir: String = ""

## Path of the loaded centreline (derived from the folder; set it before entering the tree
## only to load a different file).
var track_json: String = ""
var data: TrackData

func _enter_tree() -> void:
	# Loaded in _enter_tree so children can use it in their own _ready.
	add_to_group(&"track")
	if track_id.is_empty() and not track_dir.is_empty():
		track_id = track_dir.trim_suffix("/").get_file()
	if track_id.is_empty():
		push_error("Track: no track_id set (set it before the track enters the tree)")
		return
	if track_json.is_empty():
		track_json = file_path("track.json")
	if data == null:
		data = TrackData.load_track(track_json)

## The track's asset folder.
func dir() -> String:
	if not track_dir.is_empty():
		return track_dir.trim_suffix("/")
	return "%s/%s" % [TrackCatalog.TRACKS_DIR, track_id]

## Path of a file in the track folder (it may not exist: every file but track.json is optional).
func file_path(file: String) -> String:
	return dir().path_join(file)

## Car spawn transform at distance s: on the road surface, `lateral` metres right of centre,
## origin raised to the Car's axle height (wheel centres at local y = 0). On a track with
## declared banking the frame is the banked road plane (TrackData.sample), so the car starts
## flat on the banking; elsewhere the crossfall (at most 0.03 rad) is left to the suspension.
func spawn_transform(s: float, lateral: float = 0.0) -> Transform3D:
	var xf := data.sample(s)
	xf.origin += xf.basis.x * lateral + xf.basis.y * (Car.REAR_WHEEL_RADIUS + 0.05)
	return xf
