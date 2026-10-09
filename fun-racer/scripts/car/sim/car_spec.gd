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
## The tyre model (tyre_model.gd) is a combined-slip "magic formula". Per axis the pure-slip
## curve is F = D sin(C atan(Bx - E(Bx - atan Bx))): D is the peak force (mu x load), C sets how
## much is left when fully sliding, B puts the peak at the slip given here, E rounds the top.
## What each number does to the feel is noted with it; typical ranges are for racing slicks.
@export var tyre_mu: float = 1.75              ## peak friction coefficient at the reference load. 1.6-1.9 for slicks; scales every limit (cornering, braking, traction)
@export var tyre_reference_load: float = 4000.0   ## N, front tyre load at which mu = tyre_mu
@export var tyre_load_sensitivity: float = 0.08   ## fraction of mu lost per reference load above it (mu ~ load^-k). 0.05-0.2; higher = load transfer costs more grip, so springs and bars move the balance more
@export var tyre_peak_slip_ratio: float = 0.09 ## slip ratio of peak traction and braking. 0.07-0.12; lower = sharper bite, less margin before wheelspin or lock-up
@export var tyre_peak_slip_angle: float = 0.14 ## rad, front slip angle of peak cornering force. 0.10-0.16; lower = more direct steering, less warning
@export var tyre_peak_slip_angle_rear: float = 0.12   ## rad, same for the wider rear tyres. Lower than the front = the rear answers first and the car feels planted
@export var tyre_reference_load_rear: float = 4800.0  ## N, rear reference load. Higher than the front = the wide rears keep more mu at a given load (understeer at the limit)
@export var tyre_mu_long_scale: float = 1.05   ## longitudinal mu / lateral mu: the friction ellipse's aspect. 1.0-1.15
@export var tyre_min_load_ratio: float = 0.25  ## load sensitivity stops raising mu below this share of the reference load (an unloaded tyre does not get endless grip)
@export var tyre_slide_grip_long: float = 0.80 ## share of the peak force left at endless slip (locked or spinning wheel). 0.7-0.9; lower = locking up and wheelspin cost more
@export var tyre_slide_grip_lat: float = 0.86  ## same when sliding sideways. 0.75-0.95; lower = the car snaps past the limit, higher = it drifts progressively
@export var tyre_curvature_long: float = 0.2   ## E of the longitudinal curve, below 1. Higher = stiffer at small slip and a rounder, wider peak
@export var tyre_curvature_lat: float = 0.3    ## E of the lateral curve, below 1. Higher = a broader plateau around the limit (forgiving with tilt steering)
@export var tyre_relaxation_length: float = 0.3   ## m the tyre rolls to build 63 % of a new cornering force. 0.2-0.5; longer = lazier turn-in, softer response to steering jerks
@export var tyre_relaxation_fade_lo: float = 5.0  ## m/s, below this the cornering force follows the slip angle at once (no lag, so a slow car cannot weave)
@export var tyre_relaxation_fade_hi: float = 15.0 ## m/s, above this the full relaxation length applies
@export var tyre_low_speed_damping_long: float = 15.0  ## s/m: cap on force per sliding speed along the wheel, per newton of load (acts below about 5 m/s). Numerical: summed over the car it must stay below about mass / tick or the stopped car buzzes
@export var tyre_low_speed_damping_lat: float = 9.0    ## s/m, same across the wheel. Summed with the lever arms it must stay below about yaw inertia / tick; higher = truer slip angles at walking pace
@export var tyre_stick_length: float = 0.02    ## m of tread deflection at the peak force when standing still (static friction). Shorter = holds a slope more rigidly
@export var tyre_stick_fade_speed: float = 1.0 ## m/s, static friction fades out up to this rolling or sliding speed of the patch
@export var tyre_pneumatic_trail: float = 0.03 ## m, lever of the self-aligning moment at small slip (it falls to zero at the limit: the steering goes light)

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

func mass(fuel_kg: float) -> float:
	return dry_mass + fuel_kg
