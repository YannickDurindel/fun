class_name Track
extends Node3D
## Root of a track scene. Loads the centreline (TrackData) and exposes it to every system.
## Child slots (each owned by one subsystem): Road, Trackside, Terrain, Race.

## Catalog id of this track (folder name under assets/tracks/).
@export var track_id: String = "red_bull_ring"
@export_file("*.json") var track_json: String = "res://assets/tracks/red_bull_ring/track.json"

var data: TrackData

func _enter_tree() -> void:
	# Loaded in _enter_tree so children can use it in their own _ready.
	add_to_group(&"track")
	data = TrackData.load_track(track_json)

## Car spawn transform at distance s: on the road surface, `lateral` metres right of centre,
## origin raised to the Car's axle height (wheel centres at local y = 0).
func spawn_transform(s: float, lateral: float = 0.0) -> Transform3D:
	var xf := data.sample(s)
	xf.origin += xf.basis.x * lateral + xf.basis.y * (Car.REAR_WHEEL_RADIUS + 0.05)
	return xf
