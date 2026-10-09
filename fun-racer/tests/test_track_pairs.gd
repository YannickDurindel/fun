extends TestCase
## TrackGeometry.proximity_limits() and stretch pairs, on a synthetic lap: two long straights
## side by side, joined by a hairpin at either end (tests/test_track_baku.gd covers a real
## [[road.pair]]).
##
##   tests/run_tests.sh --filter=track_pairs

const STEP := 2.0
const STRAIGHT := 400.0
const APART := 16.0      ## between the two centrelines

## Out along z = 0 (x from 0 to STRAIGHT), a hairpin to the right, back along z = APART and
## another hairpin. `w_out` / `w_back` are the widths of the two straights.
func _lap(w_out: float, w_back: float) -> TrackData:
	var d := TrackData.new()
	d.step = STEP
	var pts: Array[Vector3] = []
	var widths: Array[float] = []
	var n_str := int(STRAIGHT / STEP)
	var r := APART * 0.5
	var n_end := int(PI * r / STEP)
	for i in n_str:
		pts.append(Vector3(i * STEP, 0.0, 0.0))
		widths.append(w_out)
	for i in n_end:
		var a := -PI * 0.5 + PI * float(i) / n_end
		pts.append(Vector3(STRAIGHT + cos(a) * r, 0.0, r + sin(a) * r))
		widths.append(w_out)
	for i in n_str:
		pts.append(Vector3(STRAIGHT - i * STEP, 0.0, APART))
		widths.append(w_back)
	for i in n_end:
		var a := PI * 0.5 + PI * float(i) / n_end
		pts.append(Vector3(cos(a) * r, 0.0, r + sin(a) * r))
		widths.append(w_back)
	d.points = PackedVector3Array(pts)
	d.widths = PackedFloat32Array(widths)
	d.length = pts.size() * STEP
	return d

func _mid_out() -> int:
	return int(STRAIGHT * 0.5 / STEP)

func _mid_back(d: TrackData) -> int:
	# The point of the return straight abeam of the middle of the outward one.
	var best := 0
	var target := Vector3(STRAIGHT * 0.5, 0.0, APART)
	for i in d.points.size():
		if d.points[i].distance_to(target) < d.points[best].distance_to(target):
			best = i
	return best

func test_equal_roads_share_the_space_between_them() -> void:
	var d := _lap(12.0, 12.0)
	var lims := TrackGeometry.no_limits(d.points.size())
	TrackGeometry.proximity_limits(d, lims[0], lims[1])
	# The lap turns right at the end of the outward straight (towards +z): the other straight
	# is on the right of both. Half of the 16 m, less the half metre each side keeps clear.
	assert_between(lims[1][_mid_out()], 7.4, 7.6, "limit beside the other straight (m from the centre)")
	assert_between(lims[1][_mid_back(d)], 7.4, 7.6, "limit of the other straight")
	assert_true(lims[0][_mid_out()] > 1000.0, "nothing on the far side")

func test_unequal_roads_meet_half_way_between_their_edges() -> void:
	# 14 m beside 8 m, 16 m apart: 5 m between the edges, so each limit is 2 m beyond its own
	# edge. Half way between the centrelines would be 1 m from the wide road's edge and 4 m
	# from the narrow one's.
	var d := _lap(14.0, 8.0)
	var lims := TrackGeometry.no_limits(d.points.size())
	TrackGeometry.proximity_limits(d, lims[0], lims[1])
	assert_between(lims[1][_mid_out()] - 7.0, 1.9, 2.1, "room beyond the wide road's edge (m)")
	assert_between(lims[1][_mid_back(d)] - 4.0, 1.9, 2.1, "room beyond the narrow road's edge (m)")

func test_the_stretches_of_a_pair_do_not_limit_each_other() -> void:
	var d := _lap(12.0, 12.0)
	var n := d.points.size()
	var a := [_mid_out() - 20, _mid_out() + 20]
	var b := [_mid_back(d) - 20, _mid_back(d) + 20]
	var lims := TrackGeometry.no_limits(n)
	TrackGeometry.proximity_limits(d, lims[0], lims[1], [a + b])
	assert_true(lims[1][_mid_out()] > 1000.0, "inside the pair: no limit from the other stretch")
	assert_true(lims[1][_mid_back(d)] > 1000.0, "inside the pair: no limit from the other stretch")
	assert_between(lims[1][_mid_out() - 40], 7.4, 7.6, "outside the pair: limited as before")
	# A point may be in two pairs at once (a carriageway that also passes a bridge): both count.
	var far := [n - 12, n - 4, n - 30, n - 20]
	var both := TrackGeometry.no_limits(n)
	TrackGeometry.proximity_limits(d, both[0], both[1], [far, a + b, [a[0], a[1], n - 30, n - 20]])
	assert_true(both[1][_mid_out()] > 1000.0, "a point in two pairs keeps both")
	assert_true(both[1][_mid_back(d)] > 1000.0, "a point in two pairs keeps both")
