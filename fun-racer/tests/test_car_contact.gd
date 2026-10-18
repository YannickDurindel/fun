extends TestCase
## Optional car contact (Settings gameplay/car_contact): solid bots bump the player and each
## other without launching, ghosts (the default) pass through.

const SCENE := "res://scenes/race_red_bull_ring.tscn"

var _scene: Node
var _mgr: BotManager
var _race: RaceManager
var _car: Car
var _data: TrackData
var _saved_bots: int = 0
var _saved_contact: bool = false

func _setup(bots: int, contact: bool) -> void:
	_saved_bots = Game.config.bots
	_saved_contact = Settings.get_value("gameplay", "car_contact")
	Game.config.bots = bots
	Settings.set_value("gameplay", "car_contact", contact)
	Bootstrap.autodrive = false
	Bootstrap.skip_countdown = true
	_scene = spawn(SCENE)
	_mgr = _scene.get_node("Bots") as BotManager
	_race = _scene.get_node("Track/Race") as RaceManager
	_car = _scene.get_node("Car") as Car
	_data = _race.data
	_race.persist_best = false

func _teardown() -> void:
	_car.clear_input_override()
	Game.config.bots = _saved_bots
	Settings.set_value("gameplay", "car_contact", _saved_contact)

## Height of the car above the road surface under it (m).
func _height(c: Car) -> float:
	return c.global_position.y - _data.sample(_data.closest_s(c.global_position)).origin.y

func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)

## Player and bot side by side at 20 m/s on the start straight, 2.8 m apart; the bot (on the
## right) steers into the player for half a second, then straight. Returns what happened.
func _side_by_side() -> Dictionary:
	await physics_frames(5)
	var bot := _mgr.bots[0]
	_mgr.drivers[0].set_physics_process(false)   # inputs by hand
	_mgr.rails_distance = 0.0
	var s := _data.wrap_s(_data.start_s + 60.0)
	_car.spawn_transform = _race.track.spawn_transform(s, -1.4)
	bot.spawn_transform = _race.track.spawn_transform(s, 1.4)
	_car.respawn()
	bot.respawn()
	_car.set_input_override(0.0, 0.0, 0.0)
	bot.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(60)   # settle on the suspension
	var y0 := maxf(_height(_car), _height(bot))
	for c: Car in [_car, bot]:
		c.linear_velocity = -c.global_transform.basis.z * 20.0
	_car.set_input_override(0.5, 0.0, 0.0)
	bot.set_input_override(0.5, 0.0, -0.35)   # negative steer = left, towards the player
	var r := {"min_sep": INF, "rise": 0.0, "finite": true, "upright": 1.0, "player_shift": 0.0, "player_kick": 0.0}
	var p_right := _car.global_transform.basis.x
	var p_lat0 := _car.global_position.dot(p_right)
	for i in 480:
		if i == 120:
			bot.set_input_override(0.5, 0.0, 0.0)
		await physics_frames(1)
		for c: Car in [_car, bot]:
			r["finite"] = r["finite"] and _finite(c.global_position) and _finite(c.linear_velocity)
			r["rise"] = maxf(r["rise"], _height(c) - y0)
			r["upright"] = minf(r["upright"], c.global_transform.basis.y.dot(Vector3.UP))
		var right := _car.global_transform.basis.x
		r["min_sep"] = minf(r["min_sep"], (bot.global_position - _car.global_position).dot(right))
		r["player_shift"] = maxf(r["player_shift"], absf(_car.global_position.dot(p_right) - p_lat0))
		r["player_kick"] = maxf(r["player_kick"], absf(_car.linear_velocity.dot(right)))
	r["final_sep"] = (bot.global_position - _car.global_position).dot(_car.global_transform.basis.x)
	r["bot_speed"] = bot.linear_velocity.length()
	return r

func test_contact_on_cars_bump_and_separate() -> void:
	_setup(1, true)
	var r: Dictionary = await _side_by_side()
	print("  contact ON: ", r)
	assert_true(_mgr.contact and _mgr.bots[0].collision_layer == BotManager.CONTACT_LAYER, "bot is solid")
	assert_true(r["finite"], "no NaN in positions or velocities")
	assert_true(r["min_sep"] < 2.1, "the cars touched (min %.2f m apart, 1.9 m wide)" % r["min_sep"])
	assert_true(r["min_sep"] > 1.3, "bot never got inside the player (min %.2f m apart)" % r["min_sep"])
	assert_true(r["player_kick"] > 0.3, "the bump pushed the player sideways (%.2f m/s)" % r["player_kick"])
	assert_true(r["rise"] < 1.0, "no car launched (rose %.2f m)" % r["rise"])
	assert_true(r["upright"] > 0.8, "both cars stayed upright (%.2f)" % r["upright"])
	assert_true(r["final_sep"] > 1.3, "bot still on its side after the bump (%.2f m)" % r["final_sep"])
	_teardown()

func test_contact_off_cars_pass_through() -> void:
	_setup(1, false)
	var r: Dictionary = await _side_by_side()
	print("  contact OFF: ", r)
	assert_true(not _mgr.contact and _mgr.bots[0].collision_layer == 0, "bot is a ghost")
	assert_true(r["min_sep"] < 0.5, "bot drove through the player (min %.2f m apart)" % r["min_sep"])
	assert_true(r["player_kick"] < 0.3, "player untouched (lateral %.2f m/s)" % r["player_kick"])
	_teardown()

## Seven solid bots start behind the parked player on pole: they get past without launching
## anyone, stay on the road, and the field is simulated near the player.
func test_contact_race_past_parked_player() -> void:
	_setup(7, true)
	_car.set_input_override(0.0, 0.0, 0.0)
	await physics_frames(5)
	var start := _car.global_position
	var ok := true
	var rise := 0.0
	for i in 240 * 12:
		await physics_frames(1)
		if i % 8 != 0:
			continue
		for c: Car in _mgr.bots + [_car]:
			ok = ok and _finite(c.global_position) and _finite(c.linear_velocity)
			if not c.freeze:
				rise = maxf(rise, _height(c))
	assert_true(ok, "no NaN with 7 solid bots")
	assert_true(rise < 2.0, "no car launched (max %.2f m above the road)" % rise)
	# Seven cars squeezing past a car stopped on the grid may clip it: no more than that.
	assert_true(_car.global_position.distance_to(start) < 50.0,
			"parked player pushed %.1f m" % _car.global_position.distance_to(start))
	assert_true(_car.global_transform.basis.y.dot(Vector3.UP) > 0.8, "player upright")
	var past := 0
	for i in _mgr.bots.size():
		var d := _mgr.drivers[i]
		var bot := _mgr.bots[i]
		assert_true(bot.global_transform.basis.y.dot(Vector3.UP) > 0.8, "bot %d upright" % (i + 1))
		if d.progress > _data.start_s + 50.0 or d.progress > 400.0:
			past += 1
		print("  bot %d progress %.0f respawns %d rails %s, %.1f m from the player, %.1f m/s" % [i + 1, d.progress,
				d.respawns, d.on_rails, bot.global_position.distance_to(_car.global_position), d.speed()])
	assert_true(past >= 6, "the field got past the parked player (%d of 7)" % past)
	_teardown()
