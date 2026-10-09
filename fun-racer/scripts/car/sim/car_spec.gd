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

@export_group("Tyre condition")
## Tyre temperature, wear and flat spots (SimTyreCondition). The compounds are in
## tyre_compounds.gd. These are design values tuned on the rig and the lap check, not tyre data.
@export var tyre_ambient_temp: float = 25.0            ## deg C, the air
@export var tyre_track_temp: float = 35.0              ## deg C, a dry road
@export var tyre_surface_heat_capacity: float = 2000.0 ## J/K, the tread: reacts in seconds
@export var tyre_core_heat_capacity: float = 8000.0   ## J/K, the carcass: reacts over tens of seconds
@export var tyre_friction_heat_share: float = 0.15     ## share of the patch's sliding power that heats the tread
@export var tyre_flex_heat_coeff: float = 0.02        ## carcass heating per N of load and m/s (hysteresis of the rolling tyre)
@export var tyre_air_cooling_base: float = 4.0        ## W/K, tread to air at a standstill
@export var tyre_air_cooling_per_speed: float = 0.6    ## W/K per m/s
@export var tyre_road_conductance: float = 25.0       ## W/K, tread to road through the patch
@export var tyre_wet_cooling: float = 1.5              ## extra road cooling at full wetness (x (1 + this))
@export var tyre_surface_core_conductance: float = 250.0   ## W/K between tread and carcass
@export var tyre_core_cooling_base: float = 3.0        ## W/K, carcass to rim and air at a standstill
@export var tyre_core_cooling_per_speed: float = 0.25   ## W/K per m/s
@export var tyre_temp_surface_weight: float = 0.5      ## share of the tread in state.tyre_temp
@export var tyre_temp_min: float = 0.0                 ## deg C, clamp
@export var tyre_temp_max: float = 220.0               ## deg C, clamp: nothing runs away
@export var tyre_slide_power_max: float = 400000.0     ## W, clamp on the sliding power of one tyre
@export var tyre_cold_grip_loss: float = 0.015         ## grip lost at the cold edge of the window (grows with the square)
@export var tyre_hot_grip_loss: float = 0.03           ## grip lost at the hot edge of the window
@export var tyre_temp_grip_floor: float = 0.75         ## the least grip temperature alone can leave
@export var tyre_wear_per_joule: float = 3.3e-8        ## wear per J of sliding energy, medium compound
@export var tyre_wear_hot_gain: float = 1.0            ## extra wear per half window above the window
@export var tyre_wear_grip_loss: float = 0.06          ## grip lost from new to the cliff
@export var tyre_wear_cliff: float = 0.8               ## wear at which the cliff starts
@export var tyre_cliff_grip_loss: float = 0.25         ## further grip lost from the cliff to worn out
@export var tyre_lock_min_speed: float = 1.0           ## m/s, a locked wheel below this does no damage
@export var tyre_flat_per_metre: float = 0.01          ## flat spot per m slid locked at the reference load
@export var tyre_lock_wear_per_metre: float = 0.0004   ## wear per m slid locked at the reference load
@export var tyre_flat_grip_loss: float = 0.08          ## grip lost with the worst flat spot
@export var tyre_flat_vibration_speed: float = 30.0    ## m/s at which the vibration reaches its amplitude
@export var tyre_condition_grip_floor: float = 0.5     ## the least grip temperature, wear and flat spot leave together
## Speeds the wear up for short races: 6 makes a 5-lap race wear like 30 laps. Flat spots are
## not scaled (a lock-up is an event, not a rate).
@export var wear_rate_scale: float = 1.0

@export_group("Fuel")
@export var fuel_capacity: float = 110.0       ## kg
@export var fuel_start: float = 10.0           ## kg on board at the start (time attack load)
@export var fuel_burn_full: float = 0.0278     ## kg/s at full throttle above fuel_flow_rpm (100 kg/h, the regulation flow limit)
@export var fuel_flow_rpm: float = 10500.0     ## rpm above which the flow limit applies; the flow is proportional below
@export var fuel_idle_fraction: float = 0.03   ## share of the full flow burnt with the throttle closed
## Speeds the burn up for short races: 14 makes a 5-lap race burn like 70 laps.
@export var fuel_burn_scale: float = 1.0

func mass(fuel_kg: float) -> float:
	return dry_mass + fuel_kg
