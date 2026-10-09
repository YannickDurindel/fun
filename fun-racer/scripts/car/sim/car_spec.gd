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
## N m on all four wheels at full pedal with the discs in their working window. Sized for the
## grip the car has near 300 km/h with its downforce: below that, full pedal locks the wheels.
@export var brake_torque_max: float = 13000.0
@export var brake_bias_front: float = 0.60     ## share of the brake torque on the front axle
## Brake migration: front share added as the pedal is released (at zero pedal the share is
## brake_bias_front + this). Negative moves the balance rearwards off the pedal. 0 = fixed.
@export var brake_bias_migration: float = 0.12
@export var brake_pedal_gamma: float = 1.3     ## pedal map exponent (1 = linear, > 1 = progressive)
@export var brake_line_pressure_max: float = 1.6e7   ## Pa, the most either circuit can reach
@export var brake_piston_area_front: float = 0.0021  ## m^2, pistons on one side of a front caliper
@export var brake_piston_area_rear: float = 0.0016
@export var brake_disc_radius_front: float = 0.135   ## m, effective (pad centre) radius
@export var brake_disc_radius_rear: float = 0.115
@export var brake_pad_mu: float = 0.6          ## carbon on carbon, in the working window
## Share of the rear axle's brake demand left to the electric motor (energy harvesting). The
## friction brakes drop it; the power unit must supply it as negative drive torque. 0 = none.
@export var brake_rear_regen_share: float = 0.0
@export var brake_temp_start: float = 450.0    ## deg C after a reset (warm)
@export var brake_temp_ambient: float = 25.0   ## deg C of the cooling air
@export var brake_temp_cold: float = 150.0     ## deg C: at and below, friction is brake_friction_cold
@export var brake_temp_work_low: float = 400.0 ## deg C: working window, full friction
@export var brake_temp_work_high: float = 1000.0
@export var brake_temp_fade: float = 1300.0    ## deg C: at and above, friction is brake_friction_fade
@export var brake_friction_cold: float = 0.65  ## friction relative to the working window
@export var brake_friction_fade: float = 0.60
@export var brake_heat_capacity_front: float = 2400.0   ## J/K, one disc with its pads
@export var brake_heat_capacity_rear: float = 1800.0
@export var brake_cooling_base: float = 4.0    ## W/K to the air at a standstill
@export var brake_cooling_per_speed: float = 0.8   ## W/K more per m/s of car speed (ducts)
@export var brake_cooling_rear_factor: float = 0.5 ## rear ducts' cooling relative to the fronts
@export var brake_radiation_area: float = 0.10 ## m^2 of disc surface that radiates
@export var brake_emissivity: float = 0.8

@export_group("Fuel")
@export var fuel_capacity: float = 110.0       ## kg
@export var fuel_start: float = 10.0           ## kg on board at the start (time attack load)
@export var fuel_burn_full: float = 0.028      ## kg/s at full throttle

func mass(fuel_kg: float) -> float:
	return dry_mass + fuel_kg
