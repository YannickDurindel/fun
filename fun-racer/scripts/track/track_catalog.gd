class_name TrackCatalog
extends RefCounted
## The list of tracks the game knows about.
##   * Playable tracks: every res://assets/tracks/<id>/track_info.json with "available": true.
##   * Coming soon: entries of the calendars (calendar.json for F1, one file per other series)
##     that have no built track yet.
## Every series is in one list: use TrackCatalog.all() / playable() / find(id), or
## SeriesCatalog.tracks(series) for one series. Entries are TrackInfo objects. A built track
## takes its series from its track_info.json, else from its calendar entry, else F1.
## A calendar entry with "track": "<id>" is an event raced on that built circuit (an endurance
## race at an F1 track): it is playable when that track is, and takes its scene, centreline and
## folder, while keeping its own id (best laps per event), name, event and series.

const TRACKS_DIR := "res://assets/tracks"
const CALENDAR := "res://assets/tracks/calendar.json"
## Series id -> calendar file, in SeriesCatalog order (tools/track/lib/recipe.py SERIES_CALENDARS
## lists the same files). Only F1 and endurance have cars: other calendars carry no "track".
const CALENDARS := {
	"f1": CALENDAR,
	"endurance": "res://assets/tracks/calendar_endurance.json",
	"junior": "res://assets/tracks/calendar_junior.json",
	"formula_e": "res://assets/tracks/calendar_formula_e.json",
	"indycar": "res://assets/tracks/calendar_indycar.json",
	"super_formula": "res://assets/tracks/calendar_super_formula.json",
	"moto": "res://assets/tracks/calendar_moto.json",
	"gt": "res://assets/tracks/calendar_gt.json",
	"super_gt": "res://assets/tracks/calendar_super_gt.json",
	"touring": "res://assets/tracks/calendar_touring.json",
	"german_touring": "res://assets/tracks/calendar_german_touring.json",
	"aus_touring": "res://assets/tracks/calendar_aus_touring.json",
	"nascar": "res://assets/tracks/calendar_nascar.json",
	"rally": "res://assets/tracks/calendar_rally.json",
	"rallycross": "res://assets/tracks/calendar_rallycross.json",
	"rally_raid": "res://assets/tracks/calendar_rally_raid.json",
	"hill_climb": "res://assets/tracks/calendar_hill_climb.json",
	"drift": "res://assets/tracks/calendar_drift.json",
	"karting": "res://assets/tracks/calendar_karting.json",
}
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
	for series: String in CALENDARS:
		var cal: Variant = _read_json(CALENDARS[series])
		if not (cal is Dictionary):
			continue
		var i := 0
		for e: Dictionary in (cal as Dictionary).get("tracks", []):
			var t := from_dict(e)
			t.series = series
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
			var t := from_dict(info as Dictionary)
			if t.id.is_empty():
				t.id = d
			if base != TRACKS_DIR or t.id != d:
				t.folder = folder
			if by_id.has(t.id):
				t.order = (by_id[t.id] as TrackInfo).order
				if not (info as Dictionary).has("series"):
					t.series = (by_id[t.id] as TrackInfo).series
			if t.track_json.is_empty():
				t.track_json = folder.path_join("track.json")
			if t.scene.is_empty():
				t.scene = GENERIC_SCENE
			# The generic scene exists for every folder: what makes a track playable is its data.
			t.available = bool((info as Dictionary).get("available", true)) and ResourceLoader.exists(t.scene) \
					and FileAccess.file_exists(t.track_json)
			by_id[t.id] = t
	for t: TrackInfo in by_id.values():
		if not t.circuit.is_empty():
			_resolve_circuit(t, by_id.get(t.circuit) as TrackInfo)
	var out: Array[TrackInfo] = []
	for t: TrackInfo in by_id.values():
		out.append(t)
	out.sort_custom(func(a: TrackInfo, b: TrackInfo) -> bool:
		if a.available != b.available:
			return a.available
		if a.series != b.series:   # F1 first: Game falls back to playable()[0]
			return _series_rank(a.series) < _series_rank(b.series)
		return a.order < b.order)
	return out

## An event on another entry's circuit takes that circuit's files (its map too while the
## circuit is not built); it is playable when the circuit is.
static func _resolve_circuit(event: TrackInfo, circuit: TrackInfo) -> void:
	event.available = false
	if circuit == null or not circuit.circuit.is_empty():
		return   # unknown, or itself an event: no chains
	event.track_json = circuit.track_json
	if not circuit.available:
		return
	event.scene = circuit.scene
	event.folder = circuit.dir()
	event.available = true

static func _series_rank(series: String) -> int:
	var i := CALENDARS.keys().find(series)
	return i if i >= 0 else CALENDARS.size()

static func from_dict(d: Dictionary) -> TrackInfo:
	var t := TrackInfo.new()
	t.id = d.get("id", "")
	t.series = d.get("series", "f1")
	t.name = d.get("name", "")
	t.grand_prix = d.get("grand_prix", "")
	t.country = d.get("country", "")
	t.country_code = d.get("country_code", "")
	t.city = d.get("city", "")
	t.length_m = float(d.get("length_m", 0.0))
	t.turns = int(d.get("turns", 0))
	t.scene = d.get("scene", "")
	t.track_json = d.get("track_json", "")
	t.circuit = d.get("track", "")
	return t

static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else null
