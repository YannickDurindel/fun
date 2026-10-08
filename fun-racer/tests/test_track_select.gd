extends TestCase
## Track select and race options screens, the OptionRow widget and the TrackMap control.

var _changes: Array[String] = []

func _open(screen: String) -> MenuRouter:
	_changes = []
	Game.scene_changer = func(path: String) -> void: _changes.append(path)
	Game.pending = RaceConfig.new()
	Game.config = RaceConfig.new()
	Bootstrap.start_screen = ""
	Game.menu_start_screen = ""
	var menu := spawn(Game.MENU_SCENE) as MenuRouter
	await get_tree().process_frame
	menu.go("tracks")
	if screen == "race_options":
		menu.go("race_options")
	await get_tree().process_frame
	return menu

func _reset(menu: MenuRouter = null) -> void:
	if menu != null:
		menu.queue_free()
		await get_tree().process_frame
	Game.scene_changer = Callable()
	Game.pending = RaceConfig.new()
	Game.config = RaceConfig.new()
	Game.menu_start_screen = ""
	Settings.reset("gameplay")

func test_cards_list_every_track() -> void:
	var menu := await _open("tracks")
	var screen := menu.current as TrackSelectScreen
	assert_true(screen != null, "tracks screen is a TrackSelectScreen")
	var all := TrackCatalog.all()
	assert_true(screen.cards.size() == all.size() and all.size() >= 20, "one card per catalog entry (%d / %d)" % [screen.cards.size(), all.size()])
	for i in mini(all.size(), screen.cards.size()):
		assert_true(screen.cards[i].info == all[i], "card %d shows %s" % [i, all[i].id])
		assert_true(screen.cards[i].focus_mode == Control.FOCUS_ALL and not screen.cards[i].disabled, "card %d can be focused" % i)
	# The track of Game.pending is pre-focused and shown in the detail panel.
	assert_true(get_viewport().gui_get_focus_owner() == screen.card_for("red_bull_ring"), "pending track is pre-focused")
	assert_true(screen.focused_info != null and screen.focused_info.id == "red_bull_ring", "detail shows the pending track")
	# Every card is reachable: walking "down" from the first card ends on BACK.
	var c: Control = screen.cards[0]
	var steps := 0
	while c != screen.back_button and steps < 100:
		c = c.get_node(c.focus_neighbor_bottom) as Control
		steps += 1
	assert_true(c == screen.back_button, "the grid leads down to BACK")
	await _reset(menu)

func test_locked_track_cannot_be_selected() -> void:
	var menu := await _open("tracks")
	var screen := menu.current as TrackSelectScreen
	var monza := screen.card_for("monza")
	assert_true(monza != null and not monza.info.available, "Monza card is locked")
	monza.grab_focus()
	assert_true(screen.focused_info.id == "monza", "locked tracks can be browsed")
	monza.pressed.emit()
	assert_true(not screen.select(monza.info), "select() refuses a locked track")
	assert_true(menu.current_name == "tracks", "still on the track list")
	assert_true(Game.pending.track_id == "red_bull_ring", "pending track unchanged (%s)" % Game.pending.track_id)
	await _reset(menu)

func test_select_playable_track_opens_race_options() -> void:
	var menu := await _open("tracks")
	var screen := menu.current as TrackSelectScreen
	Game.pending.track_id = "monza"
	screen.card_for("red_bull_ring").pressed.emit()
	assert_true(menu.current_name == "race_options", "accepting a playable track opens the race options (%s)" % menu.current_name)
	assert_true(Game.pending.track_id == "red_bull_ring", "pending.track_id set")
	assert_true(menu.current is RaceOptionsScreen, "race options screen shown")
	menu.back()
	assert_true(menu.current_name == "tracks", "back returns to the track list")
	await _reset(menu)

func test_option_rows_edit_pending() -> void:
	var menu := await _open("race_options")
	var screen := menu.current as RaceOptionsScreen
	var rows := screen.rows
	for key: StringName in [&"mode", &"laps", &"bots", &"difficulty", &"ghost", &"countdown", &"camera"]:
		assert_true(rows.has(key), "row %s exists" % key)
	var p := Game.pending
	# Defaults: time attack without opponents -> laps and difficulty do not apply.
	assert_true(rows[&"laps"].disabled and rows[&"laps"].focus_mode == Control.FOCUS_NONE, "laps disabled in time attack")
	assert_true(rows[&"difficulty"].disabled, "difficulty disabled without opponents")
	assert_true(not rows[&"laps"].step(1) and p.laps == 3, "a disabled row does not change")
	assert_true(rows[&"mode"].get_node(rows[&"mode"].focus_neighbor_bottom) == rows[&"bots"], "focus skips the disabled laps row")
	# Mode.
	rows[&"mode"].step(1)
	assert_true(p.mode == RaceConfig.MODE_RACE and not rows[&"laps"].disabled, "race mode enables laps")
	assert_true(rows[&"mode"].get_node(rows[&"mode"].focus_neighbor_bottom) == rows[&"laps"], "laps joins the focus chain")
	# Laps clamp to 1..20.
	for i in 6:
		rows[&"laps"].step(-1)
	assert_true(p.laps == 1, "laps clamp at 1 (%d)" % p.laps)
	for i in 40:
		rows[&"laps"].step(1)
	assert_true(p.laps == 20, "laps clamp at 20 (%d)" % p.laps)
	# Opponents clamp to 0..7 and gate the difficulty row.
	rows[&"bots"].step(-1)
	assert_true(p.bots == 0, "opponents clamp at 0")
	for i in 12:
		rows[&"bots"].step(1)
	assert_true(p.bots == 7 and not rows[&"difficulty"].disabled, "opponents clamp at 7 and enable difficulty (%d)" % p.bots)
	for i in 5:
		rows[&"difficulty"].step(1)
	assert_true(p.bot_difficulty == 2, "difficulty clamps at hard")
	for i in 5:
		rows[&"difficulty"].step(-1)
	assert_true(p.bot_difficulty == 0, "difficulty clamps at easy")
	for i in 7:
		rows[&"bots"].step(-1)
	assert_true(p.bots == 0 and rows[&"difficulty"].disabled, "no opponents disables difficulty again")
	# Toggles.
	rows[&"ghost"].step(1)
	assert_true(not p.ghost, "ghost off")
	rows[&"ghost"].step(1)
	assert_true(p.ghost, "ghost on again (wraps)")
	rows[&"countdown"].step(-1)
	assert_true(not p.countdown, "countdown off")
	# Camera cycles 1 -> 2 -> 3 -> 1.
	rows[&"camera"].step(1)
	assert_true(p.camera == 2, "camera 2")
	rows[&"camera"].step(1)
	rows[&"camera"].step(1)
	assert_true(p.camera == 1, "camera wraps to 1 (%d)" % p.camera)
	rows[&"camera"].step(-1)
	assert_true(p.camera == 3, "camera wraps back to 3")
	# Real input: ui_left / ui_accept on the focused row.
	rows[&"laps"].grab_focus()
	await _press(&"ui_left")
	assert_true(p.laps == 19, "ui_left lowers the focused row (%d)" % p.laps)
	assert_true(get_viewport().gui_get_focus_owner() == rows[&"laps"], "left/right keep the focus on the row")
	await _press(&"ui_right")
	await _press(&"ui_accept")
	assert_true(p.laps == 1, "ui_right raises, ui_accept cycles past the end (%d)" % p.laps)
	await _press(&"ui_down")
	assert_true(get_viewport().gui_get_focus_owner() == rows[&"bots"], "ui_down moves to the next row")
	# Back to time attack.
	rows[&"mode"].step(1)
	assert_true(p.mode == RaceConfig.MODE_TIME_ATTACK and rows[&"laps"].disabled, "time attack disables laps again")
	await _reset(menu)

func _press(action: StringName) -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await get_tree().process_frame
		await get_tree().process_frame

func test_out_of_range_laps_are_clamped_on_enter() -> void:
	var menu := await _open("tracks")
	Game.pending.laps = 50
	Game.pending.mode = RaceConfig.MODE_RACE
	Game.pending.bots = 3
	Game.pending.bot_difficulty = 2
	Game.pending.camera = 3
	Game.pending.ghost = false
	menu.go("race_options")
	var rows := (menu.current as RaceOptionsScreen).rows
	assert_true(Game.pending.laps == 20 and rows[&"laps"].value_text() == "20", "laps brought into 1..20")
	assert_true(rows[&"mode"].value_text() == "RACE" and rows[&"bots"].value_text() == "3", "rows show the pending config")
	assert_true(rows[&"difficulty"].value_text() == "HARD" and rows[&"camera"].value_text() == "COCKPIT" and rows[&"ghost"].value_text() == "OFF", "rows show the pending config (2)")
	await _reset(menu)

func test_start_race_hands_over_config() -> void:
	var menu := await _open("race_options")
	var screen := menu.current as RaceOptionsScreen
	screen.rows[&"mode"].step(1)
	screen.rows[&"laps"].step(1)          # 3 -> 4
	screen.rows[&"bots"].step(1)
	screen.rows[&"bots"].step(1)          # 2 opponents
	screen.rows[&"difficulty"].step(1)    # hard
	screen.rows[&"ghost"].step(1)         # off
	screen.rows[&"camera"].step(1)        # high chase
	assert_true(not screen.start_button.disabled, "START enabled for a playable track")
	screen.start_button.pressed.emit()
	assert_true(_changes == [Game.RACE_SCENE], "START loads the race scene: %s" % str(_changes))
	var c := Game.config
	assert_true(c.track_id == "red_bull_ring" and c.mode == RaceConfig.MODE_RACE and c.laps == 4, "track / mode / laps handed over")
	assert_true(c.bots == 2 and c.bot_difficulty == 2 and not c.ghost and c.countdown and c.camera == 2, "bots / difficulty / ghost / countdown / camera handed over")
	await _reset(menu)

func test_start_is_blocked_for_a_locked_track() -> void:
	var menu := await _open("tracks")
	Game.pending.track_id = "monza"
	menu.go("race_options")
	var screen := menu.current as RaceOptionsScreen
	assert_true(screen.start_button.disabled, "START disabled for a coming-soon track")
	screen._on_start()
	assert_true(_changes.is_empty(), "no scene change")
	await _reset(menu)

func test_track_map_polyline() -> void:
	var rbr := TrackCatalog.find("red_bull_ring")
	var map := TrackMap.new()
	map.size = Vector2(400, 300)
	add_child(map)
	map.set_track(rbr)
	assert_true(map.has_geometry(), "RBR has geometry")
	var poly := map.polyline()
	assert_true(poly.size() > 100, "polyline has points (%d)" % poly.size())
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in poly:
		lo = lo.min(p)
		hi = hi.max(p)
	assert_true(Rect2(Vector2.ZERO, map.size).has_point(lo) and Rect2(Vector2.ZERO, map.size).has_point(hi), "polyline inside the rect: %s .. %s" % [lo, hi])
	# Aspect ratio preserved and north up: compare with the raw data extents.
	var data := TrackMap.load_data(rbr)
	var dlo := Vector2(INF, INF)
	var dhi := Vector2(-INF, -INF)
	var north := 0
	for i in data.points.size():
		var q := Vector2(data.points[i].x, data.points[i].z)
		dlo = dlo.min(q)
		dhi = dhi.max(q)
		if data.points[i].z < data.points[north].z:
			north = i
	var want := (dhi.x - dlo.x) / (dhi.y - dlo.y)
	assert_between((hi.x - lo.x) / (hi.y - lo.y), want * 0.97, want * 1.03, "map aspect ratio")
	assert_between(map.map_position(north * data.step).y, lo.y - 1.0, lo.y + 3.0, "northernmost point is at the top")
	assert_between(maxf(hi.x - lo.x, hi.y - lo.y), 150.0, 400.0, "lap fills the rect")
	assert_between(TrackMap.elevation_change(data), 55.0, 80.0, "RBR elevation change")
	# Refits when resized.
	map.size = Vector2(200, 200)
	for p in map.polyline():
		if not Rect2(Vector2.ZERO, map.size).has_point(p):
			assert_true(false, "polyline outside the resized rect: %s" % p)
			break
	# A coming-soon track has no geometry: placeholder, empty polyline.
	map.set_track(TrackCatalog.find("monza"))
	assert_true(not map.has_geometry() and map.polyline().is_empty(), "locked track shows the placeholder")
	map.set_track(null)
	assert_true(map.polyline().is_empty(), "null track is fine")
	await get_tree().process_frame

func test_best_lap_and_units() -> void:
	var info := TrackInfo.new()
	info.id = "m2_test_track"
	assert_true(TrackSelectScreen.read_best(info).is_empty(), "no file -> no best")
	var f := FileAccess.open(info.best_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify({"best_lap": 67.891, "best_splits": [20.0, 45.0, 67.891], "best_sectors": [19.5, 24.25, 22.0]}))
	f.close()
	var best := TrackSelectScreen.read_best(info)
	assert_true(not best.is_empty(), "best file read")
	if not best.is_empty():
		assert_between(best["lap"], 67.89, 67.892, "best lap")
		assert_true((best["sectors"] as Array).size() == 3, "sector bests read")
	f = FileAccess.open(info.best_path(), FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	assert_true(TrackSelectScreen.read_best(info).is_empty(), "broken file -> no best")
	DirAccess.remove_absolute(info.best_path())
	assert_true(TrackSelectScreen.format_lap(67.891) == "1:07.891", "lap format")
	Settings.set_value("gameplay", "speed_unit", "kmh")
	assert_true(TrackSelectScreen.format_length(4318.0) == "4.318 KM", "length in km")
	Settings.set_value("gameplay", "speed_unit", "mph")
	assert_true(TrackSelectScreen.format_length(4318.0) == "2.683 MI", "length in miles: %s" % TrackSelectScreen.format_length(4318.0))
	await _reset()
