extends "res://scripts/race/race_setup.gd"
## TEST FIXTURE: the race scene on a track of tests/fixtures/tracks/ (default: test_oval).
## Registers the fixture folder with the TrackCatalog before the race is built, so a fixture
## track loads exactly like a real one (generic track scene, every runtime fallback).

const FIXTURE_TRACKS := "res://tests/fixtures/tracks"

func _enter_tree() -> void:
	if not FIXTURE_TRACKS in TrackCatalog.extra_dirs():
		TrackCatalog.set_extra_dirs(TrackCatalog.extra_dirs() + PackedStringArray([FIXTURE_TRACKS]))
	if track_id.is_empty():
		track_id = "test_oval"
	super()
