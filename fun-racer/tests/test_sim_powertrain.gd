extends TestCase
## Power unit, hybrid system and gearbox of the simulation car (scripts/car/sim/powertrain.gd).
## The first tests drive the part alone with a hand-built state; the rest run the whole car on
## the rig and compare with a 2020s Formula 1 car.

const SPEC_PATH := "res://assets/car/specs/f1.tres"
const DT := 1.0 / 240.0
const R := Car.REAR_WHEEL_RADIUS

var spec: CarSpec
var pt: SimPowertrain
var st: SimState

## A part on its own: the car rolling at `kmh` in `gear` with the clutch closed.
func _bench(kmh: float = 0.0, gear: int = 1) -> void:
	spec = (load(SPEC_PATH) as CarSpec).duplicate() as CarSpec
	pt = SimPowertrain.new()
	st = SimState.new()
	pt.setup(spec)
	st.reset(spec)
	pt.reset(st, spec)
	_roll(kmh, gear)

func _roll(kmh: float, gear: int) -> void:
	st.speed = kmh / 3.6
	st.v_long = st.speed
	for i in 4:
		st.omega[i] = st.speed / R
	st.gear = gear

## Steps the part with the wheels held at their speed (a car far heavier than the engine).
func _run(seconds: float, throttle: float, brake: float = 0.0) -> void:
	st.throttle = throttle
	st.in_throttle = throttle
	st.brake = brake
	st.in_brake = brake
	for k in int(round(seconds / DT)):
		pt.step(st, spec, DT)
		st.shift_request = 0

func _kmh(gear: int, rpm: float) -> float:
	return pt.speed_in_gear(spec, gear, rpm, R) * 3.6

# ---------------------------------------------------------------- the part alone

func test_torque_curve_and_peak_power() -> void:
	_bench()
	var peak := 0.0
	var peak_rpm := 0.0
	var rpm := spec.rpm_idle
	while rpm <= spec.rpm_max:
		if pt.power_at(spec, rpm) > peak:
			peak = pt.power_at(spec, rpm)
			peak_rpm = rpm
		rpm += 50.0
	print("    engine: %.0f kW at %.0f rpm, %.0f N m at 10,500, %.0f N m at 12,500; with the motor %.0f kW" % [
			peak / 1000.0, peak_rpm, pt.torque_at(spec, 10500.0), pt.torque_at(spec, 12500.0), (peak + spec.ers_power) / 1000.0])
	assert_between(peak, spec.engine_power * 0.999, spec.engine_power * 1.001, "peak combustion power (W)")
	assert_between(peak + spec.ers_power, 720000.0, 780000.0, "total power, about 750 kW (W)")
	assert_between(peak_rpm, 10500.0, 12500.0, "rpm of peak power")
	# Nearly flat power from 10,500 to 12,500 rpm (fuel-flow limited), so torque falls there.
	for flat_rpm: float in [10500.0, 11000.0, 11500.0, 12000.0, 12500.0]:
		assert_true(pt.power_at(spec, flat_rpm) > 0.97 * peak, "power within 3%% of the peak at %.0f rpm" % flat_rpm)
	assert_true(pt.torque_at(spec, 12500.0) < pt.torque_at(spec, 10500.0), "torque falls over the flat-power band")
	# Clearly less power low down and at the limit: there is a reason to shift.
	assert_true(pt.power_at(spec, 8000.0) < 0.75 * peak, "well below peak power at 8,000 rpm")
	assert_true(pt.power_at(spec, spec.rpm_max) < 0.90 * peak, "power has dropped at the rev limit")
	assert_between(spec.rpm_max, 14500.0, 15500.0, "rev limit (rpm)")
	var prev := 0.0
	rpm = spec.rpm_idle
	while rpm <= 10500.0:
		assert_true(pt.torque_at(spec, rpm) >= prev, "torque rises up to 10,500 rpm (at %.0f)" % rpm)
		prev = pt.torque_at(spec, rpm)
		rpm += 250.0

func test_gear_ratios_and_speeds() -> void:
	_bench()
	var n := spec.gear_ratios.size()
	assert_true(n == 8, "8 forward gears")
	var line := "    km/h at %d rpm:" % int(spec.rpm_shift_up)
	for g in range(1, n + 1):
		line += " %d: %.0f" % [g, _kmh(g, spec.rpm_shift_up)]
		if g > 1:
			var step := spec.gear_ratios[g - 2] / spec.gear_ratios[g - 1]
			assert_between(step, 1.10, 1.35, "ratio step %d -> %d" % [g - 1, g])
			if g > 2:
				var step_before := spec.gear_ratios[g - 3] / spec.gear_ratios[g - 2]
				assert_true(step <= step_before + 1e-3, "steps close up towards top gear (%d -> %d)" % [g - 1, g])
			# After an upshift at the shift rpm the engine is still in its strong range and
			# above the downshift rpm, so an automatic gearbox does not hunt.
			var landed := spec.rpm_shift_up / step
			assert_true(landed > spec.rpm_shift_down + 500.0, "rpm after the upshift to %d (%.0f) is above the downshift rpm" % [g, landed])
			assert_true(spec.rpm_shift_down * step < spec.rpm_shift_up - 500.0, "rpm after a downshift from %d is below the upshift rpm" % g)
	print(line)
	assert_between(_kmh(1, 9500.0), 60.0, 80.0, "1st gear at 9,500 rpm (km/h)")
	assert_between(_kmh(n, 11800.0), 330.0, 350.0, "top gear at 11,800 rpm (km/h)")
	assert_true(pt.gear_ratio(spec, -1) < 0.0, "reverse ratio is negative")
	st.gear = 3
	assert_between(pt.ratio(st, spec), spec.gear_ratios[2] * spec.final_drive - 1e-4, spec.gear_ratios[2] * spec.final_drive + 1e-4, "ratio() of the selected gear")

func test_drive_torque_follows_the_curve() -> void:
	_bench(200.0, 5)
	st.ers_energy = 0.0
	_run(0.5, 1.0)
	var rpm := 200.0 / 3.6 / R * pt.ratio(st, spec) / SimPowertrain.RPM
	var expected := pt.torque_at(spec, rpm) * pt.ratio(st, spec) * spec.driveline_efficiency
	assert_true(pt.clutch_locked, "clutch closed at speed")
	assert_between(st.rpm, rpm - 20.0, rpm + 20.0, "engine rpm follows the wheels")
	assert_between(st.drive_torque[2] + st.drive_torque[3], expected * 0.99, expected * 1.01, "axle torque at full throttle (N m)")
	assert_true(st.drive_torque[0] == 0.0 and st.drive_torque[1] == 0.0, "rear-wheel drive")
	assert_between(st.drive_torque[2], st.drive_torque[3] - 0.01, st.drive_torque[3] + 0.01, "equal split with equal wheel speeds")
	_run(0.5, 0.0)
	assert_true(st.drive_torque[2] + st.drive_torque[3] < -50.0, "engine braking with the throttle closed (%.0f N m)" % (st.drive_torque[2] + st.drive_torque[3]))

func test_rev_limiter_is_soft() -> void:
	_bench(0.0, 2)
	_roll(pt.speed_in_gear(spec, 2, spec.rpm_max - spec.rpm_limiter_band * 0.5, R) * 3.6, 2)
	st.ers_energy = 0.0
	_run(0.3, 1.0)
	var half := st.drive_torque[2] + st.drive_torque[3]
	_roll(pt.speed_in_gear(spec, 2, spec.rpm_max - spec.rpm_limiter_band * 2.0, R) * 3.6, 2)
	_run(0.3, 1.0)
	var below := st.drive_torque[2] + st.drive_torque[3]
	assert_true(half > 0.0 and half < 0.7 * below, "torque fades inside the limiter band (%.0f vs %.0f N m)" % [half, below])
	# A free engine (clutch open in neutral) cannot pass the limit.
	st.gear = 0
	_run(1.0, 1.0)
	assert_between(st.rpm, spec.rpm_max - spec.rpm_limiter_band, spec.rpm_max, "free-revving engine sits in the limiter band")

func test_idle_and_anti_stall() -> void:
	_bench(0.0, 1)
	_run(1.0, 0.0)
	assert_between(st.rpm, spec.rpm_idle - 100.0, spec.rpm_idle + 100.0, "idle rpm at a standstill")
	assert_true(absf(st.drive_torque[2] + st.drive_torque[3]) < 1.0, "no creep at idle")
	assert_true(not pt.clutch_locked, "clutch open at a standstill")
	# Rolling in a high gear far below idle speed: the clutch opens instead of stalling.
	_bench(40.0, 6)
	_run(1.0, 0.0)
	assert_true(not pt.clutch_locked, "clutch opens when the gear would stall the engine")
	assert_between(st.rpm, spec.rpm_idle - 100.0, spec.rpm_idle + 100.0, "engine idles with the clutch open")
	# The wheels come back up to speed (they were locked, or the car rolled downhill): the
	# engine is rev-matched and the clutch closes again without dragging the rear wheels.
	var worst := 0.0
	for k in 240:
		_roll(40.0 + 210.0 * (k + 1) / 240.0, 6)
		pt.step(st, spec, DT)
		worst = minf(worst, st.drive_torque[2] + st.drive_torque[3])
	_run(0.3, 0.0)
	var coast := st.drive_torque[2] + st.drive_torque[3]
	assert_true(pt.clutch_locked, "the clutch closes again once the gearbox is fast enough")
	assert_between(st.rpm, 250.0 / 3.6 / R * pt.ratio(st, spec) / SimPowertrain.RPM - 30.0, 250.0 / 3.6 / R * pt.ratio(st, spec) / SimPowertrain.RPM + 30.0, "engine back at the gearbox speed (rpm)")
	assert_true(coast < -100.0, "engine braking is back (%.0f N m)" % coast)
	assert_true(worst > 2.0 * coast, "no jolt when the clutch closes (%.0f N m against %.0f steady)" % [worst, coast])
	# Throttle and brake together: the motor does not deploy and harvest in the same tick.
	st.brake_torque[2] = 2000.0
	st.brake_torque[3] = 2000.0
	var e := st.ers_energy
	_run(0.5, 1.0, 1.0)
	assert_true(st.ers_energy < e and pt.ers_flow > 0.0 and pt.lap_harvested == 0.0, "deploying at full throttle excludes braking harvest")

func test_launch_clutch_holds_revs_without_chatter() -> void:
	_bench(0.0, 1)
	st.throttle = 1.0
	st.in_throttle = 1.0
	var flips := 0
	var was_locked := false
	var rpm_lo := INF
	var rpm_hi := 0.0
	var worst_jump := 0.0
	var last := 0.0
	# The wheels pick up at a steady 10 m/s^2, as in a traction-limited start.
	for k in 480:
		var v := 10.0 * k * DT
		st.speed = v
		st.v_long = v
		st.omega[2] = v / R
		st.omega[3] = v / R
		pt.step(st, spec, DT)
		var axle := st.drive_torque[2] + st.drive_torque[3]
		if k > 0:
			worst_jump = maxf(worst_jump, absf(axle - last))
		last = axle
		if pt.clutch_locked != was_locked:
			flips += 1
			was_locked = pt.clutch_locked
		if k > 48 and not pt.clutch_locked:
			rpm_lo = minf(rpm_lo, st.rpm)
			rpm_hi = maxf(rpm_hi, st.rpm)
	print("    launch: engine held %.0f-%.0f rpm while the clutch slipped, locked %d time(s), largest torque step %.0f N m" % [rpm_lo, rpm_hi, flips, worst_jump])
	assert_true(flips == 1 and pt.clutch_locked, "the clutch locks once and stays locked (%d changes)" % flips)
	assert_between(rpm_lo, spec.rpm_launch - spec.rpm_launch_band, spec.rpm_launch, "lowest rpm while slipping")
	assert_between(rpm_hi, spec.rpm_launch - spec.rpm_launch_band, spec.rpm_launch, "highest rpm while slipping")
	assert_true(rpm_hi - rpm_lo < 600.0, "revs are held steady while slipping (%.0f rpm spread)" % (rpm_hi - rpm_lo))
	var full := spec.engine_torque_max * pt.gear_ratio(spec, 1) * spec.driveline_efficiency
	assert_true(worst_jump < 0.15 * full, "no torque chatter (largest step %.0f of %.0f N m)" % [worst_jump, full])

func test_upshift_cuts_torque_briefly_and_downshift_blips() -> void:
	_bench(180.0, 4)
	st.ers_energy = 0.0
	_run(0.3, 1.0)
	var rpm_before := st.rpm
	st.shift_request = 1
	pt.step(st, spec, DT)
	st.shift_request = 0
	assert_true(st.gear == 5, "upshift taken")
	assert_between(st.shifting, 0.015, 0.045, "upshift time (s)")
	var cut := 0.0
	while st.shifting > 0.0:
		assert_true(pt.engine_torque <= 0.0, "combustion cut during the upshift")
		pt.step(st, spec, DT)
		cut += DT
	_run(0.1, 1.0)
	var step := spec.gear_ratios[3] / spec.gear_ratios[4]
	assert_between(st.rpm, rpm_before / step - 50.0, rpm_before / step + 50.0, "rpm after the upshift")
	assert_true(st.drive_torque[2] > 0.0, "drive is back after the upshift")
	print("    upshift 4-5 at %.0f rpm: combustion cut for %.0f ms" % [rpm_before, cut * 1000.0])
	# Downshift: the engine is blipped up with the clutch open, so the wheels are not dragged.
	_run(0.2, 0.0)
	var coast := st.drive_torque[2] + st.drive_torque[3]
	st.shift_request = -1
	pt.step(st, spec, DT)
	st.shift_request = 0
	assert_true(st.gear == 4, "downshift taken")
	var worst := 0.0
	var t := 0.0
	var blipped := false
	for k in 48:
		blipped = blipped or pt.engine_torque > 50.0
		worst = minf(worst, st.drive_torque[2] + st.drive_torque[3])
		if st.shifting > 0.0:
			t += DT
		pt.step(st, spec, DT)
	print("    downshift 5-4: %.0f ms, most negative axle torque %.0f N m (steady engine braking %.0f N m)" % [t * 1000.0, worst, coast])
	assert_true(blipped, "throttle blip on the downshift")
	assert_between(t, 0.0, spec.shift_time_down + DT, "downshift time (s)")
	assert_between(st.rpm, rpm_before - 60.0, rpm_before + 60.0, "rpm matched after the downshift")
	assert_true(worst > 3.0 * coast - 50.0, "the downshift does not jerk the rear wheels (%.0f N m)" % worst)

func test_over_rev_downshift_is_refused() -> void:
	_bench(0.0, 3)
	_roll(_kmh(3, 12000.0), 3)   # 2nd would be far past the limit
	_run(0.2, 0.0)
	st.shift_request = -1
	pt.step(st, spec, DT)
	assert_true(st.gear == 3 and st.shifting == 0.0, "downshift that would over-rev is refused (gear %d)" % st.gear)
	assert_true(not pt.can_shift_to(spec, 2, st.omega[2]), "can_shift_to agrees")
	_roll(_kmh(3, 9000.0), 3)
	_run(0.2, 0.0)
	st.shift_request = -1
	pt.step(st, spec, DT)
	assert_true(st.gear == 2, "the same downshift is taken at a safe speed (gear %d)" % st.gear)
	# The ends of the gearbox.
	_bench(300.0, 8)
	_run(0.1, 1.0)
	st.shift_request = 1
	pt.step(st, spec, DT)
	assert_true(st.gear == 8, "no gear above 8th")
	_bench(20.0, 1)
	_run(0.1, 0.5)
	st.shift_request = -1
	pt.step(st, spec, DT)
	assert_true(st.gear == 1, "no shift request selects neutral or reverse")

func test_differential_limits_the_spinning_wheel() -> void:
	_bench(80.0, 2)
	st.ers_energy = 0.0
	_run(0.3, 1.0)
	st.omega[2] += 12.0   # the left wheel spins up (inside wheel out of a right-hander)
	st.omega[3] -= 12.0
	pt.step(st, spec, DT)   # the first tick sees the jump as a wheel acceleration
	pt.step(st, spec, DT)
	var axle := st.drive_torque[2] + st.drive_torque[3]
	var bias := st.drive_torque[3] - st.drive_torque[2]
	var limit := 2.0 * (spec.diff_preload + axle * spec.diff_ramp_power)
	print("    differential on power: %.0f N m to the spinning wheel, %.0f N m to the gripping one" % [st.drive_torque[2], st.drive_torque[3]])
	assert_true(axle > 1000.0, "driving")
	assert_between(bias, 0.9 * limit, 1.01 * limit, "torque moved to the slower wheel (N m)")
	# Coasting: a lighter lock, towards the slower wheel again.
	_run(0.2, 0.0)
	st.omega[2] += 12.0
	st.omega[3] -= 12.0
	pt.step(st, spec, DT)
	pt.step(st, spec, DT)
	var coast_axle := st.drive_torque[2] + st.drive_torque[3]
	var coast_bias := st.drive_torque[3] - st.drive_torque[2]
	assert_true(coast_axle < 0.0, "engine braking")
	assert_between(coast_bias, 2.0 * spec.diff_preload, 2.0 * (spec.diff_preload + absf(coast_axle) * spec.diff_ramp_coast) * 1.01, "coast lock (N m)")
	# A small speed difference (a normal corner) only gets a proportionate torque: no fighting.
	st.omega[2] = st.omega[3] + 0.02
	pt.step(st, spec, DT)
	assert_true(absf(st.drive_torque[3] - st.drive_torque[2]) < 2.0 * spec.diff_preload, "small difference, small locking torque")

func test_ers_deploys_drains_and_tapers() -> void:
	_bench(250.0, 6)
	st.ers_energy = 0.0
	_run(0.3, 1.0)
	var rpm := st.rpm
	var without := st.drive_torque[2] + st.drive_torque[3]
	st.ers_energy = spec.ers_capacity
	_run(0.3, 1.0)
	var with_motor := st.drive_torque[2] + st.drive_torque[3]
	var extra_w := (with_motor - without) / (pt.ratio(st, spec) * spec.driveline_efficiency) * rpm * SimPowertrain.RPM
	print("    ERS at 250 km/h: +%.0f kW at the crank, battery flow %.0f kW" % [extra_w / 1000.0, pt.ers_flow / 1000.0])
	assert_between(extra_w, spec.ers_power * 0.97, spec.ers_power * 1.03, "electric power added at full throttle (W)")
	assert_between(pt.ers_flow, spec.ers_power, spec.ers_power / spec.ers_efficiency * 1.01, "battery drain (W)")
	# Ten seconds of deployment take about 1.26 MJ.
	var e0 := st.ers_energy
	_run(10.0, 1.0)
	assert_between(e0 - st.ers_energy, 1.2e6, 1.3e6, "energy used in 10 s (J)")
	# Run it dry: it tapers, never goes negative and the car ends up without the motor.
	_run(60.0, 1.0)
	assert_between(st.ers_energy, 0.0, 0.02 * spec.ers_capacity, "battery nearly empty (J)")
	var dry := st.drive_torque[2] + st.drive_torque[3]
	assert_between(dry, without * 0.999, without * 1.03, "no electric help when empty (N m)")
	assert_true(pt.lap_deployed <= spec.ers_deploy_limit + 1.0, "deployment within the lap limit")
	# No deployment at part throttle or at low speed.
	_bench(250.0, 6)
	_run(1.0, 0.8)
	assert_true(st.ers_energy >= spec.ers_capacity - 1.0, "no deployment at part throttle")
	_bench(60.0, 1)
	_run(1.0, 1.0)
	assert_true(st.ers_energy >= spec.ers_capacity - 1.0, "no deployment below the minimum speed")

func test_ers_lap_limits() -> void:
	# Deployment stops at the per-lap allowance even with energy left, until the next lap.
	_bench(250.0, 6)
	spec.ers_capacity = 8.0e6
	spec.ers_lap_distance = 0.0
	st.ers_energy = 8.0e6
	_run(90.0, 1.0)
	assert_between(pt.lap_deployed, 0.97 * spec.ers_deploy_limit, spec.ers_deploy_limit + 1.0, "deployed this lap (J)")
	assert_between(st.ers_energy, 8.0e6 - spec.ers_deploy_limit - 1.0, 8.0e6 - 0.97 * spec.ers_deploy_limit, "energy left (J)")
	pt.new_lap(st, spec)
	var e := st.ers_energy
	_run(2.0, 1.0)
	assert_true(st.ers_energy < e - 1.0e5, "a new lap renews the allowance")
	# Braking harvest: up to the generator's power, limited per lap and by the battery.
	_bench(250.0, 6)
	spec.ers_lap_distance = 0.0
	st.ers_energy = 0.0
	st.brake_torque[2] = 2000.0
	st.brake_torque[3] = 2000.0
	_run(1.0, 0.0, 1.0)
	print("    harvest under braking: %.0f kJ in 1 s" % (st.ers_energy / 1000.0))
	assert_between(st.ers_energy, 0.9 * spec.ers_harvest_power * spec.ers_efficiency, spec.ers_harvest_power, "harvested in 1 s of braking (J)")
	assert_true(pt.ers_flow < 0.0, "battery flow is negative while harvesting")
	_run(60.0, 0.0, 1.0)
	assert_between(st.ers_energy, 0.99 * spec.ers_harvest_limit, spec.ers_harvest_limit + 1.0, "braking harvest stops at the lap limit (J)")
	pt.new_lap(st, spec)
	_run(60.0, 0.0, 1.0)
	assert_between(st.ers_energy, 0.999 * spec.ers_capacity, spec.ers_capacity, "the battery never exceeds its capacity (J)")
	# Weak braking harvests no more than the rear brakes take.
	_bench(250.0, 6)
	st.ers_energy = 0.0
	st.brake_torque[2] = 50.0
	st.brake_torque[3] = 50.0
	_run(1.0, 0.0, 0.1)
	assert_between(st.ers_energy, 1.0, 100.0 * 250.0 / 3.6 / R, "harvest bounded by the rear braking power (J)")
	# Part throttle charges too, without changing the drive torque.
	_bench(150.0, 4)
	st.ers_energy = 1.0e6
	_run(2.0, 0.5)
	assert_between(st.ers_energy - 1.0e6, 0.8 * 2.0 * spec.ers_part_throttle_power * spec.ers_efficiency, 2.0 * spec.ers_part_throttle_power, "part-throttle harvest in 2 s (J)")
	var rpm := st.rpm
	var expected := (0.5 * pt.torque_at(spec, rpm) - 0.5 * spec.engine_brake_torque * (rpm - spec.rpm_idle) / (spec.engine_brake_rpm - spec.rpm_idle)) * pt.ratio(st, spec) * spec.driveline_efficiency
	assert_between(st.drive_torque[2] + st.drive_torque[3], expected - 5.0, expected + 5.0, "drive torque unchanged by the harvest (N m)")

func test_step_is_deterministic() -> void:
	var out: Array[float] = []
	for run in 2:
		_bench(0.0, 1)
		st.throttle = 1.0
		st.in_throttle = 1.0
		var sum := 0.0
		for k in 720:
			var v := 9.0 * k * DT
			_roll(v * 3.6, st.gear)
			st.shift_request = 1 if st.rpm > spec.rpm_shift_up and st.shifting <= 0.0 else 0
			pt.step(st, spec, DT)
			sum += st.drive_torque[2] + st.rpm + st.ers_energy * 1e-3
		out.append(sum)
	assert_true(out[0] == out[1], "two identical runs give identical results")

# ---------------------------------------------------------------- the whole car on the rig

func test_acceleration_times() -> void:
	var car := await SimRig.spawn(self)
	var pwr: SimPowertrain = car.sim.powertrain
	var s: SimState = car.sim.state
	assert_between(s.rpm, 3900.0, 4100.0, "idling on the grid (rpm)")
	assert_true(car.linear_velocity.length() < 0.05, "no creep in 1st at idle")
	# Launch by hand (as SimRig.launch does) to watch the gears and the clutch as well.
	car.set_input_override(1.0, 0.0, 0.0)
	var t100 := -1.0
	var t200 := -1.0
	var t300 := -1.0
	var gears_in_order := true
	var top_gear := 1
	var slip_rpm_lo := INF
	var slip_rpm_hi := 0.0
	var lock_changes := 0
	var was_locked := false
	var lock_kmh := 0.0
	var max_rpm := 0.0
	var e0 := s.ers_energy
	for k in 14 * SimRig.HZ:
		await get_tree().physics_frame
		var t := (k + 1) * SimRig.TICK
		var kmh := car.linear_velocity.length() * 3.6
		if t100 < 0.0 and kmh >= 100.0: t100 = t
		if t200 < 0.0 and kmh >= 200.0: t200 = t
		if t300 < 0.0 and kmh >= 300.0: t300 = t
		if s.gear != top_gear:
			gears_in_order = gears_in_order and s.gear == top_gear + 1
			top_gear = s.gear
		if top_gear == 1 and pwr.clutch_locked != was_locked:
			lock_changes += 1
			was_locked = pwr.clutch_locked
			lock_kmh = kmh
		if t > 0.25 and not pwr.clutch_locked and lock_changes == 0:
			slip_rpm_lo = minf(slip_rpm_lo, s.rpm)
			slip_rpm_hi = maxf(slip_rpm_hi, s.rpm)
		max_rpm = maxf(max_rpm, s.rpm)
	var v_end := car.linear_velocity.length() * 3.6
	print("    launch: 0-100 %.2f s, 0-200 %.2f s, 0-300 %.2f s, %.0f km/h after 14 s in gear %d" % [t100, t200, t300, v_end, s.gear])
	print("    clutch slipped at %.0f-%.0f rpm and locked at %.0f km/h (%d change(s)); highest rpm %.0f; %.2f MJ deployed" % [
			slip_rpm_lo, slip_rpm_hi, lock_kmh, lock_changes, max_rpm, (e0 - s.ers_energy) / 1e6])
	assert_between(t100, 2.3, 2.9, "0-100 km/h (s), reference about 2.6")
	assert_between(t200, 4.2, 5.2, "0-200 km/h (s), reference 4.5-5")
	assert_between(t300, 8.6, 11.0, "0-300 km/h (s), reference 10-11 with race fuel and more drag")
	assert_true(gears_in_order, "gears went up one at a time")
	assert_true(top_gear == 8, "reached 8th (gear %d)" % top_gear)
	assert_true(lock_changes == 1, "the clutch locked once in the launch (%d changes)" % lock_changes)
	assert_between(lock_kmh, 25.0, 90.0, "speed where the clutch locked (km/h)")
	assert_true(slip_rpm_lo > spec_rpm(car, &"rpm_idle") + 1000.0, "engine held revs while the clutch slipped (%.0f rpm)" % slip_rpm_lo)
	assert_true(max_rpm < spec_rpm(car, &"rpm_shift_up") + 400.0, "upshifts keep the engine off the limiter (%.0f rpm)" % max_rpm)
	assert_true(absf(car.global_position.x) < 1.0, "the launch stays straight (x = %.2f m)" % car.global_position.x)
	# The rig's own launch agrees (fresh car, same numbers).
	car.queue_free()
	var car2 := await SimRig.spawn(self)
	var l := await SimRig.launch(self, car2, 12.0)
	assert_between(l["t_100"], t100 - 0.05, t100 + 0.05, "SimRig.launch 0-100 (s)")
	assert_between(l["t_300"], t300 - 0.05, t300 + 0.05, "SimRig.launch 0-300 (s)")

func spec_rpm(car: Car, field: StringName) -> float:
	return float(car.sim.spec.get(field))

func test_empty_battery_is_slower() -> void:
	var times: Array[float] = []
	var power: Array[float] = []
	for empty: bool in [false, true]:
		var car := await SimRig.spawn(self)
		var s: SimState = car.sim.state
		SimRig.set_speed(car, 150.0)
		if empty:
			s.ers_energy = 0.0
		car.set_input_override(1.0, 0.0, 0.0)
		var t := 0.0
		var p_at_250 := 0.0
		while car.linear_velocity.length() * 3.6 < 300.0 and t < 20.0:
			await get_tree().physics_frame
			t += SimRig.TICK
			if p_at_250 == 0.0 and car.linear_velocity.length() * 3.6 >= 250.0 and s.shifting <= 0.0:
				# Power reaching the car: thrust plus drag, times speed.
				p_at_250 = (s.accel_long * s.mass + s.drag) * s.speed
		times.append(t)
		power.append(p_at_250)
		assert_true(not empty or s.ers_energy < 1.0, "an empty battery stays empty at full throttle")
		car.queue_free()
		await physics_frames(2)
	print("    150-300 km/h: %.2f s with the battery, %.2f s empty; at 250 km/h %.0f kW against %.0f kW at the wheels" % [
			times[0], times[1], power[0] / 1000.0, power[1] / 1000.0])
	assert_true(times[1] > times[0] + 0.5, "measurably slower without electric power (%.2f s vs %.2f s)" % [times[1], times[0]])
	assert_between(power[0] - power[1], 90000.0, 125000.0, "power lost with an empty battery, about 120 kW at the crank (W at the wheels)")

func test_engine_braking_on_lift_off() -> void:
	var car := await SimRig.spawn(self)
	var s: SimState = car.sim.state
	SimRig.set_speed(car, 200.0)
	await SimRig.drive(self, car, 0.5, 1.0, 0.0, 0.0)
	var samples := await SimRig.drive(self, car, 0.5, 0.0, 0.0, 0.0)
	var decel := 0.0
	var n := 0
	for i in range(samples.size() / 2, samples.size()):
		decel -= samples[i]["ax"]
		n += 1
	decel /= n
	var drag_decel := s.drag / s.mass
	var axle := s.drive_torque[2] + s.drive_torque[3]
	print("    lift-off at %.0f km/h in gear %d: %.2f g, of which drag %.2f g and engine braking %.2f g (%.0f N m at the axle)" % [
			s.speed * 3.6, s.gear, decel / SimRig.G, drag_decel / SimRig.G, (decel - drag_decel) / SimRig.G, axle])
	assert_true(axle < 0.0, "the engine brakes the rear axle")
	assert_between((decel - drag_decel) / SimRig.G, 0.05, 0.40, "engine-braking deceleration beyond drag (g)")
	assert_true(s.slip_ratio[2] < 0.0 and s.slip_ratio[2] > -0.05, "rear wheels are slowed but nowhere near locking (slip %.3f)" % s.slip_ratio[2])

func test_reverse() -> void:
	var car := await SimRig.spawn(self)
	var s: SimState = car.sim.state
	# Brake held at a standstill selects reverse and drives backwards.
	var fwd := -car.global_transform.basis.z
	await SimRig.drive(self, car, 3.0, 0.0, 1.0, 0.0)
	assert_true(s.gear == -1 and car.gear == -1, "reverse selected (gear %d)" % s.gear)
	var v_back := car.linear_velocity.dot(fwd)
	print("    reverse: %.1f km/h after 3 s, %.0f rpm" % [v_back * 3.6, s.rpm])
	assert_between(v_back * 3.6, -90.0, -10.0, "reversing speed after 3 s (km/h)")
	# Throttle goes back to 1st and drives forward again.
	await SimRig.drive(self, car, 4.0, 1.0, 0.0, 0.0)
	assert_true(s.gear >= 1, "forward gear again (gear %d)" % s.gear)
	assert_true(car.linear_velocity.dot(fwd) > 10.0, "driving forward again (%.1f m/s)" % car.linear_velocity.dot(fwd))
	# Braking at speed never selects reverse.
	var b := await SimRig.brake_from(self, car, 150.0, 20.0)
	assert_true(s.gear >= 1, "no reverse while moving (gear %d, %.0f m)" % [s.gear, b["distance"]])

func test_braking_downshifts_and_harvests() -> void:
	var car := await SimRig.spawn(self)
	var s: SimState = car.sim.state
	var pwr: SimPowertrain = car.sim.powertrain
	SimRig.set_speed(car, 300.0)
	await SimRig.drive(self, car, 0.3, 1.0, 0.0, 0.0)
	s.ers_energy = 1.0e6
	var top := s.gear
	car.set_input_override(0.0, 1.0, 0.0)
	var worst_rear_slip := 0.0
	var worst_front_slip := 0.0
	var max_rpm := 0.0
	var t := 0.0
	while car.linear_velocity.length() * 3.6 > 80.0 and t < 10.0:
		await get_tree().physics_frame
		t += SimRig.TICK
		worst_front_slip = minf(worst_front_slip, minf(s.slip_ratio[0], s.slip_ratio[1]))
		max_rpm = maxf(max_rpm, s.rpm)
		worst_rear_slip = minf(worst_rear_slip, minf(s.slip_ratio[2], s.slip_ratio[3]))
	var low := s.gear
	car.set_input_override(0.0, 0.0, 0.0)
	print("    braking 300-80 km/h in %.2f s: gear %d to %d, highest rpm %.0f, %.0f kJ harvested, worst slip rear %.2f, front %.2f" % [
			t, top, low, max_rpm, (s.ers_energy - 1.0e6) / 1000.0, worst_rear_slip, worst_front_slip])
	# The engine and the downshifts must not push the rear wheels further into slip than the
	# brakes alone take the fronts.
	assert_true(worst_rear_slip > worst_front_slip - 0.08, "downshifts do not lock the rear wheels (rear %.2f, front %.2f)" % [worst_rear_slip, worst_front_slip])
	assert_true(top >= 7 and low <= 4, "the gearbox came down the gears (%d to %d)" % [top, low])
	assert_true(max_rpm < car.sim.spec.rpm_downshift_limit + 200.0, "no over-rev on the way down (%.0f rpm)" % max_rpm)
	assert_true(s.ers_energy > 1.0e6 + 1.0e5, "energy harvested under braking (%.0f kJ)" % ((s.ers_energy - 1.0e6) / 1000.0))
	assert_true(pwr.lap_harvested <= car.sim.spec.ers_harvest_limit, "harvest within the lap limit")
