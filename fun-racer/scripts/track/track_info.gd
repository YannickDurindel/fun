class_name TrackInfo
extends RefCounted
## One entry of the TrackCatalog: a playable track or a "coming soon" circuit.

var id: String = ""
var name: String = ""           ## "Red Bull Ring"
var grand_prix: String = ""     ## "Austrian Grand Prix"
var country: String = ""
var country_code: String = ""   ## ISO 3166-1 alpha-2, e.g. "AT"
var city: String = ""
var length_m: float = 0.0
var turns: int = 0
var scene: String = ""          ## track scene (root: Track) when available
var track_json: String = ""     ## centreline data when available
var available: bool = false
var order: int = 999            ## calendar order, for sorting
var folder: String = ""         ## asset folder when it is not assets/tracks/<id>

func dir() -> String:
	if not folder.is_empty():
		return folder
	return "%s/%s" % [TrackCatalog.TRACKS_DIR, id]

func best_path() -> String:
	return "user://best_%s.json" % id
