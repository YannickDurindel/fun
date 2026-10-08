class_name TrackCatalog
extends RefCounted
## The list of tracks the game knows about.
##   * Playable tracks: every res://assets/tracks/<id>/track_info.json with "available": true.
##   * Coming soon: entries of res://assets/tracks/calendar.json that have no built track yet.
## Use TrackCatalog.all() / playable() / find(id). Entries are TrackInfo objects.

const TRACKS_DIR := "res://assets/tracks"
const CALENDAR := "res://assets/tracks/calendar.json"
## Scene of a track whose track_info.json names none: the generic track scene, which builds
## any track folder (race_setup.gd sets its track_id).
const GENERIC_SCENE := "res://scenes/tracks/track.tscn"

## Engine meta holding the extra folders (see set_extra_dirs). Not a static variable:
## TrackCatalog.reload(), called on the class, is also Script.reload(), which re-initialises
## every static variable of this script.
const EXTRA_DIRS_META := &"track_catalog_extra_dirs"

static var _cache: Array[TrackInfo] = []

static func all() -> Array[TrackInfo]:
	if _cache.is_empty():
		_cache = _scan()
	return _cache

static func playable() -> Array[TrackInfo]:
	var out: Array[TrackInfo] = []
	for t in all():
		if t.available:
			out.append(t)
	return out

static func find(id: String) -> TrackInfo:
	for t in all():
		if t.id == id:
			return t
	return null

static func reload() -> void:
	_cache = []

## Also scans `dirs` (folders of track folders, like TRACKS_DIR) from now on and drops the
## cached list. Tests point this at tests/fixtures/tracks; pass [] to undo.
static func set_extra_dirs(dirs: PackedStringArray) -> void:
	Engine.set_meta(EXTRA_DIRS_META, dirs)
	_cache = []

static func extra_dirs() -> PackedStringArray:
	return Engine.get_meta(EXTRA_DIRS_META, PackedStringArray())

static func _scan() -> Array[TrackInfo]:
	var by_id := {}
	var cal: Variant = _read_json(CALENDAR)
	if cal is Dictionary:
		var i := 0
		for e: Dictionary in (cal as Dictionary).get("tracks", []):
			var t := _from_dict(e)
			t.order = i
			t.available = false
			by_id[t.id] = t
			i += 1
	var bases: Array[String] = [TRACKS_DIR]
	bases.append_array(extra_dirs())
	for base in bases:
		for d: String in DirAccess.get_directories_at(base):
			var folder := base.path_join(d)
			var info: Variant = _read_json(folder.path_join("track_info.json"))
			if not (info is Dictionary):
				continue
			var t := _from_dict(info as Dictionary)
			if t.id.is_empty():
				t.id = d
			if base != TRACKS_DIR or t.id != d:
				t.folder = folder
			if by_id.has(t.id):
				t.order = (by_id[t.id] as TrackInfo).order
			if t.track_json.is_empty():
				t.track_json = folder.path_join("track.json")
			if t.scene.is_empty():
				t.scene = GENERIC_SCENE
			# The generic scene exists for every folder: what makes a track playable is its data.
			t.available = bool((info as Dictionary).get("available", true)) and ResourceLoader.exists(t.scene) \
					and FileAccess.file_exists(t.track_json)
			by_id[t.id] = t
	var out: Array[TrackInfo] = []
	for t: TrackInfo in by_id.values():
		out.append(t)
	out.sort_custom(func(a: TrackInfo, b: TrackInfo) -> bool:
		if a.available != b.available:
			return a.available
		return a.order < b.order)
	return out

static func _from_dict(d: Dictionary) -> TrackInfo:
	var t := TrackInfo.new()
	t.id = d.get("id", "")
	t.name = d.get("name", "")
	t.grand_prix = d.get("grand_prix", "")
	t.country = d.get("country", "")
	t.country_code = d.get("country_code", "")
	t.city = d.get("city", "")
	t.length_m = float(d.get("length_m", 0.0))
	t.turns = int(d.get("turns", 0))
	t.scene = d.get("scene", "")
	t.track_json = d.get("track_json", "")
	return t

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else null
