extends SceneTree
## Calibration bench for the simulation car: standard manoeuvres on a flat pad, headless and
## faster than real time, printed as one table against real Formula 1 reference numbers.
## Run it through tools/sim_bench.sh. The manoeuvres are in tests/sim_rig.gd; the targets
## below are explained and sourced in docs/sim_targets.md (the `ref` column is the row there).
##
## User arguments (after `--`):
##   --only=NAME[,NAME]    groups to run: launch, top_speed, braking, cornering, step_steer,
##                         lift_off, ride (default: all)
##   --handling=MODEL      simulation (default) or arcade
##   --csv=FILE            record the whole run with SimTelemetry and write it there
##   --bench-lap=ID:SECONDS:STATUS   a lap time from tools/lap_check.sh to add to the table
##
## This file is compiled before the autoloads exist, so it never names a game class: the rig,
## the recorder and the car are loaded and called at run time.

const GROUPS: PackedStringArray = ["launch", "top_speed", "braking", "cornering", "step_steer", "lift_off", "ride"]
const G: float = 9.81

## Target bands: key -> [low, high, row in docs/sim_targets.md]. A measurement inside the band
## is a PASS; outside by less than WARN_MARGIN of the band's width (and at least WARN_MIN of
## its centre) a WARN; further out a FAIL. Change a band there and here together.
const TARGETS: Dictionary = {
	# Acceleration: commonly quoted figures with no primary source (ACC1-3), ACC4 derived.
	"launch.t100": [2.3, 2.9, "ACC1"],
	"launch.t200": [4.3, 5.5, "ACC2"],
	"launch.t300": [8.5, 11.5, "ACC3"],
	"launch.peak_g": [1.3, 2.0, "ACC4"],
	# Top speed on an endless flat straight, medium downforce: derived from FIA speed traps.
	"top.closed": [310.0, 335.0, "TOP1"],
	"top.drs": [322.0, 348.0, "TOP2"],
	# Braking 313 -> 81 km/h is Brembo's data for Turn 3 of the Red Bull Ring (2024).
	"brake.t3.dist": [103.0, 125.0, "BRK1"],
	"brake.t3.time": [2.2, 2.8, "BRK1"],
	"brake.t3.peak": [4.2, 5.3, "BRK1"],
	# Braking to a stop: derived from the Brembo data with a deceleration model (see the doc).
	"brake.300.dist": [108.0, 135.0, "BRK2"],
	"brake.300.time": [3.1, 3.9, "BRK2"],
	"brake.300.peak": [4.2, 5.4, "BRK2"],
	"brake.200.dist": [60.0, 75.0, "BRK3"],
	"brake.200.time": [2.4, 3.0, "BRK3"],
	"brake.200.peak": [2.7, 3.6, "BRK3"],
	"brake.100.dist": [17.0, 23.5, "BRK4"],
	"brake.100.time": [1.3, 1.75, "BRK4"],
	"brake.100.peak": [1.8, 2.6, "BRK4"],
	"brake.lock": [0.0, 0.10, "BRK5"],
	# Cornering: LAT3 rests on published figures, LAT1 and LAT2 are derived.
	"corner.80": [1.8, 2.5, "LAT1"],
	"corner.120": [2.2, 3.1, "LAT1"],
	"corner.160": [2.8, 3.8, "LAT2"],
	"corner.200": [3.4, 4.6, "LAT2"],
	"corner.250": [4.3, 5.5, "LAT3"],
	"corner.300": [4.8, 6.3, "LAT3"],
	# Balance and transients: design targets, no source.
	"corner.balance": [-0.5, 3.0, "DYN1"],
	"step.rise": [0.08, 0.25, "DYN2"],
	"step.overshoot": [0.0, 20.0, "DYN2"],
	"lift.slip": [0.0, 8.0, "DYN3"],
	# Wheel load over weight: 1 at rest; the team statement behind AER1 for the rest.
	"ride.load.0": [0.97, 1.03, "AER1"],
	"ride.load.150": [1.6, 2.2, "AER1"],
	"ride.load.300": [4.0, 5.5, "AER2"],
}
const WARN_MARGIN: float = 0.5
const WARN_MIN: float = 0.05

## Pole laps for --lap: track id -> [seconds, row in docs/sim_targets.md]. The band is from
## 1 % under the pole (a lap much faster than reality is as wrong as a slow one) to 4 % over.
const POLES: Dictionary = {
	"red_bull_ring": [63.971, "LAP1"],   # 2025, Norris
	"monza": [78.792, "LAP2"],           # 2025, Verstappen
	"silverstone": [84.892, "LAP3"],     # 2025, Verstappen
	"monaco": [69.954, "LAP4"],          # 2025, Norris
}

var _rig: GDScript
var _tc: Node
var _car: RigidBody3D
var _rec: Node
var _rows: Array[Dictionary] = []
var _markers: PackedStringArray = []
## Cornering limits measured so far (speed -> g), for the manoeuvres that scale from them.
var _limit_g: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var only := PackedStringArray()
	var handling := "simulation"
	var csv := ""
	var lap := ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.get_slice("=", 1).split(",", false)
		elif a.begins_with("--handling="):
			handling = a.get_slice("=", 1)
		elif a.begins_with("--csv="):
			csv = a.trim_prefix("--csv=")
		elif a.begins_with("--bench-lap="):
			lap = a.trim_prefix("--bench-lap=")
	for name in only:
		if not name in GROUPS and name != "lap":
			print("sim_bench: unknown group '%s' (known: %s, lap)" % [name, ", ".join(GROUPS)])
			quit(64)
			return
	if handling != "simulation" and handling != "arcade":
		print("sim_bench: unknown handling '%s' (simulation or arcade)" % handling)
		quit(64)
		return
	root.get_node("/root/Settings").set(&"persist", false)
	root.get_node("/root/Bootstrap").set(&"dev_run", true)
	_rig = load("res://tests/sim_rig.gd")
	_tc = (load("res://tests/test_case.gd") as GDScript).new()
	root.add_child(_tc)
	await process_frame
	var wall := Time.get_ticks_msec()
	_car = await _rig.call(&"spawn", _tc, StringName(handling))
	var sim: Object = _car.get(&"sim")
	if csv != "":
		if sim == null:
			print("sim_bench: --csv records the simulation only; nothing is written for the arcade car")
			csv = ""
		else:
			_rec = (load("res://scripts/car/sim/telemetry.gd") as GDScript).call(&"attach", _car, 60.0, 900.0)
	var ticks0 := Engine.get_physics_frames()
	for group in GROUPS:
		if not only.is_empty() and not group in only:
			continue
		printraw("  .. %s" % group)
		await call("_bench_" + group)
		print("")
	if lap != "":
		_lap_row(lap)
	var sim_s := float(Engine.get_physics_frames() - ticks0) / Engine.physics_ticks_per_second
	_print_table(handling, sim, sim_s, (Time.get_ticks_msec() - wall) / 1000.0)
	if _rec != null:
		var err: int = _rec.call(&"write_csv", csv)
		if err == OK:
			print("csv: %d rows x %d columns at %.0f Hz -> %s%s" % [int(_rec.call(&"row_count")),
					(_rec.call(&"columns") as PackedStringArray).size(), float(_rec.call(&"actual_rate_hz")), csv,
					"  (buffer filled: the end of the run is missing)" if _rec.get(&"full") else ""])
			print("csv markers: 0 = reset between manoeuvres, " + ", ".join(_markers))
		else:
			# The file was asked for: without it the run is a failure, whatever the table says.
			print("csv: could not write %s (error %d)" % [csv, err])
			quit(4)
			return
	print("BENCH DONE")
	quit(0)

# ---------------------------------------------------------------------------- manoeuvres

## Resets the car and tags the telemetry that follows.
func _begin(label: String) -> void:
	printraw(".")
	# Marker 0 is the reset between two manoeuvres (the jump back to the start and the settle).
	if _rec != null:
		_rec.set(&"marker", 0.0)
	await _rig.call(&"reset", _tc, _car)
	if _rec != null:
		_markers.append("%d = %s" % [_markers.size() + 1, label])
		_rec.set(&"marker", float(_markers.size()))

func _bench_launch() -> void:
	await _begin("launch")
	var r: Dictionary = await _rig.call(&"launch", _tc, _car, 16.0)
	_add("launch", "0-100 km/h", _reached(r["t_100"]), "%.2f", "s", "launch.t100")
	_add("launch", "0-200 km/h", _reached(r["t_200"]), "%.2f", "s", "launch.t200")
	_add("launch", "0-300 km/h", _reached(r["t_300"]), "%.2f", "s", "launch.t300")
	_add("launch", "peak acceleration", r["peak_g"] if _car.get(&"sim") != null else NAN, "%.2f", "g", "launch.peak_g",
			"%.0f km/h and %.0f m after 16 s" % [r["v_end_kmh"], r["distance"]])

func _bench_top_speed() -> void:
	await _begin("top speed, DRS closed")
	var closed: Dictionary = await _rig.call(&"top_speed_drs", _tc, _car, false)
	_add("top speed", "DRS closed", closed["kmh"], "%.1f", "km/h", "top.closed", _top_note(closed))
	await _begin("top speed, DRS open")
	var open: Dictionary = await _rig.call(&"top_speed_drs", _tc, _car, true)
	if open["drs_opened"]:
		_add("top speed", "DRS open", open["kmh"], "%.1f", "km/h", "top.drs",
				"%+.1f km/h; %s" % [open["kmh"] - closed["kmh"], _top_note(open)])
	else:
		_add("top speed", "DRS open", NAN, "%.1f", "km/h", "top.drs", "the wing did not open with the DRS button held")

func _top_note(r: Dictionary) -> String:
	var settled := ("settled in %.0f s" if r["settled"] else "still changing after %.0f s") % r["time"]
	return "%s, %.0f %% ERS left" % [settled, r["ers_left"] * 100.0]

func _bench_braking() -> void:
	# The one braking zone with published data: Red Bull Ring Turn 3, 313 -> 81 km/h.
	await _begin("braking 313 to 81")
	var t3: Dictionary = await _rig.call(&"braking", _tc, _car, 313.0, 81.0)
	_add("braking", "313-81 km/h distance", t3["distance"], "%.1f", "m", "brake.t3.dist",
			"Red Bull Ring T3; from %.1f km/h, mean %.2f g" % [t3["v0_kmh"], t3["mean_g"]])
	_add("braking", "313-81 km/h time", t3["time"], "%.2f", "s", "brake.t3.time")
	_add("braking", "313-81 km/h peak decel", t3["peak_g"], "%.2f", "g", "brake.t3.peak")
	for kmh: float in [300.0, 200.0, 100.0]:
		await _begin("braking from %d" % int(kmh))
		var r: Dictionary = await _rig.call(&"braking", _tc, _car, kmh)
		var k := "brake.%d." % int(kmh)
		var name := "%d-0 km/h " % int(kmh)
		_add("braking", name + "distance", r["distance"], "%.1f", "m", k + "dist",
				"from %.1f km/h, mean %.2f g, %.2f m off line" % [r["v0_kmh"], r["mean_g"], r["drift_m"]])
		_add("braking", name + "time", r["time"], "%.2f", "s", k + "time")
		_add("braking", name + "peak decel", r["peak_g"], "%.2f", "g", k + "peak")
		_add("braking", name + "lock-up", r["lock_s"] if _car.get(&"sim") != null else NAN, "%.2f", "s", "brake.lock")

func _bench_cornering() -> void:
	for kmh: float in [80.0, 120.0, 160.0, 200.0, 250.0, 300.0]:
		var r := await _corner(kmh)
		var note := "steer %.2f (%.1f deg), body slip %.1f deg, held %.0f km/h%s" % [r["steer"], r["steer_deg"],
				absf(r["slip_deg"]), r["speed_kmh"], ", SPUN" if r["spun"] else ""]
		if r["lock_limited"]:
			note += "; FULL LOCK: limited by the steering, not shown to be the tyres' limit"
		_add("cornering", "limit at %d km/h" % int(kmh), r["lat_g"], "%.2f", "g", "corner.%d" % int(kmh), note)
		var bal: float = r["balance_deg"]
		var word := "neutral"
		if bal > 0.5:
			word = "understeer"
		elif bal < -0.5:
			word = "oversteer"
		_add("cornering", "balance at %d km/h" % int(kmh), bal, "%+.1f", "deg", "corner.balance",
				"" if is_nan(bal) else "%s: front %.1f deg, rear %.1f deg slip" % [word, r["front_slip_deg"], r["rear_slip_deg"]])

## The cornering limit at `kmh`, measured once per run.
func _corner(kmh: float) -> Dictionary:
	await _begin("cornering at %d" % int(kmh))
	var r: Dictionary = await _rig.call(&"cornering", _tc, _car, kmh)
	_limit_g[int(kmh)] = r["lat_g"]
	return r

func _limit(kmh: float) -> float:
	if not _limit_g.has(int(kmh)):
		await _corner(kmh)
	return _limit_g[int(kmh)]

func _bench_step_steer() -> void:
	for kmh: float in [120.0, 200.0]:
		var limit: float = await _limit(kmh)
		var g := 0.5 * limit
		await _begin("step steer at %d: finding the input" % int(kmh))
		await _rig.call(&"settle_at", _tc, _car, kmh, 0.5)
		var steer: float = await _rig.call(&"steer_for", _tc, _car, kmh, g)   # -1 if g is 0 (no limit measured)
		var name := "%d km/h " % int(kmh)
		if steer < 0.0:
			_add("step steer", name + "yaw rise time", NAN, "%.3f", "s", "step.rise", "could not corner at %.1f g" % g)
			continue
		await _begin("step steer at %d" % int(kmh))
		var r: Dictionary = await _rig.call(&"step_steer", _tc, _car, kmh, steer)
		_add("step steer", name + "yaw rise time", _reached(r["rise_s"]), "%.3f", "s", "step.rise",
				"step to %.2f steer: %.1f deg/s, %.2f g (half the limit)" % [steer, r["yaw_rate_dps"], r["lat_g"]])
		_add("step steer", name + "yaw overshoot", r["overshoot_pct"], "%.1f", "%", "step.overshoot",
				"settled within 5 %% after %.2f s" % r["settle_s"])

func _bench_lift_off() -> void:
	for kmh: float in [120.0, 200.0]:
		# 85 % of the limit: a hard corner the car can still hold steadily.
		var limit: float = await _limit(kmh)
		var g := 0.85 * limit
		await _begin("lift-off at %d" % int(kmh))
		var r: Dictionary = await _rig.call(&"lift_off", _tc, _car, kmh, g)
		var name := "%d km/h " % int(kmh)
		if not r["reached"]:
			_add("lift-off", name + "peak body slip", NAN, "%.1f", "deg", "lift.slip", "could not corner at %.1f g" % g)
			continue
		_add("lift-off", name + "peak body slip", r["slip_peak_deg"], "%.1f", "deg", "lift.slip", ("stopped at 30 deg; " if r["spun"] else "") +
				"at %.2f g: %.1f deg before the lift, yaw rate x%.2f after" % [r["lat_g"], r["slip_before_deg"], r["yaw_gain"]])
		_add_text("lift-off", name + "spin", "yes" if r["spun"] else "no", "no", "DYN3", "FAIL" if r["spun"] else "PASS")

func _bench_ride() -> void:
	for kmh: float in [0.0, 150.0, 300.0]:
		await _begin("ride at %d" % int(kmh))
		var r: Dictionary = await _rig.call(&"ride", _tc, _car, kmh)
		var name := "%d km/h " % int(kmh)
		var known := not is_nan(r["load_ratio"])
		_add("ride", name + "wheel load / weight", r["load_ratio"], "%.2f", "x", "ride.load.%d" % int(kmh),
				"%.1f kN on the wheels, %.1f kN downforce, %.1f kN drag" % [r["load_n"] / 1000.0, r["downforce_n"] / 1000.0, r["drag_n"] / 1000.0] if known else "")
		_add("ride", name + "ride height F / R", NAN, "", "", "", "against the design height; - = lower" if known else "",
				"%+.1f / %+.1f mm" % [-r["front_mm"], -r["rear_mm"]] if known else "")

## A lap from tools/lap_check.sh: "track:seconds:STATUS" (seconds < 0 = no lap completed).
func _lap_row(arg: String) -> void:
	var id := arg.get_slice(":", 0)
	var seconds := float(arg.get_slice(":", 1))
	var status := arg.get_slice(":", 2)
	var note := "autopilot flying lap" + ("" if status == "OK" else "; lap check " + status)
	var label := "%s lap" % id
	if not POLES.has(id):
		_rows.append({"group": "lap", "name": label, "value": _lap_text(seconds), "target": "no pole time on file",
				"ref": "", "status": "-" if seconds > 0.0 else "n/a", "note": note})
		return
	var pole: float = POLES[id][0]
	var lo := pole * 0.99
	var hi := pole * 1.04
	_rows.append({"group": "lap", "name": label, "value": _lap_text(seconds),
			"target": "%s .. %s" % [_lap_text(lo), _lap_text(hi)], "ref": POLES[id][1],
			"status": _status(seconds, lo, hi) if seconds > 0.0 else "n/a",
			"note": note + ("; pole %s (%+.1f %%)" % [_lap_text(pole), (seconds / pole - 1.0) * 100.0] if seconds > 0.0 else "")})

func _lap_text(seconds: float) -> String:
	if seconds <= 0.0:
		return "n/a"
	return "%d:%06.3f" % [int(seconds) / 60, fmod(seconds, 60.0)]

# ---------------------------------------------------------------------------- the table

## -1 from the rig means "never reached".
func _reached(v: float) -> float:
	return NAN if v < 0.0 else v

func _status(v: float, lo: float, hi: float) -> String:
	if v >= lo and v <= hi:
		return "PASS"
	var margin := maxf(WARN_MARGIN * (hi - lo), WARN_MIN * absf(0.5 * (lo + hi)))
	return "WARN" if v >= lo - margin and v <= hi + margin else "FAIL"

## Adds a measured row. `key` is a TARGETS key ("" = no target, shown for information);
## a NAN value is "not available" (the handling model does not have it, or never got there).
func _add(group: String, name: String, value: float, fmt: String, unit: String, key: String, note: String = "", text: String = "") -> void:
	var row := {"group": group, "name": name, "value": text, "target": "", "ref": "", "status": "-", "note": note}
	if text == "":
		row["value"] = "n/a" if is_nan(value) else ((fmt % value) + " " + unit).strip_edges()
	if TARGETS.has(key):
		var t: Array = TARGETS[key]
		var tfmt := fmt.replace("+", "")
		row["target"] = ("%s .. %s %s" % [tfmt % t[0], tfmt % t[1], unit]).strip_edges()
		row["ref"] = t[2]
		row["status"] = "n/a" if is_nan(value) else _status(value, t[0], t[1])
	elif text == "" and is_nan(value):
		row["status"] = "n/a"
	_rows.append(row)

func _add_text(group: String, name: String, value: String, target: String, ref: String, status: String, note: String = "") -> void:
	_rows.append({"group": group, "name": name, "value": value, "target": target, "ref": ref, "status": status, "note": note})

func _print_table(handling: String, sim: Object, sim_s: float, wall_s: float) -> void:
	var head := "SIM BENCH   handling=%s" % handling
	if sim != null:
		var spec: Resource = sim.get(&"spec")
		var st: Object = sim.get(&"state")
		head += "   spec=%s   mass %.0f kg with %.0f kg of fuel" % [spec.resource_path.get_file(), float(st.get(&"mass")), float(st.get(&"fuel"))]
	print("")
	print(head)
	print("flat asphalt pad, %d Hz, %.0f s simulated in %.1f s; targets and sources: docs/sim_targets.md" % [
			Engine.physics_ticks_per_second, sim_s, wall_s])
	print("")
	var cols: PackedStringArray = ["group", "name", "value", "target", "ref", "status", "note"]
	var titles: PackedStringArray = ["group", "quantity", "measured", "target band", "ref", "status", "note"]
	var width: Array[int] = []
	for c in cols.size():
		var w := titles[c].length()
		for row in _rows:
			w = maxi(w, (row[cols[c]] as String).length())
		width.append(w)
	var line := ""
	var rule := ""
	for c in cols.size():
		line += titles[c].rpad(width[c]) + "  "
		rule += "-".repeat(width[c]) + "  "
	print(line.strip_edges(false, true))
	print(rule.strip_edges(false, true))
	var last_group := ""
	var count := {"PASS": 0, "WARN": 0, "FAIL": 0, "n/a": 0, "-": 0}
	for row in _rows:
		line = ""
		for c in cols.size():
			var cell: String = row[cols[c]]
			if c == 0 and cell == last_group:
				cell = ""
			# Numbers line up on the right, text on the left.
			line += (cell.lpad(width[c]) if c == 2 else cell.rpad(width[c])) + "  "
		last_group = row["group"]
		count[row["status"]] = int(count.get(row["status"], 0)) + 1
		print(line.strip_edges(false, true))
	print("")
	print("RESULT: %d PASS, %d WARN, %d FAIL, %d not available, %d for information" % [
			count["PASS"], count["WARN"], count["FAIL"], count["n/a"], count["-"]])
