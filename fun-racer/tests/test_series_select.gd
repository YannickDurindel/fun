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
	# Every series has a calendar of its own; only F1 and endurance have cars to race them.
	assert_true(ids.size() == TrackCatalog.CALENDARS.size(), "one calendar per series")
	var all_ids := {}
	for s in SeriesCatalog.all():
		var id: String = s["id"]
		assert_true(TrackCatalog.CALENDARS.has(id), "%s has a calendar file" % id)
		assert_true(SeriesCatalog.has_events(id), "%s has events" % id)
		if id == "f1" or id == "endurance":
			continue
		assert_true(not SeriesCatalog.is_playable(id), "%s is coming soon" % id)
		for t in SeriesCatalog.tracks(id):
			assert_true(not t.available and t.circuit.is_empty(), "%s: %s is coming soon, on no built circuit" % [id, t.id])
			assert_true(not t.name.is_empty() and not t.grand_prix.is_empty() and t.country_code.length() == 2,
					"%s: %s has a venue, an event and a country" % [id, t.id])
			assert_true(not all_ids.has(t.id), "event ids are unique (%s)" % t.id)
			all_ids[t.id] = true
	for id in ["moto", "junior", "german_touring", "aus_touring", "super_formula", "super_gt", "rally_raid",
			"hill_climb", "drift", "karting"]:
		assert_true(ids.has(id), "%s is listed" % id)
	assert_true(ids.find("endurance") == 1, "the playable series come first")

func test_play_flow() -> void:
	# A permanent locked endurance fixture: every real endurance event is built now.
	TrackCatalog.set_extra_dirs(PackedStringArray(["res://tests/fixtures/locked_tracks"]))
	var menu := await _open()
	var screen := menu.current as SeriesSelectScreen
	assert_true(screen != null and screen.cards.size() == SeriesCatalog.all().size(), "one card per series")
	assert_true(get_viewport().gui_get_focus_owner() == screen.card_for("f1"), "F1 is pre-focused")
	# A coming-soon series opens its calendar, every event locked.
	screen.card_for("nascar").pressed.emit()
	assert_true(menu.current_name == "tracks", "NASCAR opens its calendar")
	var stock := menu.current as TrackSelectScreen
	assert_true(stock.cards.size() == SeriesCatalog.tracks("nascar").size() and stock.cards.size() > 20, "lists the stock car events")
	var first := stock.cards[0]
	assert_true(not first.info.available and not stock.select(first.info) and menu.current_name == "tracks", "they cannot be raced")
	menu.back()
	await get_tree().process_frame
	screen = menu.current as SeriesSelectScreen
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
	# The last card scrolls into view when focused, and right/left walk along a row.
	var last: Control = screen.cards.back()
	last.grab_focus()
	await get_tree().process_frame
	await get_tree().process_frame
	var view := screen.get_global_rect()
	var r := last.get_global_rect()
	assert_true(view.encloses(r) and r.end.y <= SeriesSelectScreen.TOP + SeriesSelectScreen.AREA_H + 20.0,
			"the last series is scrolled into view (%s)" % str(r))
	assert_true(screen.cards[0].get_node(screen.cards[0].focus_neighbor_right) == screen.cards[1], "right moves along the row")
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
