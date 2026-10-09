extends SceneTree
## Headless full-lap check for any track: the autopilot drives one standing lap and one flying
## lap; reports lap times, the closest approach to the road edge and any impacts.
## Usage: tools/lap_check.sh <track_id>     (exit code 0 = both laps clean)
## --lap-tracks-dir=res://folder also looks for the track in that folder of track folders (a
## fixture of tests/fixtures/tracks, or a scratch build copied into the project).

const TICK := 1.0 / 240.0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var id := ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--lap-track="):
			id = a.get_slice("=", 1)
		elif a.begins_with("--lap-tracks-dir="):
			(load("res://scripts/track/track_catalog.gd") as GDScript).call(
					&"set_extra_dirs", PackedStringArray([a.get_slice("=", 1)]))
		elif a.begins_with("--handling="):
			# Bootstrap parses this too; set here in case this script's args came first.
			root.get_node("/root/Bootstrap").set(&"handling_override", StringName(a.get_slice("=", 1)))
	var boot := root.get_node("/root/Bootstrap")
	var game := root.get_node("/root/Game")
	boot.set(&"autodrive", true)
	boot.set(&"skip_countdown", true)
	boot.set(&"dev_run", true)
	root.get_node("/root/Settings").set(&"persist", false)
	# Game classes are loaded at run time: typed references would be compiled before the
	# autoloads exist when this file runs as the main-loop script.
	var cfg: Object = (load("res://scripts/race/race_config.gd") as GDScript).new()
	cfg.set(&"track_id", id)
	cfg.set(&"ghost", false)
	game.set(&"config", cfg)
	var catalog: GDScript = load("res://scripts/track/track_catalog.gd")
	var info: Object = catalog.call(&"find", id)
	if info == null or not info.get(&"available"):
		print("LAPCHECK %s FAIL track not available in the catalog" % id)
		quit(2)
		return
	var scene: Node = (load("res://scenes/race.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await physics_frame
	var car := scene.get_node_or_null("Car") as RigidBody3D
	var pilot := scene.get_node_or_null("Autodrive")
	var track := scene.get_node_or_null("Track")
	if car == null or pilot == null or track == null or track.get(&"data") == null:
		print("LAPCHECK %s FAIL race scene did not build (car/autopilot/track missing)" % id)
		quit(2)
		return
	var data: Object = track.get(&"data")
	var road := track.get_node_or_null("Road")
	var s: float = data.call(&"closest_s", car.global_position)
	var progress := 0.0
	var t := 0.0
	var worst_edge := INF
	var worst_s := 0.0
	var impacts := 0
	var impact_s: Array[int] = []
	var top := 0.0
	var prev_speed := 0.0
	var laps: Array[float] = []
	var length: float = data.get(&"length")
	var limit := 60.0 + length / 25.0 * 2.2   # generous: two laps at ~25 m/s average
	var stuck := 0.0
	while t < limit and laps.size() < 2:
		await physics_frame
		t += TICK
		var pos := car.global_position
		var ns: float = data.call(&"closest_s", pos, s)
		progress += float(data.call(&"delta_s", s, ns))
		s = ns
		var hw: float = road.call(&"half_width_at", s) if road != null and road.has_method(&"half_width_at") else float(data.call(&"width_at", s)) * 0.5
		var off := absf(float(data.call(&"lateral_offset", pos, s)))
		if road != null and road.has_method(&"surface_point"):
			var c: Vector3 = road.call(&"surface_point", s, 0.0)
			var r: Vector3 = road.call(&"surface_point", s, 1.0)
			off = absf((pos - c).dot((r - c).normalized()))
		if hw - off < worst_edge:
			worst_edge = hw - off
			worst_s = s
		var speed := car.linear_velocity.length()
		top = maxf(top, speed)
		# An impact: losing more than 8 m/s within one tick (braking is ~0.08 m/s per tick).
		if prev_speed - speed > 8.0:
			impacts += 1
			impact_s.append(int(s))
		prev_speed = speed
		stuck = stuck + TICK if speed < 1.0 and t > 8.0 else 0.0
		if stuck > 6.0:
			break
		if int(t / TICK) % 4800 == 0:
			print("  .. t=%.0fs s=%.0f progress=%.0f speed=%.0fkm/h laps=%d" % [t, s, progress, speed * 3.6, int(pilot.get(&"laps_completed"))])
		if int(pilot.get(&"laps_completed")) > laps.size():
			laps.append(float(pilot.get(&"lap_time")))
	var ok := laps.size() == 2 and worst_edge > 0.0 and impacts == 0
	print("LAPCHECK %s [%s] %s laps=%s top=%.0fkm/h min_edge=%.2fm@s=%.0f impacts=%d%s progress=%.0fm/%.0fm sim=%.0fs" % [
		id, str(car.get(&"handling")), "OK" if ok else "FAIL", str(laps.map(func(x: float) -> String: return "%d:%06.3f" % [int(x) / 60, fmod(x, 60.0)])),
		top * 3.6, worst_edge, worst_s, impacts, (" at s=" + str(impact_s.slice(0, 5))) if impacts > 0 else "",
		progress, length * 2.0, t])
	if laps.size() > 0 and "--lap-report" in OS.get_cmdline_user_args():
		print(pilot.call(&"report"))
	quit(0 if ok else 1)
