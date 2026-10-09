extends SceneTree
## Experiment: measures the Car's steady-state lateral acceleration at full steering lock for a
## sweep of speeds on flat ground (main scene), plus straight-line braking and acceleration.
## The arcade autopilot's speed profile constants come from this table.
## Usage: tools/bin/godot --headless --path . --fixed-fps 240 --disable-vsync -s res://tools/lap_grip_sweep.gd
##
## With `-- --envelope` it measures the SIMULATION car instead (CarEnvelope.measure: steering
## ramps, full-throttle runs and a stop on a flat pad), prints the table and writes
## res://assets/car/envelopes/<spec>.json, the file the autopilot and the bots plan from.
## Commit that file. Rerun after changing the car spec or a simulation part: the file carries a
## hash of both, and a stale file is ignored (the game then measures by itself at the first
## simulation race and keeps the result under user://). `-- --envelope --dry-run` only prints.

const SPEEDS_KMH: Array[float] = [60.0, 80.0, 100.0, 130.0, 160.0, 200.0, 250.0, 300.0]

var _car: RigidBody3D  # Car (untyped: autoloads compile after -s scripts)

func _initialize() -> void:
	_run.call_deferred()

func _ticks(n: int) -> void:
	for i in n:
		await physics_frame

func _run() -> void:
	if "--envelope" in OS.get_cmdline_user_args():
		await _envelope()
		return
	var scene: Node = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	_car = scene.get_node("Car") as RigidBody3D
	await _ticks(60)
	print("steer   speed_kmh  a_lat(m/s2)  a_lat(g)  radius(m)  drift")
	for steer: float in [1.0, 0.6]:
		for kmh in SPEEDS_KMH:
			await _corner(kmh, steer)
	await _brake_test()
	quit(0)

## Accelerates straight to `kmh`, then holds the lock while servoing throttle/brake on speed.
func _corner(kmh: float, steer: float) -> void:
	_car.respawn()
	await _ticks(10)
	var target := kmh / 3.6
	var guard := 0
	while _car.forward_speed < target and guard < 240 * 40:
		_car.set_input_override(1.0, 0.0, 0.0)
		await physics_frame
		guard += 1
	var a_sum := 0.0
	var n := 0
	var drift := false
	for i in 240 * 3:
		var err: float = target - float(_car.forward_speed)
		_car.set_input_override(clampf(err * 0.5 + 0.3, 0.0, 1.0), 0.0, steer)
		await physics_frame
		drift = drift or _car.is_drifting
		if i > 240:   # settled
			var v := _car.linear_velocity.length()
			a_sum += v * absf(_car.angular_velocity.y)
			n += 1
	var a := a_sum / maxf(n, 1)
	var v_end := _car.linear_velocity.length()
	print("%.1f    %6.0f     %7.2f      %5.2f    %7.1f    %s" % [steer, kmh, a, a / 9.81, v_end * v_end / maxf(a, 0.01), drift])
	_car.clear_input_override()

func _brake_test() -> void:
	_car.respawn()
	await _ticks(10)
	var t := 0.0
	var marks := {100.0: -1.0, 200.0: -1.0, 300.0: -1.0}
	while _car.speed_kmh < 320.0 and t < 30.0:
		_car.set_input_override(1.0, 0.0, 0.0)
		await physics_frame
		t += 1.0 / 240.0
		for m: float in marks:
			if marks[m] < 0.0 and _car.speed_kmh >= m:
				marks[m] = t
	print("accel: 0-100 %.2fs  0-200 %.2fs  0-300 %.2fs" % [marks[100.0], marks[200.0], marks[300.0]])
	var v0 := _car.linear_velocity.length()
	var p0 := _car.global_position
	t = 0.0
	while _car.speed_kmh > 1.0 and t < 30.0:
		_car.set_input_override(0.0, 1.0, 0.0)
		await physics_frame
		t += 1.0 / 240.0
	var dist := p0.distance_to(_car.global_position)
	print("brake from %.0f km/h: %.2fs, %.1f m, mean decel %.2f m/s2 (v^2/2d = %.2f)" % [v0 * 3.6, t, dist, v0 / t, v0 * v0 / (2.0 * dist)])

## Measures the simulation car's performance envelope and writes the committed file.
func _envelope() -> void:
	root.get_node("/root/Settings").set(&"persist", false)
	# Loaded at run time: class names of the game are not known when this script is compiled.
	var script: GDScript = load("res://scripts/race/car_envelope.gd")
	var spec_path: String = (load("res://scripts/car/car.gd") as GDScript).get_script_constant_map()["SIM_SPEC_PATH"]
	var env: RefCounted = await script.call(&"measure", root, spec_path)
	print(env.call(&"describe"))
	if not env.call(&"is_sane"):
		print("ENVELOPE FAIL the measurement gave unusable numbers")
		quit(1)
		return
	var path: String = script.call(&"res_path", spec_path)
	if "--dry-run" in OS.get_cmdline_user_args():
		print("ENVELOPE OK (dry run, %s not written)" % path)
		quit(0)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var ok: bool = env.call(&"save", ProjectSettings.globalize_path(path))
	print("ENVELOPE %s %s key %s" % ["OK wrote" if ok else "FAIL could not write", path, env.get(&"key")])
	quit(0 if ok else 1)
