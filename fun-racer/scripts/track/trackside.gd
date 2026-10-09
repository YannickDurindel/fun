class_name Trackside
extends Node3D
## Trackside slot of a Track: kerbs, white edge lines, run-off areas and barriers, all swept
## at runtime from the parent Track's centreline (TrackData) so they follow whatever road
## widths, banking and crossfall the Road slot builds.
##
##   * Cross-section profiles come from CAD (cad/track/trackside_profiles.py ->
##     trackside_profiles.json in the track folder, else the shared default); placement comes
##     from TracksideLayout: the track's hand-made table, or the automatic layout.
##   * When `snap_to_road` is on, the build waits two physics frames so the Road's collision
##     is in the physics space, then ray-casts the actual surface under every kerb / line /
##     run-off vertex. Without a Road hit it falls back to the TrackData road plane.
##   * HD 520 budget: geometry is merged per ~200 m chunk (one MeshInstance3D per chunk, one
##     surface per material), posts are MultiMeshes, collisions are one body per kerb /
##     run-off patch / barrier chunk.
##
##   * Crossovers (RoadSurface.bridges, a figure-of-eight lap): the two roads do not limit
##     each other's barrier lines; the upper road gets a concrete parapet on the bridge deck
##     and the lower road's barriers stay inside the underpass (see _crossover_limits).
##   * Side-by-side carriageways (RoadSurface.pairs, the recipe's [[road.pair]]): one wall on
##     the middle of the median instead of one per road (see _share_pair_walls).
##
## Collision bodies carry meta "surface" ("kerb", "asphalt", "gravel"); barriers also carry
## meta "barrier" = true, the group "trackside_barrier" and physics layer 5 (LAYER_BARRIER).

signal built

const PROFILES_FILE := "trackside_profiles.json"
## Default kerb / barrier cross-sections (they are track-independent) for track folders
## without their own trackside_profiles.json.
const SHARED_PROFILES_PATH := "res://assets/tracks/_shared/trackside_profiles.json"
const KERB_SHADER := preload("res://shaders/kerb.gdshader")
const LAYER_BARRIER: int = 1 << 4
const KERB_PROFILE := {"flat": "kerb_flat", "saw": "kerb_sawtooth", "sausage": "kerb_sausage"}
const SAUSAGE_GAP: float = 0.3      ## space between a kerb's outer edge and a sausage kerb
const LIMIT_SLOPE: float = 0.3      ## automatic layout: max sideways run of the wall per metre
const PAIR_RAMP: float = 20.0       ## m over which the two walls of a pair become its shared one
## Cross slope (sine) above which trackside points beside the road follow the Road slot's verge
## surface instead of the extended road plane: just over the automatic camber (0.03 rad), so
## the tracks without declared banking keep their geometry exactly.
const BANKED_FROM: float = 0.035

@export var snap_to_road: bool = true
@export var chunk_length: float = 200.0
@export var kerb_row_step: float = 0.5
@export var wall_row_stride: int = 2   ## centreline points per barrier segment (~4 m)
## Ignore the track's hand-made layout table and use the automatic layout (also forced by
## --auto-trackside / FUN_TRACKSIDE_AUTO=1, see TracksideLayout).
@export var force_auto_layout: bool = false

var is_built: bool = false
var layout: TracksideLayout
var kerbs: Array[Dictionary] = []
var runoff: Array[Dictionary] = []
var snap_hits: int = 0
var snap_misses: int = 0

var _data: TrackData
var _prof: Dictionary
var _road: Node
var _space: PhysicsDirectSpaceState3D
var _ray := PhysicsRayQueryParameters3D.new()
var _off_r := PackedFloat32Array()   ## barrier line, centre offset to the right (m) per point
var _off_l := PackedFloat32Array()
var _pair_skip_l := PackedByteArray()   ## 1 = no barrier of its own on the left at this point
var _pair_skip_r := PackedByteArray()   ## (the far side of a pair's shared wall); empty = none
var _tools := {}                     ## Vector2i(chunk, material) -> SurfaceTool
var _mats: Array[Material] = []
var _bodies: Array[Node] = []        ## added at the end so ray snapping never hits our own

enum Mat { KERB_RW, KERB_YELLOW, LINE, TARMAC, GRAVEL, BEAM, CONCRETE, FENCE }

func _ready() -> void:
	var track := get_parent() as Track
	if track == null or track.data == null:
		return
	_data = track.data
	_road = track.get_node_or_null(^"Road")
	_prof = _load_profiles(track)
	if _prof.is_empty():
		return
	var forced := force_auto_layout or TracksideLayout.auto_forced()
	layout = TracksideLayout.for_track(track.track_id, _data, forced)
	if forced and TracksideLayout.has_table(track.track_id):
		print("Trackside: automatic layout forced, ignoring the hand-made table of '%s'" % track.track_id)
	kerbs = layout.kerbs
	runoff = layout.runoff
	_compute_barrier_offsets()
	if snap_to_road:
		await get_tree().physics_frame
		await get_tree().physics_frame
		if not is_inside_tree():
			return
		_space = get_world_3d().direct_space_state
	_make_materials()
	_build_kerbs()
	_build_edge_lines()
	_build_runoff()
	_build_barriers()
	_commit_chunks()
	for b in _bodies:
		add_child(b)
	_bodies.clear()
	is_built = true
	built.emit()

## Profiles of the track folder, else the shared default. Empty (and an error) if neither
## can be read.
static func _load_profiles(track: Track) -> Dictionary:
	for path: String in [track.file_path(PROFILES_FILE), SHARED_PROFILES_PATH]:
		if not FileAccess.file_exists(path):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and (parsed as Dictionary).has("kerb_flat"):
			return parsed
		push_error("Trackside: %s is not a valid profile file" % path)
	push_error("Trackside: no trackside profiles for track '%s'" % track.track_id)
	return {}

# ------------------------------------------------------------------------- public queries
## Road half width at s: the Road slot's real per-section width when it provides one,
## otherwise TrackData's.
func edge_at(s: float) -> float:
	if _road != null and _road.has_method(&"half_width_at"):
		return float(_road.call(&"half_width_at", s))
	return _data.width_at(s) * 0.5

## Road frame at s: origin on the centreline surface, +X right, +Y road normal, -Z forward.
## Banking comes from the Road slot (+ = left edge higher), which has the crossfall of every
## track; TrackData only carries declared banking.
func frame_at(s: float) -> Transform3D:
	var fwd := _data.tangent_at(s)
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd).normalized()
	var origin := _data.position_at(s)
	if _road != null and _road.has_method(&"surface_point"):
		origin = _road.call(&"surface_point", s, 0.0)
	if _road != null and _road.has_method(&"bank_at"):
		var b := float(_road.call(&"bank_at", s))
		if absf(b) > 1e-6:
			var r2 := right * cos(b) - up * sin(b)
			up = up * cos(b) + right * sin(b)
			right = r2
	return Transform3D(Basis(right, up, -fwd), origin)

## Point `dist` metres from the centreline on `side` (+1 right, -1 left). On the road it is
## the Road slot's real surface (crossfall included); beyond the edge the road plane at the
## edge is extended outward (callers ray-snap those points onto the real verge). Beside a
## banked road (BANKED_FROM) that plane leaves the ground within a few metres, so there the
## point is on the Road slot's verge surface itself.
func lateral_point(s: float, side: float, dist: float, xf: Transform3D) -> Vector3:
	var e := edge_at(s)
	var d := minf(dist, e)
	var p: Vector3
	if _road != null and _road.has_method(&"surface_point"):
		if dist > e and absf(xf.basis.x.y) > BANKED_FROM:
			return _road.call(&"surface_point", s, side * dist)
		p = _road.call(&"surface_point", s, side * d)
	else:
		p = xf.origin + xf.basis.x * side * d
	return p + xf.basis.x * side * (dist - d)

## Barrier line distance from the centreline at s on `side` (+1 right, -1 left).
func barrier_offset(s: float, side: float) -> float:
	var arr := _off_r if side > 0.0 else _off_l
	var u := _data.wrap_s(s) / _data.step
	var i := int(floor(u)) % arr.size()
	return lerpf(arr[i], arr[(i + 1) % arr.size()], u - floor(u))

## Outer extent (m beyond the road edge) of the kerbs covering s on `side`, 0 if none.
func kerb_extent(s: float, side: float, include_sausage: bool = true) -> float:
	var base := 0.0
	var sausage := false
	for k in kerbs:
		if k["side"] != side or not _covers(k, s):
			continue
		if k["kind"] == "sausage":
			sausage = true
		else:
			base = maxf(base, float(_prof[KERB_PROFILE[k["kind"]]]["width"]))
	if include_sausage and sausage:
		return base + SAUSAGE_GAP + float(_prof["kerb_sausage"]["width"])
	return base

func _covers(k: Dictionary, s: float, margin: float = 0.0) -> bool:
	var t := fposmod(s - float(k["s0"]) + margin, _data.length)
	return t <= float(k["len"]) + 2.0 * margin

# ------------------------------------------------------------------------- barrier layout
func _blend(s: float, s0: float, len: float, ramp: float) -> float:
	var t := _data.delta_s(s0, s)   # metres after s0 (signed, wrapped)
	if t >= 0.0 and t <= len:
		return 1.0
	var d := -t if t < 0.0 else t - len
	return 0.5 + 0.5 * cos(PI * clampf(d / ramp, 0.0, 1.0))

func _compute_barrier_offsets() -> void:
	var n := _data.points.size()
	var edges := PackedFloat32Array()
	edges.resize(n)
	var des_l := PackedFloat32Array()   # desired distance from the road edge
	var des_r := PackedFloat32Array()
	des_l.resize(n)
	des_r.resize(n)
	for i in n:
		var s := i * _data.step
		edges[i] = edge_at(s)
		var dl := layout.barrier_straight
		var dr := layout.barrier_straight
		for z in layout.barrier_zones:
			var v := lerpf(layout.barrier_straight, float(z["dist"]),
					_blend(s, float(z["s0"]), float(z["len"]), float(z["ramp"])))
			if z["side"] > 0.0:
				dr = maxf(dr, v)
			else:
				dl = maxf(dl, v)
		des_l[i] = dl
		des_r[i] = dr
	# Geometric limits (centre offsets): inside of tight corners and nearby legs of the lap.
	var lims := TrackGeometry.no_limits(n)
	var lim_l := lims[0]
	var lim_r := lims[1]
	TrackGeometry.inside_limits(_data, lim_l, lim_r)
	TrackGeometry.proximity_limits(_data, lim_l, lim_r, _crossover_pairs() + _carriageway_pairs())
	_crossover_limits(lim_l, lim_r, edges)
	_pair_limits(lim_l, lim_r, edges)
	if layout.is_auto:
		# Hand-made layouts keep the raw limits, so their walls stay exactly where they were.
		_limit_slope(lim_l)
		_limit_slope(lim_r)
	_off_l = _finish_offsets(des_l, lim_l, edges)
	_off_r = _finish_offsets(des_r, lim_r, edges)
	_share_pair_walls(lim_l, lim_r, edges)

## Crossovers of the lap as the Road slot reports them ([] without a Road or on a normal lap).
func _bridges() -> Array[Dictionary]:
	var none: Array[Dictionary] = []
	var road := _road as RoadSurface
	return road.bridges if road != null else none

## Centreline point range [first, last] of an s range [s0, s1] (may wrap).
func _point_range(r: Array) -> Array[int]:
	var n := _data.points.size()
	return [roundi(float(r[0]) / _data.step) % n, roundi(float(r[1]) / _data.step) % n]

## The stretch pairs of TrackGeometry.proximity_limits(): upper and lower road of each bridge.
func _crossover_pairs() -> Array:
	var out := []
	for b in _bridges():
		out.append(_point_range(b["upper_window"]) + _point_range(b["lower_window"]))
	return out

## Barrier limits around a crossover, where the other road is no longer a neighbour. Both
## roads end their verges where the other one's ground begins (cad/track/bridge.py), so the
## verge width gives the limit: the upper road's wall stands on the edge of its ground, and
## on the deck it is the parapet; the lower road's wall stands just behind its verge, and
## inside the underpass just beside the road.
func _crossover_limits(lim_l: PackedFloat32Array, lim_r: PackedFloat32Array, edges: PackedFloat32Array) -> void:
	var road := _road as RoadSurface
	var n := _data.points.size()
	for b in _bridges():
		var rooms := [float(b.get("parapet_offset", 2.0)), float(b.get("barrier_room", 1.0))]
		var windows := [_point_range(b["upper_window"]), _point_range(b["lower_window"])]
		for w in 2:
			var first: int = windows[w][0]
			for k in posmod(int(windows[w][1]) - first, n) + 1:
				var i := (first + k) % n
				lim_l[i] = minf(lim_l[i], edges[i] + road.verge_left[i] + float(rooms[w]))
				lim_r[i] = minf(lim_r[i], edges[i] + road.verge_right[i] + float(rooms[w]))

## Side-by-side carriageways as the Road slot reports them ([] without a Road or a pair).
func _pairs() -> Array[Dictionary]:
	var none: Array[Dictionary] = []
	var road := _road as RoadSurface
	return road.pairs if road != null else none

## The two stretches of each pair, for TrackGeometry.proximity_limits(): the line between them
## is known exactly (_pair_limits), so they need not estimate it from each other.
## Each stretch reaches PAIR_RAMP beyond its ends: where the roads part, an estimate made
## across the lap is on a slant and can put the wall on the road edge.
func _carriageway_pairs() -> Array:
	var n := _data.points.size()
	var beyond := _pair_beyond()
	var out := []
	for p in _pairs():
		var a := _point_range(p["a"])
		var b := _point_range(p["b"])
		out.append([posmod(a[0] - beyond, n), (a[1] + beyond) % n, posmod(b[0] - beyond, n), (b[1] + beyond) % n])
	return out

## Centreline points in PAIR_RAMP.
func _pair_beyond() -> int:
	return ceili(PAIR_RAMP / _data.step)

## The stretches of the pairs as [[first point, count, side, shares], ...]: `side` is the side
## the other carriageway is on, and `shares` is true for the stretch that builds the one wall
## between the two (the first, "a"); the other one builds none on that side.
func _pair_legs() -> Array:
	var n := _data.points.size()
	var out := []
	for p in _pairs():
		for leg: Array in [["a", "side_a", true], ["b", "side_b", false]]:
			var r := _point_range(p[leg[0]])
			out.append([r[0], posmod(r[1] - r[0], n) + 1, float(p[leg[1]]), leg[2]])
	return out

## Between the carriageways of a pair the limit of both is the line half way between their
## tarmac edges, which is where both verges end (cad/track/road.py: pair_verges).
func _pair_limits(lim_l: PackedFloat32Array, lim_r: PackedFloat32Array, edges: PackedFloat32Array) -> void:
	var road := _road as RoadSurface
	var n := _data.points.size()
	for leg: Array in _pair_legs():
		var lim := lim_l if leg[2] < 0.0 else lim_r
		var verge := road.verge_left if leg[2] < 0.0 else road.verge_right
		var first: int = leg[0]
		var count: int = leg[1]
		for k in count:
			var i := (first + k) % n
			lim[i] = minf(lim[i], edges[i] + verge[i])
		# Beyond either end, where the two no longer limit each other (_carriageway_pairs): no
		# further out than at the end of the stretch.
		for e: Array in _pair_ends(first, count):
			lim[e[0]] = minf(lim[e[0]], edges[e[0]] + verge[e[1]])

## The points within PAIR_RAMP beyond either end of a stretch, as [point, the end point of the
## stretch on that side, points from that end (1 = next to it)].
func _pair_ends(first: int, count: int) -> Array:
	var n := _data.points.size()
	var last := (first + count - 1) % n
	var out := []
	for k in range(1, _pair_beyond() + 1):
		out.append([posmod(first - k, n), first, k])
		out.append([(last + k) % n, last, k])
	return out

## One wall between the carriageways of a pair instead of one per road: along the stretch both
## barrier lines are the middle of the median (the wall's body is centred on it), and the
## second stretch does not build its own (_pair_skip). Over PAIR_RAMP before and after the
## stretch the two roads' own walls close in on that line, so they meet where the shared wall
## begins and no gap opens onto the median.
func _share_pair_walls(lim_l: PackedFloat32Array, lim_r: PackedFloat32Array, edges: PackedFloat32Array) -> void:
	var road := _road as RoadSurface
	var n := _data.points.size()
	_pair_skip_l.clear()
	_pair_skip_r.clear()
	for leg: Array in _pair_legs():
		var left: bool = leg[2] < 0.0
		var off := _off_l if left else _off_r
		var lim := lim_l if left else lim_r
		var verge := road.verge_left if left else road.verge_right
		var first: int = leg[0]
		var count: int = leg[1]
		if not leg[3]:
			var skip := _pair_skip_l if left else _pair_skip_r
			if skip.is_empty():
				skip.resize(n)
			for k in count:
				skip[(first + k) % n] = 1
			if left:
				_pair_skip_l = skip
			else:
				_pair_skip_r = skip
		for k in count:
			var i := (first + k) % n
			off[i] = minf(edges[i] + verge[i] - _shared_wall_half(i), lim[i])
		for e: Array in _pair_ends(first, count):
			var i: int = e[0]
			var w := 1.0 - float(e[2]) / (_pair_beyond() + 1)
			off[i] = lerpf(off[i], minf(edges[i] + verge[e[1]] - _shared_wall_half(i), lim[i]), w)
		if left:
			_off_l = off
		else:
			_off_r = off

## Half the thickness of the wall at point `i`: a concrete wall's body lies beyond the barrier
## line, so the line of a wall that two roads share is that far short of the median's middle.
func _shared_wall_half(i: int) -> float:
	return 0.5 * float(_prof["concrete"]["collision"]["u1"]) if layout.is_concrete(i * _data.step) else 0.0

## True when the barrier segment from point `i` to point `j` on `side` is the far side of a
## pair's shared wall: the other carriageway builds it.
func _pair_skip(i: int, j: int, side: float) -> bool:
	var skip := _pair_skip_l if side < 0.0 else _pair_skip_r
	return not skip.is_empty() and skip[i] == 1 and skip[j] == 1

## Turns the geometric limits into a continuous line: where a limit starts (the inside of a
## tight corner, another leg of the lap coming close) the wall closes in at LIMIT_SLOPE
## instead of stepping sideways.
func _limit_slope(lim: PackedFloat32Array) -> void:
	var n := lim.size()
	var rise := LIMIT_SLOPE * _data.step
	for i in 2 * n:       # twice round, so the ramp also runs through the finish line
		lim[(i + 1) % n] = minf(lim[(i + 1) % n], lim[i % n] + rise)
	for i in range(2 * n, 0, -1):
		lim[(i - 1) % n] = minf(lim[(i - 1) % n], lim[i % n] + rise)

func _finish_offsets(des: PackedFloat32Array, lim: PackedFloat32Array,
		edges: PackedFloat32Array) -> PackedFloat32Array:
	var n := des.size()
	var off := PackedFloat32Array()
	off.resize(n)
	for i in n:
		off[i] = minf(edges[i] + des[i], lim[i])
	for pass_i in 2:
		var sm := PackedFloat32Array()
		sm.resize(n)
		for i in n:
			var acc := 0.0
			for k in range(-6, 7):
				acc += off[(i + k + n) % n]
			sm[i] = acc / 13.0
		off = sm
	for i in n:
		# Keep clear of the road edge, but never past the geometric limit (another leg).
		off[i] = minf(maxf(off[i], edges[i] + 2.0), lim[i])
	return off

# ------------------------------------------------------------------------- helpers
func _snap(p: Vector3, up: Vector3, road_only: bool, above: float = 0.6, below: float = 1.0) -> float:
	## Signed distance along `up` from p to the real surface below/above it, NAN if none.
	if _space == null:
		return NAN
	_ray.from = p + up * above
	_ray.to = p - up * below
	var excl: Array[RID] = []
	for attempt in 4:
		_ray.exclude = excl
		var hit := _space.intersect_ray(_ray)
		if hit.is_empty():
			break
		var col := hit["collider"] as Node
		var ok := col is StaticBody3D and not is_ancestor_of(col)
		if ok and road_only:
			ok = _road != null and _road.is_ancestor_of(col)
		if ok:
			snap_hits += 1
			return (hit["position"] - p).dot(up)
		excl.append(hit["rid"])
	snap_misses += 1
	return NAN

func _chunk(s: float) -> int:
	return int(_data.wrap_s(s) / chunk_length)

func _st(chunk: int, mat: int) -> SurfaceTool:
	var key := Vector2i(chunk, mat)
	if not _tools.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(_mats[mat])
		_tools[key] = st
	return _tools[key]

## Quad a-b-c-d (a loop), emitted facing `want`. UVs per corner.
func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, want: Vector3) -> void:
	var cr := (b - a).cross(c - a)
	if cr.length_squared() < 1e-14:
		cr = (c - a).cross(d - a)
	# Godot front faces wind clockwise: the visible normal is -(b-a)x(c-a).
	var flip := cr.dot(want) > 0.0
	var nrm := -cr.normalized() * (-1.0 if flip else 1.0)
	st.set_normal(nrm)
	var vs := [a, b, c, a, c, d] if not flip else [a, c, b, a, d, c]
	var us := [ua, ub, uc, ua, uc, ud] if not flip else [ua, uc, ub, ua, ud, uc]
	for k in 6:
		st.set_uv(us[k])
		st.add_vertex(vs[k])

static func _faces_quad(f: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	f.append_array([a, b, c, a, c, d])

func _body(faces: PackedVector3Array, surface: String, body_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.set_meta("surface", surface)
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	_bodies.append(body)
	return body

func _make_materials() -> void:
	_mats.resize(Mat.size())
	var rw := ShaderMaterial.new()
	rw.shader = KERB_SHADER
	# Kerb colours are the track's (environment.json "kerbs"; the defaults are red / white
	# and a yellow sausage kerb).
	var track := get_parent() as Track
	var env := track.environment if track != null and track.environment != null else TrackEnvironment.new()
	rw.set_shader_parameter("color_a", env.color("kerbs", "a"))
	rw.set_shader_parameter("color_b", env.color("kerbs", "b"))
	rw.set_shader_parameter("stripe", 1.0)
	_mats[Mat.KERB_RW] = rw
	var ye := ShaderMaterial.new()
	ye.shader = KERB_SHADER
	ye.set_shader_parameter("color_a", env.color("kerbs", "sausage"))
	ye.set_shader_parameter("color_b", env.color("kerbs", "sausage"))
	ye.set_shader_parameter("stripe", 0.0)
	_mats[Mat.KERB_YELLOW] = ye
	_mats[Mat.LINE] = _std(Color(0.92, 0.92, 0.90), 0.75)
	_mats[Mat.TARMAC] = _std(Color(0.26, 0.27, 0.29), 0.95)
	var gravel := _std(Color(0.80, 0.72, 0.56), 1.0)
	var noise := NoiseTexture2D.new()
	noise.width = 128
	noise.height = 128
	noise.seamless = true
	var fn := FastNoiseLite.new()
	fn.frequency = 0.15
	noise.noise = fn
	noise.color_ramp = Gradient.new()
	noise.color_ramp.set_color(0, Color(0.62, 0.58, 0.50))
	noise.color_ramp.set_color(1, Color(1.0, 0.97, 0.90))
	gravel.albedo_texture = noise
	_mats[Mat.GRAVEL] = gravel
	var beam := _std(Color(0.70, 0.72, 0.74), 0.35)
	beam.metallic = 0.75
	beam.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[Mat.BEAM] = beam
	_mats[Mat.CONCRETE] = _std(Color(0.74, 0.73, 0.70), 0.9)
	var fence := _std(Color(0.55, 0.57, 0.58), 0.6)
	fence.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	fence.alpha_scissor_threshold = 0.5
	fence.cull_mode = BaseMaterial3D.CULL_DISABLED
	fence.albedo_texture = _fence_texture()
	_mats[Mat.FENCE] = fence

static func _std(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m

static func _fence_texture() -> ImageTexture:
	var sz := 32
	var img := Image.create(sz, sz, true, Image.FORMAT_RGBA8)
	for y in sz:
		for x in sz:
			var a := (x + y) % 16
			var b := (x - y + 32) % 16
			var on := a < 2 or b < 2
			img.set_pixel(x, y, Color(1, 1, 1, 1.0 if on else 0.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# ------------------------------------------------------------------------- kerbs
func _build_kerbs() -> void:
	var idx := 0
	for k in kerbs:
		var prof: Dictionary = _prof[KERB_PROFILE[k["kind"]]]
		var top: Array = prof["top"]
		var width: float = prof["width"]
		var amp: float = prof["ripple_amp"]
		var period: float = prof["ripple_period"]
		var side: float = k["side"]
		var len: float = k["len"]
		var mat := Mat.KERB_YELLOW if k["kind"] == "sausage" else Mat.KERB_RW
		var rows := maxi(2, ceili(len / kerb_row_step))
		var faces := PackedVector3Array()
		var prev: Array = []
		var prev_up := Vector3.UP
		for r in rows + 1:
			var t := len * r / rows
			var s: float = k["s0"] + t
			var xf := frame_at(s)
			var right := xf.basis.x * side
			var up := xf.basis.y
			var base := edge_at(s)
			if k["kind"] == "sausage":
				base += kerb_extent(s, side, false) + SAUSAGE_GAP
			var taper := clampf(minf(t, len - t) / 1.5, 0.0, 1.0)
			var u0: float = top[0][0]
			var off_in := _snap(lateral_point(s, side, base + u0, xf), up, true)
			var off_out := _snap(lateral_point(s, side, base + width, xf), up, true)
			if is_nan(off_in):
				off_in = 0.0
			if is_nan(off_out):
				off_out = off_in
			var ripple := amp * (0.5 - 0.5 * cos(TAU * t / period))
			var row: Array = []
			for pt: Array in top:
				var u: float = pt[0]
				var h: float = pt[1] + ripple * smoothstep(0.1, 0.35, u)
				var snap := lerpf(off_in, off_out, clampf((u - u0) / (width - u0), 0.0, 1.0))
				row.append(lateral_point(s, side, base + u, xf) + up * (h * taper + 0.002 + snap))
			if not prev.is_empty():
				var st := _st(_chunk(s), mat)
				var t0 := len * (r - 1) / rows
				for j in top.size() - 1:
					var ua: float = top[j][0]
					var ub: float = top[j + 1][0]
					_quad(st, prev[j], prev[j + 1], row[j + 1], row[j],
							Vector2(t0, ua), Vector2(t0, ub), Vector2(t, ub), Vector2(t, ua), up)
					_faces_quad(faces, prev[j], prev[j + 1], row[j + 1], row[j])
				# Outer skirt down into the verge.
				var la: Vector3 = prev[top.size() - 1]
				var lb: Vector3 = row[top.size() - 1]
				_quad(st, la, lb, lb - up * 0.25, la - prev_up * 0.25,
						Vector2(t0, width), Vector2(t, width), Vector2(t, width), Vector2(t0, width), right)
			prev = row
			prev_up = up
		_body(faces, "kerb", "Kerb_%s_%d" % [k["turn"], idx])
		idx += 1

# ------------------------------------------------------------------------- edge lines
func _build_edge_lines() -> void:
	var lw: float = _prof["edge_line"]["width"]
	var lift: float = _prof["edge_line"]["lift"]
	var n := _data.points.size()
	for side: float in [-1.0, 1.0]:
		var prev: Array = []
		for i in n + 1:
			var s := (i % n) * _data.step
			var on := true
			for k in kerbs:
				if k["side"] == side and k["kind"] != "sausage" and _covers(k, s, 0.5):
					on = false
					break
			if not on:
				prev = []
				continue
			var xf := frame_at(s)
			var up := xf.basis.y
			var e := edge_at(s)
			var snap := _snap(lateral_point(s, side, e - lw * 0.5 - 0.02, xf), up, true)
			if is_nan(snap):
				snap = 0.0
			var lift_v := up * (lift + snap)
			var a := lateral_point(s, side, e - lw - 0.02, xf) + lift_v
			var b := lateral_point(s, side, e - 0.02, xf) + lift_v
			if not prev.is_empty():
				var t := i * _data.step
				_quad(_st(_chunk(s - _data.step), Mat.LINE), prev[0], prev[1], b, a,
						Vector2(t - _data.step, 0), Vector2(t - _data.step, 1), Vector2(t, 1), Vector2(t, 0), up)
			prev = [a, b]

# ------------------------------------------------------------------------- run-off
func _build_runoff() -> void:
	var idx := 0
	for r in runoff:
		var side: float = r["side"]
		var len: float = r["len"]
		var mat := Mat.GRAVEL if r["kind"] == "gravel" else Mat.TARMAC
		var lift := 0.04 if r["kind"] == "gravel" else 0.03
		var cols := clampi(ceili((float(r["u1"]) - float(r["u0"])) / 3.0) + 1, 3, 11)
		var ramp := minf(25.0, len * 0.3)
		var rows := maxi(2, ceili(len / _data.step))
		var faces := PackedVector3Array()
		var prev: Array = []
		var prev_up := Vector3.UP
		for ri in rows + 1:
			var t := len * ri / rows
			var s: float = r["s0"] + t
			var xf := frame_at(s)
			var right := xf.basis.x * side
			var up := xf.basis.y
			var e := edge_at(s)
			var ext := kerb_extent(s, side)
			var taper := smoothstep(0.0, ramp, t) * smoothstep(0.0, ramp, len - t)
			var room := maxf(barrier_offset(s, side) - e - 2.5 - ext, 0.0)
			var u_in := ext + minf(float(r["u0"]), room) * taper
			var u_out := ext + minf(float(r["u1"]), room) * taper
			var row: Array = []
			var last := 0.0
			for c in cols:
				var u := lerpf(u_in, u_out, float(c) / (cols - 1))
				var p := lateral_point(s, side, e + u, xf)
				var snap := _snap(p, up, false, 1.5, 2.5)
				if is_nan(snap):
					snap = last
				last = snap
				# Inner edge flush with the road / kerb (no lip), full lift one column out.
				row.append(p + up * (snap + (0.004 if c == 0 else lift)))
			if not prev.is_empty():
				var st := _st(_chunk(s), mat)
				var t0 := len * (ri - 1) / rows
				for c in cols - 1:
					var a: Vector3 = prev[c]
					var b: Vector3 = prev[c + 1]
					var cc: Vector3 = row[c + 1]
					var d: Vector3 = row[c]
					_quad(st, a, b, cc, d, Vector2(t0, c) * 0.25, Vector2(t0, c + 1) * 0.25,
							Vector2(t, c + 1) * 0.25, Vector2(t, c) * 0.25, up)
					_faces_quad(faces, a, b, cc, d)
				var la: Vector3 = prev[cols - 1]
				var lb: Vector3 = row[cols - 1]
				_quad(st, la, lb, lb - up * 0.4, la - prev_up * 0.4,
						Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, right)
			prev = row
			prev_up = up
		_body(faces, "gravel" if r["kind"] == "gravel" else "asphalt", "Runoff_%s_%d" % [r["turn"], idx])
		idx += 1

# ------------------------------------------------------------------------- barriers
func _build_barriers() -> void:
	var n := _data.points.size()
	var stride := maxi(1, wall_row_stride)
	var armco: Dictionary = _prof["armco"]
	var conc: Dictionary = _prof["concrete"]
	var beam_full: Array = armco["beam"]
	var beam: Array = []
	for j in range(0, beam_full.size(), 3):
		beam.append(beam_full[j])
	if beam[-1] != beam_full[-1]:
		beam.append(beam_full[-1])
	var section: Array = conc["section"]
	var fence: Dictionary = conc["fence"]
	var post_xf := {}    # chunk -> Array[Transform3D]
	var fpost_xf := {}
	var col_faces := {}  # chunk -> PackedVector3Array
	for side: float in [-1.0, 1.0]:
		# Barrier line points, outward directions and types.
		var pts: Array[Vector3] = []
		var outs: Array[Vector3] = []
		var ss: PackedFloat32Array = []
		var snaps: PackedFloat32Array = []
		for i in range(0, n, stride):
			var s := i * _data.step
			var xf := frame_at(s)
			var rh := Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized() * side
			var p := lateral_point(s, side, barrier_offset(s, side), xf)
			var sn := _snap(p, Vector3.UP, false, 3.0, 4.0)
			pts.append(p)
			outs.append(rh)
			ss.append(s)
			snaps.append(0.0 if is_nan(sn) else sn)
		var m := pts.size()
		var post_next := 0.0    # distance into the next segment where the next post goes
		var fence_next := 0.0
		for i in m:   # smooth the ground snap so the wall top runs evenly
			var acc := 0.0
			for k in range(-2, 3):
				acc += snaps[(i + k + m) % m]
			pts[i].y += acc / 5.0
		for i in m:
			var j := (i + 1) % m
			if _pair_skip(i * stride, (j * stride) % n, side):
				continue   # the other carriageway of a pair builds the wall between the two
			var s := ss[i]
			var s1 := ss[j] if j > 0 else _data.length
			var ch := _chunk(s)
			var a := pts[i]
			var b := pts[j]
			var oa := outs[i]
			var ob := outs[j]
			# A bridge deck has a concrete parapet with a fence, whatever the layout says.
			var concrete := layout.is_concrete(s) or (_road is RoadSurface and (_road as RoadSurface).on_bridge(s))
			var colp: Dictionary = conc["collision"] if concrete else armco["collision"]
			if concrete:
				var st := _st(ch, Mat.CONCRETE)
				var cu := 0.0
				var ch2 := 0.0
				for q: Array in section:
					cu += float(q[0]) / section.size()
					ch2 += float(q[1]) / section.size()
				for q in section.size():
					var p0: Array = section[q]
					var p1: Array = section[(q + 1) % section.size()]
					if float(p0[1]) < -0.5 and float(p1[1]) < -0.5:
						continue   # buried bottom face
					var mu := (float(p0[0]) + float(p1[0])) * 0.5 - cu
					var mh := (float(p0[1]) + float(p1[1])) * 0.5 - ch2
					_quad(st, _wp(a, oa, p0), _wp(a, oa, p1), _wp(b, ob, p1), _wp(b, ob, p0),
							Vector2(s, p0[1]), Vector2(s, p1[1]), Vector2(s1, p1[1]), Vector2(s1, p0[1]),
							oa * mu + Vector3.UP * mh)
				var fu: float = fence["u"]
				var fb: float = fence["bottom"]
				var ft: float = fence["top"]
				_quad(_st(ch, Mat.FENCE), _wp(a, oa, [fu, fb]), _wp(a, oa, [fu, ft]),
						_wp(b, ob, [fu, ft]), _wp(b, ob, [fu, fb]),
						Vector2(s, fb) / 0.8, Vector2(s, ft) / 0.8,
						Vector2(s1, ft) / 0.8, Vector2(s1, fb) / 0.8, -oa)
				var fy := (fb + ft) * 0.5
				fence_next = _place_posts(fpost_xf, ch, a, b, oa, float(fence["post_spacing"]), fence_next,
						Vector3(fu, fy, 0.0))
			else:
				var st := _st(ch, Mat.BEAM)
				for q in beam.size() - 1:
					var p0: Array = beam[q]
					var p1: Array = beam[q + 1]
					_quad(st, _wp(a, oa, p0), _wp(a, oa, p1), _wp(b, ob, p1), _wp(b, ob, p0),
							Vector2(s, p0[1]), Vector2(s, p1[1]), Vector2(s1, p1[1]), Vector2(s1, p0[1]), -oa)
				post_next = _place_posts(post_xf, ch, a, b, oa, float(armco["post"]["spacing"]), post_next,
						Vector3.ZERO)
			# Collision: a closed-top slab from u0 to u1, bottom to top.
			if not col_faces.has(ch):
				col_faces[ch] = PackedVector3Array()
			var u0: float = colp["u0"]
			var u1: float = colp["u1"]
			var lo: float = colp["bottom"]
			var hi: float = colp["top"]
			var f: PackedVector3Array = col_faces[ch]
			# Overlap neighbouring segments by 5 cm so nothing slips through a shared edge.
			var ov := (b - a).normalized() * 0.05
			var ca := a - ov
			var cb := b + ov
			_faces_quad(f, _wp(ca, oa, [u0, lo]), _wp(ca, oa, [u0, hi]), _wp(cb, ob, [u0, hi]), _wp(cb, ob, [u0, lo]))
			_faces_quad(f, _wp(ca, oa, [u0, hi]), _wp(ca, oa, [u1, hi]), _wp(cb, ob, [u1, hi]), _wp(cb, ob, [u0, hi]))
			_faces_quad(f, _wp(ca, oa, [u1, hi]), _wp(ca, oa, [u1, lo]), _wp(cb, ob, [u1, lo]), _wp(cb, ob, [u1, hi]))
			col_faces[ch] = f
	for ch: int in col_faces:
		var body := _body(col_faces[ch], "asphalt", "Barrier_%02d" % ch)
		body.set_meta("barrier", true)
		body.add_to_group(&"trackside_barrier")
		body.collision_layer = 1 | LAYER_BARRIER
	var post_mesh := _post_mesh(armco["post"])
	var fpost_mesh := BoxMesh.new()
	var fs: float = fence["post_size"]
	fpost_mesh.size = Vector3(fs, float(fence["top"]) - float(fence["bottom"]), fs)
	fpost_mesh.material = _mats[Mat.BEAM]
	for pair: Array in [[post_xf, post_mesh, "Posts"], [fpost_xf, fpost_mesh, "FencePosts"]]:
		var by_chunk: Dictionary = pair[0]
		for ch: int in by_chunk:
			var xfs: Array = by_chunk[ch]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = pair[1]
			mm.instance_count = xfs.size()
			for q in xfs.size():
				mm.set_instance_transform(q, xfs[q])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_%02d" % [pair[2], ch]
			mmi.multimesh = mm
			add_child(mmi)

## Adds post transforms every `spacing` m along segment a-b (chunk `ch`). `next` is where the
## first post falls on this segment; returns the same for the following segment.
## `local` = post offset (u outward, h up, unused z).
static func _place_posts(out: Dictionary, ch: int, a: Vector3, b: Vector3, o: Vector3,
		spacing: float, next: float, local: Vector3) -> float:
	var seg_len := a.distance_to(b)
	if not out.has(ch):
		out[ch] = []
	var zb := o.cross(Vector3.UP).normalized()
	var d := next
	while d < seg_len:
		var p := a.lerp(b, d / seg_len) + o * local.x + Vector3.UP * local.y
		(out[ch] as Array).append(Transform3D(Basis(o, Vector3.UP, zb), p))
		d += maxf(spacing, 0.5)
	return d - seg_len

## Barrier profile point (u outward, h up) at line point p with horizontal outward dir o.
static func _wp(p: Vector3, o: Vector3, q: Array) -> Vector3:
	return p + o * float(q[0]) + Vector3.UP * float(q[1])

func _post_mesh(post: Dictionary) -> ArrayMesh:
	var fp: Array = post["footprint"]
	var poly := PackedVector2Array()
	for q: Array in fp:
		poly.append(Vector2(q[0], q[1]))
	var lo: float = post["bottom"]
	var hi: float = post["top"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_mats[Mat.BEAM])
	# Outward edge normals from the winding (the C-channel footprint is concave).
	var area2 := 0.0
	for q in poly.size():
		var p0 := poly[q]
		var p1 := poly[(q + 1) % poly.size()]
		area2 += p0.x * p1.y - p1.x * p0.y
	var wsign := 1.0 if area2 > 0.0 else -1.0
	for q in poly.size():
		var p0 := poly[q]
		var p1 := poly[(q + 1) % poly.size()]
		var dd := p1 - p0
		var nrm := Vector2(dd.y, -dd.x) * wsign
		_quad(st, Vector3(p0.x, lo, p0.y), Vector3(p1.x, lo, p1.y), Vector3(p1.x, hi, p1.y),
				Vector3(p0.x, hi, p0.y), Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
				Vector3(nrm.x, 0.0, nrm.y))
	var tris := Geometry2D.triangulate_polygon(poly)
	st.set_normal(Vector3.UP)
	for q in range(0, tris.size(), 3):
		var a := poly[tris[q]]
		var b := poly[tris[q + 1]]
		var c := poly[tris[q + 2]]
		var cr := (Vector3(b.x, hi, b.y) - Vector3(a.x, hi, a.y)).cross(Vector3(c.x, hi, c.y) - Vector3(a.x, hi, a.y))
		var order := [a, b, c] if cr.y < 0.0 else [a, c, b]
		for v: Vector2 in order:
			st.add_vertex(Vector3(v.x, hi, v.y))
	return st.commit()

# ------------------------------------------------------------------------- commit
func _commit_chunks() -> void:
	var by_chunk := {}
	for key: Vector2i in _tools:
		if not by_chunk.has(key.x):
			by_chunk[key.x] = []
		by_chunk[key.x].append(key)
	for ch: int in by_chunk:
		var mesh := ArrayMesh.new()
		var keys: Array = by_chunk[ch]
		keys.sort()
		for key: Vector2i in keys:
			(_tools[key] as SurfaceTool).commit(mesh)
		var mi := MeshInstance3D.new()
		mi.name = "Chunk_%02d" % ch
		mi.mesh = mesh
		add_child(mi)
	_tools.clear()
