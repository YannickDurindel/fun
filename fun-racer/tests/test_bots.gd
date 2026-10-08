extends TestCase
## Bot opponents: grid, countdown freeze, driving, ghost collisions, standings, difficulty pace
## and the shared racing-line cache.

const SCENE := "res://scenes/race_red_bull_ring.tscn"

var _scene: Node
var _mgr: BotManager
var _race: RaceManager
var _car: Car
var _data: TrackData
var _saved_bots: int = 0
var _saved_difficulty: int = 1

## Loads the race scene with `bots` opponents. The countdown is on unless `skip_countdown`.
func _setup(bots: int, difficulty: int = 1, skip_countdown: bool = false) -> void:
	_saved_bots = Game.config.bots
	_saved_difficulty = Game.config.bot_difficulty
	Game.config.bots = bots
	Game.config.bot_difficulty = difficulty
	Bootstrap.autodrive = false
	Bootstrap.skip_countdown = skip_countdown
	_scene = spawn(SCENE)
	_mgr = _scene.get_node("Bots") as BotManager
	_mgr.rails_distance = 0.0   # every bot fully simulated, however far (test_rails covers the rest)
	_race = _scene.get_node("Track/Race") as RaceManager
	_car = _scene.get_node("Car") as Car
	_data = _race.data
	_race.persist_best = false

func _teardown() -> void:
	Game.config.bots = _saved_bots
	Game.config.bot_difficulty = _saved_difficulty
	Bootstrap.skip_countdown = true

func _on_road(car: Car) -> bool:
	var s := _data.closest_s(car.global_position)
	return absf(_data.lateral_offset(car.global_position, s)) < _data.width_at(s) * 0.5

func test_no_bots_spawns_nothing() -> void:
	_setup(0)
	await physics_frames(5)
	assert_true(_mgr != null, "race scene has a Bots node")
	assert_true(_mgr.bots.is_empty() and _mgr.get_child_count() == 0, "bots = 0 spawns no car")
	assert_true(_mgr.get_standings().is_empty(), "no standings without bots")
	assert_true(not _mgr.is_physics_processing() and not _mgr.is_processing(), "Bots node idles with 0 bots")
	var panel := _scene.get_node("UI/Standings") as Control
	await physics_frames(20)
	assert_true(panel != null and not panel.visible, "standings panel hidden with 0 bots")
	_teardown()

func test_grid_countdown_drive_standings_restart() -> void:
	_setup(3)
	await physics_frames(30)
	assert_true(_mgr.bots.size() == 3, "3 bot cars spawned (%d)" % _mgr.bots.size())
	assert_true(_race.state == RaceManager.State.COUNTDOWN, "countdown running")
	# ---- grid: distinct slots behind the player, 8 m apart, alternating sides
	var pole_s := _data.closest_s(_car.global_position)
	var grid: Array[Vector3] = []
	for i in _mgr.bots.size():
		var bot := _mgr.bots[i]
		grid.append(bot.global_position)
		var behind := -_data.delta_s(pole_s, _data.closest_s(bot.global_position))
		assert_between(behind, 8.0 * (i + 1) - 0.5, 8.0 * (i + 1) + 0.5, "bot %d distance behind pole (m)" % (i + 1))
		var lateral := _data.lateral_offset(bot.global_position)
		assert_between(lateral * (1.0 if i % 2 == 0 else -1.0), 2.0, 3.0, "bot %d lateral slot (m)" % (i + 1))
		assert_true(not bot.simulate, "bot %d frozen during the countdown" % (i + 1))
		assert_true(bot.collision_layer == 0, "bot %d sits on no physics layer" % (i + 1))
		for j in i:
			assert_true(bot.global_position.distance_to(_mgr.bots[j].global_position) > 5.0, "bots %d and %d share a slot" % [i + 1, j + 1])
	var rows := _mgr.get_standings()
	assert_true(rows.size() == 4 and rows[0]["is_player"], "player leads the standings on the grid")
	# ---- still frozen one second into the countdown
	await physics_frames(240)
	assert_true(_race.state == RaceManager.State.COUNTDOWN, "still counting down")
	for i in _mgr.bots.size():
		assert_true(_mgr.bots[i].global_position.distance_to(grid[i]) < 0.01, "bot %d moved during the countdown" % (i + 1))
	# ---- GO: after ~8 s every bot is well down the road, on it and upright
	var player_start := _car.global_position
	_race.start_now()
	await physics_frames(240 * 8)
	for i in _mgr.bots.size():
		var bot := _mgr.bots[i]
		assert_true(bot.simulate, "bot %d released at GO" % (i + 1))
		var gone := _mgr.drivers[i].progress - _data.closest_s(grid[i])
		assert_true(gone > 150.0, "bot %d advanced %.0f m in 8 s, expected > 150" % [i + 1, gone])
		assert_true(_on_road(bot), "bot %d left the road" % (i + 1))
		assert_true(bot.global_transform.basis.y.dot(Vector3.UP) > 0.8, "bot %d is not upright" % (i + 1))
		assert_true(_mgr.drivers[i].respawns == 0, "bot %d needed a respawn" % (i + 1))
	# The bots drove straight through the parked player without touching it.
	assert_true(_car.global_position.distance_to(player_start) < 0.5,
			"player pushed %.2f m by passing bots" % _car.global_position.distance_to(player_start))
	# ---- standings: ordered by progress, player (parked) last, gaps grow down the order
	rows = _mgr.get_standings()
	assert_true(rows.size() == 4, "4 classified cars (%d)" % rows.size())
	var players := 0
	for i in rows.size():
		var row := rows[i]
		assert_true(int(row["position"]) == i + 1, "positions run 1..n")
		players += 1 if row["is_player"] else 0
		assert_true(float(row["gap"]) >= 0.0, "gap is never negative")
		if i > 0:
			assert_true(float(row["progress"]) <= float(rows[i - 1]["progress"]), "standings ordered by progress")
			assert_true(float(row["gap"]) >= float(rows[i - 1]["gap"]) - 0.01, "gap to the leader grows down the order")
	assert_true(players == 1 and rows[3]["is_player"], "the parked player is classified last")
	assert_true(float(rows[3]["gap"]) > 1.0, "the player is seconds behind (%.2f)" % float(rows[3]["gap"]))
	assert_true(_mgr.player_position() == 4, "player_position() = %d" % _mgr.player_position())
	var panel := _scene.get_node("UI/Standings") as Control
	panel.call(&"refresh")
	assert_true(panel.visible, "standings panel shown with bots")
	# ---- restart: back on the grid, frozen again
	_race.restart()
	await physics_frames(10)
	for i in _mgr.bots.size():
		assert_true(_mgr.bots[i].global_position.distance_to(grid[i]) < 0.2, "bot %d back on its slot after a restart" % (i + 1))
		assert_true(not _mgr.bots[i].simulate, "bot %d frozen again after a restart" % (i + 1))
	assert_true(_mgr.get_standings()[0]["is_player"], "player leads again after a restart")
	_teardown()

func test_bot_and_player_do_not_collide() -> void:
	_setup(1, 1, true)
	await physics_frames(5)
	var bot := _mgr.bots[0]
	# Both cars stand still under physics, the bot exactly inside the player.
	_mgr.drivers[0].set_physics_process(false)
	_car.set_input_override(0.0, 0.0, 0.0)
	bot.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(60)   # settle on the suspension
	var p0 := _car.global_position
	bot.spawn_transform = _car.global_transform
	bot.respawn()
	await physics_frames(240)
	assert_true(bot.simulate and _car.simulate, "both cars simulate")
	assert_true(_car.global_position.distance_to(p0) < 0.05,
			"player moved %.3f m with a bot inside it" % _car.global_position.distance_to(p0))
	assert_true(bot.global_position.distance_to(p0) < 0.15,
			"bot pushed %.3f m out of the player" % bot.global_position.distance_to(p0))
	assert_true(bot.global_transform.basis.y.dot(Vector3.UP) > 0.99, "bot stays level inside the player")
	_car.clear_input_override()
	_teardown()

func test_stuck_bot_respawns_on_track() -> void:
	_setup(1, 1, true)
	await physics_frames(5)
	var bot := _mgr.bots[0]
	var driver := _mgr.drivers[0]
	await physics_frames(240)
	# Far off the road, upside down.
	var s := driver.current_s
	var xf := _race.track.spawn_transform(s, 60.0)
	xf.basis = xf.basis.rotated(xf.basis.z, PI)
	xf.origin.y += 3.0
	bot.spawn_transform = xf
	bot.respawn()
	var waited := 0
	while driver.respawns == 0 and waited < int(240 * (BotDriver.STUCK_TIME + 2.0)):
		await physics_frames(1)
		waited += 1
	assert_true(driver.respawns >= 1, "stuck bot was respawned")
	await physics_frames(120)
	assert_true(_on_road(bot), "respawned bot is back on the road")
	assert_true(bot.global_transform.basis.y.dot(Vector3.UP) > 0.8, "respawned bot is upright")
	_teardown()

func test_far_bots_go_on_rails_and_come_back() -> void:
	_setup(2, 1, true)
	_mgr.rails_distance = 150.0
	_mgr.rails_distance_unseen = 0.0   # distance rule only: the bots start behind the camera
	_car.set_input_override(0.0, 0.0, 0.0)   # the player stays parked on the grid
	var waited := 0
	while not (_mgr.drivers[0].on_rails and _mgr.drivers[1].on_rails) and waited < 240 * 12:
		await physics_frames(1)
		waited += 1
	assert_true(waited < 240 * 12, "bots far from the player never went on rails")
	var driver := _mgr.drivers[0]
	var bot := _mgr.bots[0]
	assert_true(not bot.simulate, "a bot on rails is not simulated")
	assert_true(bot.global_position.distance_to(_car.global_position) > 140.0, "only far bots go on rails")
	var p0 := driver.progress
	var pos0 := bot.global_position
	await physics_frames(120)
	assert_true(driver.on_rails, "still on rails")
	assert_true(driver.progress - p0 > 15.0, "bot on rails advanced %.1f m in 0.5 s" % (driver.progress - p0))
	assert_between(bot.global_position.distance_to(pos0), (driver.progress - p0) * 0.8, (driver.progress - p0) * 1.2,
			"car on rails moved with its progress (m)")
	assert_true(_on_road(bot), "bot on rails left the road")
	assert_true(_mgr.get_standings()[0]["car"] == bot, "the bot on rails leads the standings")
	# The player catches up: the bot is handed back to the physics, at speed.
	var v_rail := driver.speed()
	_car.spawn_transform = _race.track.spawn_transform(driver.current_s - 15.0, 0.0)
	_car.respawn()
	await physics_frames(12)
	assert_true(not driver.on_rails and bot.simulate, "bot simulated again near the player")
	assert_between(bot.linear_velocity.length(), v_rail * 0.85, v_rail * 1.15, "speed kept through the hand-over (m/s)")
	await physics_frames(120)
	assert_true(_on_road(bot), "bot left the road after the hand-over")
	assert_true(bot.global_transform.basis.y.dot(Vector3.UP) > 0.8, "bot upright after the hand-over")
	assert_true(driver.respawns == 0, "hand-over needed a respawn")
	assert_true(bot.linear_velocity.length() > v_rail * 0.7, "bot still at speed 0.5 s after the hand-over")
	_car.clear_input_override()
	_teardown()

func test_difficulty_pace_and_shared_cache() -> void:
	_setup(3, BotDriver.EASY, true)
	await physics_frames(2)
	var lines := Autopilot.line_builds
	var profiles := Autopilot.profile_builds
	var easy := _mgr.drivers[0]
	assert_true(easy.predicted_lap_time > 0.0, "bot profile built at spawn")
	var pilots: Array[BotDriver] = [easy]
	for level: int in [BotDriver.MEDIUM, BotDriver.HARD, BotDriver.HARD]:
		var d := BotDriver.new()
		d.configure(_mgr.bots[0], _race.track, level, 0)
		d.set_physics_process(false)
		add_child(d)
		assert_true(d.prepare(), "driver prepares")
		pilots.append(d)
	assert_true(Autopilot.line_builds == lines, "racing line shared by every driver of the track")
	assert_true(Autopilot.profile_builds <= profiles + 2, "speed profile shared per difficulty (%d new)" % (Autopilot.profile_builds - profiles))
	assert_true(pilots[1].predicted_lap_time < pilots[0].predicted_lap_time - 2.0,
			"medium (%.1f s) is quicker than easy (%.1f s)" % [pilots[1].predicted_lap_time, pilots[0].predicted_lap_time])
	assert_true(pilots[2].predicted_lap_time < pilots[1].predicted_lap_time - 2.0,
			"hard (%.1f s) is quicker than medium (%.1f s)" % [pilots[2].predicted_lap_time, pilots[1].predicted_lap_time])
	# Corner speed at Remus (T3) rises with the difficulty.
	var apex := 0.0
	for t: Dictionary in _data.turns:
		if t.get("id", "") == "T3":
			apex = float(t["s_apex"])
	for i in 2:
		assert_true(pilots[i + 1].target_speed_at(apex) > pilots[i].target_speed_at(apex),
				"apex speed rises with difficulty (%d)" % i)
	# Bots of one difficulty still differ (seeded): pace scale and line.
	assert_true(_mgr.drivers[0].speed_scale > _mgr.drivers[2].speed_scale, "front bots are the quicker ones")
	assert_true(_mgr.drivers[0].line_shift * _mgr.drivers[1].line_shift < 0.0, "neighbours take different lines")
	var again := BotDriver.new()
	again.configure(_mgr.bots[1], _race.track, BotDriver.EASY, 1, _mgr.variation_seed)
	assert_true(is_equal_approx(again.speed_scale, _mgr.drivers[1].speed_scale)
			and is_equal_approx(again.line_shift, _mgr.drivers[1].line_shift), "variation is deterministic")
	again.free()
	# Names and liveries are distinct.
	var names := {}
	for row in _mgr.get_standings():
		names[row["name"]] = row["color"]
	assert_true(names.size() == 4, "4 distinct names")
	_teardown()
