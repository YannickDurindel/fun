class_name BotManager
extends Node3D
## AI opponents of a race (scenes/race/bots.tscn, node `Bots` of the race scene; group
## "bot_manager"). Reads Game.config.bots / bot_difficulty and does nothing with 0 bots.
##
##   * Spawns 1-7 full Cars (scenes/race/bot_car.tscn) on the grid slots behind the player
##     (slot k sits 8 m * k behind pole, alternating left / right, like the painted boxes),
##     each driven by its own BotDriver (an Autopilot in DIRECT mode) and with its own livery.
##   * Trackmania style: bots are ghosts for the player and for each other. Their bodies sit on
##     NO physics layer (so no ray or body of the player, the camera, the FX or another bot ever
##     hits them) and only mask the world; the player (who shares the world's layer) is excluded
##     explicitly. A bot close to the player or the camera is dithered out so it never blocks
##     the view.
##   * Follows the RaceManager: frozen during the countdown, released on race_started,
##     re-gridded on race_restarted. The RaceManager only knows the player; this node keeps
##     every car's progress and provides the live classification: get_standings().
##   * Keeps 7 extra cars cheap: brains think at 60 Hz, no audio / FX, bots away from the
##     camera drop their shadows and swap their animated wheels for one static mesh, and bots
##     far from the player are moved along their line ("on rails") instead of simulated.

signal bots_spawned

const BOT_CAR := preload("res://scenes/race/bot_car.tscn")

## Grid layout, matching assets/tracks/*/road_tarmac.gdshader and race_setup.gd.
const GRID_SPACING: float = 8.0
const GRID_LATERAL: float = 2.5
const POLE_OFFSET: float = 8.0
const MAX_BOTS: int = 7

## Physics ticks between two thinks of a bot brain / two standings updates (240 Hz / 4 = 60 Hz).
const THINK_EVERY: int = 4
## Gaps: every car stamps the race time when it first reaches each MARK metres of progress.
const MARK: float = 20.0
const MARK_OFFSET: float = 400.0       ## keeps mark indices positive behind the finish line
const GAP_MIN_SPEED: float = 15.0      ## m/s, for the distance-based fallback gap

## View: dither a bot out near the player (centre distance, m) and near the camera.
const FADE_NEAR: float = 3.0
const FADE_FAR: float = 7.5
const FADE_MIN_OPACITY: float = 0.3
const CAMERA_FADE_MIN: float = 1.2     ## fully dithered out closer than this to the camera (m)
const CAMERA_FADE_MAX: float = 5.0     ## opaque beyond this
const SHADOW_DISTANCE: float = 60.0    ## bots farther than this from the camera cast no shadow
## Farther than this from the camera a bot swaps its four animated wheel assemblies (14 nodes
## and a script each: most of a bot's per-tick cost) for one static mesh of four tyres.
const WHEEL_DETAIL_DISTANCE: float = 25.0
const NAME_TAG_DISTANCE: float = 70.0
const LOD_HYSTERESIS: float = 1.1
const UNSEEN_MARGIN: float = 3.0       ## m behind the camera plane before a car counts as unseen
const RAILS_RETURN: float = 0.8

## Fixed palette: one livery per bot slot (the player is blue / white / red).
const LIVERIES: Array[Dictionary] = [
	{"name": "VETTORI", "primary": Color(0.62, 0.02, 0.02), "secondary": Color(0.9, 0.9, 0.9), "accent": Color(0.95, 0.75, 0.05), "helmet": Color(0.9, 0.9, 0.92)},
	{"name": "HALLAM", "primary": Color(0.9, 0.33, 0.02), "secondary": Color(0.04, 0.2, 0.42), "accent": Color(0.04, 0.2, 0.42), "helmet": Color(0.1, 0.45, 0.9)},
	{"name": "OKABE", "primary": Color(0.0, 0.25, 0.1), "secondary": Color(0.85, 0.86, 0.82), "accent": Color(0.75, 0.9, 0.1), "helmet": Color(0.8, 0.95, 0.2)},
	{"name": "LINDQVIST", "primary": Color(0.5, 0.53, 0.56), "secondary": Color(0.04, 0.04, 0.05), "accent": Color(0.0, 0.7, 0.6), "helmet": Color(0.0, 0.75, 0.65)},
	{"name": "MORENO", "primary": Color(0.92, 0.72, 0.02), "secondary": Color(0.05, 0.05, 0.06), "accent": Color(0.05, 0.05, 0.06), "helmet": Color(0.9, 0.1, 0.1)},
	{"name": "DUBOIS", "primary": Color(0.85, 0.2, 0.5), "secondary": Color(0.9, 0.9, 0.92), "accent": Color(0.1, 0.35, 0.9), "helmet": Color(0.95, 0.5, 0.75)},
	{"name": "KOWAL", "primary": Color(0.03, 0.03, 0.035), "secondary": Color(0.7, 0.55, 0.18), "accent": Color(0.7, 0.55, 0.18), "helmet": Color(0.05, 0.05, 0.05)},
]
const PLAYER_NAME := "YOU"
const PLAYER_COLOR := Color(0.16, 0.45, 1.0)

@export var car_path: NodePath = ^"../Car"
## -1 = Game.config.bots / Game.config.bot_difficulty.
@export var bot_count: int = -1
@export var difficulty: int = -1
## Seed of the bots' personal variation (same seed = same race).
@export var variation_seed: int = 7
## A bot farther than this (m) from both the player and the camera is moved "on rails" along
## its line instead of simulated (see BotDriver.set_on_rails); it is simulated again within
## RAILS_RETURN of that distance. 0 = always simulate every bot.
@export var rails_distance: float = 35.0
## The same for a bot the camera cannot see (behind it): nothing shows there, so only the
## cars right around the player stay simulated.
@export var rails_distance_unseen: float = 8.0
## At most this many bots are simulated at once, the nearest ones (-1 = no cap). A Car costs
## about 0.2 ms per 240 Hz tick on the target CPU; on rails it costs a tenth of that.
@export var max_simulated: int = 2

## One classified car (the player or a bot).
class Entry:
	var name: String = ""
	var is_player: bool = false
	var index: int = 0                  ## grid slot (0 = pole = the player)
	var car: Car
	var driver: BotDriver
	var color: Color = Color.WHITE
	var progress: float = 0.0           ## laps * length + s
	var last_s: float = 0.0
	var times: PackedFloat32Array = []  ## race time at each MARK of progress (first passage)
	var finish_time: float = -1.0
	var rail_score: float = 0.0         ## distance used to pick the simulated bots
	# View state (bots only).
	var materials: Array[StandardMaterial3D] = []
	var meshes: Array[GeometryInstance3D] = []
	var wheels: Array[Node3D] = []
	var name_tag: Node3D
	var fade_max: float = -1.0
	var shadows: bool = true
	var far_wheels: MeshInstance3D      ## static stand-in for the four wheels
	var wheel_detail: bool = true       ## camera close enough for the real wheels
	var wheels_faded: bool = false      ## wheels hidden by the proximity fade

var bots: Array[Car] = []
var drivers: Array[BotDriver] = []
var player: Car
var track: Track
var race: RaceManager
## True between race_started and the next race_restarted.
var racing: bool = false
## Physics seconds since GO.
var race_time: float = 0.0

var _data: TrackData
var _entries: Array[Entry] = []
var _tick: int = 0

func _enter_tree() -> void:
	add_to_group(&"bot_manager")

func _exit_tree() -> void:
	# Wheels parked outside the tree by the LOD are not freed with their car.
	for e in _entries:
		for w in e.wheels:
			if is_instance_valid(w) and w.get_parent() == null:
				w.free()

func _ready() -> void:
	var n := clampi(bot_count if bot_count >= 0 else Game.config.bots, 0, MAX_BOTS)
	track = get_tree().get_first_node_in_group(&"track") as Track
	if n == 0 or track == null or track.data == null:
		set_process(false)
		set_physics_process(false)
		return
	_data = track.data
	player = get_node_or_null(car_path) as Car
	race = track.get_node_or_null(^"Race") as RaceManager
	if race == null:
		race = get_tree().get_first_node_in_group(&"race_manager") as RaceManager
	var level := difficulty if difficulty >= 0 else Game.config.bot_difficulty
	if player != null:
		var e := Entry.new()
		e.name = PLAYER_NAME
		e.is_player = true
		e.car = player
		e.color = PLAYER_COLOR
		_entries.append(e)
	for i in n:
		_spawn_bot(i, level)
	_regrid()
	if race != null:
		race.race_restarted.connect(_on_race_restarted)
		race.race_started.connect(_on_race_started)
		if race.car != null and race.state == RaceManager.State.RACING:
			_on_race_started()   # added to a race that is already running
	else:
		_on_race_started()       # no RaceManager: nothing to wait for
	bots_spawned.emit()

func bot_total() -> int:
	return bots.size()

# ================================================================ spawning
func _spawn_bot(i: int, level: int) -> void:
	var livery := LIVERIES[i % LIVERIES.size()]
	var car := BOT_CAR.instantiate() as Car
	car.name = "Bot%d" % (i + 1)
	add_child(car)
	# Ghost: on no layer (nothing detects it), masking the world only. The player lives on
	# the world's layer, so it is excluded from both the body and the wheel rays.
	car.collision_layer = 0
	if player != null:
		car.add_collision_exception_with(player)
		var ray := car.get(&"_ray") as PhysicsRayQueryParameters3D
		if ray != null:
			ray.exclude = [car.get_rid(), player.get_rid()]
	var driver := BotDriver.new()
	driver.name = "Driver"
	driver.configure(car, track, level, i, variation_seed)
	driver.think_every = THINK_EVERY
	driver.think_phase = i
	car.add_child(driver)
	driver.prepare()   # racing line + profile now (shared cache), not on the first racing tick
	bots.append(car)
	drivers.append(driver)
	var e := Entry.new()
	e.name = String(livery["name"])
	e.index = i + 1
	e.car = car
	e.driver = driver
	e.color = livery["primary"]
	_dress(e, livery)
	_entries.append(e)

## Gives the bot its own materials (livery colours + the proximity dither) and collects the
## nodes the view LOD touches.
func _dress(e: Entry, livery: Dictionary) -> void:
	var colours := {"Livery": "primary", "LiveryWhite": "secondary", "Accent": "accent", "Helmet": "helmet"}
	var body := e.car.get_node_or_null(^"BodyVisual")
	if body != null:
		for mi: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
			if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				e.meshes.append(mi)
			for surf in mi.mesh.get_surface_count() if mi.mesh != null else 0:
				var src := mi.get_active_material(surf) as StandardMaterial3D
				if src == null:
					continue
				var mat := src.duplicate() as StandardMaterial3D
				if colours.has(String(mi.name)):
					mat.albedo_color = livery[colours[String(mi.name)]]
				mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_DITHER
				mat.distance_fade_min_distance = CAMERA_FADE_MIN
				mat.distance_fade_max_distance = CAMERA_FADE_MAX
				mi.set_surface_override_material(surf, mat)
				e.materials.append(mat)
	for wheel_name: String in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		var w := e.car.get_node_or_null(wheel_name) as Node3D
		if w != null:
			e.wheels.append(w)
			for mi: MeshInstance3D in w.find_children("*", "MeshInstance3D", true, false):
				if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					e.meshes.append(mi)
	e.far_wheels = MeshInstance3D.new()
	e.far_wheels.name = "FarWheels"
	e.far_wheels.mesh = far_wheel_mesh()
	e.far_wheels.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	e.far_wheels.visible = false
	e.car.add_child(e.far_wheels)
	e.name_tag = e.car.get_node_or_null(^"NameTag") as Node3D
	var label := e.name_tag as Label3D
	if label != null:
		label.text = e.name
		label.outline_modulate = Color(e.color.darkened(0.55), 0.9)

# ================================================================ grid / race flow
## Race progress (laps * length + s) of a car standing at `s` before the start: a grid that
## straddles the finish line (s = 0) counts down into negative progress instead of wrapping
## to almost a full lap.
func _grid_progress(s: float) -> float:
	var d := _data.delta_s(_data.start_s, s)
	return _data.start_s + d if absf(d) < 2.0 * GRID_SPACING * (MAX_BOTS + 1) else s

## Grid slot of entry `index` (0 = pole): [progress, transform].
func grid_slot(index: int) -> Array:
	var pole_s := _data.start_s - POLE_OFFSET
	var pole_lateral := -GRID_LATERAL
	if race != null and race.car != null and player != null:
		pole_s = _data.closest_s(player.spawn_transform.origin)
	elif Bootstrap.spawn_s >= 0.0:
		pole_s = Bootstrap.spawn_s
	var p := _grid_progress(pole_s) - GRID_SPACING * index
	var lateral := pole_lateral if index % 2 == 0 else -pole_lateral
	return [p, track.spawn_transform(p, lateral)]

## Every bot back on its slot, frozen; progress and gaps reset.
func _regrid() -> void:
	racing = false
	race_time = 0.0
	_tick = 0
	for e in _entries:
		e.finish_time = -1.0
		e.times.clear()
		if e.is_player:
			e.last_s = _data.closest_s(e.car.global_position)
			e.progress = _grid_progress(e.last_s)
			continue
		var slot := grid_slot(e.index)
		var xf: Transform3D = slot[1]
		e.car.spawn_transform = xf
		e.car.respawn()
		e.car.simulate = false
		e.driver.reset_run(slot[0])
		e.last_s = _data.wrap_s(slot[0])
		e.progress = slot[0]
	for e in _entries:
		_stamp(e)

func _on_race_restarted() -> void:
	_regrid()

func _on_race_started() -> void:
	racing = true
	race_time = 0.0
	for e in _entries:
		if not e.is_player:
			e.car.simulate = true

# ================================================================ progress / standings
func _physics_process(delta: float) -> void:
	if not racing:
		return
	race_time += delta
	_tick += 1
	if _tick % THINK_EVERY != 0:
		return
	var target := race.target_laps if race != null else 0
	_update_rails(get_viewport().get_camera_3d() if rails_distance > 0.0 else null)
	for e in _entries:
		if e.is_player:
			var s := race.s if race != null and race.car == e.car else _data.closest_s(e.car.global_position, e.last_s)
			e.progress += _data.delta_s(e.last_s, s)
			e.last_s = s
		else:
			e.progress = e.driver.progress
		_stamp(e)
		if target > 0 and e.finish_time < 0.0:
			var laps := race.laps_completed if e.is_player and race.car == e.car else _laps(e)
			if laps >= target:
				e.finish_time = race_time

## Simulated near the player or the camera, on rails far from both or behind the camera, and
## never more than `max_simulated` at once (the nearest win).
func _update_rails(cam: Camera3D) -> void:
	if rails_distance <= 0.0 or (player == null and cam == null):
		for e in _entries:
			if not e.is_player:
				e.driver.set_on_rails(false)
		return
	var near: Array[Entry] = []
	for e in _entries:
		if e.is_player:
			continue
		var pos := e.car.global_position
		var d := INF
		var limit := rails_distance
		var seen := true
		if player != null:
			d = minf(d, pos.distance_to(player.global_position))
		if cam != null:
			d = minf(d, pos.distance_to(cam.global_position))
			seen = not cam.is_position_behind(pos)
			if rails_distance_unseen > 0.0 and not seen:
				limit = minf(limit, rails_distance_unseen)
		e.driver.rail_smooth = seen
		# Hysteresis: a simulated car keeps its place a little longer, in range and in rank.
		e.rail_score = d if e.driver.on_rails else d * RAILS_RETURN
		if e.rail_score < limit * RAILS_RETURN:
			near.append(e)
		else:
			e.driver.set_on_rails(true)
	near.sort_custom(func(a: Entry, b: Entry) -> bool: return a.rail_score < b.rail_score)
	for i in near.size():
		near[i].driver.set_on_rails(max_simulated >= 0 and i >= max_simulated)

func _speed(e: Entry) -> float:
	return e.driver.speed() if e.driver != null else e.car.linear_velocity.length()

func _laps(e: Entry) -> int:
	return maxi(0, int(floor(e.progress / _data.length)))

func _stamp(e: Entry) -> void:
	var idx := int((e.progress + MARK_OFFSET) / MARK)
	while e.times.size() <= idx:
		e.times.append(race_time)

## Race time when `e` first reached `progress` (-1 = it has not been there yet).
func _time_at(e: Entry, progress: float) -> float:
	var u := (progress + MARK_OFFSET) / MARK
	var i := int(u)
	if i < 0 or i + 1 >= e.times.size():
		return -1.0
	return lerpf(e.times[i], e.times[i + 1], u - i)

## Seconds `e` is behind `ahead`: how long ago `ahead` was where `e` is now.
func _gap(ahead: Entry, e: Entry) -> float:
	if ahead == e or not racing:
		return 0.0
	if ahead.finish_time >= 0.0 and e.finish_time >= 0.0:
		return maxf(0.0, e.finish_time - ahead.finish_time)
	var t := _time_at(ahead, e.progress)
	if t >= 0.0:
		return maxf(0.0, race_time - t)
	var v := maxf(_speed(e), GAP_MIN_SPEED)
	return maxf(0.0, ahead.progress - e.progress) / v

func _before(a: Entry, b: Entry) -> bool:
	var fa := a.finish_time >= 0.0
	var fb := b.finish_time >= 0.0
	if fa != fb:
		return fa
	if fa and a.finish_time != b.finish_time:
		return a.finish_time < b.finish_time
	if a.progress != b.progress:
		return a.progress > b.progress
	return a.index < b.index

## Live classification, leader first. One Dictionary per car:
##   position (1..), name, is_player, laps (completed), progress (m: laps * length + s),
##   gap (s behind the leader), interval (s behind the car ahead), finished, finish_time
##   (race seconds, -1 while racing), color (livery), speed_kmh, car (the Car node).
## In MODE_RACE a car that completed the race distance is classified by its finish time, ahead
## of everyone still racing. Empty when there are no bots.
func get_standings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _entries.is_empty() or bots.is_empty():
		return out
	var order := _entries.duplicate()
	order.sort_custom(_before)
	var leader: Entry = order[0]
	for i in order.size():
		var e: Entry = order[i]
		out.append({
			"position": i + 1,
			"name": e.name,
			"is_player": e.is_player,
			"laps": race.laps_completed if e.is_player and race != null and race.car == e.car else _laps(e),
			"progress": e.progress,
			"gap": _gap(leader, e),
			"interval": _gap(order[i - 1], e) if i > 0 else 0.0,
			"finished": e.finish_time >= 0.0,
			"finish_time": e.finish_time,
			"color": e.color,
			"speed_kmh": _speed(e) * Car.KMH,
			"car": e.car,
		})
	return out

## 1-based position of the player (0 without bots or without a player).
func player_position() -> int:
	for row in get_standings():
		if row["is_player"]:
			return row["position"]
	return 0

# ================================================================ view (fade + LOD)
func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var cam_forward := -cam.global_transform.basis.z
	var player_pos := player.global_position if player != null else Vector3.INF
	for e in _entries:
		if e.is_player:
			continue
		var pos := e.car.global_position
		var dc := cam_pos.distance_to(pos)
		var dp := player_pos.distance_to(pos) if player != null else INF
		_update_fade(e, dc, dp)
		# A car well behind the camera plane is never drawn: treat it as far away.
		var unseen := (pos - cam_pos).dot(cam_forward) < -UNSEEN_MARGIN
		_update_lod(e, INF if unseen else dc)

## Dithers the body out near the camera (always) and near the player: the fade range is
## stretched so the bot's pixels sit at ~`opacity` of it.
func _update_fade(e: Entry, dc: float, dp: float) -> void:
	var opacity := lerpf(FADE_MIN_OPACITY, 1.0, smoothstep(FADE_NEAR, FADE_FAR, dp))
	var ghosted := opacity < 0.999
	var fade_max := CAMERA_FADE_MAX
	if ghosted:
		fade_max = snappedf(maxf(CAMERA_FADE_MAX, dc / opacity), 0.25)
	if not is_equal_approx(fade_max, e.fade_max):
		e.fade_max = fade_max
		for m in e.materials:
			m.distance_fade_min_distance = 0.0 if ghosted else CAMERA_FADE_MIN
			m.distance_fade_max_distance = fade_max
	# The wheels keep their shared materials: they simply go when the body is mostly gone.
	var faded := opacity <= 0.6 or dc <= CAMERA_FADE_MAX * 0.7
	if faded != e.wheels_faded:
		e.wheels_faded = faded
		_show_wheels(e)
	if e.name_tag != null:
		e.name_tag.visible = not ghosted and dc < NAME_TAG_DISTANCE

func _update_lod(e: Entry, dc: float) -> void:
	var shadows := dc < (SHADOW_DISTANCE * LOD_HYSTERESIS if e.shadows else SHADOW_DISTANCE)
	if shadows != e.shadows:
		e.shadows = shadows
		var setting := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for mi in e.meshes:
			mi.cast_shadow = setting
	var detail := dc < (WHEEL_DETAIL_DISTANCE * LOD_HYSTERESIS if e.wheel_detail else WHEEL_DETAIL_DISTANCE)
	if detail != e.wheel_detail:
		e.wheel_detail = detail
		_show_wheels(e)

## Real wheels (visible, animated) near the camera, the static stand-in beyond, nothing while
## the bot is faded out. Hidden wheels stop processing.
func _show_wheels(e: Entry) -> void:
	var real := e.wheel_detail and not e.wheels_faded
	for w in e.wheels:
		# Out of the tree, not just hidden: 14 nodes per wheel would still follow the car.
		if real and w.get_parent() == null:
			e.car.add_child(w)
			w.reset_physics_interpolation()
		elif not real and w.get_parent() != null:
			e.car.remove_child(w)
	if e.far_wheels != null:
		e.far_wheels.visible = not e.wheel_detail and not e.wheels_faded

## One mesh with the four tyres at their rest positions (shared by every bot).
static var _far_wheel_mesh: ArrayMesh
static func far_wheel_mesh() -> ArrayMesh:
	if _far_wheel_mesh != null:
		return _far_wheel_mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in Car.WHEEL_OFFSETS.size():
		var front := i < 2
		var tyre := CylinderMesh.new()
		tyre.top_radius = Car.FRONT_WHEEL_RADIUS if front else Car.REAR_WHEEL_RADIUS
		tyre.bottom_radius = tyre.top_radius
		tyre.height = 0.31 if front else 0.38
		tyre.radial_segments = 12
		tyre.rings = 0
		# Cylinder axis (Y) along the axle (X); fronts sit lower by the radius difference.
		var at := Car.WHEEL_OFFSETS[i] + Vector3(0.0, tyre.top_radius - Car.REAR_WHEEL_RADIUS, 0.0)
		st.append_from(tyre, 0, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), at))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.035, 0.035, 0.04)
	mat.roughness = 0.85
	st.set_material(mat)
	_far_wheel_mesh = st.commit()
	return _far_wheel_mesh
