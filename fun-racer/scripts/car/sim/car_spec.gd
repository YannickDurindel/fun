class_name CarSpec
extends Resource
## Every physical parameter of the simulation car, in SI units. One resource
## (assets/car/specs/f1.tres) is the single place to tune; parts never hard-code numbers.
## Values are a 2020s Formula 1 car to first order. Parts may add @export fields in their own
## group; do not rename existing ones (other parts read them).

@export_group("Chassis")
@export var dry_mass: float = 798.0            ## kg, car + driver, no fuel
@export var weight_front: float = 0.46         ## share of static weight on the front axle
@export var cg_height: float = 0.25            ## m above the ground
@export var inertia: Vector3 = Vector3(1100.0, 1300.0, 320.0)   ## kg m^2 about x (pitch), y (yaw), z (roll)
@export var max_steer_angle: float = 0.35      ## rad at the front wheels, full lock

@export_group("Wheels")
@export var wheel_inertia_front: float = 1.1   ## kg m^2
@export var wheel_inertia_rear: float = 1.3

@export_group("Suspension")
@export var spring_front: float = 200000.0     ## N/m at the wheel
@export var spring_rear: float = 190000.0
@export var damper_front: float = 9000.0       ## N s/m
@export var damper_rear: float = 9000.0
@export var arb_front: float = 120000.0        ## N/m of left-right travel difference
@export var arb_rear: float = 60000.0
@export var travel_bump: float = 0.045         ## m of compression before the bump stop
@export var travel_droop: float = 0.06         ## m of extension before the wheel hangs
@export var bump_stop_rate: float = 1500000.0  ## N/m beyond travel_bump

@export_group("Tyres")
@export var tyre_mu: float = 1.75              ## peak friction coefficient at the reference load
@export var tyre_reference_load: float = 4000.0   ## N
@export var tyre_load_sensitivity: float = 0.08   ## fraction of mu lost per reference load above it
@export var tyre_peak_slip_ratio: float = 0.09
@export var tyre_peak_slip_angle: float = 0.14 ## rad

@export_group("Aero")
@export var air_density: float = 1.225
@export var cl_a: float = 3.6                  ## downforce coefficient x area (m^2)
@export var cd_a: float = 1.15                 ## drag coefficient x area (m^2)
@export var aero_balance_front: float = 0.44   ## share of downforce on the front axle
@export var drs_drag_factor: float = 0.80      ## drag multiplier with DRS open
@export var drs_downforce_factor: float = 0.85 ## rear downforce multiplier with DRS open

@export_group("Power unit")
@export var engine_power: float = 620000.0     ## W, combustion engine at peak
@export var ers_power: float = 120000.0        ## W, electric deployment
@export var ers_capacity: float = 4.0e6        ## J usable per lap
@export var engine_torque_max: float = 700.0   ## N m at the crank, engine + electric
@export var rpm_idle: float = 4000.0
@export var rpm_max: float = 13000.0           ## rev limit used in practice
@export var rpm_shift_up: float = 12200.0
@export var rpm_shift_down: float = 8200.0
@export var gear_ratios: PackedFloat32Array = PackedFloat32Array([2.85, 2.25, 1.86, 1.56, 1.33, 1.16, 1.03, 0.93])
@export var final_drive: float = 3.55
@export var reverse_ratio: float = 3.0
@export var driveline_efficiency: float = 0.94
@export var engine_brake_torque: float = 90.0  ## N m at the crank, throttle closed
@export var shift_time: float = 0.03           ## s without drive torque per shift

@export_group("Brakes")
@export var brake_torque_max: float = 14500.0  ## N m, all four wheels at full pedal
@export var brake_bias_front: float = 0.57

@export_group("Fuel")
@export var fuel_capacity: float = 110.0       ## kg
@export var fuel_start: float = 10.0           ## kg on board at the start (time attack load)
@export var fuel_burn_full: float = 0.028      ## kg/s at full throttle

@export_group("Aids")
# Traction control: a PI controller on the slip speed (m/s) of the worst driven wheel.
@export var aid_tc_slip_high: float = 1.15     ## slip-ratio target on HIGH, x the tyre's peak slip ratio
@export var aid_tc_slip_low: float = 2.2       ## slip-ratio target on LOW (lets the rear move)
@export var aid_tc_lateral_trim: float = 0.4   ## share of the HIGH target given up at full rear slip angle
@export var aid_tc_kp: float = 0.10            ## throttle removed per m/s of slip speed over the target
@export var aid_tc_ki: float = 2.0             ## throttle removed per second per m/s over the target
@export var aid_tc_min_throttle: float = 0.03  ## the cut never goes below this share of full throttle
# ABS: the same controller on the wheel closest to locking.
@export var aid_abs_slip: float = 1.15         ## braking slip target, x the tyre's peak slip ratio
@export var aid_abs_kp: float = 0.08           ## pedal released per m/s of slip speed over the target
@export var aid_abs_ki: float = 2.0            ## pedal released per second per m/s over the target
@export var aid_abs_min_brake: float = 0.03    ## the release never goes below this share of full pedal
@export var aid_abs_min_speed: float = 2.0     ## m/s: below this the pedal passes straight through
# Automatic gearbox.
@export var aid_shift_cooldown: float = 0.15   ## s between two automatic shifts
@export var aid_manual_hold_time: float = 4.0  ## s the automatic stays out after a manual shift
@export var aid_upshift_grip_rpm: float = 0.8  ## road-speed rpm / rpm_shift_up needed to shift up at once
@export var aid_upshift_spin_delay: float = 0.5   ## s on the shift rpm with spinning wheels before shifting up anyway
@export var aid_downshift_max_rpm: float = 0.95   ## no automatic downshift landing above this x rpm_shift_up
@export var aid_kickdown_throttle: float = 0.9 ## pedal that asks for a kick-down
@export var aid_kickdown_rpm: float = 0.9      ## kick down while the lower gear lands below this x rpm_shift_up
@export var aid_shift_block_slip: float = 1.0  ## no automatic downshift above this rear slip angle, x the tyre's peak
@export var aid_shift_block_release_rpm: float = 1.25   ## ... unless the engine is below this x rpm_idle
# Steering help.
@export var aid_steer_grip_usage: float = 0.9  ## share of the estimated lateral grip that full input asks for
@export var aid_steer_slip_margin: float = 0.15   ## lock beyond that turn, x the tyre's peak slip angle
@export var aid_steer_min_lock: float = 0.03   ## rad, smallest full-input lock at any speed
@export var aid_steer_center_gain: float = 0.6 ## analog response slope at the centre (1 = linear)
## s, low-pass on analog (tilt) input. Kept short: the autopilot steers through this too and
## weaves from about 0.03 s (0.015 s still laps cleanly).
@export var aid_steer_smooth_time: float = 0.012
@export var aid_steer_rate_analog: float = 12.0   ## full locks per second, analog input
@export var aid_steer_rate_digital: float = 7.0   ## full locks per second, keys
# Stability help.
@export var aid_stab_min_speed: float = 8.0    ## m/s: fades in from here to twice this
@export var aid_stab_slip_deadband: float = 1.15  ## rear slip angle that starts the help, x the tyre's peak
@export var aid_stab_slip_range: float = 1.0   ## further rear slip angle for full help, x the tyre's peak
@export var aid_stab_yaw_deadband: float = 0.12   ## rad/s of yaw beyond what steering and speed call for
@export var aid_stab_yaw_range: float = 0.5    ## rad/s further for full help
@export var aid_stab_throttle_cut: float = 0.8 ## share of the throttle removed at full help
@export var aid_stab_countersteer_gain: float = 0.5   ## rad of opposite lock per rad of rear slip over the deadband
@export var aid_stab_countersteer_max: float = 0.05   ## rad, most opposite lock the help adds
@export var aid_stab_drag_throttle: float = 0.12   ## throttle held at full help with the pedal released (cancels engine braking)
@export var aid_stab_understeer_slip: float = 1.3  ## front slip angle that counts as understeer, x the tyre's peak
@export var aid_stab_understeer_cut: float = 0.35  ## share of the throttle removed in full understeer
@export var aid_stab_response_time: float = 0.06   ## s, smoothing of the intervention
# DRS button.
@export var aid_drs_hold_time: float = 0.35    ## s: a press longer than this is a hold (release closes), shorter is a toggle
@export var aid_drs_brake_close: float = 0.05  ## brake pedal that closes the DRS

func mass(fuel_kg: float) -> float:
	return dry_mass + fuel_kg
