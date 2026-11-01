class_name TrackInfo
extends RefCounted
## One entry of the TrackCatalog: a playable track or a "coming soon" circuit.

var id: String = ""
var series: String = "f1"       ## SeriesCatalog id: which list of the menu shows it
## Catalog id of the built track this event is raced on ("track" in a calendar entry): an
## endurance event on an F1 circuit. Empty = the entry is its own circuit.
var circuit: String = ""
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

## What lists call it: the circuit for F1, the event elsewhere ("6 Hours of Imola"), so an
## endurance race on an F1 circuit is not mistaken for the Grand Prix.
func display_name() -> String:
	if series != "f1" and not grand_prix.is_empty():
		return grand_prix
	return name

## Catalog id of the circuit (folder) the event is raced on.
func circuit_id() -> String:
	return circuit if not circuit.is_empty() else id

func best_path() -> String:
	return "user://best_%s.json" % id
