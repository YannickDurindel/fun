class_name SeriesCatalog
extends RefCounted
## The motorsport series shown when the player presses PLAY. Their tracks all live in
## TrackCatalog (TrackInfo.series); a series without any (not even "coming soon" calendar
## entries) cannot be opened yet. SeriesCatalog.all() / find(id) / tracks(id).

const F1 := "f1"

## In menu order. A series' calendar file is in TrackCatalog.CALENDARS.
const SERIES: Array[Dictionary] = [
	{"id": F1, "name": "Formula 1", "tagline": "Open-wheel Grand Prix racing", "code": "F1"},
	{"id": "endurance", "name": "Endurance", "tagline": "Le Mans, Nürburgring, Daytona and more", "code": "WEC"},
	{"id": "formula_e", "name": "Formula E", "tagline": "Electric street circuits", "code": "FE"},
	{"id": "indycar", "name": "IndyCar", "tagline": "Ovals, roads and the Indy 500", "code": "INDY"},
	{"id": "nascar", "name": "NASCAR", "tagline": "Stock cars on banked ovals", "code": "NAS"},
	{"id": "rally", "name": "Rally", "tagline": "Stages on gravel, tarmac and snow", "code": "WRC"},
	{"id": "gt", "name": "GT Racing", "tagline": "GT3 sprint racing", "code": "GT"},
	{"id": "touring", "name": "Touring Cars", "tagline": "Door-to-door saloon racing", "code": "TCR"},
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
