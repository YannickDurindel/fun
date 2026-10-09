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
## Reference figures for a 2020s F1 car (sources in scripts/car/sim/aero.gd): downforce equals
## the weight near 150-160 km/h, is 3-4 times the weight at the end of a long straight, the
## drag area is about 1.2-1.3 m^2 and DRS is worth 10-15 km/h.
@export var air_density: float = 1.225
@export var cl_a: float = 6.6                  ## downforce coefficient x area (m^2) at the design ride height, medium wing
@export var cd_a: float = 1.30                 ## drag coefficient x area (m^2), medium wing
@export var aero_balance_front: float = 0.44   ## share of downforce on the front axle at the design ride height
@export var drs_drag_factor: float = 0.89      ## drag multiplier with DRS open
@export var drs_downforce_factor: float = 0.80 ## rear downforce multiplier with DRS open
@export var drs_actuation_time: float = 0.10   ## s for the flap to travel fully open or closed
@export var drs_close_throttle: float = 0.20   ## driver throttle below this counts as a lift and closes DRS
## Wing trim: 0 = lowest downforce (Monza), 0.5 = medium, 1 = highest (Monaco).
@export_range(0.0, 1.0) var wing_level: float = 0.5
@export var wing_downforce_range: float = 0.30 ## wing downforce changes by +- this share between trims 0.5 and 0 / 1
@export var wing_drag_range: float = 0.16      ## drag changes by +- this share between trims 0.5 and 0 / 1
## Ground-effect floor. Its downforce grows as the car runs lower, up to an optimum mean
## compression, then falls (the floor chokes when it is too close to the road).
@export var floor_share: float = 0.50          ## share of cl_a made by the floor at the design ride height
@export var floor_balance_front: float = 0.42  ## floor centre of pressure, share on the front axle
@export var floor_gain: float = 0.10           ## extra floor downforce (share) at the optimum compression
@export var floor_optimal_compression: float = 0.018   ## m, mean of the front and rear axle compression
@export var floor_stall_loss: float = 0.10     ## floor downforce lost (share) one optimum-compression beyond the optimum
@export var floor_min_factor: float = 0.50     ## the floor never makes less than this share of its design downforce
@export var floor_cop_per_rake: float = 2.0    ## front share gained by the floor per m of (front - rear) compression
@export var floor_cop_shift_max: float = 0.08  ## limit of that shift
@export var ride_height_filter_time: float = 0.06  ## s, low-pass on the ride heights the aero sees (no loop with the dampers)
## Yaw: the car slides sideways and the wings and floor work in crooked air.
@export var yaw_reference_angle: float = 0.35  ## rad of body slip at which the full yaw effect is reached
@export var yaw_downforce_loss: float = 0.35   ## share of downforce lost at the reference angle, on top of the lower airspeed along the car
@export var yaw_drag_gain: float = 0.25        ## share of drag gained at the reference angle
## Tow (state.tow = 1: right behind another car).
@export var tow_drag_loss: float = 0.20        ## share of drag lost
@export var tow_downforce_loss_front: float = 0.35 ## share of front downforce lost (dirty air: understeer)
@export var tow_downforce_loss_rear: float = 0.25  ## share of rear downforce lost

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
