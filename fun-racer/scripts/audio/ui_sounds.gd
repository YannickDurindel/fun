extends Node
## Autoload `UISounds`: short menu sounds, synthesised in code (no samples on disk).
##   UISounds.play(&"focus")       soft tick when the focus moves
##   UISounds.play(&"accept")      confirm
##   UISounds.play(&"back")        cancel / go back
##   UISounds.play(&"error")       locked or disabled item
##   UISounds.play(&"start_race")  bigger whoosh when a race starts loading
## Streams are synthesised on first use. Hooked up globally, so screens need no sound code:
##   * every BaseButton entering the tree: `pressed` -> accept (back for a "BACK" button),
##     mouse hover -> focus;
##   * the viewport's gui_focus_changed -> focus, except the first focus of a screen;
##   * ui_cancel while a menu or overlay has the focus -> back; ui_accept or a click on a
##     disabled button -> error;
##   * Game.race_loading -> start_race.
## The hooks only fire for controls that are visible, so nothing plays while racing unless an
## overlay (pause, results) has the focus. play() itself always plays.
## Volume: the `UI` audio bus when the project has one (its volume follows Settings audio/ui),
## otherwise `Master` with Settings audio/ui applied here.

## Emitted for every sound that is actually started (also the test hook).
signal played(sound: StringName)

const AudioLoops := preload("res://scripts/audio/audio_loops.gd")
const RATE: int = 44100
const PEAK: float = 0.7
const SOUNDS: Array[StringName] = [&"focus", &"accept", &"back", &"error", &"start_race"]
## Mix levels: these sit under the engine in the pause menu.
const LEVEL_DB: Dictionary = {
	&"focus": -19.0, &"accept": -14.0, &"back": -14.0, &"error": -13.0, &"start_race": -10.0,
}
const VOICES: int = 4
## After a screen change the next focus (the screen's initial focus) is silent, for this long.
const SCREEN_CHANGE_QUIET_MS: int = 250
## A focus tick never lands on top of another sound.
const FOCUS_GAP_MS: int = 45

## Turns the automatic hooks off (explicit play() still works).
var hooks_enabled: bool = true

var _streams: Dictionary = {}          # StringName -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _player_sound: Array[StringName] = []
var _next_voice: int = 0
var _last_focus_id: int = 0
var _quiet_until_ms: int = 0
var _skip_next_focus: bool = false
var _last_play_ms: int = -1000
var _start_frame: int = -1
var _accept_frame: int = -1

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
		_player_sound.append(&"")
	get_tree().node_added.connect(_on_node_added)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	var game := get_node_or_null(^"/root/Game")
	if game != null and game.has_signal(&"race_loading"):
		game.connect(&"race_loading", func(_track: Variant) -> void: play(&"start_race"))

## The stream of a sound (null for an unknown name). Synthesised on first use, then cached.
func stream(sound: StringName) -> AudioStreamWAV:
	if not _streams.has(sound):
		if not SOUNDS.has(sound):
			return null
		_streams[sound] = AudioLoops.to_wav(_synth(sound), 1.0, RATE, false)
	return _streams[sound] as AudioStreamWAV

func play(sound: StringName) -> void:
	if not SOUNDS.has(sound):
		push_warning("UISounds: unknown sound '%s'" % sound)
		return
	var frame := Engine.get_process_frames()
	# The race-start whoosh replaces the click of the button that started it.
	if sound == &"start_race":
		_start_frame = frame
		if _accept_frame == frame:
			for i in VOICES:
				if _player_sound[i] == &"accept":
					_players[i].stop()
	elif sound == &"accept":
		if _start_frame == frame:
			return
		_accept_frame = frame
	var gain_db: float = LEVEL_DB[sound]
	var bus := &"UI"
	if AudioServer.get_bus_index(bus) < 0:
		bus = &"Master"
		var ui: float = clampf(float(Settings.get_value("audio", "ui")), 0.0, 1.0)
		if ui <= 0.001:
			return
		gain_db += linear_to_db(ui)
	var p := _players[_next_voice]
	_player_sound[_next_voice] = sound
	_next_voice = (_next_voice + 1) % VOICES
	p.stream = stream(sound)
	p.bus = bus
	p.volume_db = gain_db
	p.play()
	_last_play_ms = Time.get_ticks_msec()
	played.emit(sound)

## Called by MenuRouter when it swaps the screen: the new screen's initial focus makes no sound.
## (Overlays need no call: a first focus coming from nothing is silent anyway.)
func screen_changed() -> void:
	_skip_next_focus = true
	_quiet_until_ms = Time.get_ticks_msec() + SCREEN_CHANGE_QUIET_MS

# ---------------------------------------------------------------------------- hooks

func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		var b := node as BaseButton
		if not b.has_meta(&"_ui_sounds"):   # a node can enter the tree more than once
			b.set_meta(&"_ui_sounds", true)
			b.pressed.connect(_on_button_pressed.bind(b))
			b.mouse_entered.connect(_on_button_hovered.bind(b))

func _on_button_pressed(b: BaseButton) -> void:
	# No visibility test: the screen's own handler may already have swapped the screen away.
	# A press that started a scene change is covered by the transition (and by start_race).
	if hooks_enabled and not _transition_busy():
		play(&"back" if _is_back_button(b) else &"accept")

func _on_button_hovered(b: BaseButton) -> void:
	if not hooks_enabled or b.disabled or b.has_focus() or not _active(b):
		return
	if Time.get_ticks_msec() < _quiet_until_ms:
		return
	_play_focus()

func _on_focus_changed(control: Control) -> void:
	var prev := instance_from_id(_last_focus_id) as Control if _last_focus_id != 0 else null
	_last_focus_id = control.get_instance_id() if control != null else 0
	var skip := _skip_next_focus and Time.get_ticks_msec() < _quiet_until_ms
	_skip_next_focus = false
	if not hooks_enabled or skip or control == null or not _active(control):
		return
	# Only a move from one visible control to another ticks: the first focus of a screen or an
	# overlay (nothing focused before, or the old screen is gone) is silent.
	if prev == null or not is_instance_valid(prev) or not prev.is_inside_tree() or not prev.is_visible_in_tree():
		return
	# A click focuses the button it presses; the press makes its own sound.
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	_play_focus()

func _play_focus() -> void:
	if Time.get_ticks_msec() - _last_play_ms >= FOCUS_GAP_MS:
		play(&"focus")

func _input(event: InputEvent) -> void:
	if not hooks_enabled or event.is_echo():
		return
	if event.is_action_pressed(&"ui_cancel"):
		var f := get_viewport().gui_get_focus_owner()
		if f == null or not _active(f):
			return
		var scene := get_tree().current_scene
		if scene is MenuRouter and not (scene as MenuRouter).can_go_back():
			return   # nothing to go back to on the first screen
		play(&"back")
	elif event.is_action_pressed(&"ui_accept"):
		var f := get_viewport().gui_get_focus_owner() as BaseButton
		if f != null and f.disabled and _active(f):
			play(&"error")
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var h := get_viewport().gui_get_hovered_control() as BaseButton
			if h != null and h.disabled and _active(h):
				play(&"error")

## True when `c` is on screen and no scene transition covers it.
func _active(c: Control) -> bool:
	if c == null or not c.is_inside_tree() or not c.is_visible_in_tree():
		return false
	return not _transition_busy()

func _transition_busy() -> bool:
	var tr := get_node_or_null(^"/root/Transitions")
	return tr != null and bool(tr.get(&"busy"))

static func _is_back_button(b: BaseButton) -> bool:
	var n := String(b.name).to_lower()
	if n == "back" or n == "backbutton" or n == "back_button" or n == "btnback":
		return true
	if b is Button:
		var t := (b as Button).text.strip_edges().to_lower().lstrip("<‹←« ")
		return t == "back" or t.begins_with("back ")
	return false

# ---------------------------------------------------------------------------- synthesis

## Mono samples of a sound, peak normalised to PEAK, with click-free ends.
static func _synth(sound: StringName) -> PackedFloat32Array:
	var data: PackedFloat32Array
	match sound:
		&"focus":
			data = _focus()
		&"accept":
			data = _two_notes(783.99, 1174.66)   # G5 -> D6, rising fifth
		&"back":
			data = _two_notes(659.26, 440.0)     # E5 -> A4, falling fifth
		&"error":
			data = _error()
		_:
			data = _start_race()
	var n := data.size()
	var edge := mini(int(RATE * 0.004), n >> 1)
	var peak := 0.0
	for i in n:
		if i < edge:
			data[i] *= float(i) / edge
		if i >= n - edge:
			data[i] *= float(n - 1 - i) / edge
		peak = maxf(peak, absf(data[i]))
	if peak > 0.0:
		var k := PEAK / peak
		for i in n:
			data[i] *= k
	return data

static func _buffer(seconds: float) -> PackedFloat32Array:
	var d := PackedFloat32Array()
	d.resize(int(RATE * seconds))
	return d

## A dry, soft tick: a quickly damped sine with a little air on top.
static func _focus() -> PackedFloat32Array:
	var d := _buffer(0.045)
	for i in d.size():
		var t := float(i) / RATE
		d[i] = sin(TAU * 1480.0 * t) * exp(-t / 0.007) + 0.3 * sin(TAU * 2960.0 * t) * exp(-t / 0.004)
	return d

## Two short bell-like notes, the second starting 55 ms after the first.
static func _two_notes(f1: float, f2: float) -> PackedFloat32Array:
	var d := _buffer(0.20)
	var gap := 0.055
	for i in d.size():
		var t := float(i) / RATE
		var s := _note(f1, t) * 0.8
		if t >= gap:
			s += _note(f2, t - gap)
		d[i] = s
	return d

static func _note(f: float, t: float) -> float:
	var attack := minf(t / 0.003, 1.0)
	return attack * exp(-t / 0.04) * (sin(TAU * f * t) + 0.22 * sin(TAU * 2.0 * f * t) + 0.08 * sin(TAU * 3.0 * f * t))

## Two dull low pulses: "no".
static func _error() -> PackedFloat32Array:
	var d := _buffer(0.21)
	var pulse := 0.075
	for i in d.size():
		var t := float(i) / RATE
		var local := fmod(t, 0.105)
		if local >= pulse:
			continue
		var env := sin(PI * local / pulse)
		var ph := TAU * 185.0 * local
		# Soft square (odd harmonics) with a touch of the octave so small speakers carry it.
		d[i] = env * (sin(ph) + 0.33 * sin(3.0 * ph) + 0.2 * sin(5.0 * ph) + 0.25 * sin(2.0 * ph))
	return d

## A rising filtered-noise whoosh that lands on an open fifth.
static func _start_race() -> PackedFloat32Array:
	var d := _buffer(0.75)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2468
	var lp := 0.0
	var lp2 := 0.0
	var hit := 0.30   # where the whoosh peaks and the chord lands
	for i in d.size():
		var t := float(i) / RATE
		# Low-pass cutoff sweeps 300 Hz -> 5 kHz up to the hit, then closes again.
		var x := clampf(t / hit, 0.0, 1.0)
		var cutoff := 300.0 * pow(5000.0 / 300.0, x * x) if t < hit else 5000.0 * exp(-(t - hit) / 0.12) + 300.0
		var a := 1.0 - exp(-TAU * cutoff / RATE)
		lp += a * (rng.randf_range(-1.0, 1.0) - lp)
		lp2 += a * (lp - lp2)
		var noise_env := x * x if t < hit else exp(-(t - hit) / 0.09)
		var s := 1.5 * lp2 * noise_env
		if t >= hit - 0.01:
			var tc := t - (hit - 0.01)
			var env := minf(tc / 0.008, 1.0) * exp(-tc / 0.16)
			s += env * (0.5 * sin(TAU * 392.0 * tc) + 0.4 * sin(TAU * 587.33 * tc) + 0.3 * sin(TAU * 783.99 * tc))
		d[i] = s
	return d
