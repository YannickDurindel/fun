class_name SimHandling
extends RefCounted
## Simulation handling model: a force-based car. Owned by a Car when its handling is
## &"simulation"; Car._integrate_forces hands over to integrate() every 240 Hz tick.
##
## One tick:
##   1. read the driver input into the state, run the driving aids (demands);
##   2. ray-cast each wheel: travel, contact point, surface;
##   3. suspension -> vertical loads; aero -> downforce and drag;
##   4. power unit -> drive torques; brakes -> brake torques;
##   5. per wheel, sub-stepped: slip ratio and slip angle -> tyre force -> wheel rotation;
##   6. sum gravity, aero and tyre forces on the body and integrate its velocities;
##   7. tyre condition and fuel; publish the Car contract (speed, rpm, gear, wheels...).
##
## Parts are plain objects with setup() / reset() / step(); swap one by replacing its file.
## Frames: car forward = -Z, up = +Y, right = +X. Wheel order FL, FR, RL, RR.

const SUBSTEPS: int = 4
## Slip is computed against at least this speed so it stays finite at a standstill (m/s).
const MIN_SLIP_SPEED_LONG: float = 2.5
const MIN_SLIP_SPEED_LAT: float = 1.5
## Ground distance below the hub at the design ride height (m): see Car.ride_ground_y.
const DESIGN_DROP: float = 0.36

var car: Car
var spec: CarSpec
var state: SimState = SimState.new()

var aids: SimAids = SimAids.new()
var suspension: SimSuspension = SimSuspension.new()
var aero: SimAero = SimAero.new()
var powertrain: SimPowertrain = SimPowertrain.new()
var brakes: SimBrakes = SimBrakes.new()
var tyres: SimTyreModel = SimTyreModel.new()
var condition: SimTyreCondition = SimTyreCondition.new()

var _ray: PhysicsRayQueryParameters3D
var _prev_x: PackedFloat32Array = [0, 0, 0, 0]
var _had_contact: Array[bool] = [false, false, false, false]
var _hit: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _normal: Array[Vector3] = [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]
var _shift_up: bool = false
var _shift_down: bool = false
var _drs_button: bool = false

func _init(p_car: Car, p_spec: CarSpec) -> void:
	car = p_car
	spec = p_spec
	_ray = PhysicsRayQueryParameters3D.new()
	_ray.exclude = [car.get_rid()]
	for part: Object in [aids, suspension, aero, powertrain, brakes, tyres, condition]:
		part.call(&"setup", spec)
	reset()

## Back to a standstill with full fuel load and fresh tyres' state as the parts define it.
func reset() -> void:
	condition.reset(state, spec)
	state.reset(spec)
	for part: Object in [aids, suspension, aero, powertrain, brakes, tyres]:
		part.call(&"reset", state, spec)
	for i in 4:
		_prev_x[i] = 0.0
		_had_contact[i] = false
	car.inertia = spec.inertia
	car.mass = state.mass

## Driver requests from the Car (one tick each).
func request_shift(dir: int) -> void:
	if dir > 0:
		_shift_up = true
	elif dir < 0:
		_shift_down = true

func set_drs_button(pressed: bool) -> void:
	_drs_button = pressed

## Test / rig helper: the car rolling straight at `mps` with matching wheel speeds and gear.
func set_speed(mps: float) -> void:
	var fwd := -car.global_transform.basis.z
	car.linear_velocity = fwd * mps
	car.angular_velocity = Vector3.ZERO
	for i in 4:
		state.omega[i] = mps / car.wheel_radius(i)
	state.gear = 1
	if mps > 1.0:
		for g in range(1, spec.gear_ratios.size() + 1):
			state.gear = g
			var rpm := mps / car.wheel_radius(2) * spec.gear_ratios[g - 1] * spec.final_drive * 60.0 / TAU
			if rpm < spec.rpm_shift_up * 0.92:
				break

func integrate(body: PhysicsDirectBodyState3D) -> void:
	var dt := body.step
	var s := state
	var xf := body.transform
	var bas := xf.basis.orthonormalized()
	var up := bas.y
	var fwd := -bas.z
	var right := bas.x
	var com := xf.origin + bas * car.center_of_mass
	var v := body.linear_velocity
	var w := body.angular_velocity
	var gravity := body.total_gravity

	# ---- 1. inputs and body state
	s.in_throttle = car.throttle
	s.in_brake = car.brake_input
	s.in_steer = car.steer
	s.in_steer_digital = car.is_steer_digital()
	s.in_steer_overdrive = car._steer_overdrive
	s.in_shift_up = _shift_up
	s.in_shift_down = _shift_down
	s.in_drs = _drs_button
	_shift_up = false
	_shift_down = false
	s.v_long = v.dot(fwd)
	s.v_lat = v.dot(right)
	s.speed = Vector2(s.v_long, s.v_lat).length()
	s.yaw_rate = w.dot(up)
	s.body_slip = atan2(s.v_lat, absf(s.v_long)) if s.speed > 2.0 else 0.0
	aids.step(s, spec, dt)

	# ---- 2. wheel raycasts
	var space := body.get_space_state()
	_ray.collision_mask = car.collision_mask
	var top := spec.travel_bump + 0.06
	s.on_ground = 0
	for i in 4:
		var hub := xf * Car.WHEEL_OFFSETS[i]
		_ray.from = hub + up * top
		_ray.to = hub - up * (DESIGN_DROP + spec.travel_droop)
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			s.contact[i] = false
			s.compression[i] = -spec.travel_droop
			s.compression_vel[i] = 0.0
			_had_contact[i] = false
			_hit[i] = hub - up * (DESIGN_DROP + spec.travel_droop)
			_normal[i] = up
			continue
		var p: Vector3 = hit["position"]
		var x := DESIGN_DROP - (hub - p).dot(up)
		s.contact[i] = true
		s.on_ground += 1
		s.compression[i] = x
		s.compression_vel[i] = clampf((x - _prev_x[i]) / dt, -5.0, 5.0) if _had_contact[i] else 0.0
		_prev_x[i] = x
		_had_contact[i] = true
		_hit[i] = p
		_normal[i] = hit["normal"]
		car.read_surface(i, hit["collider"], int(hit.get("shape", 0)))
		s.surface_mu[i] = car.surface_grip(i)
		s.surface_drag[i] = car.surface_drag(i)

	# ---- 3-4. loads, aero, torques
	suspension.step(s, spec, dt)
	aero.step(s, spec, dt)
	powertrain.step(s, spec, dt)
	brakes.step(s, spec, dt)

	# ---- 5-6. forces on the body
	var force := gravity * s.mass
	var torque := Vector3.ZERO
	var front_axle := xf * Vector3(0.0, 0.0, Car.WHEEL_OFFSETS[0].z)
	var rear_axle := xf * Vector3(0.0, 0.0, Car.WHEEL_OFFSETS[2].z)
	var f_df := -up * s.downforce_front
	var r_df := -up * s.downforce_rear
	force += f_df + r_df
	torque += (front_axle - com).cross(f_df) + (rear_axle - com).cross(r_df)
	if v.length() > 0.1:
		force -= v.normalized() * s.drag

	var h := dt / SUBSTEPS
	for i in 4:
		var r := car.wheel_radius(i)
		if not s.contact[i] or s.load[i] <= 0.0:
			# In the air: the wheel only feels its own torques.
			var inertia_air := spec.wheel_inertia_front if i < 2 else spec.wheel_inertia_rear
			s.omega[i] = _brake_wheel(s.omega[i] + s.drive_torque[i] * dt / inertia_air, s.brake_torque[i] * dt / inertia_air)
			s.slip_ratio[i] = 0.0
			s.slip_angle[i] = 0.0
			s.tyre_fx[i] = 0.0
			s.tyre_fy[i] = 0.0
			s.locked[i] = false
			continue
		var n := _normal[i]
		var heading := fwd.rotated(up, s.steer_angle) if i < 2 else fwd
		var wf := (heading - n * heading.dot(n)).normalized()
		var wr := wf.cross(n)
		var p := _hit[i]
		var vc := v + w.cross(p - com)
		var vl := vc.dot(wf)
		var vs := vc.dot(wr)
		s.wheel_v_long[i] = vl
		s.wheel_v_lat[i] = vs
		var inertia := spec.wheel_inertia_front if i < 2 else spec.wheel_inertia_rear
		var vref := maxf(absf(vl), MIN_SLIP_SPEED_LONG)
		s.slip_angle[i] = atan2(vs, maxf(absf(vl), MIN_SLIP_SPEED_LAT))
		var fx := 0.0
		var fy := 0.0
		for k in SUBSTEPS:
			s.slip_ratio[i] = (s.omega[i] * r - vl) / vref
			var f := tyres.forces(s, spec, i, h)
			fx += f.x
			fy += f.y
			# Semi-implicit wheel rotation: the tyre's own stiffness is treated implicitly so
			# the step is stable whatever the wheel inertia and speed.
			var stiff := tyres.long_stiffness(s, spec, i) * r * r / vref
			var denom := inertia + stiff * h
			var free := s.omega[i] + (s.drive_torque[i] - f.x * r) * h / denom
			s.omega[i] = _brake_wheel(free, s.brake_torque[i] * h / denom)
		fx /= SUBSTEPS
		fy /= SUBSTEPS
		s.locked[i] = s.brake_torque[i] > 0.0 and absf(s.omega[i]) < 0.5 and absf(vl) > 1.0
		# Soft surfaces drag the wheel whatever the tyre does.
		if s.surface_drag[i] > 0.0 and absf(vl) > 0.3:
			fx -= signf(vl) * s.surface_drag[i] * s.mass * 0.25
		s.tyre_fx[i] = fx
		s.tyre_fy[i] = fy
		var fw := wf * fx + wr * fy + n * s.load[i]
		force += fw
		torque += (p - com).cross(fw)

	var accel := force / s.mass
	v += accel * dt
	w += body.inverse_inertia_tensor * torque * dt
	body.linear_velocity = v
	body.angular_velocity = w
	var a_car := accel - gravity
	s.accel_long = a_car.dot(fwd)
	s.accel_lat = a_car.dot(right)

	# ---- 7. consumables and the Car contract
	condition.step(s, spec, dt)
	if absf(car.mass - s.mass) > 0.05:
		car.mass = s.mass
	_publish(xf, v, dt)

## Applies a brake impulse (rad/s, >= 0) against the rotation; the wheel stops, never reverses.
func _brake_wheel(omega: float, brake_dw: float) -> float:
	if absf(omega) <= brake_dw:
		return 0.0
	return omega - signf(omega) * brake_dw

func _publish(xf: Transform3D, v: Vector3, dt: float) -> void:
	var s := state
	car.speed_kmh = v.length() * Car.KMH
	car.forward_speed = s.v_long
	car.rpm = s.rpm
	car.gear = s.gear
	car.steer_angle = s.steer_angle
	car.slip_angle = s.body_slip
	car.is_grounded = s.on_ground > 0
	var rear_slip := 0.5 * (absf(s.slip_angle[2]) + absf(s.slip_angle[3]))
	car.is_drifting = s.speed > 12.0 and s.on_ground >= 2 and rear_slip > spec.tyre_peak_slip_angle_rear * 1.3
	car.ers_charge = clampf(s.ers_energy / maxf(spec.ers_capacity, 1.0), 0.0, 1.0)
	car.drs_open = s.drs_open
	car.fuel_kg = s.fuel
	car.tyre_compound = s.compound
	car.gear_count = spec.gear_ratios.size()
	for i in 4:
		var ws := car.wheels[i]
		var r := car.wheel_radius(i)
		ws.contact = s.contact[i]
		ws.contact_point = _hit[i]
		ws.contact_normal = _normal[i]
		# The visual hub sits one wheel radius above the ground: fronts are smaller than the
		# design drop, so they hang a little lower at ride height.
		ws.compression = clampf(s.compression[i] + r - DESIGN_DROP, -spec.travel_droop, spec.travel_bump + 0.03)
		ws.spin_angle += s.omega[i] * dt
		ws.steer_angle = s.steer_angle if i < 2 else 0.0
		var sx := s.slip_ratio[i] / spec.tyre_peak_slip_ratio
		var sy := tan(s.slip_angle[i]) / tan(spec.tyre_peak_slip_angle if i < 2 else spec.tyre_peak_slip_angle_rear)
		ws.slip = clampf(sqrt(sx * sx + sy * sy) - 0.9, 0.0, 1.0) if s.contact[i] and s.speed > 3.0 else 0.0
		ws.load = s.load[i]
		ws.slip_ratio = s.slip_ratio[i]
		ws.slip_angle = s.slip_angle[i]
		ws.temperature = s.tyre_temp[i]
		ws.wear = s.tyre_wear[i]
		ws.locked = s.locked[i]
