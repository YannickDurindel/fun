extends TestCase
## The calibration harness: the telemetry recorder, the bench manoeuvres of SimRig and the
## telemetry overlay. The bands are wide on purpose: they check the instruments, not the car
## (the car is calibrated with tools/sim_bench.sh against docs/sim_targets.md).

const OVERLAY := "res://scenes/ui/telemetry_overlay.tscn"

func test_recorder_rows_columns_and_csv() -> void:
	var car := await SimRig.spawn(self)
	var rec := SimTelemetry.attach(car, 60.0, 10.0)
	assert_true(rec.actual_rate_hz() == 60.0, "60 Hz on a 240 Hz clock (%.1f)" % rec.actual_rate_hz())
	var cols := rec.columns()
	assert_true(cols.size() == SimTelemetry.BODY_COLUMNS.size() + 4 * SimTelemetry.WHEEL_COLUMNS.size(),
			"body columns plus four wheel blocks (%d)" % cols.size())
	for c: String in ["time_s", "distance_m", "speed_kmh", "gear", "rpm", "throttle", "brake", "steer_in",
			"accel_long_g", "accel_lat_g", "yaw_rate_dps", "body_slip_deg", "load_n_fl", "slip_ratio_rr",
			"slip_angle_deg_fr", "fx_n_rl", "fy_n_rl", "tyre_temp_c_rr", "brake_temp_c_fl"]:
		assert_true(cols.has(c), "column " + c)
	rec.marker = 7.0
	await SimRig.drive(self, car, 2.0, 1.0, 0.0, 0.0)
	rec.stop()
	# 2 s at 60 Hz; the recorder and the drive loop may be one tick apart.
	assert_between(rec.row_count(), 119, 121, "rows after 2 s at 60 Hz")
	var last := rec.row_count() - 1
	assert_between(rec.value(last, "time_s"), 1.95, 2.05, "time of the last row (s)")
	assert_between(rec.value(last, "speed_kmh"), car.linear_velocity.length() * 3.6 - 3.0,
			car.linear_velocity.length() * 3.6 + 0.1, "speed of the last row (km/h)")
	assert_true(rec.value(last, "distance_m") > 10.0, "distance grows (%.1f m)" % rec.value(last, "distance_m"))
	assert_between(rec.value(last, "distance_m"), car.global_position.length() * 0.97,
			car.global_position.length() * 1.03, "distance matches the car's travel (m)")
	assert_true(rec.value(last, "accel_long_g") > 0.5, "accelerating (%.2f g)" % rec.value(last, "accel_long_g"))
	assert_true(rec.value(last, "throttle_in") == 1.0 and rec.value(last, "marker") == 7.0, "inputs and marker")
	var loads := 0.0
	for w: String in SimTelemetry.WHEEL_NAMES:
		loads += rec.value(last, "load_n_" + w)
	assert_between(loads, car.mass * 9.81 * 0.9, car.mass * 9.81 * 1.6, "wheel loads in the last row (N)")
	# Values land under their own names, from the first block to the last.
	var st := car.sim.state
	assert_true(rec.value(last, "gear") == float(st.gear) or rec.value(last, "gear") == float(st.gear - 1), "gear column")
	assert_between(rec.value(last, "mass_kg"), st.mass - 0.5, st.mass + 0.5, "mass column (kg)")
	assert_between(rec.value(last, "fuel_kg"), st.fuel - 0.1, st.fuel + 0.1, "fuel column (kg)")
	assert_between(rec.value(last, "rpm"), 3000.0, 14000.0, "rpm column")
	assert_between(rec.value(last, "tyre_temp_c_fl"), st.tyre_temp[0] - 5.0, st.tyre_temp[0] + 5.0, "tyre temperature column")
	assert_between(rec.value(last, "brake_temp_c_rr"), st.brake_temp[3] - 20.0, st.brake_temp[3] + 20.0, "brake temperature column")
	assert_true(rec.value(last, "slip_ratio_rl") > 0.0 and absf(rec.value(last, "slip_ratio_fl")) < 0.02, "driven wheels slip, the fronts roll")
	assert_true(not is_nan(rec.value(last, "wear_rr")) and rec.value(last, "tyre_temp_c_rr") > 0.0, "last wheel block")
	assert_true(is_nan(rec.value(last, "no_such_column")) and is_nan(rec.value(9999, "time_s")), "NAN outside the data")

	var path := OS.get_user_data_dir().path_join("sim9_test_telemetry_%d.csv" % Time.get_ticks_usec())
	assert_true(rec.write_csv(path) == OK, "csv written to " + path)
	var f := FileAccess.open(path, FileAccess.READ)
	assert_true(f != null, "csv can be opened")
	if f != null:
		var header := f.get_csv_line()
		assert_true(header == cols, "header is the column list")
		var rows := 0
		var first_speed := -1.0
		var prev_t := -1.0
		while not f.eof_reached():
			var line := f.get_csv_line()
			if line.size() <= 1:
				continue
			assert_true(line.size() == cols.size(), "row %d has %d cells" % [rows, line.size()])
			for cell in line:
				assert_true(cell.is_valid_float(), "numeric cell '%s' in row %d" % [cell, rows])
			var t := float(line[0])
			assert_true(t > prev_t, "time increases at row %d" % rows)
			prev_t = t
			if rows == 0:
				first_speed = float(line[cols.find("speed_kmh")])
			rows += 1
		f.close()
		assert_true(rows == rec.row_count(), "csv rows (%d) = recorded rows (%d)" % [rows, rec.row_count()])
		assert_between(first_speed, 0.0, 5.0, "first row is the standing start (km/h)")
	DirAccess.remove_absolute(path)

func test_recorder_stops_when_full() -> void:
	var car := await SimRig.spawn(self)
	var rec := SimTelemetry.attach(car, 120.0, 0.25)
	await physics_frames(SimRig.HZ)
	assert_true(rec.full and not rec.recording, "stops when the buffer is full")
	assert_true(rec.row_count() == rec.capacity(), "kept %d of %d rows" % [rec.row_count(), rec.capacity()])
	rec.clear()
	rec.start()
	await physics_frames(24)
	assert_between(rec.row_count(), 11, 13, "records again after clear()")

func test_bench_straight_line_manoeuvres() -> void:
	var car := await SimRig.spawn(self)
	var b := await SimRig.braking(self, car, 200.0)
	print("    bench braking 200-0: %.1f m in %.2f s, peak %.2f g, mean %.2f g, lock %.2f s, from %.1f km/h" % [
			b["distance"], b["time"], b["peak_g"], b["mean_g"], b["lock_s"], b["v0_kmh"]])
	assert_between(b["v0_kmh"], 198.0, 202.0, "braking starts from the asked speed (km/h)")
	assert_between(b["distance"], 40.0, 160.0, "200-0 distance (m)")
	assert_between(b["time"], 1.2, 6.0, "200-0 time (s)")
	assert_true(b["peak_g"] >= b["mean_g"] and b["peak_g"] < 8.0, "peak (%.2f g) above the mean (%.2f g)" % [b["peak_g"], b["mean_g"]])
	assert_between(b["distance"], 0.5 * 55.56 * b["time"] * 0.6, 0.5 * 55.56 * b["time"] * 1.2, "distance consistent with the time (m)")
	assert_true(b["drift_m"] < 1.0, "stops in a straight line (%.2f m off)" % b["drift_m"])
	assert_true(car.linear_velocity.length() < 1.0, "stopped")

	await SimRig.reset(self, car)
	assert_true(car.linear_velocity.length() < 0.1 and car.global_position.length() < 1.0, "reset returns to the spawn point")
	var part := await SimRig.braking(self, car, 300.0, 100.0)
	assert_between(car.linear_velocity.length() * 3.6, 80.0, 101.0, "partial braking ends at the asked speed (km/h)")
	assert_true(part["distance"] > 20.0 and part["peak_g"] > b["mean_g"], "partial braking measured")

	await SimRig.reset(self, car)
	var top := await SimRig.top_speed_drs(self, car, false, 280.0, 30.0)
	print("    bench top speed: %.1f km/h after %.0f s" % [top["kmh"], top["time"]])
	assert_between(top["kmh"], 250.0, 420.0, "top speed (km/h)")
	assert_true(top["settled"] and top["time"] < 30.0, "top speed settled")
	# With the button held the run reports whether the wing opened (the placeholder aids never
	# ask for it), and lets go of the button afterwards.
	var drs := await SimRig.top_speed_drs(self, car, true, 300.0, 2.0)
	assert_true(not drs["settled"] and drs["time"] == 2.0, "a run cut short is not reported as settled")
	await physics_frames(2)
	assert_true(not car.sim.state.in_drs, "DRS button released afterwards")
	assert_true(drs["drs_opened"] or not car.sim.state.drs_open, "drs_opened follows the wing")

	await SimRig.reset(self, car)
	var still := await SimRig.ride(self, car, 0.0, 1.0)
	assert_between(still["load_ratio"], 0.97, 1.03, "wheel load = weight at rest")
	assert_between(still["front_mm"], -3.0, 3.0, "design ride height at rest, front (mm)")
	var fast := await SimRig.ride(self, car, 250.0)
	print("    bench ride at 250 km/h: load x%.2f, downforce %.0f N, front %.1f mm, rear %.1f mm" % [
			fast["load_ratio"], fast["downforce_n"], fast["front_mm"], fast["rear_mm"]])
	assert_between(fast["speed_kmh"], 245.0, 255.0, "ride: speed held (km/h)")
	assert_true(fast["load_ratio"] > 1.3 and fast["downforce_n"] > 2000.0, "downforce loads the wheels at speed")
	assert_between(fast["load_n"], (car.mass * 9.81 + fast["downforce_n"]) * 0.95, (car.mass * 9.81 + fast["downforce_n"]) * 1.05,
			"wheel load = weight + downforce (N)")
	assert_true(fast["front_mm"] > 0.5 and fast["rear_mm"] > 0.5, "the car rides lower at speed")

func test_bench_cornering_manoeuvres() -> void:
	var car := await SimRig.spawn(self)
	var c := await SimRig.cornering(self, car, 150.0)
	print("    bench cornering 150: %.2f g, steer %.2f (%.1f deg), body %.1f deg, front %.1f / rear %.1f deg, %.0f km/h" % [
			c["lat_g"], c["steer"], c["steer_deg"], c["slip_deg"], c["front_slip_deg"], c["rear_slip_deg"], c["speed_kmh"]])
	assert_between(c["lat_g"], 1.0, 7.0, "cornering limit at 150 km/h (g)")
	assert_between(c["speed_kmh"], 135.0, 156.0, "cornering: speed held (km/h)")
	assert_true(c["steer"] > 0.05 and c["steer_deg"] > 0.5, "steering at the limit")
	assert_between(c["front_slip_deg"], 1.0, 30.0, "front slip angle at the limit (deg)")
	assert_between(c["rear_slip_deg"], 1.0, 30.0, "rear slip angle at the limit (deg)")
	assert_true(is_equal_approx(c["balance_deg"], c["front_slip_deg"] - c["rear_slip_deg"]), "balance = front - rear")
	assert_true(car.global_transform.basis.y.dot(Vector3.UP) > 0.98, "upright after cornering")

	await SimRig.reset(self, car)
	await SimRig.settle_at(self, car, 150.0, 0.5)
	var half := 0.5 * float(c["lat_g"])
	var steer := await SimRig.steer_for(self, car, 150.0, half)
	assert_true(steer > 0.0 and steer < float(c["steer"]), "steering for half the limit (%.2f) is less than at the limit" % steer)
	assert_between(absf(car.sim.state.accel_lat) / 9.81, half * 0.85, half * 1.15, "steer_for leaves the car at the asked g")

	await SimRig.reset(self, car)
	var s := await SimRig.step_steer(self, car, 150.0, steer)
	print("    bench step steer 150: %.1f deg/s, rise %.3f s, overshoot %.1f %%, settle %.2f s, %.2f g" % [
			s["yaw_rate_dps"], s["rise_s"], s["overshoot_pct"], s["settle_s"], s["lat_g"]])
	assert_between(s["lat_g"], half * 0.8, half * 1.2, "step steer settles at the asked g")
	assert_between(s["rise_s"], 0.01, 1.5, "yaw rise time (s)")
	assert_between(s["overshoot_pct"], 0.0, 150.0, "yaw overshoot (%)")
	# Steady turn: lateral acceleration = speed x yaw rate.
	assert_between(deg_to_rad(s["yaw_rate_dps"]) * 150.0 / 3.6 / 9.81, float(s["lat_g"]) * 0.85, float(s["lat_g"]) * 1.15,
			"yaw rate consistent with the lateral g")

	await SimRig.reset(self, car)
	var l := await SimRig.lift_off(self, car, 150.0, half)
	print("    bench lift-off 150 at %.2f g: slip %.1f -> %.1f deg, yaw x%.2f, spun %s" % [
			l["lat_g"], l["slip_before_deg"], l["slip_peak_deg"], l["yaw_gain"], l["spun"]])
	assert_true(l["reached"], "lift-off: the corner was reached")
	assert_between(l["lat_g"], half * 0.8, half * 1.2, "lift-off from the asked g")
	assert_true(l["slip_peak_deg"] >= l["slip_before_deg"] * 0.5 and l["slip_peak_deg"] <= 31.0, "body slip measured through the lift")
	assert_true(l["yaw_gain"] > 0.3, "yaw rate measured through the lift")
	var never := await SimRig.lift_off(self, car, 150.0, 30.0)
	assert_true(not never["reached"], "an impossible corner is reported, not invented")
	assert_true(await SimRig.steer_for(self, car, 150.0, 0.0) < 0.0, "zero g is not a corner")

## Every target the bench scores against has its row in docs/sim_targets.md.
func test_bench_targets_are_documented() -> void:
	var consts := (load("res://tools/sim_bench.gd") as GDScript).get_script_constant_map()
	var doc := FileAccess.get_file_as_string("res://docs/sim_targets.md")
	assert_true(doc.length() > 1000, "docs/sim_targets.md is readable")
	var refs := {}
	for table: String in ["TARGETS", "POLES"]:
		var d: Dictionary = consts[table]
		assert_true(d.size() > 3, table + " has entries")
		for key: String in d:
			var entry: Array = d[key]
			refs[entry[entry.size() - 1]] = true
			if table == "TARGETS":
				assert_true(float(entry[0]) <= float(entry[1]), "band of %s is ordered" % key)
	for ref: String in refs:
		assert_true(doc.contains("| %s |" % ref), "target %s has a row in docs/sim_targets.md" % ref)

func test_bench_manoeuvres_on_the_arcade_car() -> void:
	var car := await SimRig.spawn(self, Car.HANDLING_ARCADE)
	var rec := SimTelemetry.attach(car)
	var b := await SimRig.braking(self, car, 150.0)
	assert_true(rec.row_count() == 0, "the recorder writes nothing for an arcade car")
	assert_between(b["distance"], 15.0, 150.0, "arcade 150-0 distance (m)")
	assert_true(b["peak_g"] > 0.5 and not b["locked"], "arcade deceleration from the velocity (%.2f g)" % b["peak_g"])
	await SimRig.reset(self, car)
	var c := await SimRig.cornering(self, car, 150.0)
	assert_between(c["lat_g"], 0.8, 8.0, "arcade cornering at 150 km/h (g)")
	assert_true(is_nan(c["front_slip_deg"]) and is_nan(c["balance_deg"]), "no tyre slip angles in arcade")
	var r := await SimRig.ride(self, car, 0.0, 0.5)
	assert_true(is_nan(r["load_ratio"]), "no wheel loads in arcade")

func test_overlay_shows_for_simulation_only() -> void:
	var car := await SimRig.spawn(self)
	var overlay := spawn(OVERLAY) as TelemetryOverlay
	overlay.set_car(car)
	await get_tree().process_frame
	assert_true(not overlay.visible and not overlay.enabled, "off by default")
	overlay.toggle()
	assert_true(overlay.enabled and overlay.visible, "F3 shows it for a simulation car")
	await SimRig.drive(self, car, 1.5, 1.0, 0.0, 0.3)
	await get_tree().process_frame
	await get_tree().process_frame
	var s := car.sim.state
	assert_true(overlay.trail_count() > 100, "g-g trail filled (%d points)" % overlay.trail_count())
	assert_true(overlay.gg.length() > 0.3, "g-g point follows the car (%.2f g)" % overlay.gg.length())
	assert_true(overlay.gg.distance_to(Vector2(s.accel_lat, s.accel_long) / 9.81) < 0.5, "g-g point is the state's acceleration")
	var lines := overlay.readout()
	assert_true(lines.size() >= 5, "readout lines (%d)" % lines.size())
	var text := "\n".join(lines)
	for word: String in ["DOWNFORCE", "DRAG", "DRS", "ERS", "FUEL", "MASS", "RIDE"]:
		assert_true(text.contains(word), "readout shows " + word)
	# The key toggles it too.
	var key := InputEventKey.new()
	key.keycode = KEY_F3
	key.pressed = true
	overlay._unhandled_key_input(key)
	assert_true(not overlay.enabled and not overlay.visible, "F3 hides it again")
	overlay.queue_free()
	await get_tree().process_frame

func test_overlay_stays_hidden_for_arcade() -> void:
	var car := await SimRig.spawn(self, Car.HANDLING_ARCADE)
	var overlay := spawn(OVERLAY) as TelemetryOverlay
	overlay.set_car(car)
	overlay.enabled = true
	await SimRig.drive(self, car, 0.5, 1.0, 0.0, 0.0)
	await get_tree().process_frame
	assert_true(overlay.enabled and not overlay.visible, "asked for, but hidden for an arcade car")
	assert_true(overlay.readout().is_empty() and overlay.trail_count() == 0, "nothing read from an arcade car")
	# Without a car it finds none here either and stays hidden instead of failing.
	overlay.set_car(null)
	await get_tree().process_frame
	assert_true(not overlay.visible, "hidden without a simulation car")
