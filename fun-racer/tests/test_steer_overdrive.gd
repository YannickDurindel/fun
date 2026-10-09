extends TestCase
## Steering overdrive: a person on an analog device (phone tilt, stick) can turn past the grip
## limit and make the car slide; keys, the autopilot and moderate input cannot.

func _run(handling: StringName, steer: float, as_player: bool, run_up: float = 5.0, throttle: float = 0.7) -> Dictionary:
	var car := await SimRig.spawn(self, handling)
	car.override_as_player = as_player
	await SimRig.drive(self, car, run_up, 1.0, 0.0, 0.0)
	var v0 := car.speed_kmh
	var peak := 0.0
	var drifting := 0
	var ticks := int(2.5 * SimRig.HZ)
	car.set_input_override(throttle, 0.0, steer)
	for i in ticks:
		await get_tree().physics_frame
		peak = maxf(peak, absf(rad_to_deg(car.slip_angle)))
		if car.is_drifting:
			drifting += 1
	var out := {"v0": v0, "peak": peak, "drift_s": float(drifting) / SimRig.HZ, "v1": car.speed_kmh}
	print("    %s, steer %.1f, %s: from %.0f km/h, peak body slip %.1f deg, sliding %.2f s, ends at %.0f km/h"
			% [handling, steer, "player" if as_player else "autopilot", v0, peak, out["drift_s"], car.speed_kmh])
	car.queue_free()
	await physics_frames(2)
	return out

func test_arcade_full_tilt_slides() -> void:
	var full := await _run(&"arcade", 1.0, true)
	var part := await _run(&"arcade", 0.9, true)
	var auto := await _run(&"arcade", 1.0, false)
	assert_true(full["drift_s"] > 0.8, "full analog steering breaks the rear loose (%.2f s)" % full["drift_s"])
	assert_true(full["peak"] > 5.0, "and the car slides (%.1f deg)" % full["peak"])
	assert_true(part["drift_s"] == 0.0, "moderate steering keeps the grip (%.2f s)" % part["drift_s"])
	assert_true(auto["drift_s"] == 0.0, "the autopilot's steering never does (%.2f s)" % auto["drift_s"])

func test_simulation_full_tilt_turns_past_the_grip() -> void:
	# Out of a slow corner on full throttle: the overdrive turns in harder and lets the rear slide.
	var full := await _run(&"simulation", 1.0, true, 1.6, 1.0)
	var part := await _run(&"simulation", 0.85, true, 1.6, 1.0)
	var auto := await _run(&"simulation", 1.0, false, 1.6, 1.0)
	assert_true(full["peak"] > auto["peak"] + 2.0, "overdrive slides more than the grip-limited lock (%.1f vs %.1f deg)" % [full["peak"], auto["peak"]])
	assert_true(part["peak"] < 8.0, "moderate steering stays tidy (%.1f deg)" % part["peak"])
