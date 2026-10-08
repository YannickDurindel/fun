class_name InputBindings
extends RefCounted
## The game's rebindable input actions: default table, (de)serialization, and the InputMap.
##
## Every action has three slots: two keyboard keys and one gamepad input (button or axis).
## Player changes live in Settings `controls/bindings` as  action -> [slot0, slot1, slot2],
## each slot a serialized event ({} = unbound). Actions missing there use the defaults.
##
##   InputBindings.apply()                      rebuild the InputMap (defaults + overrides)
##   InputBindings.rebind("brake", SLOT_KEY_1, event) / clear(action, slot) / reset_all()
##   InputBindings.find_conflict(event, "brake") -> other action using that input, or ""
##   InputBindings.event_label(event)           "↑", "W", "RT", "Ⓑ", "L-Stick ←"
##
## Only the actions listed in ACTIONS are touched: `ui_*` and anything registered elsewhere
## stay exactly as they are.

const SLOT_KEY_1 := 0
const SLOT_KEY_2 := 1
const SLOT_PAD := 2
const SLOT_COUNT := 3

## Dead zone of the non-analog actions when they are bound to a stick or trigger.
const DIGITAL_DEADZONE := 0.5
## Lowest dead zone given to the InputMap (0 would make a resting stick count as pressed).
const MIN_DEADZONE := 0.01

const SECTION := "controls"
const KEY := "bindings"

## Display order. Each entry: name, keys (physical keycodes, up to 2), pad (serialized event
## or {}), analog (strength matters: gets the gamepad dead zone).
const ACTIONS: Dictionary = {
	"accelerate": {"name": "ACCELERATE", "keys": [KEY_UP, KEY_W],
			"pad": {"t": "axis", "a": JOY_AXIS_TRIGGER_RIGHT, "s": 1}, "analog": true},
	"brake": {"name": "BRAKE / REVERSE", "keys": [KEY_DOWN, KEY_S],
			"pad": {"t": "axis", "a": JOY_AXIS_TRIGGER_LEFT, "s": 1}, "analog": true},
	"steer_left": {"name": "STEER LEFT", "keys": [KEY_LEFT, KEY_A],
			"pad": {"t": "axis", "a": JOY_AXIS_LEFT_X, "s": -1}, "analog": true},
	"steer_right": {"name": "STEER RIGHT", "keys": [KEY_RIGHT, KEY_D],
			"pad": {"t": "axis", "a": JOY_AXIS_LEFT_X, "s": 1}, "analog": true},
	"respawn": {"name": "RESPAWN", "keys": [KEY_BACKSPACE, KEY_ENTER],
			"pad": {"t": "btn", "b": JOY_BUTTON_B}, "analog": false},
	"restart": {"name": "RESTART RACE", "keys": [KEY_DELETE],
			"pad": {"t": "btn", "b": JOY_BUTTON_BACK}, "analog": false},
	"pause": {"name": "PAUSE", "keys": [KEY_ESCAPE],
			"pad": {"t": "btn", "b": JOY_BUTTON_START}, "analog": false},
	"camera_1": {"name": "CAMERA 1", "keys": [KEY_1], "pad": {}, "analog": false},
	"camera_2": {"name": "CAMERA 2", "keys": [KEY_2], "pad": {}, "analog": false},
	"camera_3": {"name": "CAMERA 3", "keys": [KEY_3], "pad": {}, "analog": false},
}

const _KEY_LABELS: Dictionary = {
	KEY_UP: "↑", KEY_DOWN: "↓", KEY_LEFT: "←", KEY_RIGHT: "→",
	KEY_SPACE: "SPACE", KEY_ENTER: "ENTER", KEY_KP_ENTER: "NUM ENTER", KEY_ESCAPE: "ESC",
	KEY_BACKSPACE: "BACKSPACE", KEY_DELETE: "DELETE", KEY_TAB: "TAB",
	KEY_SHIFT: "SHIFT", KEY_CTRL: "CTRL", KEY_ALT: "ALT",
}
## Display servers implementing keyboard_get_label_from_physical (others log an error).
const _LAYOUT_AWARE_DISPLAYS: Array[String] = ["X11", "Wayland", "Windows", "macOS"]
const _BUTTON_LABELS: Dictionary = {
	JOY_BUTTON_A: "Ⓐ", JOY_BUTTON_B: "Ⓑ", JOY_BUTTON_X: "Ⓧ", JOY_BUTTON_Y: "Ⓨ",
	JOY_BUTTON_BACK: "BACK", JOY_BUTTON_GUIDE: "GUIDE", JOY_BUTTON_START: "START",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3",
	JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_DPAD_UP: "D-Pad ↑", JOY_BUTTON_DPAD_DOWN: "D-Pad ↓",
	JOY_BUTTON_DPAD_LEFT: "D-Pad ←", JOY_BUTTON_DPAD_RIGHT: "D-Pad →",
}

# ---------------------------------------------------------------------------- table queries

static func actions() -> Array[String]:
	var out: Array[String] = []
	for a: String in ACTIONS:
		out.append(a)
	return out

static func has_action(action: String) -> bool:
	return ACTIONS.has(action)

static func display_name(action: String) -> String:
	return ACTIONS[action]["name"] if ACTIONS.has(action) else action.to_upper()

static func is_analog(action: String) -> bool:
	return ACTIONS.has(action) and ACTIONS[action]["analog"]

static func is_pad_slot(slot: int) -> bool:
	return slot == SLOT_PAD

## The three default slots of an action, serialized.
static func default_slots(action: String) -> Array:
	var out: Array = [{}, {}, {}]
	if not ACTIONS.has(action):
		return out
	var keys: Array = ACTIONS[action]["keys"]
	for i in mini(keys.size(), 2):
		out[i] = {"t": "key", "k": int(keys[i])}
	out[SLOT_PAD] = (ACTIONS[action]["pad"] as Dictionary).duplicate()
	return out

# ---------------------------------------------------------------------------- serialization

## InputEvent -> plain Dictionary ({} for null / unsupported events).
static func serialize(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var k := event as InputEventKey
		var code: int = k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		return {"t": "key", "k": code} if code != KEY_NONE else {}
	if event is InputEventJoypadButton:
		return {"t": "btn", "b": int((event as InputEventJoypadButton).button_index)}
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		return {"t": "axis", "a": int(m.axis), "s": -1 if m.axis_value < 0.0 else 1}
	return {}

## Plain Dictionary -> InputEvent (null when empty or malformed).
static func deserialize(data: Variant) -> InputEvent:
	if not (data is Dictionary):
		return null
	var d := data as Dictionary
	match str(d.get("t", "")):
		"key":
			var code := _int_of(d.get("k"))
			if code <= 0:
				return null
			var k := InputEventKey.new()
			k.physical_keycode = code as Key
			return k
		"btn":
			var idx := _int_of(d.get("b"))
			if idx < 0 or idx >= JOY_BUTTON_MAX:
				return null
			var b := InputEventJoypadButton.new()
			b.button_index = idx as JoyButton
			return b
		"axis":
			var axis := _int_of(d.get("a"))
			if axis < 0 or axis >= JOY_AXIS_MAX:
				return null
			var m := InputEventJoypadMotion.new()
			m.axis = axis as JoyAxis
			m.axis_value = -1.0 if _int_of(d.get("s", 1)) < 0 else 1.0
			return m
	return null

static func _int_of(v: Variant) -> int:
	return int(v) if (v is int or v is float) else -1

## True when both events are the same physical input (key / button / axis direction).
static func same_event(a: InputEvent, b: InputEvent) -> bool:
	if a == null or b == null:
		return false
	var sa := serialize(a)
	return not sa.is_empty() and sa == serialize(b)

static func is_pad_event(event: InputEvent) -> bool:
	return event is InputEventJoypadButton or event is InputEventJoypadMotion

# ---------------------------------------------------------------------------- current bindings

## Serialized slots of an action: the player's override if valid, else the defaults.
static func slots_in(overrides: Dictionary, action: String) -> Array:
	var out := default_slots(action)
	var raw: Variant = overrides.get(action)
	if raw is Array and (raw as Array).size() == SLOT_COUNT:
		for i in SLOT_COUNT:
			var ev := deserialize((raw as Array)[i])
			# Keys only in the key slots, pad inputs only in the pad slot.
			if ev != null and is_pad_event(ev) != is_pad_slot(i):
				ev = null
			out[i] = serialize(ev)
	return out

## The player's overrides as stored in Settings (never mutate the returned Dictionary).
static func stored() -> Dictionary:
	var v: Variant = Settings.get_value(SECTION, KEY)
	return v if v is Dictionary else {}

## Event bound to a slot, or null.
static func get_event(action: String, slot: int) -> InputEvent:
	if not ACTIONS.has(action) or slot < 0 or slot >= SLOT_COUNT:
		return null
	return deserialize(slots_in(stored(), action)[slot])

## All three slots of an action (null = unbound).
static func get_events(action: String) -> Array[InputEvent]:
	var out: Array[InputEvent] = []
	for s: Variant in slots_in(stored(), action):
		out.append(deserialize(s))
	return out

## [action, slot] of the binding using this input, or [] if it is free.
## `except_action` is skipped entirely.
static func find_binding(event: InputEvent, except_action: String = "") -> Array:
	var wanted := serialize(event)
	if wanted.is_empty():
		return []
	var ov := stored()
	for action: String in ACTIONS:
		if action == except_action:
			continue
		var slots := slots_in(ov, action)
		for i in SLOT_COUNT:
			if slots[i] == wanted:
				return [action, i]
	return []

## Name of another action already using this input ("" = no conflict).
static func find_conflict(event: InputEvent, except_action: String = "") -> String:
	var hit := find_binding(event, except_action)
	return "" if hit.is_empty() else str(hit[0])

static func is_default() -> bool:
	var ov := stored()
	for action: String in ACTIONS:
		if slots_in(ov, action) != default_slots(action):
			return false
	return true

# ---------------------------------------------------------------------------- changes

## Binds `event` to a slot (keys go in the key slots, pad inputs in SLOT_PAD) and applies.
## A duplicate of the same input in another slot of this action is removed.
## Conflicts with other actions are NOT resolved here: see find_conflict() / swap().
static func rebind(action: String, slot: int, event: InputEvent) -> bool:
	var data := serialize(event)
	if not ACTIONS.has(action) or slot < 0 or slot >= SLOT_COUNT or data.is_empty():
		return false
	if is_pad_event(event) != is_pad_slot(slot):
		return false
	var slots := slots_in(stored(), action)
	for i in SLOT_COUNT:
		if i != slot and slots[i] == data:
			slots[i] = {}
	slots[slot] = data
	_store(action, slots)
	return true

## Unbinds a slot.
static func clear(action: String, slot: int) -> void:
	if not ACTIONS.has(action) or slot < 0 or slot >= SLOT_COUNT:
		return
	var slots := slots_in(stored(), action)
	slots[slot] = {}
	_store(action, slots)

## Binds `event` to (action, slot); the binding that used it gets this slot's old input
## instead (when it fits that slot's device, otherwise it is left unbound).
static func swap(action: String, slot: int, event: InputEvent) -> bool:
	var other := find_binding(event, action)
	var previous := get_event(action, slot)
	if not rebind(action, slot, event):
		return false
	if not other.is_empty():
		var o_action: String = other[0]
		var o_slot: int = other[1]
		if previous != null and is_pad_event(previous) == is_pad_slot(o_slot) \
				and find_binding(previous).is_empty():
			rebind(o_action, o_slot, previous)
		else:
			clear(o_action, o_slot)
	return true

## Back to the default table.
static func reset_all() -> void:
	Settings.set_value(SECTION, KEY, {})
	apply()

static func _store(action: String, slots: Array) -> void:
	var ov := stored().duplicate(true)
	if slots == default_slots(action):
		ov.erase(action)
	else:
		ov[action] = slots
	Settings.set_value(SECTION, KEY, ov)
	apply()

# ---------------------------------------------------------------------------- InputMap

## Rebuilds the InputMap of the game actions from the defaults plus the saved overrides.
static func apply() -> void:
	apply_overrides(stored(), float(Settings.get_value(SECTION, "gamepad_deadzone")))

## Same, from explicit values (used at boot before Settings is loaded).
static func apply_overrides(overrides: Dictionary, analog_deadzone: float = 0.15) -> void:
	var dz := clampf(analog_deadzone, MIN_DEADZONE, 0.95)
	for action: String in ACTIONS:
		var deadzone := dz if is_analog(action) else DIGITAL_DEADZONE
		if InputMap.has_action(action):
			InputMap.action_erase_events(action)
			InputMap.action_set_deadzone(action, deadzone)
		else:
			InputMap.add_action(action, deadzone)
		for s: Variant in slots_in(overrides, action):
			var ev := deserialize(s)
			if ev != null:
				if is_pad_event(ev):
					ev.device = -1   # any gamepad
				InputMap.action_add_event(action, ev)

# ---------------------------------------------------------------------------- labels

## Short human-readable name of an input ("—" when unbound).
static func event_label(event: InputEvent) -> String:
	if event is InputEventKey:
		var k := event as InputEventKey
		var code: Key = k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if _KEY_LABELS.has(code):
			return _KEY_LABELS[code]
		# Show what is printed on the player's keyboard layout (AZERTY: W position = Z).
		var local: Key = code
		if k.physical_keycode != KEY_NONE and DisplayServer.get_name() in _LAYOUT_AWARE_DISPLAYS:
			var l := DisplayServer.keyboard_get_label_from_physical(code)
			if l != KEY_NONE:
				local = l
		if _KEY_LABELS.has(local):
			return _KEY_LABELS[local]
		if code >= KEY_0 and code <= KEY_9:
			return char(code)   # the number row reads 1..9 on every layout
		if local > KEY_SPACE and local < 0x100:
			return char(local).to_upper()   # punctuation: ";" rather than "Semicolon"
		var text := OS.get_keycode_string(local)
		if text.is_empty():
			text = OS.get_keycode_string(code)
		return text.to_upper() if not text.is_empty() else "KEY %d" % code
	if event is InputEventJoypadButton:
		var idx := (event as InputEventJoypadButton).button_index
		return _BUTTON_LABELS[idx] if _BUTTON_LABELS.has(idx) else "BUTTON %d" % idx
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		var neg := m.axis_value < 0.0
		match m.axis:
			JOY_AXIS_TRIGGER_LEFT: return "LT"
			JOY_AXIS_TRIGGER_RIGHT: return "RT"
			JOY_AXIS_LEFT_X: return "L-Stick ←" if neg else "L-Stick →"
			JOY_AXIS_LEFT_Y: return "L-Stick ↑" if neg else "L-Stick ↓"
			JOY_AXIS_RIGHT_X: return "R-Stick ←" if neg else "R-Stick →"
			JOY_AXIS_RIGHT_Y: return "R-Stick ↑" if neg else "R-Stick ↓"
		return "AXIS %d %s" % [m.axis, "-" if neg else "+"]
	return "—"

## Label of what is bound to a slot.
static func slot_label(action: String, slot: int) -> String:
	return event_label(get_event(action, slot))
