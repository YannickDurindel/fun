class_name TelemetryOverlay
extends Control
## Debug HUD for tuning the simulation car: a g-g diagram with a fading trail, four tyre
## boxes (load bar coloured by slip, temperatures), the pedals and steering before and after
## the driving aids, and the power-unit and aero readouts. Reads `car.sim.state` only.
##
## Off by default. F3 toggles it; the `--telemetry` flag starts with it on. It never shows for
## an arcade car (car.sim == null). Instance scenes/ui/telemetry_overlay.tscn under the race
## scene's UI layer and set `car_path` (or leave it empty: the first Car in the scene is used).

const G: float = 9.81
## Authored at 1080p and scaled with the viewport height, like the HUD.
const REF_HEIGHT: float = 1080.0
const PANEL_POS := Vector2(28.0, 178.0)
const PANEL_SIZE := Vector2(468.0, 716.0)
## Outer edge of the g-g diagram (g).
const GG_MAX: float = 6.0
## Trail: one point every TRAIL_EVERY physics ticks, TRAIL_POINTS kept (2 s at 240 Hz).
const TRAIL_POINTS: int = 240
const TRAIL_EVERY: int = 2
## Frames between two searches for a car while the overlay is on without one.
const SEARCH_EVERY: int = 30
const WHEEL_NAMES: PackedStringArray = ["FL", "FR", "RL", "RR"]

const COL_PANEL := Color(0.03, 0.035, 0.05, 0.80)
const COL_FRAME := Color(1, 1, 1, 0.16)
const COL_GRID := Color(1, 1, 1, 0.22)
const COL_TEXT := Color(0.93, 0.95, 1.0)
const COL_DIM := Color(0.62, 0.66, 0.74)
const COL_ACCENT := Color(1.0, 0.78, 0.22)
const COL_OK := Color(0.35, 1.0, 0.55)
const COL_WARN := Color(1.0, 0.86, 0.25)
const COL_BAD := Color(1.0, 0.30, 0.25)
const COL_COLD := Color(0.40, 0.70, 1.0)
const COL_OFF := Color(0.35, 0.38, 0.45)

@export var car_path: NodePath
## Circle drawn in the accent colour on the g-g diagram (g): the grip you are tuning towards.
@export var reference_g: float = 5.0
## Full scale of a tyre's load bar (N).
@export var load_scale: float = 12000.0
## Tyre temperature colours: below `temp_cold` blue, above `temp_hot` red (deg C).
@export var temp_cold: float = 80.0
@export var temp_hot: float = 120.0

## Whether the player asked for the overlay (F3 / --telemetry). It is only visible when this
## is true AND the car runs the simulation model.
var enabled: bool = false:
	set(v):
		enabled = v
		_apply()

## Latest point of the g-g diagram: x = lateral g (+ = to the right), y = longitudinal g
## (+ = accelerating).
var gg: Vector2 = Vector2.ZERO

var _car: Car
var _trail: PackedVector2Array = []
var _trail_head: int = 0
var _trail_count: int = 0
var _tick: int = 0
var _search_wait: int = 0
var _k: float = 1.0
var _font: Font

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_trail.resize(TRAIL_POINTS)
	_font = get_theme_default_font()
	if _car == null and not car_path.is_empty():
		_car = get_node_or_null(car_path) as Car
	enabled = enabled or "--telemetry" in OS.get_cmdline_user_args()

## Points the overlay at a car (null detaches it).
func set_car(car: Car) -> void:
	_car = car
	_trail_count = 0
	_apply()

func get_car() -> Car:
	return _car

func toggle() -> void:
	enabled = not enabled

## Number of points currently in the g-g trail.
func trail_count() -> int:
	return _trail_count

func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F3:
		toggle()
		get_viewport().set_input_as_handled()

func _apply() -> void:
	if not is_inside_tree():
		return
	if enabled and _car == null:
		_car = _find_car(get_tree().current_scene if get_tree().current_scene != null else get_tree().root)
	visible = enabled and _car != null and is_instance_valid(_car) and _car.sim != null
	set_process(enabled)
	set_physics_process(visible)

func _find_car(node: Node) -> Car:
	if node is Car:
		return node as Car
	for child in node.get_children():
		var found := _find_car(child)
		if found != null:
			return found
	return null

func _physics_process(_delta: float) -> void:
	if _car == null or not is_instance_valid(_car) or _car.sim == null:
		return
	var s := _car.sim.state
	gg = Vector2(s.accel_lat, s.accel_long) / G
	_tick += 1
	if _tick >= TRAIL_EVERY:
		_tick = 0
		_trail[_trail_head] = gg
		_trail_head = (_trail_head + 1) % TRAIL_POINTS
		_trail_count = mini(_trail_count + 1, TRAIL_POINTS)

func _process(_delta: float) -> void:
	# The car may appear, be replaced or be freed after the overlay was switched on.
	if _car != null and not is_instance_valid(_car):
		_car = null
	var should := _car != null and _car.sim != null
	# With no car yet, look for one twice a second rather than walking the scene every frame.
	_search_wait -= 1
	if should != visible or (_car == null and _search_wait <= 0):
		_search_wait = SEARCH_EVERY
		_apply()
	if visible:
		queue_redraw()

## The text readouts, one per line (also what the panel prints).
func readout() -> PackedStringArray:
	var out := PackedStringArray()
	if _car == null or not is_instance_valid(_car) or _car.sim == null:
		return out
	var s := _car.sim.state
	var spec := _car.sim.spec
	var down := s.downforce_front + s.downforce_rear
	out.append("DOWNFORCE  %5.2f kN   front %2.0f %%" % [down / 1000.0, 100.0 * s.downforce_front / down if down > 1.0 else 0.0])
	out.append("DRAG       %5.2f kN   DRS %s" % [s.drag / 1000.0, "OPEN" if s.drs_open else "closed"])
	out.append("ERS  %3.0f %%  %4.2f MJ   FUEL %5.1f kg" % [
			100.0 * s.ers_energy / maxf(spec.ers_capacity, 1.0), s.ers_energy * 1.0e-6, s.fuel])
	out.append("MASS %4.0f kg   YAW %+6.1f deg/s   SLIP %+5.1f deg" % [s.mass, rad_to_deg(s.yaw_rate), rad_to_deg(s.body_slip)])
	out.append("RIDE  front %+5.1f mm   rear %+5.1f mm" % [
			-500.0 * (s.compression[0] + s.compression[1]), -500.0 * (s.compression[2] + s.compression[3])])
	return out

# ------------------------------------------------------------------------------ drawing

func _draw() -> void:
	if _car == null or not is_instance_valid(_car) or _car.sim == null:
		return
	var s := _car.sim.state
	var spec := _car.sim.spec
	_k = size.y / REF_HEIGHT if size.y > 0.0 else 1.0
	_box(Rect2(Vector2.ZERO, PANEL_SIZE), COL_PANEL, true)
	_box(Rect2(Vector2.ZERO, PANEL_SIZE), COL_FRAME, false)
	_text(Vector2(14, 24), "TELEMETRY", 17, COL_ACCENT)
	_text(Vector2(PANEL_SIZE.x - 150, 24), "F3 to hide", 14, COL_DIM)
	_draw_gg(Rect2(14, 36, 250, 250))
	_text(Vector2(14, 308), "LAT %+5.2f g   LONG %+5.2f g" % [gg.x, gg.y], 17, COL_TEXT)
	_draw_inputs(s, Rect2(284, 36, 170, 250))
	for i in 4:
		_draw_tyre(s, spec, i, Rect2(14.0 + (i % 2) * 224.0, 326.0 + (i / 2) * 128.0, 216, 120))
	var y := 604.0
	for line in readout():
		_text(Vector2(14, y), line, 16, COL_TEXT)
		y += 22.0

func _draw_gg(r: Rect2) -> void:
	var c := r.get_center()
	var radius := r.size.x * 0.5 - 6.0
	var per_g := radius / GG_MAX
	_box(r, Color(0, 0, 0, 0.35), true)
	for ring: float in [2.0, 4.0, GG_MAX]:
		_circle(c, ring * per_g, COL_GRID, 1.0)
		_text(c + Vector2(4, -ring * per_g + 15), "%d g" % int(ring), 12, COL_DIM)
	_circle(c, clampf(reference_g, 0.0, GG_MAX) * per_g, COL_ACCENT, 1.5)
	_line(c - Vector2(radius, 0), c + Vector2(radius, 0), COL_GRID, 1.0)
	_line(c - Vector2(0, radius), c + Vector2(0, radius), COL_GRID, 1.0)
	_text(Vector2(r.position.x + 6, r.position.y + 16), "ACCEL", 12, COL_DIM)
	_text(Vector2(r.position.x + 6, r.end.y - 6), "BRAKE", 12, COL_DIM)
	_text(Vector2(r.end.x - 42, c.y - 5), "RIGHT", 12, COL_DIM)
	# Oldest first, so the newest and brightest points are drawn on top.
	var prev := Vector2.ZERO
	for n in _trail_count:
		var p := _gg_point(c, per_g, _trail[(_trail_head - _trail_count + n + TRAIL_POINTS) % TRAIL_POINTS])
		if n > 0:
			var age := float(n) / _trail_count
			_line(prev, p, Color(COL_OK.r, COL_OK.g, COL_OK.b, 0.06 + 0.8 * age * age), 2.0)
		prev = p
	draw_circle(_at(_gg_point(c, per_g, gg)), 5.0 * _k, COL_TEXT)

## Screen position of an acceleration: right = lateral to the right, up = accelerating.
func _gg_point(c: Vector2, per_g: float, a: Vector2) -> Vector2:
	return c + Vector2(a.x, -a.y).limit_length(GG_MAX) * per_g

func _draw_inputs(s: SimState, r: Rect2) -> void:
	var bar_h := 124.0
	var top := r.position.y + 22.0
	_text(Vector2(r.position.x, r.position.y + 12), "THR", 13, COL_DIM)
	_text(Vector2(r.position.x + 44, r.position.y + 12), "BRK", 13, COL_DIM)
	_pedal(Rect2(r.position.x, top, 30, bar_h), s.in_throttle, s.throttle, COL_OK)
	_pedal(Rect2(r.position.x + 44, top, 30, bar_h), s.in_brake, s.brake, COL_BAD)
	# Gear, speed and revs beside the pedals.
	var gear := str(s.gear) if s.gear > 0 else ("R" if s.gear < 0 else "N")
	_text(Vector2(r.position.x + 92, top + 50), gear, 58, COL_TEXT)
	_text(Vector2(r.position.x + 92, top + 82), "%3.0f km/h" % (s.speed * 3.6), 18, COL_TEXT)
	_text(Vector2(r.position.x + 92, top + 106), "%5.0f rpm" % s.rpm, 15, COL_DIM)
	_text(Vector2(r.position.x + 92, top + 126), "shift" if s.shifting > 0.0 else "", 13, COL_ACCENT)
	# Steering: the driver's input as a bar from the centre, the wheel angle as text.
	var sy := top + bar_h + 52.0
	_text(Vector2(r.position.x, sy - 8), "STEER", 13, COL_DIM)
	var bar := Rect2(r.position.x, sy, r.size.x, 16)
	_box(bar, Color(0, 0, 0, 0.45), true)
	var half := bar.size.x * 0.5
	var w := clampf(s.in_steer, -1.0, 1.0) * half
	_box(Rect2(bar.position.x + half + minf(w, 0.0), bar.position.y, absf(w), bar.size.y), COL_TEXT, true)
	_box(bar, COL_FRAME, false)
	_line(Vector2(bar.position.x + half, bar.position.y - 3), Vector2(bar.position.x + half, bar.end.y + 3), COL_DIM, 1.0)
	_text(Vector2(r.position.x, sy + 36), "wheels %+5.1f deg" % rad_to_deg(-s.steer_angle), 15, COL_TEXT)

## A pedal: the outline bar is the driver's foot, the filled bar what the aids let through.
func _pedal(r: Rect2, raw: float, demand: float, col: Color) -> void:
	_box(r, Color(0, 0, 0, 0.45), true)
	var h := clampf(demand, 0.0, 1.0) * r.size.y
	_box(Rect2(r.position.x, r.end.y - h, r.size.x, h), col, true)
	var hr := clampf(raw, 0.0, 1.0) * r.size.y
	_box(Rect2(r.position.x, r.end.y - hr, r.size.x, hr), Color(col.r, col.g, col.b, 0.9), false)
	_box(r, COL_FRAME, false)
	_text(Vector2(r.position.x, r.end.y + 16), "%3.0f" % (demand * 100.0), 13, COL_TEXT)

func _draw_tyre(s: SimState, spec: CarSpec, i: int, r: Rect2) -> void:
	_box(r, Color(0, 0, 0, 0.35), true)
	_box(r, COL_FRAME, false)
	# How much of the tyre's grip is used: 1 = at the peak of its slip curve.
	var sx := s.slip_ratio[i] / maxf(spec.tyre_peak_slip_ratio, 1e-3)
	var sy := tan(s.slip_angle[i]) / maxf(tan(spec.tyre_peak_slip_angle), 1e-3)
	var use := sqrt(sx * sx + sy * sy)
	var col := COL_OFF
	if s.contact[i]:
		col = COL_OK.lerp(COL_WARN, clampf((use - 0.6) / 0.4, 0.0, 1.0)) if use < 1.0 \
				else COL_WARN.lerp(COL_BAD, clampf((use - 1.0) / 0.3, 0.0, 1.0))
	var bar := Rect2(r.position.x + 8, r.position.y + 8, 26, r.size.y - 16)
	_box(bar, Color(0, 0, 0, 0.5), true)
	var h := clampf(s.load[i] / maxf(load_scale, 1.0), 0.0, 1.0) * bar.size.y
	_box(Rect2(bar.position.x, bar.end.y - h, bar.size.x, h), col, true)
	_box(bar, COL_FRAME, false)
	var x := r.position.x + 44.0
	var y := r.position.y
	_text(Vector2(x, y + 24), WHEEL_NAMES[i], 18, COL_ACCENT)
	_text(Vector2(x + 34, y + 24), "%5.2f kN" % (s.load[i] / 1000.0), 18, COL_TEXT)
	var temp := s.tyre_temp[i]
	var tcol := COL_OK
	if temp < temp_cold:
		tcol = COL_COLD
	elif temp > temp_hot:
		tcol = COL_BAD
	_text(Vector2(x, y + 48), "tyre %3.0f C" % temp, 16, tcol)
	_text(Vector2(x, y + 70), "slip %+5.2f  %+5.1f deg" % [s.slip_ratio[i], rad_to_deg(s.slip_angle[i])], 15, col)
	_text(Vector2(x, y + 92), "brake %4.0f C" % s.brake_temp[i], 15, COL_DIM)
	if s.locked[i]:
		_text(Vector2(x, y + 112), "LOCKED", 15, COL_BAD)
	elif not s.contact[i]:
		_text(Vector2(x, y + 112), "IN THE AIR", 15, COL_DIM)
	else:
		_text(Vector2(x, y + 112), "grip used %3.0f %%" % (use * 100.0), 14, COL_DIM)

# Drawing helpers in panel units (1080p), placed and scaled to the viewport.
func _at(p: Vector2) -> Vector2:
	return (PANEL_POS + p) * _k

func _box(r: Rect2, col: Color, filled: bool) -> void:
	draw_rect(Rect2(_at(r.position), r.size * _k), col, filled, -1.0 if filled else maxf(1.0, _k))

func _line(a: Vector2, b: Vector2, col: Color, width: float) -> void:
	draw_line(_at(a), _at(b), col, maxf(1.0, width * _k), true)

func _circle(c: Vector2, radius: float, col: Color, width: float) -> void:
	if radius > 0.5:
		draw_arc(_at(c), radius * _k, 0.0, TAU, 64, col, maxf(1.0, width * _k), true)

func _text(p: Vector2, text: String, font_size: int, col: Color) -> void:
	if text != "":
		draw_string(_font, _at(p), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, maxi(8, roundi(font_size * _k)), col)
