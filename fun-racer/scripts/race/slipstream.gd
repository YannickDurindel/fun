class_name Slipstream
extends Node
## The tow: every physics tick, sets `sim.state.tow` (0..1) of each simulation car from the
## wake of the cars ahead. SimAero turns it into less drag and, more strongly, less downforce.
##
## The wake of a car trails behind it along the path it has just driven (an arc from its
## velocity and yaw rate, so it follows the road through a corner): full strength from
## `full_from` to `full_until` metres behind its centre, fading to nothing at `reach`; narrow
## laterally, widening slowly with distance. A follower takes the strongest wake it sits in (in practice
## the nearest car ahead). Any Car makes a wake, whatever its handling; only cars with a
## simulation model receive a tow.
##
## Instance one in the race scene (anywhere in the tree; it finds the cars itself and tracks
## the ones added or removed later). With fewer than two cars it does nothing. state.tow is
## only written while this node is in the tree; it is cleared when the node leaves.

## Behind this distance (m, centre to centre) the wake starts; cars side by side get no tow.
@export var start_distance: float = 2.5
## Full strength between these two distances behind the leading car (m).
@export var full_from: float = 5.0
@export var full_until: float = 10.0
## No tow beyond this distance (m).
@export var reach: float = 70.0
## Half-width of the wake at the car (m) and how much it widens per metre behind.
@export var half_width: float = 1.3
@export var spread: float = 0.02
## Cars more than this apart in height do not share air (bridges, tunnels) (m).
@export var max_height_gap: float = 3.0
## A wake needs speed: none below `min_speed`, full from `full_speed` (m/s).
@export var min_speed: float = 10.0
@export var full_speed: float = 40.0
## The wake never bends tighter than this radius (m): a spinning car leaves a straight wake.
@export var min_wake_radius: float = 25.0

var _cars: Array[Car] = []
var _pos: PackedVector3Array = PackedVector3Array()
var _vel: PackedVector3Array = PackedVector3Array()
var _yaw: PackedFloat32Array = PackedFloat32Array()
var _cleared: bool = true

func _enter_tree() -> void:
	_cars.clear()
	_collect(get_tree().root)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)

func _exit_tree() -> void:
	var tree := get_tree()
	if tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)
		tree.node_removed.disconnect(_on_node_removed)
	_clear_tows()
	_cars.clear()

func _collect(node: Node) -> void:
	if node is Car:
		_cars.append(node as Car)
	for child in node.get_children():
		_collect(child)

func _on_node_added(node: Node) -> void:
	if node is Car and not _cars.has(node):
		_cars.append(node as Car)

func _on_node_removed(node: Node) -> void:
	if node is Car:
		var car := node as Car
		if car.sim != null:
			car.sim.state.tow = 0.0
		_cars.erase(car)

## Number of cars being tracked.
func car_count() -> int:
	return _cars.size()

## Strength 0..1 of the wake of a car moving at `lead_velocity` and turning at
## `lead_yaw_rate` (rad/s, + = left), at the point `offset` (m) from its centre.
func wake_at(offset: Vector3, lead_velocity: Vector3, lead_yaw_rate: float = 0.0) -> float:
	var v := lead_velocity.length()
	if v <= min_speed:
		return 0.0
	var behind := -offset.dot(lead_velocity) / v
	if behind <= start_distance or behind >= reach:
		return 0.0
	var side := offset + lead_velocity * (behind / v)
	if absf(side.y) > max_height_gap:
		return 0.0
	# The path the leader came along curves towards the inside of its turn.
	var curvature := clampf(lead_yaw_rate / v, -1.0 / min_wake_radius, 1.0 / min_wake_radius)
	var left := Vector3.UP.cross(lead_velocity) / v
	side -= left * (0.5 * curvature * behind * behind)
	side.y = 0.0
	var width := half_width + spread * behind
	var lateral := 1.0 - side.length_squared() / (width * width)
	if lateral <= 0.0:
		return 0.0
	var along := 1.0
	if behind < full_from:
		along = (behind - start_distance) / maxf(full_from - start_distance, 1e-3)
	elif behind > full_until:
		along = (reach - behind) / maxf(reach - full_until, 1e-3)
		along *= along
	var pace := clampf((v - min_speed) / maxf(full_speed - min_speed, 1e-3), 0.0, 1.0)
	return along * lateral * pace

func _physics_process(_delta: float) -> void:
	var n := _cars.size()
	if n < 2:
		if not _cleared:
			_clear_tows()
		return
	if _pos.size() != n:
		_pos.resize(n)
		_vel.resize(n)
		_yaw.resize(n)
	for i in n:
		_pos[i] = _cars[i].global_position
		_vel[i] = _cars[i].linear_velocity
		_yaw[i] = _cars[i].angular_velocity.y
	var reach_sq := reach * reach
	for i in n:
		var car := _cars[i]
		if car.sim == null:
			continue
		var tow := 0.0
		var at := _pos[i]
		for j in n:
			if j == i:
				continue
			var offset := at - _pos[j]
			if offset.length_squared() >= reach_sq:
				continue
			tow = maxf(tow, wake_at(offset, _vel[j], _yaw[j]))
		car.sim.state.tow = tow
	_cleared = false

func _clear_tows() -> void:
	for car in _cars:
		if car.sim != null:
			car.sim.state.tow = 0.0
	_cleared = true
