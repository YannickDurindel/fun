class_name Car
extends RigidBody3D
## Player car: custom raycast vehicle tuned to feel like the Trackmania Stadium car.
##
## CONTRACT (other systems depend on these; do not rename):
##   speed_kmh, rpm, gear, throttle, brake_input, steer, is_drifting, is_grounded,
##   wheels: Array[WheelState] (order FL, FR, RL, RR), signal respawned,
##   WHEEL_OFFSETS / *_WHEEL_RADIUS (local, forward = -Z, up = +Y), wheel_radius(i), respawn().
##
## Model overview (all in _integrate_forces, custom integrator, fixed 240 Hz -> deterministic):
##   * Suspension: one raycast per wheel, stiff preloaded spring-damper with short travel, plus
##     anti-roll / anti-pitch bars. At rest the body is level with the ground at local y = -0.36.
##   * Tyres: arcade "glued" model working on the planar velocity at the centre of mass. In grip
##     mode the yaw rate tracks the kinematic bicycle yaw rate and lateral sliding is cancelled,
##     both capped by a load-independent friction budget (no understeer, no body roll).
##   * Drift: brake + steer at speed (or exceeding the grip budget) switches to a slide where the
##     rear lets go, the slip angle is servoed towards a target set by the steering input, and
##     sliding friction bleeds speed. Grip is restored progressively on exit.
##   * Drivetrain: speed-indexed acceleration table (punchy, tapering), 7-speed automatic with a
##     short torque dip on shifts, strong brakes, reverse, soft speed cap at 1000 km/h.
##   * Aero: downforce ~ v^2 (capped), heavier-than-earth gravity, angular damping in the air.
##   * Terrain: driving forces, grip and downforce work in the road plane (average contact normal),
##     so grades, crests and camber behave; hills pull with ~1 g (the extra gravity is for jumps).
##     Each wheel reads the collider's `surface` meta (asphalt / kerb / grass / gravel) for grip and
##     rolling drag; a wheel briefly unloaded by a kerb or bump keeps its grip for a few ms.

signal respawned

## Handling models. &"arcade": the Trackmania-style model in this file. &"simulation": the
## force-based model in scripts/car/sim (SimHandling), which takes over _integrate_forces.
const HANDLING_ARCADE := &"arcade"
const HANDLING_SIMULATION := &"simulation"
const SIM_SPEC_PATH := "res://assets/car/specs/f1.tres"

const WHEEL_OFFSETS: Array[Vector3] = [
	Vector3(-0.80, 0.0, -1.80), Vector3(0.80, 0.0, -1.80),
	Vector3(-0.78, 0.0, 1.80), Vector3(0.78, 0.0, 1.80),
]
const FRONT_WHEEL_RADIUS: float = 0.33
const REAR_WHEEL_RADIUS: float = 0.36
const MAX_RPM: float = 11000.0
## Distance between front and rear axles (m).
const WHEELBASE: float = 1.80 * 2.0
const KMH: float = 3.6

# ---------------------------------------------------------------- tuning
@export_group("Chassis")
## Multiplier on project gravity applied to the car at all times (snappy jumps).
@export var gravity_multiplier: float = 1.4
## Local y of the ground plane when the car is at rest (wheel centres of the rear sit at y = 0).
@export var ride_ground_y: float = -0.36
## Multiplier on gravity's along-the-road component while grounded. 1.0 = hills pull like 1 g
## (slower uphill, faster downhill, not dramatically); gravity_multiplier still applies normal to
## the road and in the air.
@export var slope_gravity_multiplier: float = 1.0

@export_group("Suspension")
## Compression travel above the rest position before the bump stop (m).
@export var travel_up: float = 0.06
## Extension travel below the rest position (m).
@export var travel_down: float = 0.08
@export var spring_rate: float = 140000.0      ## N/m per wheel
@export var damper_bump: float = 7500.0        ## N.s/m per wheel, compressing
@export var damper_rebound: float = 9000.0     ## N.s/m per wheel, extending
@export var bump_stop_start: float = 0.04      ## compression where the bump stop engages (m)
@export var bump_stop_rate: float = 1500000.0  ## N/m beyond bump_stop_start
@export var bump_stop_rebound: float = 0.25    ## fraction of bump-stop force kept while extending
@export var anti_roll_rate: float = 60000.0    ## N/m of left/right compression difference
@export var anti_pitch_rate: float = 60000.0   ## N/m of front/rear compression difference

@export_group("Aero")
@export var downforce_coef: float = 0.6        ## N per (m/s)^2
@export var downforce_max: float = 18000.0     ## N
## Angular velocity damping while fully airborne (1/s). No air control.
@export var air_angular_damping: float = 0.6
@export var speed_soft_cap_kmh: float = 1000.0
## Deceleration per m/s above the soft cap (1/s).
@export var speed_cap_stiffness: float = 4.0

@export_group("Engine")
## Full-throttle net acceleration (m/s^2) as a function of forward speed (km/h); linear lerp.
@export var accel_curve_kmh: PackedFloat32Array = PackedFloat32Array(
		[0, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 540, 580])
@export var accel_curve_ms2: PackedFloat32Array = PackedFloat32Array(
		[18.0, 16.0, 12.0, 8.6, 5.6, 3.7, 2.8, 2.25, 1.8, 1.25, 0.65, 0.2, 0.0])
@export var coast_decel: float = 0.8           ## m/s^2 rolling resistance off-throttle
@export var drag_decel_coef: float = 3.0e-5    ## extra off-throttle decel per (m/s)^2
@export var brake_decel: float = 18.0          ## m/s^2 at full brake
@export var reverse_accel: float = 9.0         ## m/s^2
@export var reverse_max_kmh: float = 80.0
## Below this forward speed (m/s), holding brake (without throttle) drives backwards.
@export var reverse_engage_speed: float = 1.0
## Off-input deceleration that holds the car still at very low speed (m/s^2).
@export var parking_decel: float = 4.0

@export_group("Gearbox")
## Upshift speed (km/h) of each gear; the last entry only scales the top-gear RPM sweep.
@export var gear_top_kmh: PackedFloat32Array = PackedFloat32Array([70, 125, 185, 255, 335, 430, 540])
@export var downshift_hysteresis_kmh: float = 8.0
@export var shift_time: float = 0.06           ## s of reduced torque per shift
@export var shift_torque_factor: float = 0.6
@export var idle_rpm: float = 3000.0
@export var shift_low_rpm: float = 4000.0      ## rpm right after an upshift
@export var launch_rpm: float = 6500.0         ## rpm with throttle held at standstill
@export var rpm_smoothing_time: float = 0.03   ## s

@export_group("Steering")
@export var steer_in_time: float = 0.065       ## s from centre to full lock
@export var steer_out_time: float = 0.035      ## s from full lock back to centre
## Keyboard (digital) steering is progressive: holding the key ramps toward full lock over
## key_steer_in_time, releasing it recentres over key_steer_out_time. Analog input
## (gamepad stick, autopilot, input override) keeps the fast steer_in/out times above.
@export var key_steer_in_time: float = 0.40
@export var key_steer_out_time: float = 0.12
@export var max_steer_angle: float = 0.5       ## rad, at low speed
## Fraction of the lateral grip budget that full lock demands (keeps the car on its line).
@export var steer_grip_usage: float = 0.92
## Minimum *visual* front-wheel lock (rad) so the wheels visibly turn at high speed.
@export var visual_min_steer: float = 0.14
@export var yaw_response_time: float = 0.025   ## s
@export var yaw_accel_max: float = 25.0        ## rad/s^2

@export_group("Grip")
@export var lateral_grip_g: float = 3.3        ## lateral grip budget at zero speed, in g
@export var aero_grip_g: float = 2.6e-4       ## extra grip in g per (m/s)^2
@export var lateral_response_time: float = 0.02  ## s
## Slip angle beyond the kinematic one that breaks traction into a drift without braking (deg).
## Large on purpose: landings, kerbs and long fast corners never start a slide (Trackmania: you
## drift when you brake); only a real knock (wall, car) does. Smaller slips re-align in grip.
@export var grip_break_angle_deg: float = 35.0
## Time constant for the heading to re-align with the velocity after a slide (s).
@export var realign_time: float = 0.2

@export_group("Drift")
@export var drift_min_speed_kmh: float = 110.0
## A drift needs a clear request: brake AND strong steer held together for drift_entry_time.
## (Raised from 0.5 / 0.1 / instant so trail braking into a corner stays glued.)
@export var drift_steer_threshold: float = 0.6
## Analog steering (phone, stick) held beyond this for overdrive_entry_time breaks the rear
## loose without the brake, above overdrive_min_speed_kmh. Keys never do: they are always at 1.
@export var overdrive_steer_threshold: float = 0.97
@export var overdrive_entry_time: float = 0.45
@export var overdrive_min_speed_kmh: float = 60.0
@export var overdrive_hold_steer: float = 0.8
@export var overdrive_slide_scale: float = 0.45  ## slide angle of a steering-only slide, x the brake drift's   ## the slide lasts while steering stays above this
@export var drift_brake_threshold: float = 0.3
## A drift only lasts while the brake is held: it ends this long after the brake is released
## (0 = keep sliding for as long as steer is held, the old behaviour).
@export var drift_brake_release_time: float = 0.25
@export var drift_entry_time: float = 0.3     ## s of brake + steer before the rear lets go
@export var drift_lateral_grip_g: float = 2.2  ## sliding friction budget, in g
## Extra sliding friction in g per (m/s)^2 (aero load), so a high-speed drift still carves the
## corner instead of washing wide.
@export var drift_aero_grip_g: float = 2.6e-4
@export var drift_drive_factor: float = 0.6    ## fraction of drive that reaches the road
## Fraction of the speed scrubbed by sliding friction that is kept (turns the slide, not stops it).
@export var drift_speed_retention: float = 0.3
@export var drift_brake_factor: float = 0.4    ## fraction of brake decel while drifting
@export var drift_base_angle_deg: float = 25.0 ## target slip angle with neutral steering
@export var drift_steer_angle_deg: float = 15.0  ## +/- target slip from steering in/out
@export var drift_min_angle_deg: float = 8.0
@export var drift_angle_time: float = 0.3      ## s, slip-angle servo time constant
@export var drift_yaw_time: float = 0.09       ## s, yaw response while sliding
@export var drift_yaw_accel_max: float = 20.0  ## rad/s^2
@export var drift_exit_angle_deg: float = 5.0
@export var drift_min_time: float = 0.3        ## s before a drift may end by re-alignment
@export var drift_recover_time: float = 0.2    ## s to ramp grip back to full after a drift
@export var drift_recover_grip: float = 0.7    ## grip fraction right after a drift ends

@export_group("Surfaces")
## Grip multipliers (lateral, drive and brake) per surface, from the collider's `surface` meta.
@export var kerb_grip: float = 1.0
@export var grass_grip: float = 0.6
@export var gravel_grip: float = 0.45
## Extra rolling resistance (m/s^2) with every wheel on the surface, throttle or not.
@export var grass_drag: float = 1.5
@export var gravel_drag: float = 5.0
## A wheel that lost contact less than this long ago (s) still grips (kerb hops, bumps).
@export var contact_grace_time: float = 0.06

@export_group("Wheels FX")
@export var launch_spin_speed: float = 10.0    ## extra rear surface speed at launch (m/s)
@export var launch_spin_fade: float = 12.0     ## m/s where launch wheelspin is gone
@export var drift_spin_speed: float = 12.0     ## extra rear surface speed while drifting (m/s)

# ---------------------------------------------------------------- contract state
var speed_kmh: float = 0.0
var rpm: float = 0.0
var gear: int = 1          ## 1..7 forward, -1 = reverse
var throttle: float = 0.0
var brake_input: float = 0.0
var steer: float = 0.0     ## smoothed steering, -1 left .. +1 right
var is_drifting: bool = false
var is_grounded: bool = true
var wheels: Array[WheelState] = []

var spawn_transform: Transform3D

## Which model drives this car. Empty = follow the game: the --handling= flag, else the
## player's `gameplay/handling` setting. Set it before the car enters the tree to force one.
@export var handling: StringName = &""
## The simulation model when handling == &"simulation", else null.
var sim: SimHandling
# ---- simulation extras (arcade leaves the defaults)
var ers_charge: float = 1.0          ## 0..1 of the lap's electric energy left
var drs_open: bool = false
var fuel_kg: float = 0.0
var tyre_compound: StringName = &"medium"
var gear_count: int = 7

# ---------------------------------------------------------------- extra read-only state
## Signed slip angle between heading and planar velocity (rad, + = nose left of velocity).
var slip_angle: float = 0.0
## Forward speed along the heading (m/s, negative when reversing).
var forward_speed: float = 0.0
## Physical front steer angle (rad, + = left).
var steer_angle: float = 0.0
var drift_time: float = 0.0

# ---------------------------------------------------------------- internals
var _raw_steer: float = 0.0
var _steer_digital: bool = false
## True when a person steers with an analog device (phone tilt, gamepad stick): the last part
## of the travel then asks for more than the grip, so the car can be made to slide.
var _steer_overdrive: bool = false
## Tests: treat the input override as a person on an analog device (steering overdrive on).
var override_as_player: bool = false
var _overdrive_time: float = 0.0
var _drift_by_steer: bool = false
var _drift_no_brake_time: float = 0.0
var _override: bool = false
var _ov_throttle: float = 0.0
var _ov_brake: float = 0.0
var _ov_steer: float = 0.0
var _respawn_pending: bool = false
var _drift_dir: float = 0.0
var _drift_request_time: float = 0.0
var _grip_blend: float = 1.0
var _shift_timer: float = 0.0
var _wheel_omega: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0])
var _ray: PhysicsRayQueryParameters3D
var _gravity: float = 9.81
var _steer_max: float = 0.5
# Per-tick scratch buffers (reused to avoid allocations at 240 Hz; arrays are shared by reference).
var _comp: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0])
var _bar_roll: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0])
var _hit_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _hit_ok: Array[bool] = [false, false, false, false]
var _air_time: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0])   ## s since last contact
var _mu: PackedFloat32Array = PackedFloat32Array([1, 1, 1, 1])         ## grip of the last surface
var _drag: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0])       ## drag of the last surface
## Average surface grip / drag of the gripping wheels, and their fraction (0..1), this tick.
var _surf_mu: float = 1.0
var _surf_drag: float = 0.0
var _grip_frac: float = 1.0

func _ready() -> void:
	spawn_transform = global_transform
	wheels.clear()
	for i in 4:
		wheels.append(WheelState.new())
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.81))
	# Body setup also lives in car.tscn; enforced here so the model's assumptions hold.
	custom_integrator = true
	can_sleep = false
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	_ray = PhysicsRayQueryParameters3D.new()
	_ray.exclude = [get_rid()]
	_ray.collision_mask = collision_mask
	if handling == &"":
		handling = Bootstrap.handling_override if Bootstrap.handling_override != &"" \
				else StringName(Settings.get_value("gameplay", "handling"))
	if handling == HANDLING_SIMULATION:
		sim = SimHandling.new(self, load(SIM_SPEC_PATH) as CarSpec)
		if Bootstrap.autodrive:
			sim.aids.use_all()   # the autopilot drives with every aid, whatever Options say
	_reset_drivetrain()
	_apply_control_settings()
	Settings.changed.connect(_on_setting_changed)

## True when the steering input is all-or-nothing (keys) and is being ramped by this car.
func is_steer_digital() -> bool:
	return _steer_digital

## Reads the `surface` meta of what wheel i stands on (asphalt / kerb / grass / gravel).
func read_surface(i: int, collider: Object, shape_idx: int) -> void:
	_set_surface(i, collider, shape_idx)

func surface_grip(i: int) -> float:
	return _mu[i]

func surface_drag(i: int) -> float:
	return _drag[i]

## Keyboard steering feel follows the player's Settings (controls screen).
func _apply_control_settings() -> void:
	key_steer_in_time = float(Settings.get_value("controls", "key_steer_in_time"))
	key_steer_out_time = float(Settings.get_value("controls", "key_steer_out_time"))

func _on_setting_changed(section: String, key: String) -> void:
	if section == "controls" and key.begins_with("key_steer_"):
		_apply_control_settings()

func wheel_radius(i: int) -> float:
	return FRONT_WHEEL_RADIUS if i < 2 else REAR_WHEEL_RADIUS

## World-space centre of wheel i, including suspension travel.
func wheel_center_world(i: int) -> Vector3:
	return global_transform * (WHEEL_OFFSETS[i] + Vector3(0.0, wheels[i].compression, 0.0))

## Test / AI hook: replaces driver input until clear_input_override().
func set_input_override(p_throttle: float, p_brake: float, p_steer: float) -> void:
	_override = true
	_ov_throttle = clampf(p_throttle, 0.0, 1.0)
	_ov_brake = clampf(p_brake, 0.0, 1.0)
	_ov_steer = clampf(p_steer, -1.0, 1.0)

func clear_input_override() -> void:
	_override = false

## When false, the car stops updating its contract fields (and stops driving),
## so tests can set speed_kmh / rpm / is_drifting / wheels by hand.
var simulate: bool = true

func _physics_process(_delta: float) -> void:
	if not simulate:
		return
	if _override:
		throttle = _ov_throttle
		brake_input = _ov_brake
		_raw_steer = _ov_steer
		_steer_digital = false
		_steer_overdrive = override_as_player
	else:
		throttle = clampf(Bootstrap.get_throttle(), 0.0, 1.0)
		brake_input = clampf(Bootstrap.get_brake(), 0.0, 1.0)
		_raw_steer = clampf(Bootstrap.get_steer(), -1.0, 1.0)
		_steer_digital = Bootstrap.is_steer_digital()
		_steer_overdrive = not _steer_digital and not Bootstrap.autodrive
		if Input.is_action_just_pressed("respawn"):
			respawn()
		if sim != null:
			if Input.is_action_just_pressed(&"shift_up") or Bootstrap.take_button(&"shift_up"):
				sim.request_shift(1)
			if Input.is_action_just_pressed(&"shift_down") or Bootstrap.take_button(&"shift_down"):
				sim.request_shift(-1)
			sim.set_drs_button(Input.is_action_pressed(&"drs") or Bootstrap.is_button_down(&"drs"))

func respawn() -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = spawn_transform   # immediate, for readers this frame
	reset_physics_interpolation()        # no interpolated swoop from the old position
	_respawn_pending = true              # authoritative reset inside the integrator
	_reset_drivetrain()
	respawned.emit()

func _reset_drivetrain() -> void:
	speed_kmh = 0.0
	forward_speed = 0.0
	gear = 1
	rpm = idle_rpm
	steer = 0.0
	steer_angle = 0.0
	slip_angle = 0.0
	is_drifting = false
	drift_time = 0.0
	_drift_dir = 0.0
	_drift_request_time = 0.0
	_grip_blend = 1.0
	_shift_timer = 0.0
	for i in 4:
		_wheel_omega[i] = 0.0
		_air_time[i] = 0.0
		if i < wheels.size():
			var w := wheels[i]
			w.contact = false
			w.slip = 0.0
			w.steer_angle = 0.0
			w.compression = 0.0
	if sim != null:
		sim.reset()

# ================================================================ simulation
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not simulate:
		return
	var dt := state.step
	if _respawn_pending:
		_respawn_pending = false
		state.transform = spawn_transform
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		return

	if sim != null:
		_update_steer_smoothing(dt)
		sim.integrate(state)
		return

	var xf := state.transform
	var bas := xf.basis.orthonormalized()
	var up := bas.y
	var fwd := -bas.z
	var com := xf.origin + bas * center_of_mass
	var v := state.linear_velocity
	var w := state.angular_velocity
	var inv_mass := state.inverse_mass
	var inv_inertia := state.inverse_inertia_tensor
	var gravity_vec := state.total_gravity
	_gravity = gravity_vec.length()
	var g := _gravity * gravity_multiplier

	_update_steer_smoothing(dt)

	# ---- gravity
	v += gravity_vec * gravity_multiplier * dt

	# ---- suspension raycasts
	var space := state.get_space_state()
	_ray.collision_mask = collision_mask
	var contacts := 0
	var normal_sum := Vector3.ZERO
	var hit_pos := _hit_pos
	var hit_ok := _hit_ok
	for i in 4:
		hit_ok[i] = false
		var r := wheel_radius(i)
		var mount := xf * (WHEEL_OFFSETS[i] + Vector3(0.0, travel_up, 0.0))
		_ray.from = mount
		_ray.to = mount - up * (travel_up + travel_down + r)
		var hit := space.intersect_ray(_ray)
		var ws := wheels[i]
		if hit.is_empty():
			_comp[i] = -travel_down
			_air_time[i] += dt
			ws.contact = false
			ws.contact_point = xf * (WHEEL_OFFSETS[i] + Vector3(0.0, -travel_down - r, 0.0))
			ws.contact_normal = up
		else:
			var p: Vector3 = hit["position"]
			var n: Vector3 = hit["normal"]
			_comp[i] = travel_up + r - mount.distance_to(p)
			hit_pos[i] = p
			hit_ok[i] = true
			contacts += 1
			normal_sum += n
			ws.contact = true
			ws.contact_point = p
			ws.contact_normal = n
			_air_time[i] = 0.0
			_set_surface(i, hit["collider"], hit["shape"])
		# Travel relative to WHEEL_OFFSETS (wheel_visual adds it to the offset). The body rests
		# level, so the smaller front wheels sit at -(REAR_WHEEL_RADIUS - FRONT_WHEEL_RADIUS).
		ws.compression = _comp[i]

	# Static wheel loads from the centre-of-mass position, so the car rests exactly at ride height.
	var com_z := center_of_mass.z
	var front_share := clampf((WHEEL_OFFSETS[2].z - com_z) / WHEELBASE, 0.0, 1.0)
	var weight := mass * g
	_bar_roll.fill(0.0)
	if hit_ok[0] and hit_ok[1]:
		var d := anti_roll_rate * (_comp[0] - _comp[1])
		_bar_roll[0] = d
		_bar_roll[1] = -d
	if hit_ok[2] and hit_ok[3]:
		var d := anti_roll_rate * (_comp[2] - _comp[3])
		_bar_roll[2] = d
		_bar_roll[3] = -d
	var pitch_term := 0.0
	if contacts == 4:
		var front_rel := 0.5 * (_comp[0] + _comp[1]) - (ride_ground_y + FRONT_WHEEL_RADIUS)
		var rear_rel := 0.5 * (_comp[2] + _comp[3]) - (ride_ground_y + REAR_WHEEL_RADIUS)
		pitch_term = anti_pitch_rate * (front_rel - rear_rel)

	var dv := Vector3.ZERO
	var dw := Vector3.ZERO
	for i in 4:
		if not hit_ok[i]:
			continue
		var share := front_share if i < 2 else 1.0 - front_share
		var static_load := 0.5 * share * weight
		var rest_comp := ride_ground_y + wheel_radius(i)
		var x := _comp[i] - rest_comp
		var arm := hit_pos[i] - com
		var vp := v + w.cross(arm)
		var comp_vel := -vp.dot(up)
		var force := static_load + spring_rate * x
		force += (damper_bump if comp_vel > 0.0 else damper_rebound) * comp_vel
		if x > bump_stop_start:
			# Rubber bump stop: stiff on the way in, mostly dead on the way out (no bounce).
			var bump := bump_stop_rate * (x - bump_stop_start)
			force += bump if comp_vel > 0.0 else bump * bump_stop_rebound
		force += _bar_roll[i] + (pitch_term if i < 2 else -pitch_term)
		force = maxf(force, 0.0)
		var j := up * force * dt
		dv += j * inv_mass
		dw += inv_inertia * arm.cross(j)
	v += dv
	w += dw

	is_grounded = contacts > 0
	var gf := contacts / 4.0
	# Grip: wheels that touched within contact_grace_time still count, so a kerb or bump that
	# unloads a wheel for a few ticks does not cut the friction budget (and the car's line).
	var grip_n := 0
	_surf_mu = 0.0
	_surf_drag = 0.0
	for i in 4:
		if _air_time[i] <= contact_grace_time:
			grip_n += 1
			_surf_mu += _mu[i]
			_surf_drag += _drag[i]
	_grip_frac = grip_n / 4.0
	if grip_n > 0:
		_surf_mu /= grip_n
		_surf_drag /= grip_n
	else:
		_surf_mu = 1.0

	# ---- planar driving model
	var n_avg := up
	if contacts > 0:
		n_avg = normal_sum.normalized()
	var f := fwd - n_avg * fwd.dot(n_avg)
	f = f.normalized() if f.length_squared() > 1.0e-4 else fwd
	var right := f.cross(n_avg)
	var v_long := v.dot(f)
	var v_lat := v.dot(right)
	var planar_speed := Vector2(v_long, v_lat).length()
	var planar_kmh := planar_speed * KMH

	slip_angle = atan2(v_lat, v_long) if planar_speed > 2.0 else 0.0

	# Steering angle shrinks with speed so full lock ~ the grip limit.
	var a_lat_max := g / gravity_multiplier * (lateral_grip_g + aero_grip_g * planar_speed * planar_speed)
	var steer_max := max_steer_angle
	if planar_speed > 1.0:
		steer_max = minf(max_steer_angle,
				atan(WHEELBASE * steer_grip_usage * a_lat_max / (planar_speed * planar_speed)))
	_steer_max = steer_max
	steer_angle = -steer * steer_max

	var b_rear := WHEEL_OFFSETS[2].z - com_z
	var kin_slip := 0.0
	if v_long > 0.5:
		kin_slip = atan2(-b_rear * w.dot(n_avg), v_long)

	if contacts > 0:
		# Hills pull with slope_gravity_multiplier, not the full jump gravity (no-op on flat ground).
		var g_road := gravity_vec - n_avg * gravity_vec.dot(n_avg)
		v -= g_road * ((gravity_multiplier - slope_gravity_multiplier) * dt * gf)
		v_long = v.dot(f)
		v_lat = v.dot(right)
		var ggf := maxf(gf, _grip_frac)
		_update_drift_state(dt, planar_kmh, kin_slip)
		var a_long := _drivetrain(dt, v_long, contacts)
		var new_long := _apply_longitudinal(v_long, a_long, dt, ggf)
		var v_planar_before := v - n_avg * v.dot(n_avg)
		v += f * (new_long - v_long)
		v_long = new_long

		var yaw := w.dot(n_avg)
		var new_yaw := yaw
		if is_drifting:
			# Rear lets go: sliding friction opposes lateral motion (curves the path, bleeds speed).
			var drift_g := drift_lateral_grip_g + drift_aero_grip_g * planar_speed * planar_speed
			var max_dv := drift_g * _surf_mu * _gravity * dt * ggf
			var speed_before := (v - n_avg * v.dot(n_avg)).length()
			v -= right * clampf(v_lat, -max_dv, max_dv)
			var v_planar_after := v - n_avg * v.dot(n_avg)
			var speed_after := v_planar_after.length()
			if speed_after > 1.0:
				var kept := lerpf(speed_after, speed_before, drift_speed_retention)
				v += v_planar_after * (kept / speed_after - 1.0)
				v_planar_after = v - n_avg * v.dot(n_avg)
			var path_rate := 0.0
			if v_planar_before.length() > 1.0 and v_planar_after.length() > 1.0:
				path_rate = v_planar_before.signed_angle_to(v_planar_after, n_avg) / dt
			var s_in := clampf(-steer * _drift_dir, -1.0, 1.0)
			var target_deg := clampf(drift_base_angle_deg + s_in * drift_steer_angle_deg,
					drift_min_angle_deg, drift_base_angle_deg + drift_steer_angle_deg)
			if _drift_by_steer:
				target_deg *= overdrive_slide_scale   # a slide from the steering alone is a mild one
			var target := _drift_dir * deg_to_rad(target_deg)
			var yaw_target := path_rate + (target - slip_angle) / drift_angle_time
			var step := (yaw_target - yaw) * (1.0 - exp(-dt / drift_yaw_time))
			var cap := drift_yaw_accel_max * dt * ggf
			new_yaw = yaw + clampf(step, -cap, cap)
		else:
			# Grip: yaw follows the kinematic bicycle model, lateral slide is cancelled.
			var grip := a_lat_max * _grip_blend * _surf_mu
			var yaw_des := v_long * tan(steer_angle) / WHEELBASE
			if planar_speed > 1.0:
				var lim := grip / planar_speed
				yaw_des = clampf(yaw_des, -lim, lim)
			if v_long > 2.0:
				# Re-align heading with the velocity after a slide or a knock.
				yaw_des -= (slip_angle - kin_slip) / realign_time
			var step := (yaw_des - yaw) * (1.0 - exp(-dt / yaw_response_time))
			var cap := yaw_accel_max * dt * ggf
			new_yaw = yaw + clampf(step, -cap, cap)
			var lat_target := -b_rear * new_yaw
			var dlat := (lat_target - v_lat) * (1.0 - exp(-dt / lateral_response_time))
			var max_dv := grip * dt * ggf
			v += right * clampf(dlat, -max_dv, max_dv)
		w += n_avg * (new_yaw - yaw)

		# Downforce keeps it planted, pressing into the road.
		var df := minf(downforce_coef * v_long * v_long, downforce_max) * gf
		v -= n_avg * df * inv_mass * dt
	else:
		_drivetrain(dt, v_long, 0)
		w *= exp(-air_angular_damping * dt)

	# Soft speed cap.
	var speed := v.length()
	var cap_speed := speed_soft_cap_kmh / KMH
	if speed > cap_speed:
		var new_speed := maxf(cap_speed, speed - (speed - cap_speed) * speed_cap_stiffness * dt)
		v *= new_speed / speed

	state.linear_velocity = v
	state.angular_velocity = w

	forward_speed = v.dot(f)
	speed_kmh = v.length() * KMH
	_update_wheels(dt, xf, v, w, com, f, right)

## Reads the surface of the collider under wheel i: the CollisionShape3D's `surface` meta wins,
## then the body's; missing = asphalt.
func _set_surface(i: int, collider: Object, shape_idx: int) -> void:
	var surf: StringName = &"asphalt"
	var body := collider as CollisionObject3D
	if body != null:
		var owner_node: Object = body.shape_owner_get_owner(body.shape_find_owner(shape_idx))
		if owner_node != null and owner_node.has_meta(&"surface"):
			surf = StringName(owner_node.get_meta(&"surface"))
		elif body.has_meta(&"surface"):
			surf = StringName(body.get_meta(&"surface"))
	wheels[i].surface = surf
	match surf:
		&"kerb":
			_mu[i] = kerb_grip
			_drag[i] = 0.0
		&"grass":
			_mu[i] = grass_grip
			_drag[i] = grass_drag
		&"gravel":
			_mu[i] = gravel_grip
			_drag[i] = gravel_drag
		_:
			_mu[i] = 1.0
			_drag[i] = 0.0

func _update_steer_smoothing(dt: float) -> void:
	var target := _raw_steer
	var t_in := key_steer_in_time if _steer_digital else steer_in_time
	var t_out := key_steer_out_time if _steer_digital else steer_out_time
	if steer != 0.0 and signf(target) != signf(steer):
		steer = move_toward(steer, 0.0, dt / maxf(t_out, 0.001))
	elif absf(target) < absf(steer):
		steer = move_toward(steer, target, dt / maxf(t_out, 0.001))
	else:
		steer = move_toward(steer, target, dt / maxf(t_in, 0.001))

func _update_drift_state(dt: float, planar_kmh: float, kin_slip: float) -> void:
	if not is_drifting:
		_grip_blend = minf(1.0, _grip_blend + dt * (1.0 - drift_recover_grip) / maxf(drift_recover_time, 0.001))
		if _steer_overdrive and absf(steer) > overdrive_steer_threshold and planar_kmh > overdrive_min_speed_kmh and forward_speed > 0.0:
			_overdrive_time += dt
			if _overdrive_time >= overdrive_entry_time:
				_drift_by_steer = true
				_enter_drift(-signf(steer))
				return
		else:
			_overdrive_time = 0.0
		if planar_kmh < drift_min_speed_kmh or forward_speed < 0.0:
			_drift_request_time = 0.0
			return
		var excess := slip_angle - kin_slip
		if brake_input > drift_brake_threshold and absf(steer) > drift_steer_threshold:
			_drift_request_time += dt
		else:
			_drift_request_time = 0.0
		if _drift_request_time >= drift_entry_time:
			_enter_drift(-signf(steer))
		elif _grip_blend >= 1.0 and absf(excess) > deg_to_rad(grip_break_angle_deg):
			_enter_drift(signf(excess))
		return
	drift_time += dt
	var steering := absf(steer) > 0.15 or brake_input > drift_brake_threshold
	if brake_input > drift_brake_threshold:
		_drift_no_brake_time = 0.0
	else:
		_drift_no_brake_time += dt
		if drift_brake_release_time > 0.0 and _drift_no_brake_time > drift_brake_release_time:
			steering = false
	var min_kmh := drift_min_speed_kmh
	if _drift_by_steer:
		# A slide started with the steering alone lasts as long as the steering is held.
		steering = _steer_overdrive and absf(steer) > overdrive_hold_steer
		min_kmh = overdrive_min_speed_kmh
	var aligned := absf(slip_angle) < deg_to_rad(drift_exit_angle_deg) and drift_time > drift_min_time
	var reversed := signf(slip_angle) == -_drift_dir and absf(slip_angle) > deg_to_rad(drift_exit_angle_deg)
	if not steering or aligned or reversed or planar_kmh < min_kmh * 0.5:
		is_drifting = false
		_drift_by_steer = false
		_overdrive_time = 0.0
		_drift_dir = 0.0
		drift_time = 0.0
		_grip_blend = drift_recover_grip

func _enter_drift(dir: float) -> void:
	if dir == 0.0:
		return
	is_drifting = true
	_drift_dir = dir
	drift_time = 0.0
	_drift_request_time = 0.0
	_drift_no_brake_time = 0.0

## Returns the longitudinal acceleration request and updates gear / rpm.
func _drivetrain(dt: float, v_long: float, contacts: int) -> float:
	var kmh := v_long * KMH
	var reversing := brake_input > 0.05 and throttle < 0.05 and v_long < reverse_engage_speed
	var a := 0.0
	if reversing:
		gear = -1
		if v_long > -reverse_max_kmh / KMH:
			a = -reverse_accel * brake_input
	elif v_long < -0.5:
		gear = -1
	else:
		if gear < 1:
			gear = 1
		var n := gear_top_kmh.size()
		if gear < n and kmh > gear_top_kmh[gear - 1]:
			gear += 1
			_shift_timer = shift_time
		elif gear > 1 and kmh < gear_top_kmh[gear - 2] - downshift_hysteresis_kmh:
			gear -= 1
			_shift_timer = shift_time
		var shift_k := shift_torque_factor if _shift_timer > 0.0 else 1.0
		var drive_k := drift_drive_factor if is_drifting else 1.0
		a = throttle * _accel_at(kmh) * shift_k * drive_k
	_shift_timer = maxf(0.0, _shift_timer - dt)

	# RPM (for audio): sweeps shift_low_rpm..MAX_RPM within each gear band.
	var target_rpm: float
	if gear == -1:
		target_rpm = lerpf(idle_rpm, MAX_RPM * 0.8, clampf(absf(kmh) / reverse_max_kmh, 0.0, 1.0))
	else:
		var lo := 0.0 if gear == 1 else float(gear_top_kmh[gear - 2])
		var hi := float(gear_top_kmh[gear - 1])
		var frac := clampf((kmh - lo) / maxf(hi - lo, 1.0), 0.0, 1.0)
		target_rpm = lerpf(idle_rpm if gear == 1 else shift_low_rpm, MAX_RPM, frac)
		if gear == 1:
			target_rpm = maxf(target_rpm, lerpf(idle_rpm, launch_rpm, throttle))
	if contacts == 0:
		target_rpm = lerpf(target_rpm, MAX_RPM * 0.97, throttle)
	elif is_drifting:
		target_rpm += throttle * 1500.0
	target_rpm = clampf(target_rpm, idle_rpm, MAX_RPM)
	rpm = lerpf(rpm, target_rpm, 1.0 - exp(-dt / maxf(rpm_smoothing_time, 0.001)))
	return a

func _accel_at(kmh: float) -> float:
	var n := mini(accel_curve_kmh.size(), accel_curve_ms2.size())
	if n == 0:
		return 0.0
	if kmh <= accel_curve_kmh[0]:
		return accel_curve_ms2[0]
	for i in range(1, n):
		if kmh <= accel_curve_kmh[i]:
			var t := (kmh - accel_curve_kmh[i - 1]) / maxf(accel_curve_kmh[i] - accel_curve_kmh[i - 1], 0.001)
			return lerpf(accel_curve_ms2[i - 1], accel_curve_ms2[i], t)
	return accel_curve_ms2[n - 1]

## Integrates drive (signed accel request) plus brakes / resistance, which never cross zero.
func _apply_longitudinal(v_long: float, a_drive: float, dt: float, gf: float) -> float:
	var reversing := gear == -1 and brake_input > 0.05 and throttle < 0.05
	var dec := (1.0 - throttle) * (coast_decel + drag_decel_coef * v_long * v_long)
	if reversing:
		dec = 0.0 if a_drive != 0.0 else coast_decel
	elif v_long < -0.5:
		dec += throttle * brake_decel   # throttle while rolling backwards brakes
	else:
		dec += brake_input * brake_decel * (drift_brake_factor if is_drifting else 1.0)
	if throttle < 0.05 and brake_input < 0.05 and absf(v_long) < 1.0:
		dec += parking_decel
	# Low-grip surfaces cut traction and braking, and add rolling drag.
	var nv := v_long + a_drive * _surf_mu * dt * gf
	return move_toward(nv, 0.0, (dec * _surf_mu + _surf_drag) * dt * gf)

func _update_wheels(dt: float, xf: Transform3D, v: Vector3, w: Vector3, com: Vector3,
		f: Vector3, right: Vector3) -> void:
	var vis_steer := -steer * maxf(_steer_max, visual_min_steer)
	var road_speed := absf(forward_speed)
	for i in 4:
		var ws := wheels[i]
		var r := wheel_radius(i)
		var is_front := i < 2
		ws.steer_angle = vis_steer if is_front else 0.0
		var p := xf * WHEEL_OFFSETS[i]
		var vp := v + w.cross(p - com)
		# Velocity in the wheel's own frame (front wheels are steered).
		var wf := f.rotated(xf.basis.y.normalized(), ws.steer_angle) if is_front else f
		var wr := right.rotated(xf.basis.y.normalized(), ws.steer_angle) if is_front else right
		var vl := vp.dot(wf)
		var vt := vp.dot(wr)
		if ws.contact:
			var surface := vl
			if not is_front:
				var launch := throttle * launch_spin_speed * maxf(0.0, 1.0 - road_speed / launch_spin_fade)
				var drift_spin := throttle * drift_spin_speed if is_drifting else 0.0
				surface += (launch + drift_spin) * (1.0 if gear != -1 else -1.0)
			_wheel_omega[i] = surface / r
			var alpha := atan2(absf(vt), maxf(absf(vl), 1.0))
			var s := smoothstep(deg_to_rad(4.0), deg_to_rad(20.0), alpha)
			if not is_front and road_speed < launch_spin_fade and throttle > 0.5:
				s = maxf(s, throttle * (1.0 - road_speed / launch_spin_fade))
			if road_speed > 8.0 and brake_input > 0.5 and not is_drifting and gear != -1:
				s = maxf(s, 0.25 * brake_input)   # tyre load hint, below the skid-mark threshold
			if is_drifting and not is_front:
				s = maxf(s, 0.85)
			ws.slip = clampf(s, 0.0, 1.0)
		else:
			if is_front:
				_wheel_omega[i] *= exp(-0.5 * dt)
			else:
				_wheel_omega[i] = lerpf(_wheel_omega[i], throttle * 60.0, 1.0 - exp(-dt / 0.3))
			ws.slip = 0.0
		ws.spin_angle = fmod(ws.spin_angle + _wheel_omega[i] * dt, TAU * 1000.0)
