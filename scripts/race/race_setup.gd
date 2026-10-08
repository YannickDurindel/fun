extends Node3D
## Race scene root: places the car on the grid (or at --spawn_s) of the Track, then hands
## the car to the Track's RaceManager (`Race` slot) to run the countdown and lap timing.

@export var car_path: NodePath = ^"Car"
@export var track_path: NodePath = ^"Track"
@export var grid_lateral: float = -2.5   ## pole position sits left of centre

func _ready() -> void:
	var car := get_node_or_null(car_path) as Car
	var track := get_node_or_null(track_path) as Track
	if car == null or track == null or track.data == null:
		return
	var s := track.data.start_s - 8.0 if Bootstrap.spawn_s < 0.0 else Bootstrap.spawn_s
	var xf := track.spawn_transform(s, grid_lateral if Bootstrap.spawn_s < 0.0 else 0.0)
	car.global_transform = xf
	car.spawn_transform = xf
	car.reset_physics_interpolation()
	var race := track.get_node_or_null(^"Race")
	if race != null and race.has_method(&"begin"):
		race.call(&"begin", car, xf)
