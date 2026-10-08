extends TestCase
## Scratch: full autopilot lap of Suzuka (run with --fixed-fps 240 --disable-vsync).

const TICK := 1.0 / 240.0

func test_full_lap() -> void:
	Bootstrap.autodrive = true
	Bootstrap.skip_countdown = true
	var scene := (load("res://scenes/race.tscn") as PackedScene).instantiate()
	scene.set(&"track_id", "suzuka")
	add_child(scene)
	var car := scene.get_node("Car") as Car
	var pilot := scene.get_node("Autodrive") as Autopilot
	var track := scene.get_node("Track") as Track
	var road := track.get_node("Road") as RoadSurface
	var data := track.data
	var waited := 0
	while car.linear_velocity.length() < 1.0 and waited < 240 * 15:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 15, "car never started moving")
	var s := data.closest_s(car.global_position)
	var time := 0.0
	var progress := 0.0
	var worst_edge := INF
	var worst_s := 0.0
	var top := 0.0
	var top_s := 0.0
	var max_dy := 0.0
	var dy_s := 0.0
	var log_next := 0.0
	while time < 260.0 and pilot.laps_completed < 2:
		await physics_frames(1)
		time += TICK
		var pos := car.global_position
		var ns := data.closest_s(pos, s)
		progress += data.delta_s(s, ns)
		s = ns
		var off := absf(data.lateral_offset(pos, s))
		var edge := road.half_width_at(s) - off
		if edge < worst_edge:
			worst_edge = edge
			worst_s = s
		var v := car.linear_velocity.length() * 3.6
		if v > top:
			top = v
			top_s = s
		var dy := absf(pos.y - data.position_at(s).y - 0.38)
		if dy > max_dy:
			max_dy = dy
			dy_s = s
		if progress >= log_next:
			print("       s=%6.0f  t=%6.2f  %3.0f km/h  y=%.1f  edge %.1f" % [s, time, v, pos.y, edge])
			log_next += 250.0
		if pilot.laps_completed == 1 and log_next < 1e8:
			print("\nLAP 1 (standing): %.3f s\n%s" % [pilot.lap_time, pilot.report()])
			print("       lap 1: top speed %.0f km/h at s=%.0f, min edge margin %.2f m at s=%.0f, max height off the road %.2f m at s=%.0f" % [top, top_s, worst_edge, worst_s, max_dy, dy_s])
			log_next = 1e9
	assert_true(pilot.laps_completed >= 2, "two laps not completed in 260 s (progress %.0f m, s=%.0f)" % [progress, s])
	assert_true(worst_edge > 0.0, "car left the road: edge margin %.2f m at s=%.0f" % [worst_edge, worst_s])
	assert_true(max_dy < 0.6, "car left the road surface vertically: %.2f m at s=%.0f" % [max_dy, dy_s])
	print("\nLAP 2 (flying): %.3f s\n%s" % [pilot.lap_time, pilot.report()])
	print("       both laps: top speed %.0f km/h at s=%.0f, min edge margin %.2f m at s=%.0f, max height off the road %.2f m at s=%.0f" % [top, top_s, worst_edge, worst_s, max_dy, dy_s])
	Bootstrap.autodrive = false
	Bootstrap.skip_countdown = false
