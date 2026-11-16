class_name SeriesCatalog
extends RefCounted
## The motorsport series shown when the player presses PLAY. Their tracks all live in
## TrackCatalog (TrackInfo.series); a series without any (not even "coming soon" calendar
## entries) cannot be opened yet. SeriesCatalog.all() / find(id) / tracks(id).

const F1 := "f1"

## In menu order: the playable series first, then single-seaters, GT and touring cars, stock
## cars, rally and the other disciplines. A series' calendar file is in TrackCatalog.CALENDARS.
## New names and taglines are neutral (no series' trademarks).
const SERIES: Array[Dictionary] = [
	{"id": F1, "name": "Formula 1", "tagline": "Open-wheel Grand Prix racing", "code": "F1"},
	{"id": "endurance", "name": "Endurance", "tagline": "Le Mans, Nürburgring, Daytona and more", "code": "WEC"},
	{"id": "junior", "name": "Junior Formula", "tagline": "Feeder single-seaters on the Grand Prix bill", "code": "JNR"},
	{"id": "formula_e", "name": "Formula E", "tagline": "Electric street circuits", "code": "FE"},
	{"id": "indycar", "name": "IndyCar", "tagline": "Ovals, roads and the Indy 500", "code": "INDY"},
	{"id": "super_formula", "name": "Japanese Formula", "tagline": "Japan's fastest single-seaters", "code": "JPF"},
	{"id": "moto", "name": "Motorcycle Grand Prix", "tagline": "Prototype bikes, knee down", "code": "MGP"},
	{"id": "gt", "name": "GT Racing", "tagline": "GT3 sprint racing", "code": "GT"},
	{"id": "super_gt", "name": "Japanese GT", "tagline": "Two classes of GT cars, one grid", "code": "JGT"},
	{"id": "touring", "name": "Touring Cars", "tagline": "Door-to-door saloon racing", "code": "TCR"},
	{"id": "german_touring", "name": "German Touring Cars", "tagline": "GT cars on German and European circuits", "code": "GTC"},
	{"id": "aus_touring", "name": "Australian Touring Cars", "tagline": "V8 saloons, Bathurst and the streets", "code": "ATC"},
	{"id": "nascar", "name": "NASCAR", "tagline": "Stock cars on banked ovals", "code": "NAS"},
	{"id": "rally", "name": "Rally", "tagline": "Stages on gravel, tarmac and snow", "code": "WRC"},
	{"id": "rallycross", "name": "Rallycross", "tagline": "Short heats on tarmac and dirt", "code": "RX"},
	{"id": "rally_raid", "name": "Rally-Raid", "tagline": "Days of desert and dunes", "code": "RAID"},
	{"id": "hill_climb", "name": "Hill Climb", "tagline": "Against the clock, up the mountain", "code": "HC"},
	{"id": "drift", "name": "Drifting", "tagline": "Judged on angle, line and smoke", "code": "DRF"},
	{"id": "karting", "name": "Karting", "tagline": "Where every driver starts", "code": "KRT"},
]

static func all() -> Array[Dictionary]:
	return SERIES

static func find(id: String) -> Dictionary:
	for s in SERIES:
		if s["id"] == id:
			return s
	return {}

## Tracks of a series (built and coming soon), in TrackCatalog order.
static func tracks(id: String) -> Array[TrackInfo]:
	var out: Array[TrackInfo] = []
	for t in TrackCatalog.all():
		if t.series == id:
			out.append(t)
	return out

## True when the series has events to browse (its track list can be opened).
static func has_events(id: String) -> bool:
	return not tracks(id).is_empty()

## True when at least one of its tracks can be raced.
static func is_playable(id: String) -> bool:
	for t in tracks(id):
		if t.available:
			return true
	return false
