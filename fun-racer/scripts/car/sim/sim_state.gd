class_name SimState
extends RefCounted
## Everything the simulation parts share for one car, in SI units. Wheel arrays are indexed
## FL, FR, RL, RR. Each field has ONE writer (named in the comment); everyone may read.
## The loop in sim_handling.gd runs the parts in this order every 240 Hz tick:
##   aids -> suspension -> aero -> powertrain -> brakes -> (wheel rotation + tyre forces, sub-stepped)
##   -> tyre_condition

# ---- raw driver input (written by SimHandling from the Car's inputs)
var in_throttle: float = 0.0     ## 0..1
var in_brake: float = 0.0        ## 0..1
var in_steer: float = 0.0        ## -1 left .. +1 right
var in_steer_overdrive: bool = false ## a person on an analog device: the end of the travel may exceed the grip
var in_steer_digital: bool = false   ## true when steering comes from keys (all or nothing)
var in_shift_up: bool = false    ## true for one tick when requested
var in_shift_down: bool = false
var in_drs: bool = false         ## DRS button state (toggle handled by aids)

# ---- demands after the driving aids (written by SimAids)
var throttle: float = 0.0        ## 0..1 to the power unit
var brake: float = 0.0           ## 0..1 pedal pressure to the brakes
var steer_angle: float = 0.0     ## rad at the front wheels, + = left
var shift_request: int = 0       ## +1 / -1 / 0 this tick (manual or from the automatic gearbox)
var drs_request: bool = false

# ---- body (written by SimHandling)
var speed: float = 0.0           ## m/s, magnitude of the velocity in the road plane
var v_long: float = 0.0          ## m/s along the car's heading
var v_lat: float = 0.0           ## m/s to the car's right
var yaw_rate: float = 0.0        ## rad/s, + = turning left
var accel_long: float = 0.0      ## m/s^2, + = accelerating (previous tick)
var accel_lat: float = 0.0       ## m/s^2, + = to the right (previous tick)
var body_slip: float = 0.0       ## rad, angle between heading and velocity
var mass: float = 800.0          ## kg including fuel
var on_ground: int = 0           ## wheels in contact

# ---- per wheel, geometry and kinematics (written by SimHandling)
var contact: Array[bool] = [false, false, false, false]
var compression: PackedFloat32Array = [0, 0, 0, 0]      ## m, + = compressed from design ride height
var compression_vel: PackedFloat32Array = [0, 0, 0, 0]  ## m/s
var surface_mu: PackedFloat32Array = [1, 1, 1, 1]       ## grip multiplier of the surface
var surface_drag: PackedFloat32Array = [0, 0, 0, 0]     ## rolling drag of the surface, m/s^2
var wheel_v_long: PackedFloat32Array = [0, 0, 0, 0]     ## m/s of the contact patch along the wheel
var wheel_v_lat: PackedFloat32Array = [0, 0, 0, 0]      ## m/s across the wheel, + = to its right
var omega: PackedFloat32Array = [0, 0, 0, 0]            ## rad/s wheel rotation, + = rolling forward
var slip_ratio: PackedFloat32Array = [0, 0, 0, 0]       ## (omega R - v_long) / |v_long|
var slip_angle: PackedFloat32Array = [0, 0, 0, 0]       ## rad, + = patch moving to the wheel's right
var locked: Array[bool] = [false, false, false, false]

# ---- per wheel, forces (writer in brackets)
var load: PackedFloat32Array = [0, 0, 0, 0]             ## N vertical load            [SimSuspension]
var drive_torque: PackedFloat32Array = [0, 0, 0, 0]     ## N m at the wheel           [SimPowertrain]
var brake_torque: PackedFloat32Array = [0, 0, 0, 0]     ## N m, always >= 0           [SimBrakes]
var tyre_fx: PackedFloat32Array = [0, 0, 0, 0]          ## N along the wheel          [SimHandling, from SimTyreModel]
var tyre_fy: PackedFloat32Array = [0, 0, 0, 0]          ## N to the wheel's right     [SimHandling, from SimTyreModel]
var grip_factor: PackedFloat32Array = [1, 1, 1, 1]      ## condition multiplier on mu [SimTyreCondition]
var tyre_temp: PackedFloat32Array = [90, 90, 90, 90]    ## deg C                      [SimTyreCondition]
var tyre_wear: PackedFloat32Array = [0, 0, 0, 0]        ## 0 new .. 1 worn out        [SimTyreCondition]
var brake_temp: PackedFloat32Array = [400, 400, 400, 400]   ## deg C                  [SimBrakes]

# ---- aero (written by SimAero)
var downforce_front: float = 0.0   ## N on the front axle
var downforce_rear: float = 0.0    ## N on the rear axle
var drag: float = 0.0              ## N opposing the velocity
var drs_open: bool = false
## 0..1 loss of downforce and drag from running behind another car; set by whoever knows the
## other cars (0 = clean air). SimAero reads it.
var tow: float = 0.0

# ---- power unit (written by SimPowertrain)
var gear: int = 1                  ## 1..n forward, 0 neutral, -1 reverse
var rpm: float = 4000.0
var ers_energy: float = 4.0e6      ## J left this lap
var shifting: float = 0.0          ## s of the current shift remaining

# ---- consumables (written by SimTyreCondition)
var fuel: float = 10.0             ## kg
var compound: StringName = &"medium"

func reset(spec: CarSpec) -> void:
	for i in 4:
		contact[i] = false
		compression[i] = 0.0
		compression_vel[i] = 0.0
		omega[i] = 0.0
		slip_ratio[i] = 0.0
		slip_angle[i] = 0.0
		locked[i] = false
		load[i] = 0.0
		drive_torque[i] = 0.0
		brake_torque[i] = 0.0
		tyre_fx[i] = 0.0
		tyre_fy[i] = 0.0
	throttle = 0.0
	brake = 0.0
	steer_angle = 0.0
	shift_request = 0
	speed = 0.0
	v_long = 0.0
	v_lat = 0.0
	yaw_rate = 0.0
	accel_long = 0.0
	accel_lat = 0.0
	body_slip = 0.0
	gear = 1
	rpm = spec.rpm_idle
	shifting = 0.0
	drs_open = false
	mass = spec.mass(fuel)
