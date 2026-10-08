extends Node
## PLACEHOLDER autodrive driver for track scenes: pure pursuit on the centreline with a crude
## curvature speed limit. Registers itself as Bootstrap.autodrive_provider.
## Replaced by the real autopilot (unit "Autopilot driver & full-lap validation").

@export var car_path: NodePath
@export var lookahead_base: float = 8.0
@export var lookahead_per_mps: float = 0.35
@export var lateral_g: float = 1.6

var _car: Car
var _track: Track
var _s: float = -1.0
var _throttle: float = 0.0
var _brake: float = 0.0
var _steer: float = 0.0

func _ready() -> void:
	_car = get_node_or_null(car_path) as Car
	_track = get_tree().get_first_node_in_group(&"track") as Track
	if Bootstrap.autodrive_provider == null:
		Bootstrap.autodrive_provider = self

func _exit_tree() -> void:
	if Bootstrap.autodrive_provider == self:
		Bootstrap.autodrive_provider = null

func _physics_process(_delta: float) -> void:
	if _car == null or _track == null or _track.data == null:
		return
	var d := _track.data
	var pos := _car.global_position
	_s = d.closest_s(pos, _s)
	var v := _car.linear_velocity.length()
	var target := d.position_at(_s + lookahead_base + v * lookahead_per_mps)
	var local := _car.global_transform.affine_inverse() * target
	var ang := atan2(local.x, -local.z)       # + = target to the right
	_steer = clampf(ang * 2.5, -1.0, 1.0)
	# Speed limit from the tightest curvature in the next stretch.
	var v_max := 140.0
	var probe := 10.0
	while probe < 40.0 + v * 2.0:
		var k := _curvature(d, _s + probe)
		var allowed := sqrt(lateral_g * 9.81 / maxf(k, 1e-4))
		# braking distance allowance (~3 g decel)
		v_max = minf(v_max, sqrt(allowed * allowed + 2.0 * 25.0 * probe))
		probe += 10.0
	_throttle = 1.0 if v < v_max * 0.97 else 0.0
	_brake = 1.0 if v > v_max * 1.05 else 0.0

func _curvature(d: TrackData, s: float) -> float:
	var a := d.tangent_at(s - 6.0)
	var b := d.tangent_at(s + 6.0)
	return a.angle_to(b) / 12.0

func get_throttle() -> float:
	return _throttle

func get_brake() -> float:
	return _brake

func get_steer() -> float:
	return _steer
