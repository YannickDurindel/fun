extends Control
## HUD widgets of the simulation car, drawn left of the speedometer on two slanted plates:
##   left plate:  four tyres coloured by tread temperature (blue cold, green in the window,
##                red hot) with the wear in percent, flashing while a wheel is locked, and the
##                compound badge between them (S red, M yellow, H white, I green, W blue);
##   right plate: DRS light, ERS battery bar (amber while deploying, cyan while harvesting),
##                fuel in kg, and TC / ABS lights that come on while an aid is intervening.
## The HUD calls update_from(car, delta) every frame; the widget only redraws when something
## it shows has changed. Everything is read from the Car contract (and car.sim.state for the
## aids). Authored at 1080p and scaled by the HUD.

const FONT_BOLD := preload("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")
const FONT_SEMI := preload("res://assets/ui/fonts/BarlowCondensed-SemiBoldItalic.ttf")

const DESIGN_SIZE := Vector2(348.0, 232.0)
const TYRE_PLATE := Rect2(0.0, 0.0, 170.0, 232.0)
const INFO_PLATE := Rect2(160.0, 0.0, 188.0, 232.0)
const PLATE_SLANT: float = 14.0
const TYRE_SIZE := Vector2(34.0, 60.0)
## Top-left corner of each tyre shape (FL, FR, RL, RR) on the tyre plate.
const TYRE_POS: Array[Vector2] = [Vector2(39.0, 14.0), Vector2(107.0, 14.0), Vector2(31.0, 122.0), Vector2(99.0, 122.0)]

## Tread temperatures (deg C): below COLD_FULL fully blue, WINDOW_LO..WINDOW_HI green, above
## HOT_FULL fully red, blending in between.
const TEMP_COLD_FULL: float = 65.0
const TEMP_WINDOW_LO: float = 85.0
const TEMP_WINDOW_HI: float = 105.0
const TEMP_HOT_FULL: float = 125.0
## A driving aid counts as intervening when it changes the pedal by more than this.
const AID_THRESHOLD: float = 0.08
## Lights stay on at least this long so a one-tick intervention is still readable (s).
const AID_HOLD: float = 0.18
const LOCK_FLASH_HZ: float = 9.0
## Change of battery charge (1/s) that counts as deploying or harvesting.
const ERS_RATE_THRESHOLD: float = 0.004
const ERS_RATE_TAU: float = 0.25
## A change of charge this large in one frame is a reset (respawn, new lap), not a flow.
const ERS_JUMP: float = 0.05

const COL_PLATE := Color(0.03, 0.035, 0.05, 0.62)
const COL_ACCENT := Color(1, 1, 1, 0.22)
const COL_WHITE := Color(1, 1, 1, 1)
const COL_DIM := Color(1, 1, 1, 0.55)
const COL_OFF := Color(1, 1, 1, 0.10)
const COL_COLD := Color(0.24, 0.52, 1.0)
const COL_OK := Color(0.24, 0.88, 0.40)
const COL_HOT := Color(1.0, 0.22, 0.16)
const COL_LOCK := Color(1.0, 1.0, 1.0)
const COL_DRS := Color(0.25, 0.95, 0.38)
const COL_ERS := Color(1.0, 0.86, 0.2)
const COL_ERS_DEPLOY := Color(1.0, 0.55, 0.12)
const COL_ERS_HARVEST := Color(0.25, 0.9, 0.95)
const COL_TC := Color(1.0, 0.75, 0.15)
const COL_ABS := Color(1.0, 0.75, 0.15)
const COMPOUNDS := {
	&"soft": ["S", Color(1.0, 0.2, 0.18)],
	&"medium": ["M", Color(1.0, 0.86, 0.15)],
	&"hard": ["H", Color(0.95, 0.96, 0.98)],
	&"intermediate": ["I", Color(0.25, 0.85, 0.35)],
	&"wet": ["W", Color(0.22, 0.5, 1.0)],
}

# ---- what is shown (read by tests)
var ers_fraction: float = 1.0
## +1 deploying, -1 harvesting, 0 neither.
var ers_mode: int = 0
var drs_lit: bool = false
var fuel_text: String = ""
var compound_letter: String = "M"
var compound_color: Color = Color(1.0, 0.86, 0.15)
var tc_active: bool = false
var abs_active: bool = false

var _tyre_colors: PackedColorArray = PackedColorArray([COL_OK, COL_OK, COL_OK, COL_OK])
var _wear_pct: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
var _wear_text: PackedStringArray = PackedStringArray(["0%", "0%", "0%", "0%"])
var _locked: Array[bool] = [false, false, false, false]
var _lock_flash_on: bool = false
var _lock_clock: float = 0.0
var _ers_pct: int = 100
var _fuel_tenths: int = -1
var _compound: StringName = &""
var _prev_charge: float = -1.0
var _ers_rate: float = 0.0
var _tc_hold: float = 0.0
var _abs_hold: float = 0.0
var _num_font: FontVariation
var _small_font: FontVariation
var _poly: PackedVector2Array = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var _tyre_box: StyleBoxFlat = StyleBoxFlat.new()

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = DESIGN_SIZE
	_num_font = FontVariation.new()
	_num_font.base_font = FONT_BOLD
	_num_font.opentype_features = {"tnum": 1}
	_small_font = FontVariation.new()
	_small_font.base_font = FONT_SEMI
	_small_font.spacing_glyph = 1
	_tyre_box.set_corner_radius_all(9)
	_tyre_box.anti_aliasing = true

## Tread temperature to colour: blue cold, green in the working window, red hot.
static func temp_color(deg_c: float) -> Color:
	if deg_c < TEMP_WINDOW_LO:
		return COL_COLD.lerp(COL_OK, smoothstep(TEMP_COLD_FULL, TEMP_WINDOW_LO, deg_c))
	return COL_OK.lerp(COL_HOT, smoothstep(TEMP_WINDOW_HI, TEMP_HOT_FULL, deg_c))

func tyre_color(i: int) -> Color:
	return _tyre_colors[i]

func wear_text(i: int) -> String:
	return _wear_text[i]

func is_lock_flashing(i: int) -> bool:
	return _locked[i]

func ers_text() -> String:
	return "%d%%" % _ers_pct

## Reads the car and redraws if anything shown has changed.
func update_from(car: Car, delta: float) -> void:
	var dirty := false
	# Tyres.
	var any_locked := false
	for i in mini(4, car.wheels.size()):
		var w := car.wheels[i]
		var col := temp_color(w.temperature)
		var old := _tyre_colors[i]
		if absf(col.r - old.r) + absf(col.g - old.g) + absf(col.b - old.b) > 0.012:
			_tyre_colors[i] = col
			dirty = true
		var pct := clampi(roundi(w.wear * 100.0), 0, 100)
		if pct != _wear_pct[i]:
			_wear_pct[i] = pct
			_wear_text[i] = "%d%%" % pct
			dirty = true
		if w.locked != _locked[i]:
			_locked[i] = w.locked
			dirty = true
		any_locked = any_locked or w.locked
	if any_locked:
		_lock_clock = fmod(_lock_clock + delta * LOCK_FLASH_HZ, 2.0)
		var on := _lock_clock < 1.0
		if on != _lock_flash_on:
			_lock_flash_on = on
			dirty = true
	else:
		_lock_clock = 0.0
		_lock_flash_on = true   # a lock-up shows from its first frame
	if car.tyre_compound != _compound:
		_compound = car.tyre_compound
		var entry: Array = COMPOUNDS.get(_compound, [String(_compound).left(1).to_upper(), COL_WHITE])
		compound_letter = entry[0]
		compound_color = entry[1]
		dirty = true
	# Battery: level from the contract, deploy / harvest from which way it is moving.
	var charge := clampf(car.ers_charge, 0.0, 1.0)
	ers_fraction = charge
	if _prev_charge < 0.0 or absf(charge - _prev_charge) > ERS_JUMP:
		_ers_rate = 0.0
	elif delta > 0.0:
		_ers_rate = lerpf(_ers_rate, (charge - _prev_charge) / delta, 1.0 - exp(-delta / ERS_RATE_TAU))
	_prev_charge = charge
	var mode := 0
	if _ers_rate < -ERS_RATE_THRESHOLD:
		mode = 1
	elif _ers_rate > ERS_RATE_THRESHOLD:
		mode = -1
	var pct_ers := roundi(charge * 100.0)
	if mode != ers_mode or pct_ers != _ers_pct:
		ers_mode = mode
		_ers_pct = pct_ers
		dirty = true
	if car.drs_open != drs_lit:
		drs_lit = car.drs_open
		dirty = true
	var tenths := roundi(maxf(car.fuel_kg, 0.0) * 10.0)
	if tenths != _fuel_tenths:
		_fuel_tenths = tenths
		fuel_text = "%.1f" % (tenths / 10.0)
		dirty = true
	# Driving aids: lit while the aid holds the pedal back from what the driver asks.
	var tc := false
	var abs_on := false
	# (Not in reverse, where the brake pedal is the accelerator and nothing is being helped.)
	if car.sim != null and car.sim.state != null and car.gear >= 0:
		var st := car.sim.state
		tc = st.in_throttle - st.throttle > AID_THRESHOLD
		abs_on = st.in_brake - st.brake > AID_THRESHOLD
	_tc_hold = AID_HOLD if tc else maxf(_tc_hold - delta, 0.0)
	_abs_hold = AID_HOLD if abs_on else maxf(_abs_hold - delta, 0.0)
	if (_tc_hold > 0.0) != tc_active or (_abs_hold > 0.0) != abs_active:
		tc_active = _tc_hold > 0.0
		abs_active = _abs_hold > 0.0
		dirty = true
	if dirty:
		queue_redraw()

func _plate(r: Rect2, slant: float, color: Color) -> void:
	_poly[0] = Vector2(r.position.x + slant, r.position.y)
	_poly[1] = Vector2(r.end.x, r.position.y)
	_poly[2] = Vector2(r.end.x - slant, r.end.y)
	_poly[3] = Vector2(r.position.x, r.end.y)
	draw_colored_polygon(_poly, color)

func _text(font: Font, text: String, rect: Rect2, font_size: int, color: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> void:
	# draw_string positions the baseline; centre the cap height in the rect.
	var y := rect.position.y + rect.size.y * 0.5 + font.get_ascent(font_size) * 0.5 - font.get_descent(font_size) * 0.5
	draw_string(font, Vector2(rect.position.x, y), text, align, rect.size.x, font_size, color)

func _light(r: Rect2, label: String, lit: bool, color: Color) -> void:
	_plate(r, 7.0, Color(color, 0.92) if lit else COL_OFF)
	_text(_small_font, label, r, 21, Color(0.03, 0.04, 0.06) if lit else COL_DIM)

func _draw() -> void:
	# ---- tyres
	_plate(TYRE_PLATE, PLATE_SLANT, COL_PLATE)
	draw_line(Vector2(PLATE_SLANT * 0.15, TYRE_PLATE.end.y - 1.5),
			Vector2(TYRE_PLATE.end.x - PLATE_SLANT * 1.05, TYRE_PLATE.end.y - 1.5), COL_ACCENT, 3.0)
	for i in 4:
		var flashing := _locked[i] and _lock_flash_on
		_tyre_box.bg_color = COL_LOCK if flashing else _tyre_colors[i]
		var r := Rect2(TYRE_POS[i], TYRE_SIZE)
		draw_style_box(_tyre_box, r)
		_text(_num_font, _wear_text[i], Rect2(r.position.x - 14.0, r.end.y + 1.0, r.size.x + 28.0, 26.0), 22, COL_WHITE)
	# Compound badge between the four tyres.
	var badge := Vector2(85.0, 112.0)
	draw_circle(badge, 16.0, Color(0.03, 0.035, 0.05, 0.9))
	draw_arc(badge, 15.0, 0.0, TAU, 32, compound_color, 3.5, true)
	_text(_num_font, compound_letter, Rect2(badge.x - 16.0, badge.y - 15.0, 32.0, 28.0), 23, COL_WHITE)

	# ---- DRS, battery, fuel, aids
	_plate(INFO_PLATE, PLATE_SLANT, COL_PLATE)
	draw_line(Vector2(INFO_PLATE.position.x + PLATE_SLANT * 0.15, INFO_PLATE.end.y - 1.5),
			Vector2(INFO_PLATE.end.x - PLATE_SLANT * 1.05, INFO_PLATE.end.y - 1.5), COL_ACCENT, 3.0)
	var x0 := INFO_PLATE.position.x
	_light(Rect2(x0 + 30.0, 14.0, 134.0, 36.0), "DRS", drs_lit, COL_DRS)
	# Battery.
	var ers_col := COL_ERS
	var ers_label := "ERS"
	if ers_mode > 0:
		ers_col = COL_ERS_DEPLOY
	elif ers_mode < 0:
		ers_col = COL_ERS_HARVEST
	_text(_small_font, ers_label, Rect2(x0 + 26.0, 58.0, 60.0, 28.0), 22, COL_DIM, HORIZONTAL_ALIGNMENT_LEFT)
	_text(_num_font, ers_text(), Rect2(x0 + 86.0, 58.0, 72.0, 28.0), 25, COL_WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
	var bar := Rect2(x0 + 22.0, 90.0, 138.0, 16.0)
	_plate(bar, 5.0, COL_OFF)
	if ers_fraction > 0.005:
		_plate(Rect2(bar.position, Vector2(maxf(bar.size.x * ers_fraction, 7.0), bar.size.y)), 5.0, ers_col)
	# Fuel.
	_text(_small_font, "FUEL", Rect2(x0 + 19.0, 116.0, 60.0, 30.0), 22, COL_DIM, HORIZONTAL_ALIGNMENT_LEFT)
	_text(_num_font, fuel_text, Rect2(x0 + 66.0, 116.0, 62.0, 30.0), 27, COL_WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(_small_font, "KG", Rect2(x0 + 132.0, 118.0, 30.0, 30.0), 19, COL_DIM, HORIZONTAL_ALIGNMENT_LEFT)
	# Aids.
	_light(Rect2(x0 + 12.0, 164.0, 62.0, 34.0), "TC", tc_active, COL_TC)
	_light(Rect2(x0 + 78.0, 164.0, 72.0, 34.0), "ABS", abs_active, COL_ABS)
