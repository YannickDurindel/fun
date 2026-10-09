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
@export var brake_torque_max: float = 14500.0  ## N m, all four wheels at full pedal
@export var brake_bias_front: float = 0.57

@export_group("Fuel")
@export var fuel_capacity: float = 110.0       ## kg
@export var fuel_start: float = 10.0           ## kg on board at the start (time attack load)
@export var fuel_burn_full: float = 0.028      ## kg/s at full throttle

func mass(fuel_kg: float) -> float:
	return dry_mass + fuel_kg
