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
# -- combustion engine: a 1.6 L turbo V6. Above 10,500 rpm the fuel flow is capped, so the
#    power is nearly flat and the torque falls as 1/rpm.
@export var engine_power: float = 620000.0     ## W, combustion engine at peak (the curve below is scaled to it)
@export var ers_power: float = 120000.0        ## W, electric deployment (MGU-K)
@export var ers_capacity: float = 4.0e6        ## J usable in the battery
@export var engine_torque_max: float = 700.0   ## N m at the crank, engine + electric
@export var rpm_idle: float = 4000.0
@export var rpm_max: float = 15000.0           ## rev limit (the soft limiter ends here)
@export var rpm_shift_up: float = 12400.0
@export var rpm_shift_down: float = 8200.0
## Overall ratios chosen with final_drive for a 0.36 m rear tyre: 1st = 70 km/h at 9,500 rpm,
## 8th = 340 km/h at 11,800 rpm, steps closing from 1.30 to 1.15.
@export var gear_ratios: PackedFloat32Array = PackedFloat32Array([3.68, 2.83, 2.246, 1.826, 1.51, 1.268, 1.084, 0.942])
@export var final_drive: float = 5.0
@export var reverse_ratio: float = 3.2
@export var driveline_efficiency: float = 0.94
@export var engine_brake_torque: float = 90.0  ## N m at the crank, throttle closed, at engine_brake_rpm
@export var shift_time: float = 0.03           ## s without combustion torque per upshift
## Full-throttle torque curve of the combustion engine: rpm knots and the relative torque at
## each (any unit; SimPowertrain scales it so the peak power is engine_power).
@export var torque_curve_rpm: PackedFloat32Array = PackedFloat32Array([4000, 6000, 8000, 9000, 10000, 10500, 11000, 11500, 12000, 12500, 13000, 14000, 15000])
@export var torque_curve: PackedFloat32Array = PackedFloat32Array([330, 430, 520, 550, 562, 564, 538, 515, 492, 470, 445, 390, 330])
@export var engine_inertia: float = 0.045      ## kg m^2 at the crank: engine, clutch, MGU-K, input shaft
@export var engine_brake_rpm: float = 12000.0  ## rpm at which engine_brake_torque is reached (0 at idle)
@export var rpm_limiter_band: float = 300.0    ## rpm below rpm_max over which the torque fades out
@export var idle_torque_max: float = 120.0     ## N m the idle governor may add below rpm_idle
@export var idle_response: float = 0.03        ## s, time constant of the idle governor
# -- clutch (automatic: anti-stall when rolling, slipping launch from rest)
@export var clutch_torque_max: float = 900.0   ## N m the closed clutch can carry
@export var rpm_clutch_bite: float = 4300.0    ## rpm where the clutch starts to bite when rolling
@export var rpm_clutch_band: float = 800.0     ## rpm from the bite point to fully closed
@export var rpm_launch: float = 9000.0         ## rpm where the clutch is fully closed in a full-throttle launch
@export var rpm_launch_band: float = 3000.0    ## rpm below rpm_launch where it starts to bite in a launch
# -- gearbox
@export var shift_time_down: float = 0.06      ## s, longest a downshift waits for the rev-matching blip
@export var shift_sync_rpm: float = 250.0      ## rpm of mismatch at which a blipped downshift closes the clutch
@export var rpm_downshift_limit: float = 14200.0   ## a downshift that would rev higher than this is refused
@export var reverse_throttle: float = 0.35     ## share of the engine torque available in reverse
@export var reverse_speed_max: float = 22.0    ## m/s, no more drive in reverse above this
@export var reverse_select_speed: float = 0.5  ## m/s, the car counts as stopped below this
@export var reverse_select_brake: float = 0.5  ## brake pedal held above this at a standstill selects reverse
@export var reverse_cancel_throttle: float = 0.05  ## throttle above this leaves reverse (and blocks selecting it)
# -- limited-slip differential (clutch type): locking torque = preload + ramp x input torque
@export var diff_preload: float = 60.0         ## N m across the rear wheels with no input torque
@export var diff_ramp_power: float = 0.35      ## locking torque per N m of axle torque when driving
@export var diff_ramp_coast: float = 0.25      ## ... when the engine brakes the axle
@export var diff_lock_rate: float = 1.0        ## 0..1 share of the speed difference the diff may remove per tick
# -- hybrid system (MGU-K and battery)
@export var ers_torque_max: float = 200.0      ## N m at the crank, motor or generator
@export var ers_efficiency: float = 0.95       ## each way between battery and crank
@export var ers_deploy_throttle: float = 0.85  ## deployment fades in from this throttle to full throttle
@export var ers_min_speed: float = 22.0        ## m/s, no deployment below (the car is traction limited)
@export var ers_speed_band: float = 8.0        ## m/s over which deployment fades in above ers_min_speed
@export var ers_taper_energy: float = 300000.0 ## J left below which the deployment tapers to zero
@export var ers_deploy_limit: float = 4.0e6    ## J from the battery per lap
@export var ers_harvest_limit: float = 2.0e6   ## J into the battery per lap from braking
@export var ers_harvest_power: float = 120000.0    ## W at the crank while braking
@export var ers_harvest_brake_min: float = 0.05    ## brake pedal above which braking harvest runs
@export var ers_part_throttle_power: float = 70000.0   ## W harvested at part throttle from the engine's spare torque
@export var ers_part_throttle_min: float = 0.1     ## part-throttle harvest runs between this throttle and ers_deploy_throttle
@export var ers_lap_distance: float = 5000.0   ## m: the per-lap limits renew after this distance until new_lap() is called (0 = never)
@export var driveline_accel_limit: float = 8000.0  ## rad/s^2: a rear axle speed change beyond this means the car was placed, not driven

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
