extends TestCase
## Survey Circuit de la Sarthe: the generated trackside table (kerbs and run-off from the
## orthophoto, measured barrier stretches from OSM, concrete on the Bugatti part). Layout
## level only (no scene).

const ID := "wec_le_mans_survey"

func _data() -> TrackData:
	return TrackData.load_track("res://assets/tracks/%s/track.json" % ID)

func test_table_is_used() -> void:
	var d := _data()
	assert_true(TracksideLayout.has_table(ID), "survey Le Mans has a trackside table")
	var layout := TracksideLayout.for_track(ID, d)
	assert_true(not layout.is_auto, "the table, not the automatic layout")
	assert_true(layout.kerbs.size() >= 40, "kerbs traced on the photo (%d)" % layout.kerbs.size())
	assert_true(layout.runoff.size() >= 20, "run-off areas (%d)" % layout.runoff.size())
	for k in layout.kerbs:
		assert_true(k["kind"] in ["flat", "saw", "sausage"] and float(k["len"]) > 0.0, "kerb %s" % str(k))
	for r in layout.runoff:
		assert_true(r["kind"] in ["tarmac", "gravel"] and float(r["u1"]) > float(r["u0"]), "run-off %s" % str(r))

func test_barriers_by_section() -> void:
	var d := _data()
	var layout := TracksideLayout.for_track(ID, d)
	assert_true(layout.barrier_zones.size() >= 50, "measured barrier stretches")
	assert_true(layout.barrier_straight < 1.5, "the armco may stand close to the white line")
	# Concrete + fence on the Bugatti part (pits, Dunlop), armco on the public roads.
	assert_true(layout.is_concrete(100.0) and layout.is_concrete(900.0), "Bugatti part is concrete")
	for s: float in [3000.0, 5000.0, 7000.0, 9000.0, 10500.0]:
		assert_true(not layout.is_concrete(s), "public road at %d m is armco" % s)
	# The armco of the Mulsanne stands 1 to 4 m from the edge (no corner push-outs there).
	for z in layout.barrier_zones:
		assert_true(float(z["dist"]) >= 0.0 and float(z["dist"]) <= 60.0, "barrier zone %s" % str(z))
