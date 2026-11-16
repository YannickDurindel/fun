extends TestCase
## The race scene's CatchPlane (a solid half-space that stops a car falling for ever) must sit
## below the whole lap. It used to be fixed at y = -80: the Nordschleife's Breidscheid valley
## is at about -280 m (relative to the finish line), so that part of the lap was inside the
## half-space and a car there was thrown ~160 m into the air on its first physics tick.

const TRACK := "n24_nurburgring"
const VALLEY_S := 12150.0   ## Breidscheid, the lowest part of the lap

func test_deep_lap_stays_above_the_catch_plane() -> void:
	var info := TrackCatalog.find(TRACK)
	if info == null or not info.available:
		failures.append("%s is not built (tools/track/build_track.py %s)" % [TRACK, TRACK])
		return
	var saved_track := Game.config.track_id
	var saved_bots := Game.config.bots
	var saved_spawn := Bootstrap.spawn_s
	Game.config.track_id = TRACK
	Game.config.bots = 0
	Bootstrap.autodrive = false
	Bootstrap.spawn_s = VALLEY_S
	var scene := spawn("res://scenes/race.tscn")
	await physics_frames(2)
	var track := scene.get_node("Track") as Track
	var low := 0.0
	for p in track.data.points:
		low = minf(low, p.y)
	var plane := scene.get_node("CatchPlane") as Node3D
	assert_true(low < -250.0, "the N24 lap dips deep (lowest point %.0f m)" % low)
	assert_true(plane.global_position.y <= low - 79.0, "catch plane %.0f m is below the lap's lowest point %.0f m" % [plane.global_position.y, low])
	# A car placed in the valley stays on the road instead of being thrown out of it.
	var car := scene.get_node("Car") as Car
	await physics_frames(240)
	var road_y := track.data.sample(track.data.closest_s(car.global_position)).origin.y
	assert_true(absf(car.global_position.y - road_y) < 2.0,
			"the car sits on the road in the valley (car %.1f, road %.1f)" % [car.global_position.y, road_y])
	scene.queue_free()
	await get_tree().process_frame
	Bootstrap.spawn_s = saved_spawn
	Game.config.track_id = saved_track
	Game.config.bots = saved_bots
