class_name TrackGeometry
extends RefCounted
## Plan-view geometry of a centreline (TrackData) shared by the track slots: curvature, and
## how far a strip beside the road (verge, run-off, barrier line) can reach before it folds
## over itself on the inside of a corner or runs into another leg of the lap.
## Limits are "centre offsets": metres from the centreline, per centreline point.

const NO_LIMIT: float = 1e6
const CURVATURE_SPAN: float = 6.0   ## curvature is measured between s - span and s + span
const INSIDE_FACTOR: float = 0.8    ## a strip on the inside reaches at most this share of the radius
const INSIDE_WINDOW: int = 8        ## ... of the tightest radius within this many points either way
const LEG_CELL: float = 25.0        ## spatial hash cell for the other-leg search (m)
const LEG_MIN_GAP: float = 150.0    ## points closer than this along the lap are the same leg

## Signed curvature (1/m) at every centreline point, + = LEFT-hand turn.
static func curvature(data: TrackData) -> PackedFloat32Array:
	var n := data.points.size()
	var kappa := PackedFloat32Array()
	kappa.resize(n)
	for i in n:
		var s := i * data.step
		kappa[i] = data.tangent_at(s - CURVATURE_SPAN).cross(data.tangent_at(s + CURVATURE_SPAN)).y \
				/ (2.0 * CURVATURE_SPAN)
	return kappa

## Two arrays of `n` limits, all NO_LIMIT: [left, right].
static func no_limits(n: int) -> Array[PackedFloat32Array]:
	var lim := PackedFloat32Array()
	lim.resize(n)
	lim.fill(NO_LIMIT)
	return [lim, lim.duplicate()]

## Caps the limits on the inside of corners at INSIDE_FACTOR x the local radius.
static func inside_limits(data: TrackData, lim_l: PackedFloat32Array, lim_r: PackedFloat32Array) -> void:
	var n := data.points.size()
	var kappa := curvature(data)
	for i in n:
		var worst := 0.0
		for k in range(-INSIDE_WINDOW, INSIDE_WINDOW + 1):
			var kk: float = kappa[(i + k + n) % n]
			if absf(kk) > absf(worst):
				worst = kk
		if worst > 1e-4:
			lim_l[i] = minf(lim_l[i], INSIDE_FACTOR / worst)
		elif worst < -1e-4:
			lim_r[i] = minf(lim_r[i], INSIDE_FACTOR / -worst)

## Caps the limits at half the lateral distance to any other leg of the lap.
static func proximity_limits(data: TrackData, lim_l: PackedFloat32Array, lim_r: PackedFloat32Array) -> void:
	var n := data.points.size()
	var cell := LEG_CELL
	var grid := {}
	for i in n:
		var p := data.points[i]
		var key := Vector2i(floori(p.x / cell), floori(p.z / cell))
		var bucket: PackedInt32Array = grid.get(key, PackedInt32Array())
		bucket.append(i)
		grid[key] = bucket
	var skip := int(LEG_MIN_GAP / data.step)
	for i in n:
		var p := data.points[i]
		var t := data.tangent_at(i * data.step)
		var th := Vector3(t.x, 0.0, t.z).normalized()
		var rh := th.cross(Vector3.UP)
		var c := Vector2i(floori(p.x / cell), floori(p.z / cell))
		for gx in range(c.x - 4, c.x + 5):
			for gz in range(c.y - 4, c.y + 5):
				var key := Vector2i(gx, gz)
				if not grid.has(key):
					continue
				var bucket: PackedInt32Array = grid[key]
				for j in bucket:
					var di := absi(j - i)
					if mini(di, n - di) < skip:
						continue
					var dv := data.points[j] - p
					dv.y = 0.0
					var lat := dv.dot(rh)
					if absf(dv.dot(th)) > absf(lat):
						continue
					var cap := absf(lat) * 0.5 - 0.5
					if lat > 0.0:
						lim_r[i] = minf(lim_r[i], cap)
					else:
						lim_l[i] = minf(lim_l[i], cap)
