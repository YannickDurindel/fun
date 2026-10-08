class_name TracksideLayout
extends RefCounted
## Trackside layout of one track: where the kerbs, run-off areas and barrier types go.
## Trackside (scripts/track/trackside.gd) sweeps the geometry from it.
##
##   var layout := TracksideLayout.for_track(track_id, data)
##
##   * A track with a hand-made table (scripts/track/trackside_layouts/<track_id>.gd, see
##     red_bull_ring.gd for the format) uses it: everything there is relative to the turn
##     table of track.json.
##   * Any other track gets the AUTOMATIC layout, derived from the centreline alone
##     (see _build_auto): apex and exit kerbs, sausage kerbs on tight apexes, tarmac run-off
##     behind heavy braking zones, gravel outside the other corners, barrier distances that
##     grow with the approach speed, concrete + fence along the start/finish straight.
##   * The automatic layout can be forced for every track with the user argument
##     `--auto-trackside` or the environment variable FUN_TRACKSIDE_AUTO=1 (quality check).
##
## Sides are lateral signs: +1 = right of the road in race direction, -1 = left.

const LAYOUTS_DIR := "res://scripts/track/trackside_layouts"
const AUTO_FLAG := "--auto-trackside"
const AUTO_ENV := "FUN_TRACKSIDE_AUTO"

## Defaults of the automatic layout (a hand-made table brings its own).
const BARRIER_STRAIGHT: float = 10.0       ## barrier distance from the road edge on straights
const BARRIER_BEHIND_RUNOFF: float = 5.0   ## space between a run-off's outer edge and the wall
const RUNOFF_KERB_ALLOWANCE: float = 2.5   ## room kept for kerbs between the edge and a run-off

# ---- automatic layout tuning
const K_MIN: float = 1.0 / 400.0     ## curvature below this is "straight"
const TURN_MIN_ANGLE: float = 0.10   ## rad; smaller direction changes are not turns
const EXTENT_MAX: float = 200.0      ## a turn reaches at most this far from its apex
const LAT_ACC: float = 25.0          ## m/s^2, corner speed estimate v = sqrt(LAT_ACC * R)
const LONG_ACC: float = 8.0          ## m/s^2, speed gained along a straight
const V_MAX: float = 90.0            ## m/s
const SAUSAGE_RADIUS: float = 25.0   ## sausage kerbs on apexes tighter than this
const SAW_RADIUS: float = 120.0      ## sawtooth kerbs below, flat kerbs above (fast kinks)
const EXIT_KERB_ANGLE: float = 0.26  ## rad; smaller corners get no exit kerb
const GRAVEL_ANGLE: float = 0.35     ## rad; smaller corners get no gravel
const HEAVY_BRAKING: float = 25.0    ## m/s lost into the corner ...
const HEAVY_RADIUS: float = 45.0     ## ... with a radius below this: tarmac run-off

var track_id: String = ""
## False when the hand-made table of `track_id` was used.
var is_auto: bool = true
## [{turn, kind (flat | saw | sausage), side, s0, len}]; s0 is wrapped into [0, length).
var kerbs: Array[Dictionary] = []
## [{turn, kind (tarmac | gravel), side, s0, len, u0, u1}]; u = metres outward measured from
## the outer edge of any kerb there (0 = right behind it).
var runoff: Array[Dictionary] = []
## Where the barrier stands further out than `barrier_straight`:
## [{s0, len, ramp, side, dist}] = `dist` metres from the road edge over [s0, s0 + len],
## blending back to the straight distance over `ramp` metres on both ends.
var barrier_zones: Array[Dictionary] = []
var barrier_straight: float = BARRIER_STRAIGHT
## Concrete wall + debris fence: [[from_s, to_s]] absolute, may wrap through the finish line.
## Armco everywhere else.
var concrete_ranges: Array = []
## Automatic layout only: the analysed corners (see analyse_turns).
var turns: Array[Dictionary] = []

var _length: float = 1.0

## True when the automatic layout is forced for every track (dev flag / environment).
static func auto_forced() -> bool:
	return AUTO_FLAG in OS.get_cmdline_user_args() or OS.get_environment(AUTO_ENV) == "1"

static func table_path(id: String) -> String:
	return "%s/%s.gd" % [LAYOUTS_DIR, id]

static func has_table(id: String) -> bool:
	return id.is_valid_filename() and ResourceLoader.exists(table_path(id))

## Layout of track `id` on centreline `data`. `force_auto` ignores a hand-made table.
static func for_track(id: String, data: TrackData, force_auto: bool = false) -> TracksideLayout:
	var layout := TracksideLayout.new()
	layout.track_id = id
	layout._length = maxf(data.length, 1.0)
	var table: Script = null
	if not force_auto and has_table(id):
		table = load(table_path(id)) as Script
	if table != null:
		layout._build_from_table(table.get_script_constant_map(), data)
	else:
		layout._build_auto(data)
	return layout

## Kerbs of track `id` (hand-made table, or automatic when it has none).
static func resolve_kerbs(data: TrackData, id: String) -> Array[Dictionary]:
	return for_track(id, data).kerbs

func is_concrete(s: float) -> bool:
	for r: Array in concrete_ranges:
		var a: float = r[0]
		var span := fposmod(float(r[1]) - a, _length)
		if fposmod(s - a, _length) <= span:
			return true
	return false

## Turn table lookup: {id: {s_apex, sign}} where sign = +1 for right-hand corners.
static func turn_index(data: TrackData) -> Dictionary:
	var out := {}
	for t: Dictionary in data.turns:
		out[t["id"]] = {"s_apex": float(t["s_apex"]),
				"sign": 1.0 if String(t["direction"]) == "right" else -1.0,
				"min_radius": float(t.get("min_radius", 50.0))}
	return out

## Lateral sign (+1 right of the road, -1 left) of the given side of a corner.
static func side_sign(turn_sign: float, side: String) -> float:
	return turn_sign if side == "in" else -turn_sign

# ------------------------------------------------------------------ hand-made tables
## `c` = constants of a table script: KERBS, RUNOFF, CONCRETE_RANGES, BARRIER_STRAIGHT,
## BARRIER_CORNER_OUTSIDE, BARRIER_BEHIND_RUNOFF (see trackside_layouts/red_bull_ring.gd).
func _build_from_table(c: Dictionary, data: TrackData) -> void:
	is_auto = false
	var idx := turn_index(data)
	for k: Array in c.get("KERBS", []):
		if not idx.has(k[0]):
			continue
		var t: Dictionary = idx[k[0]]
		kerbs.append({"turn": k[0], "kind": k[4], "side": side_sign(t["sign"], k[1]),
				"s0": data.wrap_s(t["s_apex"] + k[2]), "len": float(k[3]) - float(k[2])})
	for r: Array in c.get("RUNOFF", []):
		if not idx.has(r[0]):
			continue
		var t: Dictionary = idx[r[0]]
		runoff.append({"turn": r[0], "kind": r[4], "side": side_sign(t["sign"], r[1]),
				"s0": data.wrap_s(t["s_apex"] + r[2]), "len": float(r[3]) - float(r[2]),
				"u0": float(r[5]), "u1": float(r[6])})
	concrete_ranges = c.get("CONCRETE_RANGES", [])
	barrier_straight = float(c.get("BARRIER_STRAIGHT", BARRIER_STRAIGHT))
	var corner := float(c.get("BARRIER_CORNER_OUTSIDE", 15.0))
	var behind := float(c.get("BARRIER_BEHIND_RUNOFF", BARRIER_BEHIND_RUNOFF))
	for id: String in idx:
		var t: Dictionary = idx[id]
		barrier_zones.append({"s0": float(t["s_apex"]) - 60.0, "len": 140.0, "ramp": 40.0,
				"side": -float(t["sign"]), "dist": corner})
	_add_runoff_zones(behind)

func _add_runoff_zones(behind: float) -> void:
	for r in runoff:
		barrier_zones.append({"s0": r["s0"], "len": r["len"], "ramp": 30.0, "side": r["side"],
				"dist": float(r["u1"]) + RUNOFF_KERB_ALLOWANCE + behind})

# ------------------------------------------------------------------ automatic layout
## Signed curvature (1/m) per centreline point, + = right-hand turn.
static func curvature(data: TrackData) -> PackedFloat32Array:
	var k := TrackGeometry.curvature(data)   # + = left there
	for i in k.size():
		k[i] = -k[i]
	return k

## Corners of the lap, in lap order: the turn table of track.json when it has one, otherwise
## detected from the curvature. Each:
##   {id, s_apex, sign (+1 right), radius, s_in, s_out, angle (rad), gap_prev, gap_next,
##    approach (m of straight before it), v_corner, v_approach (m/s estimates)}
## s_in <= s_apex <= s_out are NOT wrapped (s_in may be negative, s_out beyond the length).
static func analyse_turns(data: TrackData) -> Array[Dictionary]:
	var k := curvature(data)
	var n := k.size()
	var out: Array[Dictionary] = []
	if n < 8 or data.step <= 0.0:
		return out
	if data.turns.is_empty():
		out = _detect_turns(data, k)
	else:
		for t: Dictionary in data.turns:
			out.append({"id": String(t["id"]), "s_apex": data.wrap_s(float(t["s_apex"])),
					"sign": 1.0 if String(t.get("direction", "right")) == "right" else -1.0,
					"radius": float(t.get("min_radius", 0.0))})
		out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["s_apex"] < b["s_apex"])
	var m := out.size()
	for q in m:
		var t := out[q]
		var apex: float = t["s_apex"]
		var sgn: float = t["sign"]
		t["gap_prev"] = fposmod(apex - float(out[(q - 1 + m) % m]["s_apex"]), data.length) if m > 1 else data.length
		t["gap_next"] = fposmod(float(out[(q + 1) % m]["s_apex"]) - apex, data.length) if m > 1 else data.length
		var ia := roundi(apex / data.step) % n
		var peak := K_MIN
		for j in range(-8, 9):
			peak = maxf(peak, k[(ia + j + n) % n] * sgn)
		if float(t["radius"]) <= 0.0:
			t["radius"] = 1.0 / peak
		# The turn lasts while the road keeps curving that way (at least 20 % of the peak),
		# and never past the midpoint to the next corner.
		var thr := maxf(K_MIN, 0.2 * peak)
		var back := 0
		while (back + 1) * data.step <= minf(EXTENT_MAX, 0.5 * float(t["gap_prev"])) \
				and k[posmod(ia - back - 1, n)] * sgn > thr:
			back += 1
		var fwd := 0
		while (fwd + 1) * data.step <= minf(EXTENT_MAX, 0.5 * float(t["gap_next"])) \
				and k[posmod(ia + fwd + 1, n)] * sgn > thr:
			fwd += 1
		var angle := 0.0
		for j in range(-back, fwd + 1):
			angle += maxf(k[posmod(ia + j, n)] * sgn, 0.0) * data.step
		t["s_in"] = apex - back * data.step
		t["s_out"] = apex + fwd * data.step
		t["angle"] = angle
		t["v_corner"] = minf(V_MAX, sqrt(LAT_ACC * float(t["radius"])))
	for q in m:
		var t := out[q]
		var prev := out[(q - 1 + m) % m]
		var approach := data.length - (float(t["s_out"]) - float(t["s_in"]))
		if m > 1:
			approach = fposmod(float(t["s_in"]) - float(prev["s_out"]), data.length)
			if approach > float(t["gap_prev"]):   # the two extents touch or overlap
				approach = 0.0
		t["approach"] = approach
		var v0: float = prev["v_corner"]
		t["v_approach"] = minf(V_MAX, sqrt(v0 * v0 + 2.0 * LONG_ACC * approach))
	return out

## Corners from the curvature alone: runs curving one way by more than TURN_MIN_ANGLE.
static func _detect_turns(data: TrackData, k: PackedFloat32Array) -> Array[Dictionary]:
	var n := k.size()
	# Scan from the straightest point of the lap, so no corner straddles the scan's seam
	# (on a lap without any straight, the corner there is split at its gentlest point).
	var start := 0
	for i in n:
		if absf(k[i]) < absf(k[start]):
			start = i
	# Runs [first, last] (indices counted from `start`, not wrapped) of one curvature sign.
	var runs: Array[Array] = []
	var cur := 0.0
	var first := 0
	for q in n + 1:
		var v := k[(start + q) % n] if q < n else 0.0
		var sgn := 0.0 if absf(v) <= K_MIN else signf(v)
		if sgn == cur:
			continue
		if cur != 0.0:
			runs.append([first, q - 1, cur])
		cur = sgn
		first = q
	# Join runs of the same direction separated by less than 20 m of straight.
	var merged: Array[Array] = []
	for r in runs:
		if not merged.is_empty() and merged[-1][2] == r[2] \
				and (int(r[0]) - int(merged[-1][1])) * data.step < 20.0:
			merged[-1][1] = r[1]
		else:
			merged.append(r)
	var out: Array[Dictionary] = []
	for r in merged:
		var angle := 0.0
		var peak := 0.0
		var peak_q: int = r[0]
		for q in range(int(r[0]), int(r[1]) + 1):
			var v := absf(k[(start + q) % n])
			angle += v * data.step
			if v > peak:
				peak = v
				peak_q = q
		if angle < TURN_MIN_ANGLE:
			continue
		# Apex = middle of the tightest stretch around the peak (a constant-radius arc has no
		# single peak; joined runs keep the apex inside the tighter one).
		var tight_first := peak_q
		var tight_last := peak_q
		while tight_first > int(r[0]) and absf(k[(start + tight_first - 1) % n]) >= 0.9 * peak:
			tight_first -= 1
		while tight_last < int(r[1]) and absf(k[(start + tight_last + 1) % n]) >= 0.9 * peak:
			tight_last += 1
		peak_q = (tight_first + tight_last) / 2
		out.append({"s_apex": ((start + peak_q) % n) * data.step, "sign": float(r[2]), "radius": 1.0 / peak})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["s_apex"] < b["s_apex"])
	for q in out.size():
		out[q]["id"] = "T%d" % (q + 1)
	return out

## Kerbs, run-off, barrier zones and wall types from the centreline geometry.
func _build_auto(data: TrackData) -> void:
	is_auto = true
	turns = analyse_turns(data)
	var exits: Array[Dictionary] = []
	for t in turns:
		var id: String = t["id"]
		var apex: float = t["s_apex"]
		var sgn: float = t["sign"]          # inside of the corner = this side
		var radius: float = t["radius"]
		var angle: float = t["angle"]
		var arc_in: float = apex - float(t["s_in"])
		var arc_out: float = float(t["s_out"]) - apex
		var kind := "saw" if radius < SAW_RADIUS else "flat"
		# Apex kerb on the inside, over the middle of the corner (longer for long corners),
		# never reaching the next corner's.
		var a := maxf(minf(clampf(0.7 * arc_in + 8.0, 15.0, 50.0), 0.5 * float(t["gap_prev"]) - 1.0), 4.0)
		var b := maxf(minf(clampf(0.7 * arc_out + 8.0, 15.0, 50.0), 0.5 * float(t["gap_next"]) - 1.0), 4.0)
		kerbs.append(_kerb(data, id, kind, sgn, apex - a, a + b))
		if radius < SAUSAGE_RADIUS:
			kerbs.append(_kerb(data, id, "sausage", sgn, apex - 0.4 * a, 0.4 * a + 0.6 * b))
		# Exit kerb on the outside, from the second half of the corner onto the next straight.
		if angle >= EXIT_KERB_ANGLE:
			var e0 := apex + maxf(0.6 * arc_out - 5.0, 0.0)
			exits.append(_kerb(data, id, kind, -sgn, e0, clampf(25.0 + 0.3 * radius + 12.0 * angle, 35.0, 80.0)))
		# Run-off on the outside.
		var braking := maxf(float(t["v_approach"]) - float(t["v_corner"]), 0.0)
		if braking > HEAVY_BRAKING and radius < HEAVY_RADIUS:
			var lead := clampf(1.5 * braking, 30.0, 70.0)
			_add_runoff({"turn": id, "kind": "tarmac", "side": -sgn, "s0": float(t["s_in"]) - lead,
					"len": lead + arc_in + arc_out + 70.0, "u0": 0.0,
					"u1": lerpf(18.0, 28.0, clampf((braking - HEAVY_BRAKING) / 40.0, 0.0, 1.0))}, data)
		elif angle >= GRAVEL_ANGLE:
			_add_runoff({"turn": id, "kind": "gravel", "side": -sgn, "s0": apex - minf(arc_in, 10.0),
					"len": minf(arc_in, 10.0) + arc_out + clampf(40.0 + 0.5 * radius, 50.0, 100.0), "u0": 1.5,
					"u1": lerpf(14.0, 22.0, clampf((float(t["v_approach"]) - 40.0) / 50.0, 0.0, 1.0))}, data)
		# The faster the cars arrive, the further out the wall on the outside stands.
		barrier_zones.append({"s0": float(t["s_in"]) - 30.0, "len": arc_in + arc_out + 90.0, "ramp": 40.0,
				"side": -sgn, "dist": lerpf(12.0, 20.0, clampf((float(t["v_approach"]) - 30.0) / 60.0, 0.0, 1.0))})
	# Exit kerbs give way to any kerb already on that side (chicanes, back-to-back corners).
	for e in exits:
		if _trim(e, kerbs, data, 12.0):
			kerbs.append(e)
	_add_runoff_zones(BARRIER_BEHIND_RUNOFF)
	concrete_ranges = [_start_straight(data)]

static func _kerb(data: TrackData, id: String, kind: String, side: float, s0: float, span: float) -> Dictionary:
	return {"turn": id, "kind": kind, "side": side, "s0": data.wrap_s(s0), "len": span}

func _add_runoff(r: Dictionary, data: TrackData) -> void:
	r["s0"] = data.wrap_s(float(r["s0"]))
	if _trim(r, runoff, data, 40.0):
		runoff.append(r)

## Shortens item {s0, len, side, kind} so it does not overlap any of `others` on its side
## (sausage kerbs sit behind the other kerbs and are ignored). False if less than `min_len`
## metres are left.
static func _trim(item: Dictionary, others: Array[Dictionary], data: TrackData, min_len: float) -> bool:
	for o in others:
		if o["side"] != item["side"] or o["kind"] == "sausage":
			continue
		var span: float = item["len"]
		var a := data.delta_s(float(item["s0"]), float(o["s0"]))   # o's start in item metres
		var b := a + float(o["len"])
		if b <= 0.0 or a >= span:
			continue
		if a <= 0.0:    # o covers the start
			item["s0"] = data.wrap_s(float(item["s0"]) + b)
			item["len"] = span - b
		else:           # o starts inside: stop there
			item["len"] = a
		if float(item["len"]) < min_len:
			return false
	return float(item["len"]) >= min_len

## The straight through the finish line, as a concrete range [from_s, to_s]: from just after
## the last corner to the braking zone of the first one.
func _start_straight(data: TrackData) -> Array:
	var before := INF   # distance from the end of the last corner to the line
	var after := INF    # distance from the line to the start of the first corner
	for t in turns:
		before = minf(before, fposmod(-float(t["s_out"]), data.length))
		after = minf(after, fposmod(float(t["s_in"]), data.length))
	if before + after > data.length:
		# No corners at all: just the grid area.
		return [data.wrap_s(-minf(100.0, 0.2 * data.length)), data.wrap_s(data.start_s + minf(150.0, 0.2 * data.length))]
	return [data.wrap_s(-before + minf(30.0, 0.2 * before)), data.wrap_s(after - minf(80.0, 0.4 * after))]
