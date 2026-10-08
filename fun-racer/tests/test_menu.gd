extends TestCase
## Game shell: track catalog, settings, menu navigation and the menu -> race hand-off.

func test_track_catalog() -> void:
	TrackCatalog.reload()
	var all := TrackCatalog.all()
	assert_true(all.size() >= 20, "calendar lists the F1 circuits (%d)" % all.size())
	var rbr := TrackCatalog.find("red_bull_ring")
	assert_true(rbr != null and rbr.available, "Red Bull Ring is playable")
	assert_true(all[0].available, "playable tracks sort first")
	assert_between(rbr.length_m, 4300.0, 4330.0, "RBR length")
	assert_true(ResourceLoader.exists(rbr.scene), "RBR scene exists")
	var monza := TrackCatalog.find("monza")
	assert_true(monza != null and not monza.available, "Monza is listed as coming soon")
	assert_true(TrackCatalog.playable().size() >= 1, "at least one playable track")

func test_settings_round_trip() -> void:
	assert_true(not Settings.persist, "tests must not touch the real settings file")
	var seen: Array[String] = []
	var cb := func(section: String, key: String) -> void: seen.append(section + "/" + key)
	Settings.changed.connect(cb)
	Settings.set_value("audio", "master", 0.25)
	assert_between(Settings.get_value("audio", "master"), 0.249, 0.251, "value stored")
	assert_true(seen == ["audio/master"], "changed emitted once: %s" % str(seen))
	Settings.set_value("audio", "master", 0.25)
	assert_true(seen.size() == 1, "no signal when unchanged")
	Settings.reset("audio")
	assert_between(Settings.get_value("audio", "master"), 0.99, 1.01, "reset restores the default")
	Settings.changed.disconnect(cb)

func test_race_config() -> void:
	var c := RaceConfig.new()
	c.apply_dict({"mode": "race", "laps": 500, "bots": 3, "camera": 9})
	assert_true(c.mode == RaceConfig.MODE_RACE, "mode parsed")
	assert_true(c.laps == 99 and c.bots == 3 and c.camera == 3, "values clamped")
	var d := c.copy()
	d.laps = 5
	assert_true(c.laps == 99, "copy is independent")

func test_menu_flow_to_race() -> void:
	var changes: Array[String] = []
	Game.scene_changer = func(path: String) -> void: changes.append(path)
	Bootstrap.start_screen = ""
	Game.menu_start_screen = ""
	var menu := spawn(Game.MENU_SCENE) as MenuRouter
	await get_tree().process_frame
	assert_true(menu.current_name == "main", "menu opens on the main screen")
	menu.go("tracks")
	assert_true(menu.current_name == "tracks" and menu.can_go_back(), "tracks screen")
	Game.pending.track_id = "red_bull_ring"
	menu.go("race_options")
	menu.back()
	assert_true(menu.current_name == "tracks", "back returns to the previous screen")
	menu.go("race_options")
	Game.pending.mode = RaceConfig.MODE_RACE
	Game.pending.laps = 2
	Game.start_race()
	assert_true(changes == [Game.RACE_SCENE], "start_race loads the race scene: %s" % str(changes))
	assert_true(Game.config.track_id == "red_bull_ring" and Game.config.laps == 2, "config handed over")
	menu.queue_free()
	await get_tree().process_frame
	# The race scene builds the chosen track and applies the options.
	var race := spawn(Game.RACE_SCENE)
	await physics_frames(5)
	var track := race.get_node_or_null("Track") as Track
	assert_true(track != null and track.track_id == "red_bull_ring", "race scene instanced the track")
	var rm := track.get_node("Race") as RaceManager
	assert_true(rm.target_laps == 2, "lap target applied (%d)" % rm.target_laps)
	Game.quit_to_menu("tracks")
	assert_true(changes.back() == Game.MENU_SCENE and Game.menu_start_screen == "tracks", "quit_to_menu returns to the track list")
	Game.scene_changer = Callable()
	Game.pending = RaceConfig.new()
	Game.config = RaceConfig.new()
	Game.menu_start_screen = ""
