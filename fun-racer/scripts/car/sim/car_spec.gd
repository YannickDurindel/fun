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
## compression 0 = design ride height (body floor about 8 cm above the road). Rates are at
## the wheel. Seen at one wheel: heave = spring + heave, roll = spring + 2 arb,
## one-wheel bump = spring + arb + heave / 2. See scripts/car/sim/suspension.gd.
@export var spring_front: float = 150000.0     ## N/m at the wheel, corner spring
@export var spring_rear: float = 130000.0
@export var heave_front: float = 70000.0       ## N/m at each wheel per m of mean axle travel (third element)
@export var heave_rear: float = 70000.0
@export var damper_front: float = 7000.0       ## N s/m in bump (compression), below the knee speed
@export var damper_rear: float = 7000.0
@export var damper_rebound_front: float = 11000.0   ## N s/m in rebound (extension), below the knee speed
@export var damper_rebound_rear: float = 11000.0
@export var damper_knee_speed: float = 0.25    ## m/s of wheel travel where the damper turns digressive
@export var damper_high_speed_ratio: float = 0.4   ## damper slope above the knee, as a share of the slope below
## Roll stiffness is 448 kN m/rad front, 353 rear: 56 % front against 46 % of the weight,
## for mild understeer at the limit. More front bar = more understeer.
@export var arb_front: float = 100000.0        ## N/m of left-right travel difference
@export var arb_rear: float = 80000.0
@export var travel_bump: float = 0.045         ## m of compression before the bump stop
@export var travel_droop: float = 0.06         ## m of extension before the wheel hangs
@export var bump_stop_rate: float = 1500000.0  ## N/m at first touch, beyond travel_bump
@export var bump_stop_progression: float = 0.02   ## m into the bump stop over which its force doubles again (progressive)

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

func mass(fuel_kg: float) -> float:
	return dry_mass + fuel_kg
