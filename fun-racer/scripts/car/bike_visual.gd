extends Node3D
## The two-wheel look of the motorcycle kit (CarKit.MOTO, scenes/car/moto_body_visual.tscn).
##
## The physics under a bike is the Car's (four ray-cast contacts close together, tuned like a
## bike; see CarKit.MOTO_KIT): it never leans or falls. Everything two-wheeled that shows is
## done here, on the visual only, from how the bike moves:
##   * lean: the bike and rider roll about the tyres' contact line by the angle that balances
##     the cornering, atan(lateral acceleration / g), up to the kit's lean_max_deg (60 deg);
##   * wheelie / stoppie: the front lifts a little about the rear contact when the drive is
##     close to the wheelie limit, the rear about the front contact under the hardest braking;
##   * the front wheel and fork steer about the raked steering axis, both wheels roll;
##   * the rider tucks in behind the screen on the straights, sits up on the brakes and hangs
##     off the inside in the corners.
## A Car ancestor gives the motion straight from its rigid body; anything else (the ghost, a bot
## moved on rails) is read from this node's own movement between frames.

const G: float = 9.81
const GROUND_Y: float = -0.36
const FRONT_AXLE := Vector3(0.0, -0.06, -0.725)
const REAR_AXLE := Vector3(0.0, -0.03, 0.725)
const FRONT_RADIUS: float = 0.30
const REAR_RADIUS: float = 0.33
## Steering axis: 24 deg of rake, up and back (car frame).
const STEER_AXIS := Vector3(0.0, 0.9135, 0.4067)
## Share of the Car's front steer angle the fork shows (a bike steers less than a car at speed).
const STEER_SHOW: float = 0.6
## Smoothing of the measured motion (s) and of the lean itself.
const MOTION_TIME: float = 0.05
const ACCEL_TIME: float = 0.12
const LEAN_TIME: float = 0.07
## Fastest roll rate (rad/s) of the visual lean.
const LEAN_RATE_MAX: float = 4.5
## Below this speed (m/s) the lean fades out (standing up at a standstill).
const LEAN_MIN_SPEED: float = 3.0
## Rider: torso pitch of the full tuck (deg, forward), of sitting up on the brakes (deg, back),
## hang-off sideways (m) and extra roll into the corner (deg) at full lean.
const TUCK_DEG: float = 17.0
const SIT_UP_DEG: float = 6.0
const TUCK_MIN_KMH: float = 110.0
const HANG_OFF: float = 0.17
const HANG_ROLL_DEG: float = 12.0
const RIDER_TIME: float = 0.25

## Current visual state: lean (rad, + = leaning to the right), pitch (rad, + = front up),
## tuck (0..1) and hang-off (-1 left .. 1 right).
var lean: float = 0.0
var pitch: float = 0.0
var tuck: float = 0.0
var hang: float = 0.0
## Filtered motion: forward speed (m/s), lateral (+ = right) and longitudinal acceleration.
var speed: float = 0.0
var accel_lat: float = 0.0
var accel_long: float = 0.0

var lean_max: float = deg_to_rad(60.0)
var wheelie_accel: float = 10.5
var stoppie_decel: float = 12.0
var wheelie_max: float = deg_to_rad(4.0)
var stoppie_max: float = deg_to_rad(3.0)

var _car: Car
var _prev: Transform3D
var _have_prev: bool = false
var _prev_speed: float = 0.0
var _spin_front: float = 0.0
var _spin_rear: float = 0.0

@onready var _lean_node: Node3D = $Lean
@onready var _pitch_node: Node3D = $Lean/Pitch
@onready var _fork: Node3D = $Lean/Pitch/Fork
@onready var _front_spin: Node3D = $Lean/Pitch/Fork/FrontSpin
@onready var _rear_spin: Node3D = $Lean/Pitch/RearSpin
@onready var _rider: Node3D = $Lean/Pitch/Rider
@onready var _torso: Node3D = $Lean/Pitch/Rider/Torso
var _rider_rest: Transform3D
var _torso_rest: Transform3D

func _ready() -> void:
	var n: Node = get_parent()
	while n != null and not (n is Car):
		n = n.get_parent()
	_car = n as Car
	var bike: Dictionary = CarKit.bike(CarKit.MOTO)
	lean_max = deg_to_rad(float(bike.get("lean_max_deg", 60.0)))
	wheelie_accel = float(bike.get("wheelie_accel", wheelie_accel))
	stoppie_decel = float(bike.get("stoppie_decel", stoppie_decel))
	wheelie_max = deg_to_rad(float(bike.get("wheelie_max_deg", 4.0)))
	stoppie_max = deg_to_rad(float(bike.get("stoppie_max_deg", 3.0)))
	_rider_rest = _rider.transform
	_torso_rest = _torso.transform
	if _car != null:
		_car.respawned.connect(reset)

## Upright, no motion (respawn, a teleported ghost).
func reset() -> void:
	lean = 0.0
	pitch = 0.0
	tuck = 0.0
	hang = 0.0
	speed = 0.0
	accel_lat = 0.0
	accel_long = 0.0
	_have_prev = false
	_apply()

func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	step(delta)

## Advances the look by `delta` seconds (tests call it directly).
func step(delta: float) -> void:
	_measure(delta)
	# Lean that balances the cornering, faded out at walking pace.
	var target := clampf(atan(accel_lat / G), -lean_max, lean_max)
	target *= clampf(absf(speed) / LEAN_MIN_SPEED, 0.0, 1.0)
	var want := lerpf(lean, target, 1.0 - exp(-delta / LEAN_TIME))
	lean = move_toward(lean, want, LEAN_RATE_MAX * delta)
	# Wheelie near the traction limit, stoppie under the hardest braking (simple limits: the
	# kit's acceleration and braking never pass them, so the bike never loops).
	var p := 0.0
	if accel_long > 0.0:
		p = wheelie_max * smoothstep(0.85 * wheelie_accel, wheelie_accel, accel_long)
	else:
		p = -stoppie_max * smoothstep(0.85 * stoppie_decel, stoppie_decel, -accel_long)
	pitch = lerpf(pitch, p, 1.0 - exp(-delta / 0.15))
	# Rider: tucked on a straight at speed, sitting up on the brakes, hanging off in a corner.
	var kr := 1.0 - exp(-delta / RIDER_TIME)
	var straight := 1.0 - smoothstep(deg_to_rad(6.0), deg_to_rad(18.0), absf(lean))
	var fast := smoothstep(TUCK_MIN_KMH * 0.6, TUCK_MIN_KMH, absf(speed) * 3.6)
	var braking := smoothstep(3.0, 7.0, -accel_long)
	tuck = lerpf(tuck, straight * fast * (1.0 - braking) - braking, kr)
	hang = lerpf(hang, clampf(lean / deg_to_rad(40.0), -1.0, 1.0), kr)
	# Wheels.
	_spin_front = fmod(_spin_front + speed / FRONT_RADIUS * delta, TAU)
	_spin_rear = fmod(_spin_rear + speed / REAR_RADIUS * delta, TAU)
	_apply()

func _measure(delta: float) -> void:
	var xf := global_transform
	var up := xf.basis.y.normalized()
	var fwd := -xf.basis.z.normalized()
	var v_fwd := 0.0
	var yaw_rate := 0.0
	if _car != null and _car.simulate and not _car.freeze:
		v_fwd = _car.linear_velocity.dot(fwd)
		yaw_rate = _car.angular_velocity.dot(up)
	elif _have_prev:
		v_fwd = (xf.origin - _prev.origin).dot(fwd) / delta
		var prev_fwd := -_prev.basis.z.normalized()
		yaw_rate = prev_fwd.signed_angle_to(fwd, up) / delta
		if absf(v_fwd) > 150.0:   # a teleport, not motion
			v_fwd = speed
			yaw_rate = 0.0
	_prev = xf
	var first := not _have_prev and (_car == null or not _car.simulate or _car.freeze)
	_have_prev = true
	if first:
		_prev_speed = v_fwd
		speed = v_fwd
		return
	var k := 1.0 - exp(-delta / MOTION_TIME)
	speed = lerpf(speed, v_fwd, k)
	# + to the right: a turn to the right (negative yaw rate) pushes the bike's path right.
	accel_lat = lerpf(accel_lat, -yaw_rate * v_fwd, k)
	var a := (speed - _prev_speed) / delta
	_prev_speed = speed
	accel_long = lerpf(accel_long, a, 1.0 - exp(-delta / ACCEL_TIME))

func _apply() -> void:
	if _lean_node == null:
		return
	# Lean about the contact line (car frame: x = 0, y = ground); + lean = roll to the right.
	var pivot := Vector3(0.0, GROUND_Y, 0.0)
	var r := Basis(Vector3.BACK, -lean)
	_lean_node.transform = Transform3D(r, pivot - r * pivot)
	# Pitch about the rear contact (wheelie) or the front contact (stoppie).
	var at := Vector3(0.0, GROUND_Y, REAR_AXLE.z if pitch >= 0.0 else FRONT_AXLE.z)
	var pb := Basis(Vector3.RIGHT, pitch)
	_pitch_node.transform = Transform3D(pb, at - pb * at)
	# Fork about the steering axis through the front axle.
	var steer := 0.0
	if _car != null and not _car.wheels.is_empty():
		steer = _car.wheels[0].steer_angle * STEER_SHOW
	_fork.transform = Transform3D(Basis(STEER_AXIS, steer), FRONT_AXLE)
	_front_spin.rotation.x = -_spin_front
	_rear_spin.rotation.x = -_spin_rear
	# Rider: hang off to the inside and roll a little more than the bike; tuck about the hips.
	var hb := Basis(Vector3.BACK, -hang * deg_to_rad(HANG_ROLL_DEG))
	_rider.transform = Transform3D(hb * _rider_rest.basis,
			_rider_rest.origin + Vector3(hang * HANG_OFF, -absf(hang) * 0.03, 0.0))
	var t := -tuck * deg_to_rad(TUCK_DEG) if tuck >= 0.0 else -tuck * deg_to_rad(SIT_UP_DEG)
	_torso.transform = Transform3D(Basis(Vector3.RIGHT, t) * _torso_rest.basis, _torso_rest.origin)
