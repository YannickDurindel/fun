extends TestCase
## The detailed track look (TrackLook): the player's TRACK LOOK option picks its style on
## tracks opted in with environment.json "look": "detailed"; other tracks keep their plain look.

const SCREEN := "res://scenes/menu/settings.tscn"
const LE_MANS := "res://assets/tracks/wec_le_mans/environment.json"
const SURVEY := "res://assets/tracks/wec_le_mans_survey/environment.json"
const PLAIN := "res://assets/tracks/baku/environment.json"   # has a file, without "look"

func _restore() -> void:
	Settings.set_value("graphics", "track_look", Settings.default_value("graphics", "track_look"))

func test_settings_row() -> void:
	var screen := spawn(SCREEN) as SettingsScreen
	await get_tree().process_frame
	var r := screen.row("graphics", "track_look")
	assert_true(r != null, "Graphics has a TRACK LOOK row")
	assert_true(str(Settings.default_value("graphics", "track_look")) == TrackLook.REALISTIC,
			"REALISTIC is the default")
	_restore()

func test_style_follows_the_option() -> void:
	for path: String in [LE_MANS, SURVEY]:
		Settings.set_value("graphics", "track_look", TrackLook.GENERATED)
		var gen := TrackEnvironment.load_file(path)
		assert_true(gen.detailed() and gen.look_style() == TrackLook.GENERATED, "%s: generated style" % path)
		assert_true(TrackLook.day_sky(gen).is_empty(), "%s: no photographed sky when generated" % path)
		Settings.set_value("graphics", "track_look", TrackLook.REALISTIC)
		var real := TrackEnvironment.load_file(path)
		assert_true(real.look_style() == TrackLook.REALISTIC, "%s: realistic style" % path)
		assert_true(not TrackLook.day_sky(real).is_empty(), "%s: photographed sky when realistic" % path)
		assert_true(absf(real.number("sun", "azimuth_deg") - gen.number("sun", "azimuth_deg")) > 1.0,
				"%s: the realistic block of environment.json applies only to that style" % path)
	# A track without the flag has no style whatever the option says.
	var plain := TrackEnvironment.load_file(PLAIN)
	assert_true(not plain.detailed() and plain.look_style() == "", "a plain track keeps its look")
	_restore()
