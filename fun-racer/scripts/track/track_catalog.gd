class_name TrackCatalog
extends RefCounted
## The list of tracks the game knows about.
##   * Playable tracks: every res://assets/tracks/<id>/track_info.json with "available": true.
##   * Coming soon: entries of res://assets/tracks/calendar.json that have no built track yet.
## Use TrackCatalog.all() / playable() / find(id). Entries are TrackInfo objects.

const TRACKS_DIR := "res://assets/tracks"
const CALENDAR := "res://assets/tracks/calendar.json"

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
	for d: String in DirAccess.get_directories_at(TRACKS_DIR):
		var info: Variant = _read_json("%s/%s/track_info.json" % [TRACKS_DIR, d])
		if not (info is Dictionary):
			continue
		var t := _from_dict(info as Dictionary)
		if t.id.is_empty():
			t.id = d
		if by_id.has(t.id):
			t.order = (by_id[t.id] as TrackInfo).order
		if t.track_json.is_empty():
			t.track_json = "%s/%s/track.json" % [TRACKS_DIR, t.id]
		t.available = bool((info as Dictionary).get("available", true)) and ResourceLoader.exists(t.scene)
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
