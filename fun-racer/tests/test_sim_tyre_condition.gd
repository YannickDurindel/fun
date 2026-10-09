extends TestCase
## Tyre temperature, wear, flat spots, compounds and fuel (SimTyreCondition). The pure tests
## build a SimState by hand and call the part's step; the last test drives the rig.

const DT: float = 1.0 / 240.0
## Fast-forward of the rig test (simulated seconds per real second).
const FAST: int = 10

var state: SimState
var spec: CarSpec
var cond: SimTyreCondition

func _fresh(compound: StringName = &"medium") -> void:
	state = SimState.new()
	spec = CarSpec.new()
	cond = SimTyreCondition.new()
	cond.setup(spec)
	state.compound = compound
	cond.reset(state, spec)

## All four wheels rolling straight at `speed` (m/s) with no slip and no tyre force.
func _roll(speed: float, load: float = 4000.0) -> void:
	state.speed = speed
	for i in 4:
		state.contact[i] = true
		state.load[i] = load
		state.wheel_v_long[i] = speed
		state.wheel_v_lat[i] = 0.0
		state.slip_ratio[i] = 0.0
		state.slip_angle[i] = 0.0
		state.tyre_fx[i] = 0.0
		state.tyre_fy[i] = 0.0
		state.locked[i] = false

## All four wheels cornering hard at `speed`: `fy` N of side force with the patch sliding
## sideways at `v_lat` m/s.
func _slide(speed: float, fy: float = 7000.0, v_lat: float = 6.0) -> void:
	_roll(speed, 5000.0)
	for i in 4:
		state.wheel_v_lat[i] = v_lat
		state.slip_angle[i] = atan2(v_lat, speed)
		state.tyre_fy[i] = -fy

func _run(seconds: float) -> void:
	for k in int(seconds / DT):
		cond.step(state, spec, DT)

func _set_temp(temp: float) -> void:
	for i in 4:
		cond.surface_temp[i] = temp
		cond.core_temp[i] = temp

func test_starts_from_the_blankets() -> void:
	_fresh()
	for i in 4:
		assert_between(state.tyre_temp[i], 69.9, 70.1, "blanket temperature of a medium (deg C)")
		assert_true(state.tyre_wear[i] == 0.0, "a new tyre has no wear")
		assert_between(state.grip_factor[i], 0.85, 0.999, "a tyre out of the blankets is a little below its peak")
	assert_true(state.compound == &"medium", "medium by default")
	assert_between(state.mass, spec.dry_mass + spec.fuel_start - 0.01, spec.dry_mass + spec.fuel_start + 0.01, "mass = dry mass + fuel (kg)")

func test_sliding_heats_and_rolling_in_clean_air_cools() -> void:
	_fresh()
	_slide(50.0)
	_run(3.0)
	var after_3s := state.tyre_temp[0]
	assert_true(after_3s > 72.0, "3 s of sliding heat the tyre (%.1f C)" % after_3s)
	assert_true(cond.surface_temp[0] > cond.core_temp[0] + 3.0, "the surface heats first (surface %.1f, core %.1f)" % [cond.surface_temp[0], cond.core_temp[0]])
	_run(40.0)
	var hot := state.tyre_temp[0]
	assert_true(hot > after_3s + 10.0, "sliding on keeps heating (%.1f C)" % hot)
	assert_true(cond.slide_energy[0] > 1.0e6, "sliding energy is counted")
	# Rolling straight in clean air: no friction heat, air and road take the heat away.
	_roll(40.0, 3000.0)
	var surface_hot := cond.surface_temp[0]
	var core_hot := cond.core_temp[0]
	_run(4.0)
	var surface_drop := surface_hot - cond.surface_temp[0]
	var core_drop := core_hot - cond.core_temp[0]
	assert_true(surface_drop > 5.0, "the surface cools within seconds (%.1f C in 4 s)" % surface_drop)
	assert_true(core_drop < surface_drop * 0.5, "the core follows slowly (%.1f C against %.1f C)" % [core_drop, surface_drop])
	_run(90.0)
	assert_true(state.tyre_temp[0] < hot - 10.0, "more rolling cools the tyre (%.1f -> %.1f C)" % [hot, state.tyre_temp[0]])
	assert_true(state.tyre_temp[0] > spec.tyre_ambient_temp, "never below the air")
	# Faster air cools more.
	_fresh()
	_set_temp(120.0)
	_roll(20.0)
	_run(10.0)
	var slow_air := state.tyre_temp[0]
	_fresh()
	_set_temp(120.0)
	_roll(80.0, 1000.0)
	_run(10.0)
	assert_true(state.tyre_temp[0] < slow_air, "more airflow cools more (%.1f C at 80 m/s, %.1f C at 20 m/s)" % [state.tyre_temp[0], slow_air])

func test_load_and_speed_heat_the_core() -> void:
	_fresh()
	_set_temp(40.0)
	_roll(80.0, 2000.0)
	_run(120.0)
	var light := cond.core_temp[0]
	_fresh()
	_set_temp(40.0)
	_roll(80.0, 9000.0)
	_run(120.0)
	assert_true(cond.core_temp[0] > light + 5.0, "a loaded tyre flexes itself warmer (%.1f C against %.1f C)" % [cond.core_temp[0], light])

func test_grip_has_a_window_per_compound_and_a_floor() -> void:
	var centres: Array[float] = []
	for compound in SimTyreCompounds.NAMES:
		_fresh(compound)
		var row := SimTyreCompounds.row(compound)
		var low: float = row["temp_low"]
		var high: float = row["temp_high"]
		var centre := (low + high) * 0.5
		centres.append(centre)
		assert_between(cond.temp_factor(spec, centre), 0.9999, 1.0001, "%s: peak at the centre of the window" % compound)
		assert_between(cond.temp_factor(spec, low), 0.95, 0.999, "%s: a little less at the cold edge" % compound)
		assert_between(cond.temp_factor(spec, high), 0.95, 0.999, "%s: a little less at the hot edge" % compound)
		assert_true(cond.temp_factor(spec, low - 15.0) < cond.temp_factor(spec, low), "%s: colder is worse" % compound)
		assert_true(cond.temp_factor(spec, high + 15.0) < cond.temp_factor(spec, high), "%s: hotter is worse" % compound)
		assert_true(cond.temp_factor(spec, high + 10.0) < cond.temp_factor(spec, low - 10.0), "%s: overheating costs more than running cold" % compound)
		assert_between(cond.temp_factor(spec, -40.0), spec.tyre_temp_grip_floor - 1e-6, spec.tyre_temp_grip_floor + 1e-6, "%s: floor when frozen" % compound)
		assert_between(cond.temp_factor(spec, 400.0), spec.tyre_temp_grip_floor - 1e-6, spec.tyre_temp_grip_floor + 1e-6, "%s: floor when cooked" % compound)
		# Monotonic on each side of the centre.
		var prev := 0.0
		for t in range(-20, int(centre) + 1, 5):
			var f := cond.temp_factor(spec, float(t))
			assert_true(f >= prev, "%s: grip rises towards the window (%d C)" % [compound, t])
			prev = f
		# The state's grip factor is the compound's grip times the temperature factor.
		_set_temp(centre)
		_roll(0.0)
		cond.step(state, spec, 1e-6)
		assert_between(state.grip_factor[0], float(row["grip_dry"]) - 1e-3, float(row["grip_dry"]) + 1e-3, "%s: grip factor at the centre of the window" % compound)
		_set_temp(high + 300.0)
		cond.step(state, spec, 1e-6)
		assert_between(state.grip_factor[0], float(row["grip_dry"]) * 0.75 - 2e-3, float(row["grip_dry"]) * 0.75 + 2e-3, "%s: grip factor floor when overheated" % compound)
	assert_between(spec.tyre_temp_grip_floor, 0.70, 0.80, "the floor is about 0.75")
	assert_true(centres[0] < centres[1] and centres[1] < centres[2], "softer slicks work colder")
	assert_true(centres[4] < centres[3] and centres[3] < centres[0], "rain tyres work colder still")

func test_wear_is_monotonic_and_lowers_grip_with_a_cliff() -> void:
	_fresh()
	spec.wear_rate_scale = 400.0
	_slide(50.0)
	var prev := 0.0
	var monotonic := true
	var steps := 0
	while state.tyre_wear[0] < 1.0 and steps < 240 * 600:
		cond.step(state, spec, DT)
		monotonic = monotonic and state.tyre_wear[0] >= prev
		prev = state.tyre_wear[0]
		steps += 1
	assert_true(monotonic, "wear never goes down")
	assert_true(steps > 240, "wearing a tyre out takes time even at 400x (%d ticks)" % steps)
	assert_between(state.tyre_wear[0], 0.9999, 1.0, "wear stops at 1")
	_run(1.0)
	assert_true(state.tyre_wear[0] <= 1.0, "wear stays at 1")
	# Grip against wear: a slow loss, then the cliff.
	var cliff := spec.tyre_wear_cliff
	assert_between(cond.wear_factor(spec, 0.0), 0.9999, 1.0001, "a new tyre has all its grip")
	var last := 1.0
	for k in range(1, 101):
		var f := cond.wear_factor(spec, k / 100.0)
		assert_true(f < last, "grip falls with wear (%d%%)" % k)
		last = f
	var at_cliff := cond.wear_factor(spec, cliff)
	assert_between(at_cliff, 0.90, 0.97, "grip at the cliff")
	var slope_before := (1.0 - at_cliff) / cliff
	var slope_after := (at_cliff - cond.wear_factor(spec, 1.0)) / (1.0 - cliff)
	assert_true(slope_after > slope_before * 5.0, "the cliff is much steeper (%.3f against %.3f per unit of wear)" % [slope_after, slope_before])
	assert_between(cond.wear_factor(spec, 1.0), 0.6, 0.8, "a worn out tyre still drives")
	# Through the state: same temperature, worn against new.
	_fresh()
	_set_temp(103.0)
	_roll(0.0)
	cond.step(state, spec, 1e-6)
	var new_grip := state.grip_factor[0]
	spec.wear_rate_scale = 400.0
	_slide(50.0)
	_run(20.0)
	var worn := state.tyre_wear[0]
	_set_temp(103.0)
	_roll(0.0)
	cond.step(state, spec, 1e-6)
	assert_true(worn > 0.01 and state.grip_factor[0] < new_grip, "a worn tyre grips less at the same temperature (wear %.3f: %.4f against %.4f)" % [worn, state.grip_factor[0], new_grip])
	assert_between(state.grip_factor[0], new_grip * cond.wear_factor(spec, worn) - 1e-3, new_grip * cond.wear_factor(spec, worn) + 1e-3, "grip factor follows the wear curve")

func test_overheating_wears_faster() -> void:
	_fresh()
	_roll(50.0)
	_slide(50.0)
	_set_temp(100.0)
	cond.step(state, spec, DT)
	var in_window := state.tyre_wear[0]
	_fresh()
	_slide(50.0)
	_set_temp(150.0)
	cond.step(state, spec, DT)
	assert_true(state.tyre_wear[0] > in_window * 1.5, "the same sliding wears more above the window (%.3f against %.3f millionths)" % [state.tyre_wear[0] * 1e6, in_window * 1e6])

func test_a_locked_wheel_makes_a_flat_spot() -> void:
	_fresh()
	_roll(40.0)
	_set_temp(103.0)
	# Front left locked: the patch slides at the car's speed.
	state.locked[0] = true
	state.slip_ratio[0] = -1.0
	state.tyre_fx[0] = -7000.0
	_run(1.5)
	assert_true(cond.flat_spot[0] > 0.2, "1.5 s locked at 144 km/h leaves a flat spot (%.2f)" % cond.flat_spot[0])
	assert_true(cond.flat_spot[1] == 0.0 and cond.flat_spot[2] == 0.0, "only on the locked wheel")
	assert_true(state.tyre_wear[0] > state.tyre_wear[1] + 0.01, "locking wears quickly (%.4f against %.4f)" % [state.tyre_wear[0], state.tyre_wear[1]])
	assert_true(cond.vibration[0] > 0.2 and cond.vibration[1] == 0.0, "the flat spot shakes that wheel at speed")
	var flat := cond.flat_spot[0]
	# Released: the flat spot stays, and so does the grip loss at an equal temperature and wear.
	_roll(40.0)
	_run(30.0)
	assert_true(cond.flat_spot[0] == flat, "a flat spot is permanent")
	_set_temp(103.0)
	_roll(0.0)
	cond.step(state, spec, 1e-6)
	# Wheel 0 is also more worn; take the wear out to see the flat spot's own cost.
	var by_wear := cond.wear_factor(spec, state.tyre_wear[0]) / cond.wear_factor(spec, state.tyre_wear[1])
	var by_flat := state.grip_factor[0] / (state.grip_factor[1] * by_wear)
	assert_between(by_flat, 1.0 - spec.tyre_flat_grip_loss * flat - 1e-4, 1.0 - spec.tyre_flat_grip_loss * flat + 1e-4, "grip lost to the flat spot alone")
	assert_true(by_flat < 0.99, "the flat-spotted tyre grips less (x %.4f)" % by_flat)
	assert_true(cond.vibration[0] == 0.0, "no vibration at a standstill")
	# Sliding sideways with the wheel locked damages it too.
	_fresh()
	_roll(2.0)
	for i in 4:
		state.wheel_v_lat[i] = 40.0
	state.locked[0] = true
	_run(1.0)
	assert_true(cond.flat_spot[0] > 0.2 and cond.flat_spot[1] == 0.0, "a locked wheel sliding sideways flat-spots (%.2f)" % cond.flat_spot[0])
	# A wheel held on the brake at a standstill is not damaged.
	_fresh()
	_roll(0.0)
	state.locked[0] = true
	_run(5.0)
	assert_true(cond.flat_spot[0] == 0.0 and state.tyre_wear[0] == 0.0, "no flat spot without movement")
	# A new set clears it.
	_fresh()
	_roll(40.0)
	state.locked[0] = true
	_run(1.0)
	assert_true(cond.set_compound(state, spec, &"hard"), "fit a new set")
	assert_true(cond.flat_spot[0] == 0.0 and state.tyre_wear[0] == 0.0, "a new set has no flat spot and no wear")

func test_compound_ordering() -> void:
	var grip: Dictionary = {}
	var wear: Dictionary = {}
	for compound in SimTyreCompounds.NAMES:
		_fresh(compound)
		assert_true(state.compound == compound, "compound %s fitted" % compound)
		var row := SimTyreCompounds.row(compound)
		_set_temp((float(row["temp_low"]) + float(row["temp_high"])) * 0.5)
		_roll(0.0)
		cond.step(state, spec, 1e-6)
		grip[compound] = state.grip_factor[0]
		_slide(50.0)
		_run(20.0)
		wear[compound] = state.tyre_wear[0]
	assert_between(grip[&"medium"], 0.999, 1.001, "the medium is the reference")
	assert_true(grip[&"soft"] > grip[&"medium"] and grip[&"medium"] > grip[&"hard"], "dry grip: soft > medium > hard")
	assert_true(grip[&"hard"] > grip[&"intermediate"] and grip[&"intermediate"] > grip[&"wet"], "dry grip: slicks > intermediate > wet")
	assert_between(grip[&"soft"] / grip[&"hard"], 1.03, 1.12, "soft against hard grip")
	assert_true(wear[&"soft"] > wear[&"medium"] * 1.3 and wear[&"medium"] > wear[&"hard"] * 1.3, "wear: soft > medium > hard (%.4f, %.4f, %.4f)" % [wear[&"soft"], wear[&"medium"], wear[&"hard"]])
	assert_true(wear[&"intermediate"] > wear[&"soft"] and wear[&"wet"] > wear[&"intermediate"], "rain tyres are destroyed on a dry road")
	# Heat: the soft warms up faster than the hard from the same blanket temperature.
	_fresh(&"soft")
	_slide(50.0)
	_run(10.0)
	var soft_temp := state.tyre_temp[0]
	_fresh(&"hard")
	_slide(50.0)
	_run(10.0)
	assert_true(soft_temp > state.tyre_temp[0] + 0.5, "the soft heats faster than the hard (%.1f against %.1f C)" % [soft_temp, state.tyre_temp[0]])
	# Unknown names change nothing.
	_fresh(&"soft")
	assert_true(not cond.set_compound(state, spec, &"hypersoft"), "unknown compound refused")
	assert_true(state.compound == &"soft", "the compound stays")
	state.compound = &"nonsense"
	cond.reset(state, spec)
	assert_true(state.compound == &"medium", "reset falls back to the medium")

func test_a_respawn_can_keep_the_stint() -> void:
	_fresh()
	cond.set_fuel(state, spec, 60.0)
	spec.wear_rate_scale = 50.0
	_slide(50.0)
	state.locked[0] = true
	_run(5.0)
	var wear := state.tyre_wear[0]
	var temp := state.tyre_temp[0]
	var flat := cond.flat_spot[0]
	cond.keep_on_reset = true
	cond.reset(state, spec)
	assert_true(state.tyre_wear[0] == wear and cond.flat_spot[0] == flat and state.tyre_temp[0] == temp, "a respawn in the race keeps the tyres as they are")
	assert_between(state.fuel, 59.0, 60.0, "and the fuel")
	assert_between(state.mass, spec.dry_mass + state.fuel - 1e-3, spec.dry_mass + state.fuel + 1e-3, "and the mass")
	cond.keep_on_reset = false
	cond.reset(state, spec)
	assert_true(state.tyre_wear[0] == 0.0 and cond.flat_spot[0] == 0.0 and state.fuel == spec.fuel_start, "a new run starts fresh")

func test_wet_track_reverses_the_order() -> void:
	var c := SimTyreCompounds
	assert_true(c.grip(&"wet", 1.0) > c.grip(&"intermediate", 1.0), "standing water: wet > intermediate")
	assert_true(c.grip(&"intermediate", 1.0) > c.grip(&"soft", 1.0) * 1.4, "standing water: slicks are far slower")
	assert_true(c.grip(&"intermediate", 0.5) > c.grip(&"wet", 0.5), "damp: the intermediate is the tyre")
	assert_true(c.grip(&"intermediate", 0.5) > c.grip(&"soft", 0.5), "damp: slicks are slower")
	assert_true(c.grip(&"soft", 0.0) > c.grip(&"intermediate", 0.0), "dry: slicks are faster")
	for compound in c.NAMES:
		assert_true(c.grip(compound, 1.0) <= c.grip(compound, 0.0), "%s: no more grip in the wet than in the dry" % compound)
		assert_true(c.grip(compound, 0.25) <= c.grip(compound, 0.0) and c.grip(compound, 0.75) <= c.grip(compound, 0.5), "%s: grip falls with wetness" % compound)
	# The part's single wetness parameter drives the state.
	_fresh(&"soft")
	_set_temp(95.0)
	_roll(0.0)
	cond.step(state, spec, 1e-6)
	var dry := state.grip_factor[0]
	cond.track_wetness = 1.0
	cond.step(state, spec, 1e-6)
	assert_between(state.grip_factor[0] / dry, 0.3, 0.5, "a slick on standing water against dry")
	# A wet road cools the tyre more.
	_fresh()
	_set_temp(100.0)
	_roll(40.0)
	_run(5.0)
	var dry_temp := state.tyre_temp[0]
	_fresh()
	cond.track_wetness = 1.0
	_set_temp(100.0)
	_roll(40.0)
	_run(5.0)
	assert_true(state.tyre_temp[0] < dry_temp - 1.0, "a wet road cools more (%.1f against %.1f C)" % [state.tyre_temp[0], dry_temp])

func test_fuel_burns_with_throttle_and_mass_follows() -> void:
	_fresh()
	cond.set_fuel(state, spec, 100.0)
	assert_between(state.mass, spec.dry_mass + 99.999, spec.dry_mass + 100.001, "mass with 100 kg of fuel")
	state.throttle = 1.0
	state.rpm = 12000.0
	_run(36.0)
	var burnt := 100.0 - state.fuel
	assert_between(burnt, 0.95, 1.05, "full power for 36 s burns 1 kg (100 kg/h)")
	assert_between(cond.fuel_flow(spec, 1.0, 12000.0) * 3600.0, 95.0, 105.0, "full flow (kg/h)")
	assert_between(state.mass, spec.dry_mass + state.fuel - 1e-3, spec.dry_mass + state.fuel + 1e-3, "mass follows the fuel")
	assert_between(cond.fuel_used, burnt - 1e-3, burnt + 1e-3, "fuel used is counted")
	# Lifting burns almost nothing; half the revs burn about half.
	var before := state.fuel
	state.throttle = 0.0
	_run(36.0)
	var idle := before - state.fuel
	assert_true(idle > 0.0 and idle < burnt * 0.1, "closed throttle burns little (%.3f kg)" % idle)
	# In reverse the brake pedal is the accelerator.
	before = state.fuel
	state.gear = -1
	state.in_brake = 1.0
	_run(36.0)
	assert_true(before - state.fuel > idle * 5.0, "reversing under power burns fuel (%.3f kg)" % (before - state.fuel))
	state.gear = 1
	state.in_brake = 0.0
	assert_true(cond.fuel_flow(spec, 0.5, 12000.0) < cond.fuel_flow(spec, 1.0, 12000.0) * 0.6, "half throttle burns about half")
	assert_between(cond.fuel_flow(spec, 1.0, spec.fuel_flow_rpm * 0.5) / cond.fuel_flow(spec, 1.0, 12000.0), 0.45, 0.6, "half the flow at half the limit rpm")
	assert_between(cond.fuel_flow(spec, 1.0, 13000.0), cond.fuel_flow(spec, 1.0, 11000.0) - 1e-9, cond.fuel_flow(spec, 1.0, 11000.0) + 1e-9, "the flow is capped above the limit rpm")
	# A race distance fits in the tank at full flow for two thirds of the time.
	assert_true(spec.fuel_capacity <= 110.0, "110 kg at most")
	# The tank runs dry, not negative.
	cond.set_fuel(state, spec, 0.01)
	state.throttle = 1.0
	_run(5.0)
	assert_true(state.fuel == 0.0, "the tank runs dry (%.6f kg)" % state.fuel)
	assert_between(state.mass, spec.dry_mass - 1e-3, spec.dry_mass + 1e-3, "mass of the empty car")
	cond.set_fuel(state, spec, 500.0)
	assert_true(state.fuel == spec.fuel_capacity, "no more than the tank holds")

func test_the_scale_factors_scale() -> void:
	_fresh()
	_slide(50.0)
	state.throttle = 1.0
	state.rpm = 12000.0
	_run(20.0)
	var wear_1 := state.tyre_wear[0]
	var fuel_1 := cond.fuel_used
	var temp_1 := state.tyre_temp[0]
	_fresh()
	spec.wear_rate_scale = 6.0
	spec.fuel_burn_scale = 3.0
	_slide(50.0)
	state.throttle = 1.0
	state.rpm = 12000.0
	_run(20.0)
	assert_true(wear_1 > 0.0 and fuel_1 > 0.0, "something was worn and burnt")
	assert_between(state.tyre_wear[0] / wear_1, 5.99, 6.01, "wear_rate_scale 6 wears 6 times as fast")
	assert_between(cond.fuel_used / fuel_1, 2.99, 3.01, "fuel_burn_scale 3 burns 3 times as fast")
	assert_between(state.tyre_temp[0], temp_1 - 1e-3, temp_1 + 1e-3, "the scales do not touch the temperatures")
	_fresh()
	spec.wear_rate_scale = 0.0
	spec.fuel_burn_scale = 0.0
	_slide(50.0)
	state.throttle = 1.0
	state.rpm = 12000.0
	_run(5.0)
	assert_true(state.tyre_wear[0] == 0.0 and state.fuel == spec.fuel_start, "scale 0 turns wear and fuel burn off")

func test_step_is_deterministic() -> void:
	var temps: Array[float] = []
	for pass_i in 2:
		_fresh(&"soft")
		_slide(60.0)
		state.throttle = 0.7
		state.rpm = 9000.0
		_run(15.0)
		temps.append(state.tyre_temp[2])
		temps.append(state.tyre_wear[2])
		temps.append(state.fuel)
	assert_true(temps[0] == temps[3] and temps[1] == temps[4] and temps[2] == temps[5], "two runs give the same numbers")

## Three minutes of weaving on the rig (run faster than real time): the temperatures stay in a
## sane band, nothing runs away and nothing is NaN.
func test_rig_three_minutes_of_weaving_stays_sane() -> void:
	var car := await SimRig.spawn(self)
	var st: SimState = car.sim.state
	var cond_live: SimTyreCondition = car.sim.condition
	assert_true(st.compound == &"medium", "the rig car starts on mediums")
	var fuel_start := st.fuel
	SimRig.set_speed(car, 160.0)
	await _fast_forward(true)
	var lo := INF
	var hi := -INF
	var finite := true
	var grip_lo := INF
	var grip_hi := -INF
	var target := 160.0 / 3.6
	var ticks := 180 * SimRig.HZ
	for k in ticks:
		var t := k * SimRig.TICK
		# Weave: 0.35 Hz, with a harder phase every 20 s that slides the tyres.
		var amp := 0.5 if fmod(t, 20.0) < 6.0 else 0.22
		var err := target - car.linear_velocity.length()
		car.set_input_override(clampf(0.4 + err * 0.4, 0.0, 1.0), 0.0, amp * sin(TAU * 0.35 * t))
		await get_tree().physics_frame
		for i in 4:
			var temp := st.tyre_temp[i]
			finite = finite and is_finite(temp) and is_finite(st.tyre_wear[i]) and is_finite(st.grip_factor[i]) \
					and is_finite(cond_live.surface_temp[i]) and is_finite(cond_live.core_temp[i])
			lo = minf(lo, temp)
			hi = maxf(hi, temp)
			grip_lo = minf(grip_lo, st.grip_factor[i])
			grip_hi = maxf(grip_hi, st.grip_factor[i])
	await _fast_forward(false)
	car.set_input_override(0.0, 0.0, 0.0)
	print("    rig weave 180 s: tyre temp %.1f..%.1f C, now %.1f/%.1f/%.1f/%.1f, wear %.4f/%.4f/%.4f/%.4f, grip %.3f..%.3f, fuel used %.2f kg, %.0f km/h" % [
			lo, hi, st.tyre_temp[0], st.tyre_temp[1], st.tyre_temp[2], st.tyre_temp[3],
			st.tyre_wear[0], st.tyre_wear[1], st.tyre_wear[2], st.tyre_wear[3], grip_lo, grip_hi,
			fuel_start - st.fuel, car.linear_velocity.length() * 3.6])
	assert_true(finite and is_finite(st.fuel) and is_finite(st.mass), "no NaN or infinity")
	assert_true(car.linear_velocity.length() > 20.0, "the car kept driving (%.0f km/h)" % (car.linear_velocity.length() * 3.6))
	assert_between(lo, 40.0, 71.0, "coldest tyre temperature (deg C)")
	assert_between(hi, 75.0, 160.0, "hottest tyre temperature (deg C)")
	assert_between(grip_lo, 0.75, 1.0, "lowest grip factor")
	assert_true(grip_hi <= 1.0001, "a medium never exceeds its peak")
	for i in 4:
		assert_between(st.tyre_wear[i], 1e-5, 0.3, "wear of wheel %d after 3 minutes" % i)
	assert_between(fuel_start - st.fuel, 0.2, 5.1, "fuel burnt in 3 minutes (kg)")
	assert_between(st.mass, spec_mass(car) - 0.01, spec_mass(car) + 0.01, "mass follows the fuel")
	assert_between(car.mass, st.mass - 0.06, st.mass + 0.06, "the body's mass follows")

## Faster than real time with the same 1/240 s step: the engine runs FAST times as many
## physics ticks per second, each of 1/(240 FAST) s x time_scale FAST.
func _fast_forward(on: bool) -> void:
	Engine.physics_ticks_per_second = SimRig.HZ * (FAST if on else 1)
	Engine.time_scale = float(FAST) if on else 1.0
	await get_tree().physics_frame
	assert_between(get_physics_process_delta_time(), SimRig.TICK * 0.999, SimRig.TICK * 1.001, "the physics step stays 1/240 s")

## The weight of the fuel on the rig: a full tank against a time-attack load. Prints the
## numbers used for the lap-time sensitivity in the PR.
func test_rig_fuel_load_costs_time() -> void:
	var res: Array[Dictionary] = []
	for kg: float in [10.0, 100.0]:
		var car := await SimRig.spawn(self)
		var sim: SimHandling = car.sim
		# No burn and no wear, and the same manoeuvres, so only the mass differs.
		sim.spec = sim.spec.duplicate() as CarSpec
		sim.spec.fuel_burn_scale = 0.0
		sim.spec.wear_rate_scale = 0.0
		sim.condition.set_fuel(sim.state, sim.spec, kg)
		await _fast_forward(true)
		await physics_frames(SimRig.HZ)
		assert_between(car.mass, sim.spec.dry_mass + kg - 0.1, sim.spec.dry_mass + kg + 0.1, "the body weighs the car and %.0f kg of fuel" % kg)
		var l := await SimRig.launch(self, car, 14.0)
		var b := await SimRig.brake_from(self, car, 300.0, 100.0)
		var c := await SimRig.max_lateral_g(self, car, 150.0)
		await _fast_forward(false)
		res.append({"t_100": l["t_100"], "t_200": l["t_200"], "t_300": l["t_300"], "brake_m": b["distance"], "brake_s": b["time"], "lat_g": c["lat_g"]})
		print("    fuel %3.0f kg: 0-100 %.3f s, 0-200 %.3f s, 0-300 %.3f s | 300-100 km/h in %.1f m, %.3f s | %.3f g at 150 km/h" % [
				kg, l["t_100"], l["t_200"], l["t_300"], b["distance"], b["time"], c["lat_g"]])
		car.queue_free()
		await physics_frames(2)
	var light := res[0]
	var heavy := res[1]
	assert_true(light["t_300"] > 0.0 and heavy["t_300"] > 0.0, "both reach 300 km/h")
	assert_true(heavy["t_200"] > light["t_200"] and heavy["t_300"] > light["t_300"], "a full tank accelerates slower")
	assert_between((heavy["t_300"] - heavy["t_100"]) / (light["t_300"] - light["t_100"]), 1.03, 1.16, "100-300 km/h time, 100 kg against 10 kg")
	assert_true(heavy["brake_m"] > light["brake_m"], "a full tank stops later")
	assert_true(heavy["lat_g"] < light["lat_g"], "a full tank corners slower")

func spec_mass(car: Car) -> float:
	return car.sim.spec.mass(car.sim.state.fuel)
