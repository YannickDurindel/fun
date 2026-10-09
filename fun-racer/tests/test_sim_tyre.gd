extends TestCase
## The tyre model (scripts/car/sim/tyre_model.gd). Most tests are pure: a hand-built SimState
## and CarSpec, one wheel, no physics scene. The last ones drive the whole car on the SimRig.

const FL: int = 0
const RL: int = 2
## A rolling speed well above every low-speed blend, and a step long enough for the
## relaxation lag to settle: together they give the steady-state force.
const V_FAST: float = 50.0
const SETTLED: float = 1.0

var spec: CarSpec
var state: SimState
var tyre: SimTyreModel

func _make(load_n: float = 4000.0) -> void:
	spec = CarSpec.new()
	state = SimState.new()
	tyre = SimTyreModel.new()
	tyre.setup(spec)
	tyre.reset(state, spec)
	for i in 4:
		state.load[i] = load_n
		state.wheel_v_long[i] = V_FAST
		state.surface_mu[i] = 1.0
		state.grip_factor[i] = 1.0

## Steady-state force of wheel i at the given slips.
func _f(i: int, slip_ratio: float, slip_angle: float) -> Vector2:
	state.slip_ratio[i] = slip_ratio
	state.slip_angle[i] = slip_angle
	return tyre.forces(state, spec, i, SETTLED)

func _peak_fx(i: int) -> float:
	return tyre.mu(state, spec, i) * spec.tyre_mu_long_scale * state.load[i]

func _peak_fy(i: int) -> float:
	return tyre.mu(state, spec, i) * state.load[i]

func test_curves_pass_through_zero() -> void:
	_make()
	for i in [FL, RL]:
		var f := _f(i, 0.0, 0.0)
		assert_true(f.length() < 1e-6, "no slip, no force (wheel %d: %s)" % [i, f])
		assert_true(absf(_f(i, 0.02, 0.0).y) < 1e-6, "pure longitudinal slip gives no side force")
		assert_true(absf(_f(i, 0.0, 0.02).x) < 1e-6, "pure slip angle gives no longitudinal force")
		assert_true(_f(i, 0.001, 0.0).x > 0.0 and _f(i, 0.0, 0.001).y < 0.0, "signs: drive slip pushes forward, slip to the right pushes left")
	state.load[FL] = 0.0
	assert_true(_f(FL, 0.1, 0.1) == Vector2.ZERO, "an unloaded tyre gives no force")
	assert_true(tyre.long_stiffness(state, spec, FL) == 0.0, "and has no stiffness")

func test_peak_at_the_expected_slip() -> void:
	_make()
	for i in [FL, RL]:
		var best := 0.0
		var best_slip := 0.0
		for k in 500:
			var slip := 0.001 * k
			var fx := _f(i, slip, 0.0).x
			if fx > best:
				best = fx
				best_slip = slip
		assert_between(best_slip, spec.tyre_peak_slip_ratio - 0.003, spec.tyre_peak_slip_ratio + 0.003, "slip ratio of the peak (wheel %d)" % i)
		assert_between(best / _peak_fx(i), 0.999, 1.0001, "longitudinal peak / (mu x load) (wheel %d)" % i)
		best = 0.0
		for k in 500:
			var angle := 0.001 * k
			var fy := -_f(i, 0.0, angle).y
			if fy > best:
				best = fy
				best_slip = angle
		var expected := spec.tyre_peak_slip_angle if i < 2 else spec.tyre_peak_slip_angle_rear
		assert_between(best_slip, expected - 0.003, expected + 0.003, "slip angle of the peak (wheel %d)" % i)
		assert_between(best / _peak_fy(i), 0.999, 1.0001, "lateral peak / (mu x load) (wheel %d)" % i)
	assert_true(spec.tyre_peak_slip_angle_rear < spec.tyre_peak_slip_angle, "the wide rear tyre peaks at a smaller angle")
	# The low-speed cap is out of the way from town speeds on, whatever the load: the peaks
	# of a heavily loaded tyre at 8 m/s are where the spec puts them.
	state.load[FL] = 9000.0
	state.wheel_v_long[FL] = 8.0
	var at_peak := _f(FL, spec.tyre_peak_slip_ratio, 0.0).x
	assert_between(at_peak / _peak_fx(FL), 0.9999, 1.0001, "longitudinal peak at 8 m/s under 9000 N")
	assert_true(_f(FL, spec.tyre_peak_slip_ratio * 1.2, 0.0).x < at_peak and _f(FL, spec.tyre_peak_slip_ratio * 0.8, 0.0).x < at_peak, "and it is the peak")
	var at_peak_y := -_f(FL, 0.0, spec.tyre_peak_slip_angle).y
	assert_between(at_peak_y / _peak_fy(FL), 0.9999, 1.0001, "lateral peak at 8 m/s under 9000 N")
	assert_true(-_f(FL, 0.0, spec.tyre_peak_slip_angle * 1.2).y < at_peak_y and -_f(FL, 0.0, spec.tyre_peak_slip_angle * 0.8).y < at_peak_y, "and it is the peak")

func test_saturates_and_falls_after_the_peak() -> void:
	_make()
	var peak := _f(FL, spec.tyre_peak_slip_ratio, 0.0).x
	var prev := peak
	for k in range(1, 40):
		var fx := _f(FL, spec.tyre_peak_slip_ratio + 0.025 * k, 0.0).x
		assert_true(fx <= prev + 1e-3, "longitudinal force never rises again after the peak (slip %.3f)" % (spec.tyre_peak_slip_ratio + 0.025 * k))
		prev = fx
	var locked := -_f(FL, -1.0, 0.0).x
	print("    tyre: locked wheel keeps %.1f %% of the peak" % (100.0 * locked / peak))
	assert_between(locked / peak, 0.78, 0.92, "locked wheel force / peak (10-20 % lost)")
	assert_between(_f(FL, 2.0 * spec.tyre_peak_slip_ratio, 0.0).x / peak, 0.90, 0.995, "gentle fall-off: force at twice the peak slip / peak")
	var peak_y := -_f(FL, 0.0, spec.tyre_peak_slip_angle).y
	prev = peak_y
	for k in range(1, 40):
		var fy := -_f(FL, 0.0, spec.tyre_peak_slip_angle + 0.03 * k).y
		assert_true(fy <= prev + 1e-3, "lateral force never rises again after the peak")
		prev = fy
	var sliding := -_f(FL, 0.0, deg_to_rad(45.0)).y
	print("    tyre: sliding at 45 deg keeps %.1f %% of the peak" % (100.0 * sliding / peak_y))
	assert_between(sliding / peak_y, 0.80, 0.95, "force sliding at 45 degrees / peak")
	assert_between(-_f(FL, 0.0, 2.0 * spec.tyre_peak_slip_angle).y / peak_y, 0.90, 0.995, "gentle fall-off: force at twice the peak angle / peak")
	# Even moving purely sideways the force is finite and below the peak.
	var side := -_f(FL, 0.0, PI * 0.5).y
	assert_between(side / peak_y, spec.tyre_slide_grip_lat - 0.01, 0.95, "force moving purely sideways / peak")

func test_symmetric_in_the_sign_of_slip() -> void:
	_make()
	for i in [FL, RL]:
		for slip: float in [0.01, 0.05, 0.09, 0.3, 1.0]:
			var a := _f(i, slip, 0.0)
			var b := _f(i, -slip, 0.0)
			assert_true(absf(a.x + b.x) < 1e-3 * absf(a.x), "Fx odd in slip ratio (%.2f)" % slip)
		for angle: float in [0.01, 0.07, 0.14, 0.4, 1.2]:
			var a := _f(i, 0.0, angle)
			var b := _f(i, 0.0, -angle)
			assert_true(absf(a.y + b.y) < 1e-3 * absf(a.y), "Fy odd in slip angle (%.2f)" % angle)
		var c := _f(i, 0.06, 0.08)
		var d := _f(i, -0.06, -0.08)
		assert_true((c + d).length() < 1e-3 * c.length(), "combined force odd in both slips")
		var e := _f(i, 0.06, -0.08)
		assert_true(absf(e.x - c.x) < 1e-3 * c.x and absf(e.y + c.y) < 1e-3 * absf(c.y), "mirrored slip angle mirrors Fy only")

func test_long_stiffness_matches_the_slope() -> void:
	_make()
	var eps := 1e-4
	for i in [FL, RL]:
		for load_n: float in [1500.0, 4000.0, 9000.0]:
			state.load[i] = load_n
			# At speed: the slope of the pure curve.
			state.wheel_v_long[i] = V_FAST
			var slope := (_f(i, eps, 0.0).x - _f(i, -eps, 0.0).x) / (2.0 * eps)
			var stiff := tyre.long_stiffness(state, spec, i)
			assert_between(stiff / slope, 0.995, 1.005, "long_stiffness / finite difference at speed (wheel %d, %.0f N)" % [i, load_n])
			assert_true(stiff > _peak_fx(i) / spec.tyre_peak_slip_ratio, "steeper at the origin than the secant to the peak")
			# At a standstill: the capped slope (dt = 0 keeps the static friction out of it).
			state.wheel_v_long[i] = 0.0
			state.slip_angle[i] = 0.0
			state.slip_ratio[i] = eps
			var up := tyre.forces(state, spec, i, 0.0).x
			state.slip_ratio[i] = -eps
			var down := tyre.forces(state, spec, i, 0.0).x
			var slow_slope := (up - down) / (2.0 * eps)
			var slow_stiff := tyre.long_stiffness(state, spec, i)
			assert_between(slow_stiff / slow_slope, 0.995, 1.005, "long_stiffness / finite difference at a standstill (wheel %d, %.0f N)" % [i, load_n])
			assert_true(slow_stiff <= spec.tyre_low_speed_damping_long * load_n * SimHandling.MIN_SLIP_SPEED_LONG * 1.0001, "the standstill damper is capped")
			assert_true(slow_stiff < 0.8 * stiff, "and the cap acts at a standstill")

func test_mu_falls_with_load() -> void:
	_make()
	var prev_mu := INF
	var prev_force := 0.0
	for load_n: float in [500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0]:
		state.load[FL] = load_n
		var m := tyre.mu(state, spec, FL)
		var force := -_f(FL, 0.0, spec.tyre_peak_slip_angle).y
		assert_true(m <= prev_mu, "mu does not rise with load (%.0f N: %.3f)" % [load_n, m])
		if load_n > spec.tyre_reference_load * spec.tyre_min_load_ratio:
			assert_true(m < prev_mu, "mu falls with load (%.0f N: %.3f)" % [load_n, m])
		assert_true(force > prev_force, "the peak force still grows with load (%.0f N)" % load_n)
		prev_mu = m
		prev_force = force
	state.load[FL] = spec.tyre_reference_load
	assert_between(tyre.mu(state, spec, FL), spec.tyre_mu - 1e-4, spec.tyre_mu + 1e-4, "mu at the reference load")
	# Degressive: two tyres sharing a load unevenly make less than two sharing it evenly.
	state.load[FL] = 4000.0
	var even := 2.0 * -_f(FL, 0.0, spec.tyre_peak_slip_angle).y
	state.load[FL] = 6500.0
	var uneven := -_f(FL, 0.0, spec.tyre_peak_slip_angle).y
	state.load[FL] = 1500.0
	uneven += -_f(FL, 0.0, spec.tyre_peak_slip_angle).y
	print("    tyre: load transfer 4000/4000 -> 6500/1500 N keeps %.1f %% of the axle's grip" % (100.0 * uneven / even))
	assert_between(uneven / even, 0.9, 0.9999, "grip kept by an axle under load transfer")
	state.load[FL] = 4000.0
	state.load[RL] = 4000.0
	assert_true(tyre.mu(state, spec, RL) > tyre.mu(state, spec, FL), "the wide rear tyre has more mu at the same load")

func test_combined_slip_stays_inside_the_ellipse() -> void:
	_make()
	for i in [FL, RL]:
		var dx := _peak_fx(i)
		var dy := _peak_fy(i)
		var worst := 0.0
		for a in range(-20, 21):
			for b in range(-20, 21):
				var f := _f(i, 0.02 * a, 0.03 * b)
				var e := (f.x / dx) * (f.x / dx) + (f.y / dy) * (f.y / dy)
				worst = maxf(worst, e)
		assert_true(worst <= 1.0 + 1e-4, "combined force inside the friction ellipse (worst %.5f, wheel %d)" % [worst, i])
		assert_true(worst > 0.98, "and the ellipse is reached (worst %.3f)" % worst)
	# Braking takes cornering force away, smoothly and more the harder it is.
	var angle := spec.tyre_peak_slip_angle
	var prev := -_f(FL, 0.0, angle).y
	var pure := prev
	for k in range(1, 30):
		var fy := -_f(FL, -0.01 * k, angle).y
		assert_true(fy < prev, "more braking slip, less cornering force (slip %.2f)" % (0.01 * k))
		assert_true(prev - fy < 0.12 * pure, "no step in the cornering force (slip %.2f)" % (0.01 * k))
		prev = fy
	# And cornering takes traction away.
	var slip := spec.tyre_peak_slip_ratio
	prev = _f(FL, slip, 0.0).x
	for k in range(1, 30):
		var fx := _f(FL, slip, 0.01 * k).x
		assert_true(fx < prev, "more slip angle, less traction (angle %.2f)" % (0.01 * k))
		prev = fx
	# At equal normalised slips the force points halfway (in ellipse coordinates).
	var f := _f(FL, slip, angle)
	assert_between((f.x / _peak_fx(FL)) / (-f.y / _peak_fy(FL)), 0.9, 1.1, "force direction at equal normalised slips")

func test_surface_and_condition_scale_the_force() -> void:
	_make()
	var grip := _f(FL, 0.05, 0.06)
	var peak := _f(FL, 0.3, 0.3)
	var mu_ref := tyre.mu(state, spec, FL)
	for surface: float in [1.0, 0.9, 0.55, 0.35]:
		state.surface_mu[FL] = surface
		assert_between(tyre.mu(state, spec, FL) / mu_ref, surface - 1e-4, surface + 1e-4, "mu scales with the surface (%.2f)" % surface)
		var f := _f(FL, 0.3, 0.3)
		assert_between(f.length() / peak.length(), surface - 1e-3, surface + 1e-3, "sliding force scales with the surface (%.2f)" % surface)
		assert_between(_f(FL, 0.05, 0.06).length() / grip.length(), surface - 1e-3, surface + 1e-3, "force below the peak scales with the surface (%.2f)" % surface)
	state.surface_mu[FL] = 1.0
	state.grip_factor[FL] = 0.8
	assert_between(_f(FL, 0.3, 0.3).length() / peak.length(), 0.799, 0.801, "force scales with the tyre's condition")
	state.surface_mu[FL] = 0.5
	assert_between(_f(FL, 0.3, 0.3).length() / peak.length(), 0.399, 0.401, "surface and condition multiply")
	state.surface_mu[FL] = 0.0
	assert_true(_f(FL, 0.3, 0.3) == Vector2.ZERO and tyre.long_stiffness(state, spec, FL) == 0.0, "no grip at all gives no force and no error")

func test_relaxation_length() -> void:
	_make()
	var angle := 0.01    # linear range, so the force follows the felt slip angle
	var steady := -_f(FL, 0.0, angle).y
	var h := 1.0 / 960.0
	# At speed the force builds over the distance rolled: 63 % after one relaxation length.
	for v: float in [30.0, 80.0]:
		tyre.reset(state, spec)
		state.wheel_v_long[FL] = v
		state.slip_ratio[FL] = 0.0
		state.slip_angle[FL] = angle
		var rolled := 0.0
		var at_length := -1.0
		var first := -1.0
		while rolled < 5.0 * spec.tyre_relaxation_length:
			var fy := -tyre.forces(state, spec, FL, h).y
			rolled += v * h
			if first < 0.0:
				first = fy
			if at_length < 0.0 and rolled >= spec.tyre_relaxation_length:
				at_length = fy
		var settled := -tyre.forces(state, spec, FL, h).y
		assert_true(first < 0.25 * steady, "the force does not jump at %.0f m/s (%.0f %% at once)" % [v, 100.0 * first / steady])
		assert_between(at_length / steady, 0.58, 0.70, "share of the force after one relaxation length at %.0f m/s" % v)
		assert_between(settled / steady, 0.99, 1.001, "settled after five lengths at %.0f m/s" % v)
	# Rolling backwards lags the same way.
	tyre.reset(state, spec)
	state.wheel_v_long[FL] = -30.0
	assert_true(-tyre.forces(state, spec, FL, h).y < 0.25 * steady, "lag when rolling backwards")
	# Below the fade speed there is no lag at all.
	tyre.reset(state, spec)
	state.wheel_v_long[FL] = spec.tyre_relaxation_fade_lo
	var slow := -tyre.forces(state, spec, FL, h).y
	var slow_steady := -tyre.forces(state, spec, FL, SETTLED).y
	state.wheel_v_long[FL] = V_FAST
	assert_true(slow > 0.0, "a force at low speed")
	assert_between(slow / slow_steady, 0.999, 1.001, "the force follows at once at low speed")
	# Longitudinal force is not lagged (the wheel integrator needs it immediate).
	tyre.reset(state, spec)
	state.slip_angle[FL] = 0.0
	state.slip_ratio[FL] = 0.02
	var fx := tyre.forces(state, spec, FL, h).x
	assert_between(fx / _f(FL, 0.02, 0.0).x, 0.999, 1.001, "longitudinal force is immediate")

func test_static_friction_at_a_standstill() -> void:
	_make(2000.0)
	var h := 1.0 / 960.0
	state.wheel_v_long[FL] = 0.0
	# The patch creeps 1 mm/s along and across for a while, then stops: the tyre keeps holding.
	var creep := 0.001
	state.slip_ratio[FL] = creep / SimHandling.MIN_SLIP_SPEED_LONG
	state.slip_angle[FL] = atan2(creep, SimHandling.MIN_SLIP_SPEED_LAT)
	var moving := Vector2.ZERO
	for k in 960:
		moving = tyre.forces(state, spec, FL, h)
	state.slip_ratio[FL] = 0.0
	state.slip_angle[FL] = 0.0
	var held := tyre.forces(state, spec, FL, h)
	assert_true(held.x > 50.0 and held.y < -50.0, "a stopped tyre holds against where it was pushed (%s)" % held)
	assert_true(held.length() > 0.5 * moving.length(), "most of the force is held, not damping (%s moving, %s held)" % [moving, held])
	for k in 960:
		held = tyre.forces(state, spec, FL, h)
	assert_true(held.x > 50.0 and held.y < -50.0, "and keeps holding (%s)" % held)
	# Dragged far, the hold saturates at the friction limit.
	state.slip_ratio[FL] = 0.2 / SimHandling.MIN_SLIP_SPEED_LONG
	for k in 960:
		held = tyre.forces(state, spec, FL, h)
	assert_true(held.x <= _peak_fx(FL) * 1.0001, "static friction is limited to the peak (%.0f N of %.0f N)" % [held.x, _peak_fx(FL)])
	assert_true(held.x > 0.75 * _peak_fx(FL), "and reaches it (%.0f N of %.0f N)" % [held.x, _peak_fx(FL)])
	# Rolling away sheds the deflection: no force left without slip.
	state.slip_ratio[FL] = 0.0
	state.wheel_v_long[FL] = 0.5
	for k in 960:
		held = tyre.forces(state, spec, FL, h)
	assert_true(held.length() < 1.0, "the hold is shed once the wheel rolls (%s)" % held)
	# Sliding sideways fast there is no static friction: only the sliding force, and nothing
	# is left wound up when the slide ends.
	tyre.reset(state, spec)
	state.wheel_v_long[FL] = 0.0
	state.slip_ratio[FL] = 0.0
	state.slip_angle[FL] = atan2(4.0, SimHandling.MIN_SLIP_SPEED_LAT)
	var plain := tyre.forces(state, spec, FL, 0.0)
	for k in 960:
		held = tyre.forces(state, spec, FL, h)
	assert_true(absf(held.y - plain.y) < 1.0, "no static friction while sliding sideways at 4 m/s (%.0f N vs %.0f N)" % [held.y, plain.y])
	state.slip_angle[FL] = 0.0
	assert_true(tyre.forces(state, spec, FL, h).length() < 1.0, "nothing wound up after the slide")
	# reset() clears it.
	state.wheel_v_long[FL] = 0.0
	state.slip_ratio[FL] = 0.2 / SimHandling.MIN_SLIP_SPEED_LONG
	for k in 100:
		tyre.forces(state, spec, FL, h)
	tyre.reset(state, spec)
	state.slip_ratio[FL] = 0.0
	assert_true(tyre.forces(state, spec, FL, h).length() < 1e-6, "reset clears the per-wheel state")

func test_self_aligning_moment() -> void:
	_make()
	_f(FL, 0.0, 0.03)
	var small := tyre.aligning_moment[FL]
	assert_true(small < -1.0, "slipping to the right, the moment turns the wheel right, into the slide (%.1f N m)" % small)
	_f(FL, 0.0, -0.03)
	assert_between(tyre.aligning_moment[FL], -small * 0.999, -small * 1.001, "odd in the slip angle")
	_f(FL, 0.0, spec.tyre_peak_slip_angle * 1.5)
	assert_true(absf(tyre.aligning_moment[FL]) < 1e-6, "the moment is gone past the limit (the steering goes light)")
	_f(FL, 0.0, 0.0)
	assert_true(absf(tyre.aligning_moment[FL]) < 1e-6, "no slip, no moment")

func test_same_inputs_same_forces() -> void:
	_make()
	var first := PackedVector2Array()
	for run in 2:
		tyre.reset(state, spec)
		for k in 200:
			state.wheel_v_long[RL] = 0.2 * k
			state.slip_ratio[RL] = 0.3 * sin(0.1 * k)
			state.slip_angle[RL] = 0.2 * cos(0.07 * k)
			var f := tyre.forces(state, spec, RL, 1.0 / 960.0)
			assert_true(is_finite(f.x) and is_finite(f.y), "finite force")
			if run == 0:
				first.append(f)
			else:
				assert_true(f == first[k], "deterministic (step %d)" % k)

# ---------------------------------------------------------------- whole car on the rig

func test_parked_on_the_flat_stays_put() -> void:
	var car := await SimRig.spawn(self)
	await physics_frames(SimRig.HZ)
	var start := car.global_transform
	var fastest := 0.0
	var fastest_turn := 0.0
	for k in 3 * SimRig.HZ:
		await get_tree().physics_frame
		fastest = maxf(fastest, car.linear_velocity.length())
		fastest_turn = maxf(fastest_turn, car.angular_velocity.length())
	var moved := car.global_position.distance_to(start.origin)
	print("    tyre: parked on the flat for 3 s: moved %.3f mm, fastest %.3f mm/s, %.5f rad/s" % [moved * 1000.0, fastest * 1000.0, fastest_turn])
	assert_true(moved < 0.002, "the parked car stays put (moved %.2f mm)" % (moved * 1000.0))
	assert_true(fastest < 0.003, "no jitter (%.2f mm/s)" % (fastest * 1000.0))
	assert_true(fastest_turn < 0.002, "no rocking or weaving (%.5f rad/s)" % fastest_turn)
	assert_true(start.basis.z.dot(car.global_transform.basis.z) > 0.999999, "heading unchanged")
	# A shove sideways dies out without oscillating on.
	car.linear_velocity += car.global_transform.basis.x * 0.5
	car.angular_velocity += Vector3.UP * 0.3
	await physics_frames(SimRig.HZ * 2)
	assert_true(car.linear_velocity.length() < 0.003 and car.angular_velocity.length() < 0.002,
			"at rest again 2 s after a shove (%.2f mm/s, %.5f rad/s)" % [car.linear_velocity.length() * 1000.0, car.angular_velocity.length()])

## Half pedal: at a standstill more than half, without throttle, selects reverse.
const HOLD_PEDAL: float = 0.5

## A car settled on a pad tilted by `tilt` (the pad's basis), brakes as given.
func _spawn_on_slope(tilt: Basis, brake: float) -> Car:
	var pad := Node3D.new()
	add_child(pad)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	ground.add_child(shape)
	ground.basis = tilt
	pad.add_child(ground)
	var car := (load("res://scenes/car/car.tscn") as PackedScene).instantiate() as Car
	car.handling = Car.HANDLING_SIMULATION
	car.transform = Transform3D(tilt, tilt.y * 0.40)
	pad.add_child(car)
	car.set_input_override(0.0, brake, 0.0)
	await physics_frames(SimRig.HZ * 2)
	return car

## Removes the pad and the car made by _spawn_on_slope.
func _clear_slope(car: Car) -> void:
	var pad := car.get_parent()
	remove_child(pad)
	pad.queue_free()
	await physics_frames(2)

func test_parked_on_a_slope_with_the_brakes_on() -> void:
	var angle := atan(0.10)    # a 10 % slope
	var cases := {"nose down the slope": Basis(Vector3.RIGHT, -angle), "nose up the slope": Basis(Vector3.RIGHT, angle),
			"across the slope": Basis(Vector3.BACK, angle)}
	for label: String in cases:
		var car := await _spawn_on_slope(cases[label], HOLD_PEDAL)
		var start := car.global_position
		var fastest := 0.0
		for k in 4 * SimRig.HZ:
			await get_tree().physics_frame
			fastest = maxf(fastest, car.linear_velocity.length())
		var creep := car.global_position.distance_to(start) / 4.0
		print("    tyre: parked %s (10 %%): creep %.3f mm/s, fastest %.3f mm/s" % [label, creep * 1000.0, fastest * 1000.0])
		assert_true(car.sim.state.on_ground == 4, "all wheels on the slope (%s)" % label)
		assert_true(creep < 0.002, "no creep %s (%.2f mm/s)" % [label, creep * 1000.0])
		assert_true(fastest < 0.004, "no jitter %s (%.2f mm/s)" % [label, fastest * 1000.0])
		await _clear_slope(car)
	# Without the brakes it rolls away down the slope (the hold is friction, not glue).
	var free := await _spawn_on_slope(Basis(Vector3.RIGHT, -angle), 0.0)
	assert_true(free.linear_velocity.length() > 0.3, "rolls down the slope with the brakes off (%.2f m/s)" % free.linear_velocity.length())
	await _clear_slope(free)

func test_lateral_g_in_the_reference_band() -> void:
	var car := await SimRig.spawn(self)
	var slow := await SimRig.max_lateral_g(self, car, 100.0)
	print("    tyre: cornering at 100 km/h: %.2f g (steer %.2f, body slip %.1f deg, held %.0f km/h)" % [slow["lat_g"], slow["steer"], slow["slip_deg"], slow["speed_kmh"]])
	assert_between(slow["lat_g"], 1.7, 2.2, "lateral g at 100 km/h")
	car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(SimRig.HZ)
	var fast := await SimRig.max_lateral_g(self, car, 250.0)
	print("    tyre: cornering at 250 km/h: %.2f g (steer %.2f, body slip %.1f deg, held %.0f km/h)" % [fast["lat_g"], fast["steer"], fast["slip_deg"], fast["speed_kmh"]])
	assert_between(fast["lat_g"], 3.3, 5.2, "lateral g at 250 km/h")
	assert_true(fast["lat_g"] > slow["lat_g"] + 1.0, "downforce raises the cornering limit")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.98, "upright after cornering")
