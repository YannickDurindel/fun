extends TestCase
## Series select screen (PLAY -> series -> tracks) and the SeriesCatalog.

func _open() -> MenuRouter:
	Game.scene_changer = func(_path: String) -> void: pass
	Game.pending = RaceConfig.new()
	Bootstrap.start_screen = ""
	Game.menu_start_screen = ""
	TrackSelectScreen.series = SeriesCatalog.F1
	var menu := spawn(Game.MENU_SCENE) as MenuRouter
	await get_tree().process_frame
	menu.go("series")
	await get_tree().process_frame
	return menu

func _close(menu: MenuRouter) -> void:
	menu.queue_free()
	await get_tree().process_frame
	Game.scene_changer = Callable()
	Game.pending = RaceConfig.new()
	TrackSelectScreen.series = SeriesCatalog.F1
	TrackCatalog.set_extra_dirs(PackedStringArray())

func test_catalog() -> void:
	var ids: Array[String] = []
	for s in SeriesCatalog.all():
		ids.append(s["id"])
	assert_true(ids[0] == "f1" and ids.has("endurance") and ids.size() >= 6, "series list: %s" % str(ids))
	var f1 := SeriesCatalog.tracks("f1")
	assert_true(f1.size() >= 20 and TrackCatalog.find("red_bull_ring") in f1, "F1 lists the F1 circuits")
	assert_true(TrackCatalog.playable()[0].series == "f1", "F1 tracks sort first")
	assert_true(SeriesCatalog.is_playable("f1"), "F1 has playable tracks")
	var endurance := SeriesCatalog.tracks("endurance")
	var names: Array[String] = []
	for t in endurance:
		names.append(t.grand_prix)
		assert_true(TrackCatalog.find(t.id) == t and not f1.has(t), "%s has its own id, outside F1" % t.id)
	assert_true(names.has("24 Hours of Le Mans") and names.has("Nürburgring 24 Hours") and names.has("6 Hours of Imola"),
			"endurance calendar: %s" % str(names))
	assert_true(SeriesCatalog.has_events("endurance"), "endurance can be browsed")
	var le_mans := TrackCatalog.find("wec_le_mans")
	assert_true(le_mans != null and le_mans.series == "endurance", "Le Mans is an endurance event")
	assert_true(not SeriesCatalog.has_events("nascar"), "series without a calendar cannot be opened")

func test_play_flow() -> void:
	# A permanent locked endurance fixture: every real endurance event is built now.
	TrackCatalog.set_extra_dirs(PackedStringArray(["res://tests/fixtures/locked_tracks"]))
	var menu := await _open()
	var screen := menu.current as SeriesSelectScreen
	assert_true(screen != null and screen.cards.size() == SeriesCatalog.all().size(), "one card per series")
	assert_true(get_viewport().gui_get_focus_owner() == screen.card_for("f1"), "F1 is pre-focused")
	# A coming-soon series stays on this screen.
	screen.card_for("nascar").pressed.emit()
	assert_true(menu.current_name == "series", "NASCAR cannot be opened yet")
	# Endurance opens its own track list, every event locked.
	screen.card_for("endurance").pressed.emit()
	assert_true(menu.current_name == "tracks", "endurance opens the track list")
	var tracks := menu.current as TrackSelectScreen
	assert_true(tracks.cards.size() == SeriesCatalog.tracks("endurance").size(), "lists the endurance events")
	var locked := tracks.card_for("locked_endurance")
	assert_true(locked != null and not tracks.select(locked.info) and menu.current_name == "tracks", "a coming-soon event cannot be raced")
	# Back returns to the series list with Endurance focused.
	menu.back()
	await get_tree().process_frame
	screen = menu.current as SeriesSelectScreen
	assert_true(screen != null and get_viewport().gui_get_focus_owner() == screen.card_for("endurance"), "focus returns to Endurance")
	screen.card_for("f1").pressed.emit()
	tracks = menu.current as TrackSelectScreen
	assert_true(tracks != null and tracks.card_for("red_bull_ring") != null, "F1 lists the F1 tracks")
	# Walking down from the first series card ends on BACK.
	menu.back()
	await get_tree().process_frame
	screen = menu.current as SeriesSelectScreen
	var c: Control = screen.cards[0]
	var steps := 0
	while c != screen.back_button and steps < 10:
		c = c.get_node(c.focus_neighbor_bottom) as Control
		steps += 1
	assert_true(c == screen.back_button, "the grid leads down to BACK")
	await _close(menu)

func test_start_on_tracks_keeps_back_path() -> void:
	Bootstrap.start_screen = ""
	Game.menu_start_screen = "tracks"
	var menu := spawn(Game.MENU_SCENE) as MenuRouter
	await get_tree().process_frame
	assert_true(menu.current_name == "tracks", "opens on the track list")
	menu.back()
	assert_true(menu.current_name == "series", "back from tracks goes to the series list")
	menu.back()
	assert_true(menu.current_name == "main", "then to the main menu")
	await _close(menu)

func test_endurance_event_on_an_f1_circuit() -> void:
	# 6 Hours of Imola is raced on the built F1 Imola folder: playable, with its own records.
	var imola := TrackCatalog.find("imola")
	var event := TrackCatalog.find("wec_imola")
	assert_true(imola != null and imola.available, "Imola is built")
	assert_true(event != null and event.available, "6 Hours of Imola is playable")
	assert_true(event.circuit_id() == "imola" and event.dir() == imola.dir(), "it uses the Imola folder (%s)" % event.dir())
	assert_true(event.scene == imola.scene and event.track_json == imola.track_json, "and the Imola scene and centreline")
	assert_true(event.series == "endurance" and event.grand_prix == "6 Hours of Imola", "it keeps its series and event")
	assert_true(event.best_path() == "user://best_wec_imola.json" and event.best_path() != imola.best_path(), "best laps per event")
	assert_true(event.display_name() == "6 Hours of Imola" and imola.display_name() == imola.name, "lists name the event")
	assert_true(event in SeriesCatalog.tracks("endurance") and not (event in SeriesCatalog.tracks("f1")), "only the endurance list shows it")
	var f1_ids: Array[String] = []
	for t in SeriesCatalog.tracks("f1"):
		f1_ids.append(t.id)
	assert_true(f1_ids.count("imola") == 1 and not f1_ids.has("wec_imola"), "no duplicate in the F1 list")
	# An event with its own folder is not an alias.
	var le_mans := TrackCatalog.find("wec_le_mans")
	assert_true(le_mans != null and le_mans.circuit.is_empty(), "Le Mans has its own circuit")

func test_event_race_loads_the_circuit_with_the_endurance_car() -> void:
	var saved_track := Game.config.track_id
	var saved_bots := Game.config.bots
	Game.config.track_id = "wec_imola"
	Game.config.bots = 0
	Bootstrap.autodrive = false
	var scene := spawn("res://scenes/race.tscn")
	await physics_frames(3)
	var track := scene.get_node("Track") as Track
	assert_true(track.track_id == "imola" and track.dir() == "res://assets/tracks/imola", "the Imola folder is loaded (%s)" % track.dir())
	assert_true(track.race_id() == "wec_imola", "the race is recorded as the event (%s)" % track.race_id())
	var race := track.get_node("Race") as RaceManager
	assert_true(race.call(&"_save_path") == "user://best_wec_imola.json", "best lap file of the event (%s)" % race.call(&"_save_path"))
	assert_true((scene.get_node("Car") as Car).kit == CarKit.ENDURANCE, "the endurance car races it")
	scene.queue_free()
	await get_tree().process_frame
	Game.config.track_id = saved_track
	Game.config.bots = saved_bots
