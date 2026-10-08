extends UIScreen
## RECORDS screen: every playable track with its best lap, sector bests, theoretical best (sum
## of the sector bests), the date it was set and whether a ghost is saved.
##   Left:  the track list (up / down). Right: the focused track's times and its actions:
##   RACE THIS TRACK (-> race options) and DELETE RECORD (asks first; removes the best-times
##   file written by RaceManager and the ghost).
## Times come from user://best_<id>.json (see RaceManager._save_best), ghosts from GhostData.
## Dev flag: --records-dir=DIR reads best_<id>.json from DIR and ghosts from DIR/ghosts
## (screenshots and tests never touch the player's files).

const RaceTimer := preload("res://scripts/ui/race_timer.gd")
const NO_TIME := "-:--.---"
const MONTHS: Array[String] = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
const COL_PURPLE := Color(0.78, 0.45, 1.0)

## Folder holding the best_<id>.json files; empty = each TrackInfo's own path (user://).
var best_dir: String = ""

var _tracks: Array[TrackInfo] = []
var _records: Dictionary = {}          ## track id -> record Dictionary (see read_record)
var _selected: String = ""
var _row_buttons: Dictionary = {}      ## track id -> Button
var _row_times: Dictionary = {}        ## track id -> Label
var _built: bool = false

var _name_label: Label
var _info_label: Label
var _times_box: Control
var _empty_box: Control
var _best_label: Label
var _sector_row: HBoxContainer
var _theory_label: Label
var _date_label: Label
var _date_caption: Label
var _ghost_label: Label
var _race_button: Button
var _delete_button: Button
var _back_button: Button
var _confirm: Control
var _confirm_text: Label
var _confirm_cancel: Button
var _confirm_ok: Button

func on_enter() -> void:
	if best_dir.is_empty():
		for arg: String in OS.get_cmdline_user_args():
			if arg.begins_with("--records-dir="):
				best_dir = arg.get_slice("=", 1)
				GhostData.dir_override = best_dir.path_join("ghosts")
	_tracks = TrackCatalog.playable()
	if not _built:
		_build()
		_built = true
	refresh()
	var start := Game.pending.track_id if _row_buttons.has(Game.pending.track_id) else ""
	if start.is_empty() and not _tracks.is_empty():
		start = _tracks[0].id
	select(start)
	if _row_buttons.has(start):
		initial_focus = get_path_to(_row_buttons[start])
	else:
		initial_focus = get_path_to(_back_button)

func on_back() -> void:
	if is_confirming():
		cancel_delete()
	else:
		super.on_back()

# ---------------------------------------------------------------- data

func best_path(info: TrackInfo) -> String:
	return info.best_path() if best_dir.is_empty() else best_dir.path_join("best_%s.json" % info.id)

## What is known about a track: {best_lap (s, -1 = none), sectors (Array[float], -1 =
## none), theoretical (s, -1 = incomplete), date (unix, 0 = unknown), date_exact (the best
## lap's own date, not just the file's), has_ghost (a usable ghost), has_file (anything to
## delete)}.
func read_record(info: TrackInfo) -> Dictionary:
	var ghost := GhostData.load_header(info.id)
	var rec := {"best_lap": -1.0, "sectors": [] as Array[float], "theoretical": -1.0, "date": 0,
			"date_exact": false, "has_ghost": ghost != null, "has_file": GhostData.exists(info.id)}
	var path := best_path(info)
	if FileAccess.file_exists(path):
		rec["has_file"] = true
		rec["date"] = FileAccess.get_modified_time(path)
		var f := FileAccess.open(path, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
		if parsed is Dictionary:
			var d: Dictionary = parsed
			var best: Variant = d.get("best_lap", -1.0)
			if (best is float or best is int) and is_finite(best) and best > 0.0:
				rec["best_lap"] = float(best)
			var raw: Variant = d.get("best_sectors", [])
			var sectors: Array[float] = []
			if raw is Array:
				for v: Variant in raw:
					sectors.append(float(v) if (v is float or v is int) and is_finite(v) and v > 0.0 else -1.0)
			rec["sectors"] = sectors
			var sum := 0.0
			for st in sectors:
				sum = sum + st if st > 0.0 and sum >= 0.0 else -1.0
			rec["theoretical"] = sum if not sectors.is_empty() else -1.0
	# The ghost is saved with the best lap, so its date is that lap's date. Without it only the
	# file's date is known (the file is also rewritten when a sector best falls).
	if ghost != null and ghost.date > 0 and absf(ghost.lap_time - float(rec["best_lap"])) < 0.002:
		rec["date"] = ghost.date
		rec["date_exact"] = true
	return rec

static func has_times(rec: Dictionary) -> bool:
	if float(rec.get("best_lap", -1.0)) > 0.0:
		return true
	for st: float in rec.get("sectors", []):
		if st > 0.0:
			return true
	return false

static func can_delete(rec: Dictionary) -> bool:
	return bool(rec.get("has_file", false))

## M:SS.mmm, truncated to the millisecond like the race clock.
static func format_time(seconds: float) -> String:
	if seconds <= 0.0 or not is_finite(seconds):
		return NO_TIME
	return RaceTimer.format_time(seconds)

static func format_date(unix: int) -> String:
	if unix <= 0:
		return "-"
	var bias: int = int(Time.get_time_zone_from_system().get("bias", 0))
	var d := Time.get_datetime_dict_from_unix_time(unix + bias * 60)
	return "%d %s %d" % [d["day"], MONTHS[clampi(int(d["month"]) - 1, 0, 11)], d["year"]]

# ---------------------------------------------------------------- actions

func refresh() -> void:
	_records.clear()
	for info in _tracks:
		var rec := read_record(info)
		_records[info.id] = rec
		var label := _row_times.get(info.id) as Label
		if label != null:
			label.text = format_time(rec["best_lap"])
			label.modulate = COL_TEXT if rec["best_lap"] > 0.0 else COL_TEXT_DIM
	_show_details()

func select(id: String) -> void:
	if not _row_buttons.has(id):
		id = ""
	_selected = id
	for key: String in _row_buttons:
		(_row_buttons[key] as Button).set_pressed_no_signal(key == id)
	_show_details()

func race_selected() -> void:
	if _selected.is_empty():
		return
	Game.pending.track_id = _selected
	if router != null:
		router.go("race_options")

## Opens the confirmation; nothing is deleted until confirm_delete().
func request_delete() -> void:
	var info := TrackCatalog.find(_selected)
	if info == null or not can_delete(_records.get(_selected, {})):
		return
	_confirm_text.text = "%s: the best lap, the sector bests and the ghost will be erased." % info.name.to_upper()
	_confirm.visible = true
	_confirm_cancel.grab_focus()

func is_confirming() -> bool:
	return _confirm != null and _confirm.visible

func cancel_delete() -> void:
	_confirm.visible = false
	_focus_actions()

func confirm_delete() -> void:
	var info := TrackCatalog.find(_selected)
	_confirm.visible = false
	if info != null:
		var path := best_path(info)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		GhostData.delete(info.id)
	refresh()
	_focus_actions()

func _focus_actions() -> void:
	if not is_inside_tree():
		return
	if not _delete_button.disabled:
		_delete_button.grab_focus()
	elif not _race_button.disabled:
		_race_button.grab_focus()
	else:
		_back_button.grab_focus()

# ---------------------------------------------------------------- test / tooling access

func get_track_ids() -> Array[String]:
	var out: Array[String] = []
	for info in _tracks:
		out.append(info.id)
	return out

func get_row_text(id: String) -> String:
	if not _row_buttons.has(id):
		return ""
	return "%s %s" % [(_row_buttons[id] as Button).text, (_row_times[id] as Label).text]

func get_selected() -> String:
	return _selected

func get_best_text() -> String:
	return _best_label.text

func is_empty_state_shown() -> bool:
	return _empty_box.visible

# ---------------------------------------------------------------- details panel

func _show_details() -> void:
	if not _built:
		return
	var info := TrackCatalog.find(_selected)
	var rec: Dictionary = _records.get(_selected, {})
	_race_button.disabled = info == null
	_delete_button.disabled = info == null or not can_delete(rec)
	# A disabled DELETE is skipped by left / right.
	_delete_button.focus_mode = Control.FOCUS_NONE if _delete_button.disabled else Control.FOCUS_ALL
	var middle := _back_button if _delete_button.disabled else _delete_button
	_race_button.focus_neighbor_right = _race_button.get_path_to(middle)
	_back_button.focus_neighbor_left = _back_button.get_path_to(_race_button if _delete_button.disabled else _delete_button)
	if info == null:
		_name_label.text = "NO TRACKS"
		_info_label.text = ""
		_times_box.visible = false
		_empty_box.visible = true
		return
	_name_label.text = info.name.to_upper()
	var bits: Array[String] = []
	if not info.country.is_empty():
		bits.append(info.country.to_upper())
	if info.length_m > 0.0:
		bits.append("%.3f KM" % (info.length_m / 1000.0))
	if info.turns > 0:
		bits.append("%d TURNS" % info.turns)
	_info_label.text = "   /   ".join(bits)
	var any := has_times(rec)
	_times_box.visible = any
	_empty_box.visible = not any
	if not any:
		return
	_best_label.text = format_time(rec["best_lap"])
	for c in _sector_row.get_children():
		_sector_row.remove_child(c)
		c.queue_free()
	var sectors: Array[float] = rec["sectors"]
	for i in sectors.size():
		_sector_row.add_child(_stat("S%d" % (i + 1), format_time(sectors[i]), COL_PURPLE if sectors[i] > 0.0 else COL_TEXT_DIM))
	_theory_label.text = format_time(rec["theoretical"])
	_date_caption.text = "DATE SET" if rec["date_exact"] else "LAST UPDATED"
	_date_label.text = format_date(rec["date"])
	_ghost_label.text = "SAVED" if rec["has_ghost"] else "NONE"
	_ghost_label.modulate = COL_ACCENT.lightened(0.35) if rec["has_ghost"] else COL_TEXT_DIM

# ---------------------------------------------------------------- construction

func _build() -> void:
	var title := _label("RECORDS", &"TitleLabel")
	title.position = Vector2(140, 96)
	add_child(title)
	var sub := _label("BEST LAPS, SECTORS AND GHOSTS", &"DimLabel")
	sub.position = Vector2(144, 186)
	add_child(sub)

	# Track list.
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(140, 260)
	scroll.size = Vector2(640, 660)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override(&"separation", 10)
	scroll.add_child(list)
	for info in _tracks:
		var b := Button.new()
		b.text = info.name.to_upper()
		b.custom_minimum_size = Vector2(600, 72)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		b.focus_entered.connect(select.bind(info.id))
		b.pressed.connect(_on_row_pressed.bind(info.id))
		list.add_child(b)
		var t := _label(NO_TIME, &"HeaderLabel")
		t.add_theme_font_size_override(&"font_size", 32)
		t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		t.offset_right = -28
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(t)
		_row_buttons[info.id] = b
		_row_times[info.id] = t

	# Details panel.
	var panel := PanelContainer.new()
	panel.position = Vector2(840, 260)
	panel.size = Vector2(940, 660)
	add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22 if side in ["top", "bottom"] else 18)
	panel.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 4)
	margin.add_child(col)
	_name_label = _label("", &"HeaderLabel")
	_name_label.add_theme_font_size_override(&"font_size", 52)
	col.add_child(_name_label)
	_info_label = _label("", &"DimLabel")
	col.add_child(_info_label)
	col.add_child(_spacer(18))

	_times_box = VBoxContainer.new()
	_times_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	(_times_box as VBoxContainer).add_theme_constant_override(&"separation", 0)
	col.add_child(_times_box)
	_times_box.add_child(_label("BEST LAP", &"DimLabel"))
	_best_label = _label(NO_TIME, &"TitleLabel")
	_best_label.add_theme_font_size_override(&"font_size", 124)
	_best_label.add_theme_constant_override(&"line_spacing", -12)
	_times_box.add_child(_best_label)
	_times_box.add_child(_spacer(10))
	_sector_row = HBoxContainer.new()
	_sector_row.add_theme_constant_override(&"separation", 56)
	_times_box.add_child(_sector_row)
	_times_box.add_child(_spacer(22))
	var facts := HBoxContainer.new()
	facts.add_theme_constant_override(&"separation", 56)
	_times_box.add_child(facts)
	var theory := _stat("THEORETICAL BEST", NO_TIME, COL_TEXT)
	_theory_label = theory.get_child(1) as Label
	facts.add_child(theory)
	var date := _stat("DATE SET", "-", COL_TEXT)
	_date_caption = date.get_child(0) as Label
	_date_label = date.get_child(1) as Label
	facts.add_child(date)
	var ghost := _stat("GHOST", "NONE", COL_TEXT)
	_ghost_label = ghost.get_child(1) as Label
	facts.add_child(ghost)

	_empty_box = VBoxContainer.new()
	_empty_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	(_empty_box as VBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(_empty_box)
	var empty := _label("NO TIMES SET YET", &"TitleLabel")
	empty.modulate = Color(1, 1, 1, 0.5)
	_empty_box.add_child(empty)
	_empty_box.add_child(_label("Complete a lap on this track to set a record.", &"DimLabel"))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override(&"separation", 16)
	col.add_child(actions)
	_race_button = _button("RACE THIS TRACK", race_selected, 340)
	actions.add_child(_race_button)
	_delete_button = _button("DELETE RECORD", request_delete, 300)
	actions.add_child(_delete_button)
	_back_button = _button("BACK", on_back, 180)
	actions.add_child(_back_button)

	var hint := _label("UP / DOWN  TRACK      RIGHT  ACTIONS      ESC  BACK", &"DimLabel")
	hint.position = Vector2(144, 946)
	add_child(hint)

	_build_confirm()
	_wire_focus()

func _build_confirm() -> void:
	_confirm = ColorRect.new()
	(_confirm as ColorRect).color = Color(0.0, 0.01, 0.03, 0.72)
	_confirm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirm.mouse_filter = Control.MOUSE_FILTER_STOP
	_confirm.visible = false
	add_child(_confirm)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirm.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 26)
	panel.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 14)
	margin.add_child(col)
	var q := _label("DELETE THIS RECORD?", &"HeaderLabel")
	q.modulate = COL_HILITE.lightened(0.15)
	col.add_child(q)
	_confirm_text = _label("", &"DimLabel")
	_confirm_text.custom_minimum_size = Vector2(760, 0)
	_confirm_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_confirm_text)
	col.add_child(_spacer(10))
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 16)
	col.add_child(row)
	_confirm_cancel = _button("CANCEL", cancel_delete, 280)
	row.add_child(_confirm_cancel)
	_confirm_ok = _button("DELETE", confirm_delete, 280)
	row.add_child(_confirm_ok)
	# Focus cannot leave the dialog.
	for b: Button in [_confirm_cancel, _confirm_ok]:
		var other := _confirm_ok if b == _confirm_cancel else _confirm_cancel
		for side: StringName in [&"focus_neighbor_top", &"focus_neighbor_bottom"]:
			b.set(side, b.get_path_to(b))
		for side: StringName in [&"focus_neighbor_left", &"focus_neighbor_right", &"focus_next", &"focus_previous"]:
			b.set(side, b.get_path_to(other))

## List on the left, actions on the right: left / right move between them.
func _wire_focus() -> void:
	var actions: Array[Button] = [_race_button, _delete_button, _back_button]
	for i in actions.size():
		var b := actions[i]
		b.focus_neighbor_top = b.get_path_to(b)
		b.focus_neighbor_bottom = b.get_path_to(b)
		b.focus_neighbor_right = b.get_path_to(actions[mini(i + 1, actions.size() - 1)])
		if i > 0:
			b.focus_neighbor_left = b.get_path_to(actions[i - 1])
	for i in _tracks.size():
		var b := _row_buttons[_tracks[i].id] as Button
		b.focus_neighbor_left = b.get_path_to(b)
		b.focus_neighbor_right = b.get_path_to(_race_button)
		b.focus_neighbor_top = b.get_path_to(_row_buttons[_tracks[maxi(i - 1, 0)].id] as Button)
		b.focus_neighbor_bottom = b.get_path_to(_row_buttons[_tracks[mini(i + 1, _tracks.size() - 1)].id] as Button)

func _input(event: InputEvent) -> void:
	# From the first action, "left" returns to the selected track (the neighbour changes with
	# the selection, so it is resolved here).
	if is_confirming() or not event.is_action_pressed(&"ui_left"):
		return
	if get_viewport().gui_get_focus_owner() == _race_button and _row_buttons.has(_selected):
		get_viewport().set_input_as_handled()
		(_row_buttons[_selected] as Button).grab_focus()

func _on_row_pressed(id: String) -> void:
	select(id)
	_race_button.grab_focus()

func _label(text: String, variation: StringName = &"") -> Label:
	var l := Label.new()
	l.text = text
	if not variation.is_empty():
		l.theme_type_variation = variation
	return l

func _spacer(height: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c

## A small caption with a value under it.
func _stat(caption: String, value: String, colour: Color) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", -4)
	box.add_child(_label(caption, &"DimLabel"))
	var v := _label(value, &"HeaderLabel")
	v.modulate = colour
	box.add_child(v)
	return box

func _button(text: String, action: Callable, width: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(width, 64)
	b.pressed.connect(action)
	return b
