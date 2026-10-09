extends Node
## Autoload `PhoneController`: the phone as the game's steering wheel and pedals.
##
## When `controls/phone_enabled` is on (it is OFF by default) the game listens on
## `controls/phone_port` and serves one web page (assets/phone/controller.html). The phone
## opens it over the local Wi-Fi, connects back with a WebSocket, sends the 4-digit pairing
## code shown in Options -> Controls, and then streams tilt, pedals and buttons about 60 times
## a second. Those values reach the car through `Bootstrap.external_input` like an analog
## gamepad. The same page is also served over HTTPS (self-signed, `controls/phone_https_port`,
## 0 = off) because iPhones only give motion sensors to secure pages.
##
## Safety:
##   * nothing listens until the player turns the option on, and it stops when turned off;
##   * no input is accepted before the right pairing code (anyone on the Wi-Fi could
##     otherwise drive); 5 wrong codes from a device lock that device out for a while;
##   * if no valid input arrives for 0.3 s every input is released (dropped connection);
##   * everything received is validated and clamped; malformed messages are ignored;
##   * the game only serves its own page: no internet access, no firewall or system change.
##
## Messages (JSON text):
##   phone -> game   {"t":"pair","c":"1234"}                       first message
##                   {"t":"in","s":steer,"th":throttle,"b":brake,"k":buttons,"n":sequence}
##                   {"t":"pg","x":number}                         ping, answered at once
##   game -> phone   {"t":"ok","deg":tilt_degrees}  /  {"t":"no","r":"code"|"locked","w":seconds}
##                   {"t":"st","sp":speed_kmh,"g":gear,"v":vibrate_ms,"a":last_sequence}  ~10 Hz
##                   {"t":"cfg","deg":tilt_degrees}  {"t":"po","x":number}  {"t":"bye","r":"replaced"}
##
## The WebSocket is implemented in PhoneConnection rather than with WebSocketPeer.accept_stream()
## because the page and the socket share one port: the request has to be read to know which
## of the two it is, and by then accept_stream() can no longer do its own handshake.
##
## Dev flag: --phone starts the server for this run without changing the saved option, and
## prints the port and the pairing code.

## Status, addresses, pairing code or errors changed (the Controls screen redraws).
signal state_changed

enum Status { OFF, WAITING, CONNECTED, ERROR }

const SECTION := "controls"
const PAGE_PATH := "res://assets/phone/controller.html"
## Bits of the "k" field. shift_up / shift_down / drs are polled by the car
## (Bootstrap.take_button / is_button_down); respawn and pause are injected as Input actions.
const BUTTONS: Dictionary = {&"shift_up": 1, &"shift_down": 2, &"drs": 4, &"respawn": 8, &"pause": 16, &"camera": 32}
const BUTTON_MASK := 63
const ACTION_BUTTONS: Array[StringName] = [&"respawn", &"pause"]
const INPUT_TIMEOUT_MS := 300        ## silence after which every input is released
const STATUS_INTERVAL_MS := 100
const ADDRESS_INTERVAL_MS := 2000    ## how often the network addresses are looked up again
const PRESS_LIFETIME_MS := 250       ## an unread one-shot press expires
const ACTION_HOLD_MS := 80           ## how long an injected action stays pressed
const PAIR_TIMEOUT_MS := 10000       ## a WebSocket that never pairs is closed
const MAX_CONNECTIONS := 12
const MAX_PER_ADDRESS := 4           ## so one device cannot take every connection slot
const MAX_FAILURES := 5
const LOCKOUT_BASE_S := 10.0
const LOCKOUT_MAX_S := 300.0
const MAX_GUARDS := 32               ## devices whose wrong codes are remembered
const MAX_SMOOTHING_TAU := 0.25      ## s, time constant at phone_smoothing = 1
const VIBRATE_SHIFT_MS := 30
const VIBRATE_KERB_MS := 45
## Interface name prefixes of containers, virtual machines and VPNs: listed last.
const VIRTUAL_INTERFACES: Array[String] = ["lo", "docker", "podman", "br-", "bridge", "cni", "veth", "vnet", "virbr",
		"vbox", "vmnet", "vethernet", "lxc", "tun", "utun", "tap", "wg", "tailscale", "zt", "ppp"]

var status: Status = Status.OFF
## Why the server could not start (status ERROR), for the Controls screen.
var error_text: String = ""
## Why HTTPS is not available although the plain port works ("" = fine or switched off).
var https_error: String = ""
## The 4 digits the phone must send first. New every time the server starts.
var pairing_code: String = ""
## Ports actually open (0 = closed). They can differ from the settings when those were taken.
var port: int = 0
var https_port: int = 0
## How many consecutive ports are tried when the wanted one is busy.
var port_attempts: int = 10
## A paired phone that sends nothing at all for this long is gone (it pings every second).
var paired_silence_ms: int = 5000

var _http: TCPServer
var _https: TCPServer
var _https_wanted: int = 0           # port to open once the certificate is ready (0 = none)
var _tls_options: TLSOptions
var _connections: Array[PhoneConnection] = []
var _phone: PhoneConnection
var _page: PackedByteArray = PackedByteArray()
var _addresses: PackedStringArray = PackedStringArray()
var _addresses_msec: int = 0
var _forced: bool = false            # --phone: running although the saved option is off
var _announce: bool = false          # --phone: print the ports and the code

var _steer_target: float = 0.0
var _steer: float = 0.0
var _throttle: float = 0.0
var _brake: float = 0.0
var _buttons: int = 0
var _presses: Dictionary = {}        # StringName -> msec of the press, until taken
var _held_actions: Dictionary = {}   # StringName -> msec the injected action was pressed
var _last_input_msec: int = -1000000
var _last_seq: float = -1.0
var _live: bool = false              # inputs currently non-released

## Wrong pairing codes per device: address -> {"f": failures, "n": lock-outs, "until": msec}.
var _guards: Dictionary = {}

var _tilt_degrees: float = 40.0
var _deadzone: float = 0.0
var _smoothing: float = 0.0
var _last_status_msec: int = 0
var _vibrate_ms: int = 0
var _last_gear: int = 0
var _last_car_id: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_read_tuning()
	Settings.changed.connect(_on_setting_changed)
	if OS.get_cmdline_user_args().has("--phone"):
		_forced = true
		_announce = true
		start()
		if status != Status.ERROR:
			print("PhoneController: http port %d, pairing code %s" % [port, pairing_code])
		else:
			print("PhoneController: not started: %s" % error_text)
	elif bool(Settings.get_value(SECTION, "phone_enabled")):
		start()

func _exit_tree() -> void:
	stop()
	PhoneTLS.finish()

## What the Controls switch shows: the saved option, or a server forced on by --phone.
func is_enabled() -> bool:
	return _forced or bool(Settings.get_value(SECTION, "phone_enabled"))

## Turns the option on or off (the Controls switch) and starts or stops the server.
func set_enabled(on: bool) -> void:
	_forced = false
	Settings.set_value(SECTION, "phone_enabled", on)   # starts / stops through `changed`
	if on and status == Status.OFF:
		start()
	elif not on and status != Status.OFF:
		stop()

func _on_setting_changed(section: String, key: String) -> void:
	if section != SECTION or not key.begins_with("phone_"):
		return
	_read_tuning()
	match key:
		"phone_enabled":
			if bool(Settings.get_value(SECTION, "phone_enabled")):
				start()
			elif not _forced:
				stop()
		"phone_port", "phone_https_port":
			if status != Status.OFF:
				start()
		"phone_tilt_degrees":
			if _phone != null:
				_phone.send_text('{"t":"cfg","deg":%.1f}' % _tilt_degrees)

func _read_tuning() -> void:
	_tilt_degrees = clampf(float(Settings.get_value(SECTION, "phone_tilt_degrees")), 15.0, 60.0)
	_deadzone = clampf(float(Settings.get_value(SECTION, "phone_deadzone")), 0.0, 0.5)
	_smoothing = clampf(float(Settings.get_value(SECTION, "phone_smoothing")), 0.0, 1.0)

# ---------------------------------------------------------------------------- server

func is_running() -> bool:
	return _http != null

## Opens the port(s) and makes a new pairing code. On failure `status` is ERROR and
## `error_text` says why.
func start() -> void:
	stop()
	error_text = ""
	https_error = ""
	var wanted := int(Settings.get_value(SECTION, "phone_port"))
	if wanted < 1024 or wanted > 65535:
		_fail("Port %d is not usable: choose one between 1024 and 65535." % wanted)
		return
	if not FileAccess.file_exists(PAGE_PATH):
		_fail("The controller page (%s) is missing from this build." % PAGE_PATH)
		return
	_http = TCPServer.new()
	port = _listen(_http, wanted, -1)
	if port == 0:
		_http = null
		_fail("Port %d could not be opened: another program is probably using it. Close that program, or set another phone_port." % wanted)
		return
	var random := Crypto.new().generate_random_bytes(4)
	pairing_code = "%04d" % (random.decode_u32(0) % 10000)
	_guards.clear()
	_addresses = lan_addresses()
	_addresses_msec = Time.get_ticks_msec()
	Bootstrap.external_input = self
	status = Status.WAITING
	_start_https(int(Settings.get_value(SECTION, "phone_https_port")))
	_build_page()
	state_changed.emit()

## Closes the ports and every connection, and releases all inputs.
func stop() -> void:
	var was := status
	for c in _connections:
		c.close(1001)
		c.abort()
	_connections.clear()
	_phone = null
	if _http != null:
		_http.stop()
		_http = null
	if _https != null:
		_https.stop()
		_https = null
	_https_wanted = 0
	port = 0
	https_port = 0
	pairing_code = ""
	_guards.clear()
	_addresses = PackedStringArray()
	_release_inputs()
	if Bootstrap.external_input == self:
		Bootstrap.external_input = null
	status = Status.OFF
	error_text = ""
	https_error = ""
	if was != Status.OFF:
		state_changed.emit()

func _fail(text: String) -> void:
	status = Status.ERROR
	error_text = text
	state_changed.emit()

## Listens on the first free port from `wanted` (skipping `avoid`). Returns it, or 0.
func _listen(server: TCPServer, wanted: int, avoid: int) -> int:
	for i in maxi(port_attempts, 1):
		var p := wanted + i
		if p > 65535:
			break
		if p != avoid and server.listen(p) == OK:
			return p
	return 0

## The page as served: the ports are written into it so it can link to the other address.
func _build_page() -> void:
	var secure_port := https_port if https_port > 0 else _https_wanted
	_page = FileAccess.get_file_as_string(PAGE_PATH).replace("__HTTPS_PORT__", str(secure_port)) \
			.replace("__HTTP_PORT__", str(port)).to_utf8_buffer()

func _start_https(wanted: int) -> void:
	if wanted == 0:
		return   # switched off
	if wanted < 1024 or wanted > 65535:
		https_error = "HTTPS port %d is not usable." % wanted
		return
	_https_wanted = wanted
	_poll_https()

## True while the certificate is being made; the HTTPS port opens when it is ready.
func is_https_pending() -> bool:
	return _https_wanted > 0

## Opens the HTTPS port as soon as the certificate exists (made on a worker thread the first
## time, so turning the option on never freezes the game).
func _poll_https() -> void:
	var options := PhoneTLS.request(Settings.persist and not Bootstrap.dev_run)
	if options == null:
		if PhoneTLS.failed():
			_https_wanted = 0
			https_error = "HTTPS is unavailable: the certificate could not be created."
			state_changed.emit()
		return
	var wanted := _https_wanted
	_https_wanted = 0
	_tls_options = options
	_https = TCPServer.new()
	https_port = _listen(_https, wanted, port)
	if https_port == 0:
		_https = null
		https_error = "HTTPS port %d could not be opened." % wanted
	elif _announce:
		print("PhoneController: https port %d" % https_port)
	_build_page()
	state_changed.emit()

# ---------------------------------------------------------------------------- addresses

## IPv4 addresses a phone on the same network can reach, most likely first: real private
## LAN addresses, then other ones, then virtual interfaces (containers, VPNs).
static func lan_addresses() -> PackedStringArray:
	var ranked: Array[Dictionary] = []
	for iface: Dictionary in IP.get_local_interfaces():
		var is_virtual := is_virtual_interface(str(iface.get("name", ""))) or is_virtual_interface(str(iface.get("friendly", "")))
		for addr: String in iface.get("addresses", []):
			var rank := address_rank(addr)
			if rank < 0:
				continue
			# The position keeps the order stable among equals (sort_custom is not).
			ranked.append({"a": addr, "r": (rank + (10 if is_virtual else 0)) * 1000 + ranked.size()})
	ranked.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return int(x["r"]) < int(y["r"]))
	var out := PackedStringArray()
	for e in ranked:
		if not out.has(str(e["a"])):
			out.append(str(e["a"]))
	return out

static func is_virtual_interface(iface_name: String) -> bool:
	var lower := iface_name.to_lower()
	for prefix in VIRTUAL_INTERFACES:
		if lower.begins_with(prefix):
			return true
	return false

## -1 = not usable (IPv6, loopback, link-local); lower is more likely the Wi-Fi address.
static func address_rank(addr: String) -> int:
	var parts := addr.split(".")
	if addr.contains(":") or parts.size() != 4:
		return -1
	var a := int(parts[0])
	var b := int(parts[1])
	if a == 127 or a == 0 or (a == 169 and b == 254):
		return -1
	if a == 192 and b == 168:
		return 0
	if a == 10:
		return 1
	if a == 172 and b >= 16 and b <= 31:
		return 2
	return 3

## "http://192.168.1.20:8080" for every candidate address ([] while the server is off).
func urls(secure: bool = false) -> PackedStringArray:
	var out := PackedStringArray()
	var p := https_port if secure else port
	if p == 0:
		return out
	for addr in _addresses:
		out.append("%s://%s:%d" % ["https" if secure else "http", addr, p])
	return out

## Seconds until the device locked out the longest may pair again (0 = nobody is locked).
func lockout_left() -> float:
	var until := 0
	for guard: Dictionary in _guards.values():
		until = maxi(until, int(guard["until"]))
	return maxf(0.0, float(until - Time.get_ticks_msec()) / 1000.0)

# ---------------------------------------------------------------------------- input source

## True while a paired phone is sending valid input (Bootstrap.external_input contract).
func is_active() -> bool:
	return _phone != null and Time.get_ticks_msec() - _last_input_msec <= INPUT_TIMEOUT_MS

func get_throttle() -> float:
	return _throttle if is_active() else 0.0

func get_brake() -> float:
	return _brake if is_active() else 0.0

## -1 = full left, +1 = full right, after the dead zone and smoothing.
func get_steer() -> float:
	return _steer if is_active() else 0.0

## True once per press of shift_up / shift_down / drs.
func take_button(button: StringName) -> bool:
	if not is_active() or not _presses.has(button):
		return false
	var fresh := Time.get_ticks_msec() - int(_presses[button]) <= PRESS_LIFETIME_MS
	_presses.erase(button)
	return fresh

func is_button_down(button: StringName) -> bool:
	return is_active() and (_buttons & int(BUTTONS.get(button, 0))) != 0

## Asks the phone to vibrate for `ms` with the next status message (kerbs, shifts, impacts).
func vibrate(ms: int) -> void:
	_vibrate_ms = clampi(maxi(_vibrate_ms, ms), 0, 400)

## Zeroes every input. `forget_buttons` false keeps the raw button state (the failsafe): a
## button still held when input resumes must not count as a new press.
func _release_inputs(forget_buttons: bool = true) -> void:
	_steer_target = 0.0
	_steer = 0.0
	_throttle = 0.0
	_brake = 0.0
	if forget_buttons:
		_buttons = 0
	_presses.clear()
	_live = false
	_last_input_msec = -1000000
	for action: StringName in _held_actions.keys():
		_send_action(action, false)
	_held_actions.clear()

func _send_action(action: StringName, pressed: bool) -> void:
	if not InputMap.has_action(action):
		return
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)

func _shape_steer(raw: float) -> float:
	var m := absf(raw)
	if m <= _deadzone:
		return 0.0
	return signf(raw) * clampf((m - _deadzone) / (1.0 - _deadzone), 0.0, 1.0)

# ---------------------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if _http == null:
		return
	var now := Time.get_ticks_msec()
	if _https_wanted > 0:
		_poll_https()
	if now - _addresses_msec >= ADDRESS_INTERVAL_MS:
		_addresses_msec = now
		var addresses := lan_addresses()
		if addresses != _addresses:
			_addresses = addresses
			state_changed.emit()
	_accept(_http, false)
	if _https != null:
		_accept(_https, true)
	for c in _connections:
		var messages := c.poll()
		if c.request_ready:
			_handle_request(c)
		for text in messages:
			if c.is_websocket():
				_handle_message(c, text)
		if c.is_websocket() and not c.paired and now - c.opened_msec > PAIR_TIMEOUT_MS:
			c.close(1008)
		elif c == _phone and c.is_websocket() and now - c.last_heard_msec > paired_silence_ms:
			c.abort()   # half-open socket: the phone left without saying so
	var phone_lost := false
	for i in range(_connections.size() - 1, -1, -1):
		var c := _connections[i]
		if not c.is_open() or (c == _phone and not c.is_websocket()):
			if c == _phone:
				phone_lost = true
			_connections.remove_at(i)
	if phone_lost:
		_phone = null
		_release_inputs()
		status = Status.WAITING
		state_changed.emit()
	# Failsafe: silence releases everything, even though the socket may still look open.
	if _live and not is_active():
		_release_inputs(false)
	if _live:
		var target := _shape_steer(_steer_target)
		if _smoothing <= 0.001:
			_steer = target
		else:
			_steer = lerpf(_steer, target, 1.0 - exp(-delta / (_smoothing * MAX_SMOOTHING_TAU)))
	for action: StringName in _held_actions.keys():
		if now - int(_held_actions[action]) >= ACTION_HOLD_MS:
			_send_action(action, false)
			_held_actions.erase(action)
	if _phone != null and now - _last_status_msec >= STATUS_INTERVAL_MS:
		_last_status_msec = now
		_send_status()

func _accept(server: TCPServer, secure: bool) -> void:
	while server.is_connection_available():
		var tcp := server.take_connection()
		if tcp == null:
			break
		var remote := tcp.get_connected_host()
		var from_same := 0
		for c in _connections:
			if c.remote == remote:
				from_same += 1
		if _connections.size() >= MAX_CONNECTIONS or from_same >= MAX_PER_ADDRESS:
			tcp.disconnect_from_host()
			continue
		if secure:
			var tls := StreamPeerTLS.new()
			if tls.accept_stream(tcp, _tls_options) != OK:
				tcp.disconnect_from_host()
				continue
			_connections.append(PhoneConnection.new(tcp, tls))
		else:
			_connections.append(PhoneConnection.new(tcp))

func _handle_request(c: PhoneConnection) -> void:
	match c.path:
		"/", "/index.html":
			if c.method != "GET":
				c.respond(405, "Method Not Allowed", "text/plain; charset=utf-8", "405 Method Not Allowed\n".to_utf8_buffer(),
						PackedStringArray(["Allow: GET"]))
				return
			c.respond(200, "OK", "text/html; charset=utf-8", _page, PackedStringArray([
				# The page may only run its own inline code and talk back to this server.
				"Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self' ws: wss:; base-uri 'none'; form-action 'none'",
			]))
		"/ws":
			# A web page from somewhere else must not be able to open the socket.
			var origin := str(c.headers.get("origin", ""))
			if not origin.is_empty() and origin.get_slice("://", 1) != str(c.headers.get("host", "")):
				c.respond_text(403, "Forbidden")
				return
			c.accept_websocket()
		_:
			c.respond_text(404, "Not Found")

func _handle_message(c: PhoneConnection, text: String) -> void:
	var json := JSON.new()
	var msg: Dictionary = {}
	if json.parse(text) == OK and json.data is Dictionary:
		msg = json.data
	var type: Variant = msg.get("t")
	if not c.paired:
		_handle_pairing(c, msg if (type is String and type == "pair") else {})
		return
	if c != _phone or not type is String:
		return
	match type:
		"in":
			_handle_input(msg)
		"pg":
			var x: Variant = msg.get("x")
			if _is_number(x):
				c.send_text('{"t":"po","x":%d}' % int(clampf(float(x), -9.0e15, 9.0e15)))

## The first message must be the pairing code; anything else closes the connection.
## Wrong codes are counted per device, so a stranger cannot lock the player's phone out.
func _handle_pairing(c: PhoneConnection, msg: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	var guard: Dictionary = _guards.get(c.remote, {"f": 0, "n": 0, "until": 0})
	if now < int(guard["until"]):
		c.send_text('{"t":"no","r":"locked","w":%d}' % ceili(float(int(guard["until"]) - now) / 1000.0))
		c.close(1008)
		return
	var code: Variant = msg.get("c")
	if code is String and (code as String).length() == 4 and code == pairing_code:
		if _phone != null and _phone != c:
			_phone.send_text('{"t":"bye","r":"replaced"}')
			_phone.close(1000)
		_release_inputs()
		_phone = c
		c.paired = true
		_guards.erase(c.remote)
		_last_seq = -1.0
		_last_gear = 0
		_last_car_id = 0
		c.send_text('{"t":"ok","deg":%.1f}' % _tilt_degrees)
		status = Status.CONNECTED
		state_changed.emit()
		return
	guard["f"] = int(guard["f"]) + 1
	var wait := 0
	if int(guard["f"]) >= MAX_FAILURES:
		var seconds := minf(LOCKOUT_BASE_S * pow(2.0, float(int(guard["n"]))), LOCKOUT_MAX_S)
		guard["f"] = 0
		guard["n"] = int(guard["n"]) + 1
		guard["until"] = now + int(seconds * 1000.0)
		wait = ceili(seconds)
	if not _guards.has(c.remote) and _guards.size() >= MAX_GUARDS:
		_forget_a_guard(now)
	_guards[c.remote] = guard
	if wait > 0:
		state_changed.emit()
	c.send_text('{"t":"no","r":"%s","w":%d}' % ["locked" if wait > 0 else "code", wait])
	c.close(1008)

## Keeps the table of wrong-code counters bounded: drops one that is not locked out, or the
## one whose lock-out ends first.
func _forget_a_guard(now: int) -> void:
	var victim: Variant = null
	var earliest := 0
	for address: Variant in _guards:
		var until := int((_guards[address] as Dictionary)["until"])
		if until <= now:
			victim = address
			break
		if victim == null or until < earliest:
			victim = address
			earliest = until
	_guards.erase(victim)

static func _is_number(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))

func _handle_input(msg: Dictionary) -> void:
	var s: Variant = msg.get("s")
	var th: Variant = msg.get("th")
	var b: Variant = msg.get("b")
	var k: Variant = msg.get("k")
	var n: Variant = msg.get("n")
	if not (_is_number(s) and _is_number(th) and _is_number(b) and _is_number(k) and _is_number(n)):
		return
	if float(n) <= _last_seq or float(k) < 0.0 or float(k) > 65535.0:
		return   # stale or replayed, or not a button mask
	_last_seq = float(n)
	_steer_target = clampf(float(s), -1.0, 1.0)
	_throttle = clampf(float(th), 0.0, 1.0)
	_brake = clampf(float(b), 0.0, 1.0)
	var buttons := int(k) & BUTTON_MASK   # unknown bits are dropped
	var now := Time.get_ticks_msec()
	var pressed := buttons & ~_buttons
	_buttons = buttons
	for button: StringName in BUTTONS:
		if (pressed & int(BUTTONS[button])) == 0:
			continue
		if button in ACTION_BUTTONS:
			if not _held_actions.has(button):
				_send_action(button, true)
				_held_actions[button] = now
		else:
			_presses[button] = now
	_last_input_msec = now
	_live = true

## Speed, gear and vibration for the phone, from the player's car when a race is running.
func _send_status() -> void:
	var speed := 0
	var gear := 0
	var car := _find_car()
	if car != null:
		speed = int(clampf(absf(car.speed_kmh), 0.0, 999.0))
		gear = clampi(car.gear, -1, 9)
		if car.get_instance_id() == _last_car_id and gear != _last_gear:
			vibrate(VIBRATE_SHIFT_MS)
		_last_car_id = car.get_instance_id()
		_last_gear = gear
		if speed > 15:
			for w: WheelState in car.wheels:
				if w != null and w.contact and w.surface == &"kerb":
					vibrate(VIBRATE_KERB_MS)
					break
	_phone.send_text('{"t":"st","sp":%d,"g":%d,"v":%d,"a":%d}' % [speed, gear, _vibrate_ms, int(maxf(_last_seq, 0.0))])
	_vibrate_ms = 0

func _find_car() -> Car:
	var manager := get_tree().get_first_node_in_group(&"race_manager")
	if manager == null:
		return null
	var car: Variant = manager.get(&"car")
	return (car as Car) if is_instance_valid(car) else null
