class_name AutoBrake
extends Node
## Brake assist (like Real Racing 3's): slows the player's car before a corner so it arrives
## at a sensible entry speed. It never steers and never takes the pedals away: it only cuts
## the throttle and adds brake on top of what the player does (the larger brake wins).
##
## The entry speeds are the autopilot's speed profile for this car on this track (corner
## limit + braking zones; shared with the bots through the Autopilot cache), read through a
## hidden Autopilot that never drives. Settings `gameplay/auto_brake`, applied live:
##   0 off; 1 LIGHT, 2 MEDIUM, 3 STRONG. The levels differ only in the speed they aim for
##   (LEVEL_SCALE x the profile): LIGHT arrives a little too fast (the player still has to
##   brake a bit), MEDIUM about right, STRONG a little too slow. Every level brakes as hard
##   as it must, so the gap between them stays small and the same everywhere.
##
## Arcade car: braking with a lot of steering above drift_min_speed_kmh starts a drift, so
## while the wheel is turned that far the assist keeps its brake under drift_brake_threshold.
##
## Use: AutoBrake.attach(car, track) (race_setup.gd does it for the player's car).

const SECTION := "gameplay"
const KEY := "auto_brake"
## Target speed = profile x this, per level (index = setting).
const LEVEL_SCALE: Array[float] = [0.0, 1.06, 1.0, 0.94]
## Profile read this far ahead (s at the current speed): pedal / tyre response lag.
const PREVIEW_TIME: float = 0.15
## m/s over the target that ask for full brake (the brake ramps up from 0 at the target).
const FULL_BRAKE_EXCESS: float = 3.0
## Below the target the throttle is limited over this band (m/s), so the car settles on
## the target instead of hunting around it.
const THROTTLE_BAND: float = 1.5
## Below this forward speed (m/s) the assist does nothing (standing starts, reversing).
const MIN_SPEED: float = 8.0

var level: int = 0
## What the assist did on the last tick (HUD / tests): brake added (0..1), throttle removed.
var brake: float = 0.0
var throttle_cut: float = 0.0
## Target speed (m/s) on the last tick, 0 when inactive.
var target: float = 0.0

var car: Car
var _ap: Autopilot
var _s: float = -1.0

## Adds an AutoBrake for `car` on `track` (as a child of the car) and returns it.
static func attach(p_car: Car, track: Track) -> AutoBrake:
	var ab := AutoBrake.new()
	ab.name = "AutoBrake"
	ab.car = p_car
	var ap := Autopilot.new()
	ap.name = "Plan"
	ap.mode = Autopilot.Mode.DIRECT
	ap.collect_stats = false
	ap.track = track
	ab._ap = ap
	ab.add_child(ap)
	p_car.add_child(ab)
	ap.set_physics_process(false)   # it only plans; it never drives
	ap.car = p_car
	p_car.auto_brake = ab
	return ab

func _ready() -> void:
	_read_setting()
	Settings.changed.connect(_on_setting_changed)
	if car != null:
		car.respawned.connect(func() -> void: _s = -1.0)

func _on_setting_changed(section: String, key: String) -> void:
	if section == SECTION and key == KEY:
		_read_setting()

func _read_setting() -> void:
	level = clampi(int(Settings.get_value(SECTION, KEY)), 0, LEVEL_SCALE.size() - 1)

## Called by the Car right after it read the player's pedals: lowers car.throttle and raises
## car.brake_input when the car is too fast for what is coming.
func apply(c: Car) -> void:
	brake = 0.0
	throttle_cut = 0.0
	target = 0.0
	if level == 0 or c.forward_speed < MIN_SPEED or not _ap.ensure_plan():
		return
	_s = _ap.closest_s(c.global_position, _s)
	var v := c.linear_velocity.length()
	var profile := minf(_ap.target_speed_at(_s), _ap.target_speed_at(_s + v * PREVIEW_TIME))
	target = profile * LEVEL_SCALE[level]
	var excess := v - target
	if excess > -THROTTLE_BAND:
		var limit := clampf(-excess / THROTTLE_BAND, 0.0, 1.0)
		if c.throttle > limit:
			throttle_cut = c.throttle - limit
			c.throttle = limit
	if excess <= 0.0:
		return
	var want := clampf(excess / FULL_BRAKE_EXCESS, 0.0, 1.0)
	if c.sim == null and c.speed_kmh > c.drift_min_speed_kmh \
			and absf(c.steer) >= c.drift_steer_threshold - 0.1:
		want = minf(want, c.drift_brake_threshold - 0.05)   # no drift on the player's behalf
	if want > c.brake_input:
		brake = want - c.brake_input
		c.brake_input = want
