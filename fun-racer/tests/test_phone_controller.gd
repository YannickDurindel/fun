extends TestCase
## Phone controller (scripts/phone/): the server, pairing, the input protocol, the failsafe,
## the Controls section and the QR encoder. Everything runs on 127.0.0.1 with a fake phone
## written here (raw TCP + the client side of the WebSocket framing), on a random high port.

const SECTION := "controls"
const SCREEN := "res://scenes/menu/controls.tscn"
const KEYS: Array[String] = ["phone_enabled", "phone_port", "phone_https_port", "phone_tilt_degrees",
		"phone_deadzone", "phone_smoothing"]
## QRCode.encode("http://192.168.1.20:8080", 2): version 2, level M, byte mode, mask 2.
## Reference computed with Python's `qrcode` package (QRCode(error_correction=M,
## mask_pattern=2), 8-bit byte mode); all 8 masks and versions 1, 2, 5 and 6 were compared
## the same way when the encoder was written.
const QR_TEXT := "http://192.168.1.20:8080"
const QR_REFERENCE: Array[String] = [
	"#######..###..#...#######",
	"#.....#..#...#.#..#.....#",
	"#.###.#.##......#.#.###.#",
	"#.###.#.#....#....#.###.#",
	"#.###.#.#.#.#.#...#.###.#",
	"#.....#.#..##..##.#.....#",
	"#######.#.#.#.#.#.#######",
	"........##.#...#.........",
	"#.#####...##.#.##.#####..",
	"..#.##..#.##.##..#.....#.",
	"##...####.##.#.#..##.#.##",
	"#####..##.#.....#...#...#",
	"##....##.##..#....###.###",
	"#...##...##.###......#.#.",
	"#..#..#.##.....#.#.#.#.##",
	"#.##.#....#.#..#.....#..#",
	"#...#.#.#...##..#####.#..",
	"........##....#.#...###..",
	"#######..####...#.#.#####",
	"#.....#.####...##...##..#",
	"#.###.#.######.########..",
	"#.###.#.#.#.#####.###.###",
	"#.###.#.#...#....#....#.#",
	"#.....#...#.#...#.####..#",
	"#######.#....#.#.########",
]

var _port: int = 0

## A fake phone: one TCP (or TLS) connection speaking HTTP, then masked WebSocket frames.
class Client:
	var tcp := StreamPeerTCP.new()
	var stream: StreamPeer
	var buf := PackedByteArray()
	var closed := false         # the server sent a close frame or dropped the socket
	var messages: Array[Dictionary] = []

	func open(port: int, secure: bool = false) -> void:
		tcp.connect_to_host("127.0.0.1", port)
		stream = tcp
		if secure:
			stream = StreamPeerTLS.new()

	func is_connected_to_server() -> bool:
		tcp.poll()
		return tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED

	func failed() -> bool:
		tcp.poll()
		return tcp.get_status() == StreamPeerTCP.STATUS_ERROR or tcp.get_status() == StreamPeerTCP.STATUS_NONE

	## Starts the TLS handshake (after the TCP connection is up).
	func start_tls() -> void:
		(stream as StreamPeerTLS).connect_to_stream(tcp, "localhost", TLSOptions.client_unsafe())

	func tls_ready() -> bool:
		(stream as StreamPeerTLS).poll()
		return (stream as StreamPeerTLS).get_status() == StreamPeerTLS.STATUS_CONNECTED

	func send_raw(text: String) -> void:
		stream.put_data(text.to_utf8_buffer())

	func upgrade() -> void:
		send_raw("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
				+ "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")

	## One masked text frame, as browsers send them.
	func send(text: String) -> void:
		var payload := text.to_utf8_buffer()
		var frame := PackedByteArray([0x81])
		if payload.size() < 126:
			frame.append(0x80 | payload.size())
		else:
			frame.append(0x80 | 126)
			frame.append(payload.size() >> 8)
			frame.append(payload.size() & 0xFF)
		var mask := PackedByteArray([0x12, 0x34, 0x56, 0x78])
		frame.append_array(mask)
		for i in payload.size():
			frame.append(payload[i] ^ mask[i & 3])
		stream.put_data(frame)

	func pump() -> void:
		tcp.poll()
		if stream is StreamPeerTLS:
			(stream as StreamPeerTLS).poll()
			if (stream as StreamPeerTLS).get_status() != StreamPeerTLS.STATUS_CONNECTED:
				closed = closed or (stream as StreamPeerTLS).get_status() != StreamPeerTLS.STATUS_HANDSHAKING
				return
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			closed = true
			return
		var n := stream.get_available_bytes()
		if n > 0:
			buf.append_array(stream.get_partial_data(n)[1] as PackedByteArray)

	## The HTTP head received so far ("" until the blank line arrived); it is taken off buf.
	func take_head() -> String:
		pump()
		var text := buf.get_string_from_utf8()
		var end := text.find("\r\n\r\n")
		if end < 0:
			return ""
		buf = buf.slice(text.substr(0, end + 4).to_utf8_buffer().size())
		return text.substr(0, end)

	## Decodes the server's (unmasked) frames into `messages`.
	func read_frames() -> void:
		pump()
		while buf.size() >= 2:
			var opcode := buf[0] & 0x0F
			var length := buf[1] & 0x7F
			var header := 2
			if length == 126:
				if buf.size() < 4:
					return
				length = (buf[2] << 8) | buf[3]
				header = 4
			if buf.size() < header + length:
				return
			var payload := buf.slice(header, header + length)
			buf = buf.slice(header + length)
			if opcode == 0x8:
				closed = true
			elif opcode == 0x1:
				var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
				if parsed is Dictionary:
					messages.append(parsed)

	func last_of(type: String) -> Dictionary:
		for i in range(messages.size() - 1, -1, -1):
			if messages[i].get("t") == type:
				return messages[i]
		return {}

# ---------------------------------------------------------------------------- helpers

func _until(cond: Callable, timeout_s: float = 3.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())

func _wait(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

## Turns the option on, on a random high port, with raw steering (no dead zone, no smoothing).
func _start(https_port: int = 0) -> void:
	_cleanup()
	_port = 20000 + randi() % 20000
	PhoneController.port_attempts = 1
	Settings.set_value(SECTION, "phone_port", _port)
	Settings.set_value(SECTION, "phone_https_port", https_port)
	Settings.set_value(SECTION, "phone_deadzone", 0.0)
	Settings.set_value(SECTION, "phone_smoothing", 0.0)
	Settings.set_value(SECTION, "phone_enabled", true)

## Server off, settings back to their defaults, Bootstrap's hook released.
func _cleanup() -> void:
	Settings.set_value(SECTION, "phone_enabled", false)
	for key in KEYS:
		Settings.set_value(SECTION, key, Settings.default_value(SECTION, key))
	PhoneController.port_attempts = 10
	PhoneController.paired_silence_ms = 5000
	assert_true(PhoneController.status == PhoneController.Status.OFF and not PhoneController.is_running(), "server is off after the test")
	assert_true(Bootstrap.external_input == null, "Bootstrap.external_input is released")

func _connect(port: int) -> Client:
	var c := Client.new()
	c.open(port)
	await _until(func() -> bool: return c.is_connected_to_server() or c.failed(), 2.0)
	return c

## A WebSocket that has sent `first` as its first message.
func _ws(first: String) -> Client:
	var c: Client = await _connect(_port)
	c.upgrade()
	var head: Array[String] = [""]
	await _until(func() -> bool:
		head[0] = c.take_head()
		return not head[0].is_empty())
	assert_true(head[0].begins_with("HTTP/1.1 101"), "WebSocket upgrade accepted: %s" % head[0].get_slice("\r\n", 0))
	assert_true(head[0].contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "RFC 6455 accept key")
	if not first.is_empty():
		c.send(first)
	return c

func _paired() -> Client:
	var c: Client = await _ws('{"t":"pair","c":"%s"}' % PhoneController.pairing_code)
	await _until(func() -> bool:
		c.read_frames()
		return not c.last_of("ok").is_empty())
	assert_true(not c.last_of("ok").is_empty(), "the right code is accepted")
	return c

func _send_input(c: Client, steer: float, throttle: float, brake: float, buttons: int, seq: int) -> void:
	c.send('{"t":"in","s":%f,"th":%f,"b":%f,"k":%d,"n":%d}' % [steer, throttle, brake, buttons, seq])

func _http(port: int, request: String) -> String:
	var c: Client = await _connect(port)
	c.send_raw(request)
	await _until(func() -> bool:
		c.pump()
		return c.closed)
	return c.buf.get_string_from_utf8()

func _port_open(port: int) -> bool:
	var c: Client = await _connect(port)
	var up := c.is_connected_to_server()
	c.tcp.disconnect_from_host()
	return up

# ---------------------------------------------------------------------------- server

func test_off_by_default_enable_opens_port_disable_closes_it() -> void:
	assert_true(Settings.default_value(SECTION, "phone_enabled") == false, "the option is off by default")
	_cleanup()
	assert_true(PhoneController.urls().is_empty() and PhoneController.pairing_code.is_empty(), "no address and no code while off")
	_start()
	assert_true(PhoneController.status == PhoneController.Status.WAITING, "enabled: waiting for a phone")
	assert_true(PhoneController.port == _port and PhoneController.https_port == 0, "listening on the configured port only")
	assert_true(PhoneController.pairing_code.length() == 4 and PhoneController.pairing_code.is_valid_int(), "a 4-digit pairing code: %s" % PhoneController.pairing_code)
	assert_true(Bootstrap.external_input == PhoneController, "registered as Bootstrap's external input")
	assert_true(not PhoneController.is_active(), "not active before a phone is paired")
	assert_true(await _port_open(_port), "the port accepts connections")
	var port := _port
	Settings.set_value(SECTION, "phone_enabled", false)
	assert_true(PhoneController.status == PhoneController.Status.OFF, "disabled: off")
	assert_true(not await _port_open(port), "the port is closed again")
	_cleanup()

func test_http_serves_the_page_only() -> void:
	_start()
	var page: String = await _http(_port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	assert_true(page.begins_with("HTTP/1.1 200 OK\r\n"), "GET / is 200: %s" % page.get_slice("\r\n", 0))
	assert_true(page.contains("Content-Type: text/html; charset=utf-8") and page.contains("Cache-Control: no-store"), "html, never cached")
	assert_true(page.contains("Content-Security-Policy: default-src 'none'"), "restrictive content security policy")
	var body := page.get_slice("\r\n\r\n", 1)
	assert_true(body.contains("<title>Fun Racer controller</title>") and body.strip_edges().ends_with("</html>"), "the whole controller page is served")
	assert_true(page.contains("Content-Length: %d\r\n" % body.to_utf8_buffer().size()), "Content-Length matches the body")
	assert_true(not body.contains("__HTTPS_PORT__") and not body.contains("__HTTP_PORT__"), "ports are filled in")
	for external: String in ["src=\"http", "href=\"http", "url(http", "@import", "<link"]:
		assert_true(not body.contains(external), "the page loads nothing external (%s)" % external)
	var missing: String = await _http(_port, "GET /secret.txt HTTP/1.1\r\nHost: x\r\n\r\n")
	assert_true(missing.begins_with("HTTP/1.1 404"), "other paths are 404: %s" % missing.get_slice("\r\n", 0))
	var traversal: String = await _http(_port, "GET /../project.godot HTTP/1.1\r\nHost: x\r\n\r\n")
	assert_true(traversal.begins_with("HTTP/1.1 404"), "no file access: %s" % traversal.get_slice("\r\n", 0))
	var post: String = await _http(_port, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
	assert_true(post.begins_with("HTTP/1.1 405"), "POST is rejected: %s" % post.get_slice("\r\n", 0))
	var garbage: String = await _http(_port, "hello there\r\n\r\n")
	assert_true(garbage.begins_with("HTTP/1.1 400"), "garbage is a 400: %s" % garbage.get_slice("\r\n", 0))
	var plain_get: String = await _http(_port, "GET /ws HTTP/1.1\r\nHost: x\r\n\r\n")
	assert_true(plain_get.begins_with("HTTP/1.1 426"), "/ws without an upgrade: %s" % plain_get.get_slice("\r\n", 0))
	var foreign: String = await _http(_port, "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: http://evil.example\r\nUpgrade: websocket\r\n" % _port \
			+ "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
	assert_true(foreign.begins_with("HTTP/1.1 403"), "a WebSocket from another site's page is refused: %s" % foreign.get_slice("\r\n", 0))
	assert_true(PhoneController.status == PhoneController.Status.WAITING, "still waiting")
	_cleanup()

func test_port_in_use_gives_a_clear_error() -> void:
	_cleanup()
	var blocker := TCPServer.new()
	var port := 20000 + randi() % 20000
	assert_true(blocker.listen(port) == OK, "test port taken")
	PhoneController.port_attempts = 1
	Settings.set_value(SECTION, "phone_port", port)
	Settings.set_value(SECTION, "phone_https_port", 0)
	Settings.set_value(SECTION, "phone_enabled", true)
	assert_true(PhoneController.status == PhoneController.Status.ERROR, "status is ERROR")
	assert_true(PhoneController.error_text.contains(str(port)), "the error names the port: %s" % PhoneController.error_text)
	assert_true(Bootstrap.external_input == null and not PhoneController.is_running(), "nothing registered, nothing listening")
	# With the fallback the next free port is used instead.
	Settings.set_value(SECTION, "phone_enabled", false)
	PhoneController.port_attempts = 10
	Settings.set_value(SECTION, "phone_enabled", true)
	assert_true(PhoneController.status == PhoneController.Status.WAITING and PhoneController.port > port, "falls back to the next free port: %d" % PhoneController.port)
	blocker.stop()
	_cleanup()

func test_https_port_serves_the_same_page() -> void:
	var https_port := 41000 + randi() % 10000
	_start(https_port)
	assert_true(PhoneController.status == PhoneController.Status.WAITING and PhoneController.port == _port, "the plain port does not wait for the certificate")
	# The certificate is made on a worker thread the first time; the port opens when it is ready.
	await _until(func() -> bool: return not PhoneController.is_https_pending(), 30.0)
	assert_true(PhoneController.https_error.is_empty() and PhoneController.https_port == https_port, "HTTPS port open: %s" % PhoneController.https_error)
	assert_true(PhoneController.urls(true).size() == PhoneController.urls(false).size(), "an https address for every http one")
	var c := Client.new()
	c.open(https_port, true)
	await _until(func() -> bool: return c.is_connected_to_server() or c.failed(), 2.0)
	c.start_tls()
	assert_true(await _until(func() -> bool: return c.tls_ready(), 5.0), "TLS handshake with the self-signed certificate")
	c.send_raw("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
	await _until(func() -> bool:
		c.pump()
		return c.closed or c.buf.get_string_from_utf8().contains("</html>"))
	var page := c.buf.get_string_from_utf8()
	assert_true(page.begins_with("HTTP/1.1 200 OK") and page.contains("<title>Fun Racer controller</title>"), "page over HTTPS: %s" % page.get_slice("\r\n", 0))
	# Pairing and input over wss.
	var w := Client.new()
	w.open(https_port, true)
	await _until(func() -> bool: return w.is_connected_to_server() or w.failed(), 2.0)
	w.start_tls()
	await _until(func() -> bool: return w.tls_ready(), 5.0)
	w.upgrade()
	await _until(func() -> bool: return not w.take_head().is_empty())
	w.send('{"t":"pair","c":"%s"}' % PhoneController.pairing_code)
	_send_input(w, 0.25, 1.0, 0.0, 0, 1)
	assert_true(await _until(func() -> bool: return PhoneController.is_active()), "paired over wss")
	assert_between(Bootstrap.get_throttle(), 0.99, 1.0, "throttle over wss")
	_cleanup()

# ---------------------------------------------------------------------------- pairing

func test_pairing_code_is_required() -> void:
	_start()
	var code := PhoneController.pairing_code
	var wrong_code := "%04d" % ((int(code) + 1) % 10000)
	# Wrong code: told so, then closed.
	var wrong: Client = await _ws('{"t":"pair","c":"%s"}' % wrong_code)
	await _until(func() -> bool:
		wrong.read_frames()
		return wrong.closed)
	assert_true(wrong.last_of("no").get("r") == "code" and wrong.closed, "a wrong code is refused and the connection closed")
	assert_true(wrong.last_of("ok").is_empty(), "no ok for a wrong code")
	# Input without pairing: closed, and nothing reaches the game.
	var rude: Client = await _ws('{"t":"in","s":1,"th":1,"b":0,"k":1,"n":1}')
	await _until(func() -> bool:
		rude.read_frames()
		return rude.closed)
	assert_true(rude.closed, "input before pairing closes the connection")
	assert_true(not PhoneController.is_active() and Bootstrap.get_throttle() == 0.0 and Bootstrap.get_steer() == 0.0, "no input without pairing")
	assert_true(PhoneController.status == PhoneController.Status.WAITING, "still waiting for a phone")
	# The right code.
	var good: Client = await _paired()
	assert_between(float(good.last_of("ok").get("deg", 0.0)), 29.9, 30.1, "the phone is told the tilt range")
	assert_true(PhoneController.status == PhoneController.Status.CONNECTED, "status: connected")
	# A stranger with a wrong code does not disturb the paired phone.
	var stranger: Client = await _ws('{"t":"pair","c":"%s"}' % wrong_code)
	await _until(func() -> bool:
		stranger.read_frames()
		return stranger.closed)
	_send_input(good, 0.0, 0.5, 0.0, 0, 1)
	assert_true(await _until(func() -> bool: return PhoneController.is_active()), "the paired phone still drives")
	# A second phone with the right code takes over; the first is told and closed.
	var second: Client = await _paired()
	await _until(func() -> bool:
		good.read_frames()
		return good.closed)
	assert_true(good.last_of("bye").get("r") == "replaced" and good.closed, "the first phone is replaced after the new one paired")
	assert_true(Bootstrap.get_throttle() == 0.0, "inputs are released when the phone changes")
	_send_input(second, 0.0, 0.75, 0.0, 0, 1)
	assert_true(await _until(func() -> bool: return Bootstrap.get_throttle() > 0.7), "the new phone drives")
	_cleanup()

func test_lockout_after_five_wrong_codes() -> void:
	_start()
	var wrong_code := "%04d" % ((int(PhoneController.pairing_code) + 7) % 10000)
	for i in PhoneController.MAX_FAILURES:
		var c: Client = await _ws('{"t":"pair","c":"%s"}' % wrong_code)
		await _until(func() -> bool:
			c.read_frames()
			return c.closed)
		assert_true(c.last_of("no").get("r") == ("locked" if i == PhoneController.MAX_FAILURES - 1 else "code"), "wrong code %d refused" % (i + 1))
	assert_true(PhoneController.lockout_left() > 5.0, "pairing is locked: %.1f s" % PhoneController.lockout_left())
	var late: Client = await _ws('{"t":"pair","c":"%s"}' % PhoneController.pairing_code)
	await _until(func() -> bool:
		late.read_frames()
		return late.closed)
	assert_true(late.last_of("no").get("r") == "locked" and late.last_of("ok").is_empty(), "even the right code waits during the lock-out")
	assert_true(PhoneController.status == PhoneController.Status.WAITING and not PhoneController.is_active(), "nobody paired")
	_cleanup()

# ---------------------------------------------------------------------------- inputs

func test_inputs_drive_the_car_inputs() -> void:
	_start()
	var c: Client = await _paired()
	assert_true(not PhoneController.is_active(), "paired but silent: not active yet")
	_send_input(c, 0.5, 0.8, 0.25, 0, 1)
	assert_true(await _until(func() -> bool: return PhoneController.is_active()), "active once input arrives")
	assert_between(Bootstrap.get_steer(), 0.499, 0.501, "steer")
	assert_between(Bootstrap.get_throttle(), 0.799, 0.801, "throttle")
	assert_between(Bootstrap.get_brake(), 0.249, 0.251, "brake")
	assert_true(not Bootstrap.is_steer_digital(), "phone steering is analog: no keyboard ramp")
	_send_input(c, -0.3, 0.0, 1.0, 0, 2)
	await _until(func() -> bool: return Bootstrap.get_brake() > 0.99)
	assert_between(Bootstrap.get_steer(), -0.301, -0.299, "steer left")
	assert_between(Bootstrap.get_throttle(), 0.0, 0.0, "throttle released")
	# Out-of-range values are clamped.
	_send_input(c, -7.0, 12.0, -3.0, 0, 3)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.99)
	assert_between(Bootstrap.get_steer(), -1.0, -1.0, "steer clamped to -1")
	assert_between(Bootstrap.get_throttle(), 1.0, 1.0, "throttle clamped to 1")
	assert_between(Bootstrap.get_brake(), 0.0, 0.0, "brake clamped to 0")
	c.send('{"t":"in","s":1e999,"th":0.5,"b":0.5,"k":0,"n":4}')
	# Malformed messages are ignored: the last good values stay.
	_send_input(c, 0.2, 0.4, 0.6, 0, 5)
	await _until(func() -> bool: return absf(Bootstrap.get_brake() - 0.6) < 0.01)
	for bad: String in ["", "garbage", "{", "[1,2,3]", "null", "42", '{"t":"in"}', '{"t":7}', '{"t":"in","s":"x","th":1,"b":1,"k":0,"n":9}',
			'{"t":"in","s":0.9,"th":0.9,"b":0.9,"k":0}', '{"t":"in","s":[1],"th":{},"b":null,"k":0,"n":10}',
			'{"t":"in","s":0.9,"th":0.9,"b":0.9,"k":"1","n":11}', '{"t":"nope","s":1}', '{"t":"pair","c":"0000"}',
			'{"t":"in","s":0.9,"th":0.9,"b":0.9,"k":0,"n":2}', "x".repeat(900)]:
		c.send(bad)
	c.send('{"t":"pg","x":123}')
	assert_true(await _until(func() -> bool:
		c.read_frames()
		return not c.last_of("po").is_empty()), "ping answered after the malformed messages (connection alive)")
	assert_between(float(c.last_of("po").get("x", 0.0)), 123.0, 123.0, "ping payload echoed")
	assert_between(Bootstrap.get_steer(), 0.199, 0.201, "malformed and stale messages left steer alone")
	assert_between(Bootstrap.get_throttle(), 0.399, 0.401, "... and throttle")
	assert_between(Bootstrap.get_brake(), 0.599, 0.601, "... and brake")
	# Status comes back about 10 times a second.
	assert_true(await _until(func() -> bool:
		c.read_frames()
		return float(c.last_of("st").get("a", -1.0)) >= 5.0), "status message received, acknowledging the last input")
	var st := c.last_of("st")
	assert_true(st.has("sp") and st.has("g") and st.has("v") and float(st.get("a", -1.0)) >= 1.0, "status has speed, gear, vibration and the last sequence: %s" % str(st))
	# The tilt range reaches the phone when the slider moves.
	Settings.set_value(SECTION, "phone_tilt_degrees", 25.0)
	assert_true(await _until(func() -> bool:
		c.read_frames()
		return not c.last_of("cfg").is_empty()), "tilt range change is sent to the phone")
	assert_between(float(c.last_of("cfg").get("deg", 0.0)), 24.9, 25.1, "new tilt range")
	_cleanup()

func test_dead_zone_and_smoothing() -> void:
	_start()
	Settings.set_value(SECTION, "phone_deadzone", 0.2)
	var c: Client = await _paired()
	_send_input(c, 0.1, 0.3, 0.0, 0, 1)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.29)
	await get_tree().process_frame
	assert_between(Bootstrap.get_steer(), 0.0, 0.0, "inside the dead zone")
	_send_input(c, -0.6, 0.31, 0.0, 0, 2)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.305)
	await get_tree().process_frame
	assert_between(Bootstrap.get_steer(), -0.501, -0.499, "rescaled outside the dead zone")
	_send_input(c, 1.0, 0.32, 0.0, 0, 3)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.315)
	await get_tree().process_frame
	assert_between(Bootstrap.get_steer(), 1.0, 1.0, "full lock is still reachable")
	# Smoothing: the value approaches the target instead of jumping, but gets there.
	Settings.set_value(SECTION, "phone_deadzone", 0.0)
	Settings.set_value(SECTION, "phone_smoothing", 1.0)
	_send_input(c, -1.0, 0.33, 0.0, 0, 4)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.325)
	await get_tree().process_frame
	assert_true(Bootstrap.get_steer() > -0.999, "smoothed steering does not jump: %.3f" % Bootstrap.get_steer())
	var seq: Array[int] = [5]
	var converged := func() -> bool:
		_send_input(c, -1.0, 0.33, 0.0, 0, seq[0])
		seq[0] += 1
		return Bootstrap.get_steer() < -0.98
	assert_true(await _until(converged, 4.0), "... and converges: %.3f" % Bootstrap.get_steer())
	_cleanup()

func test_buttons() -> void:
	_start()
	var c: Client = await _paired()
	_send_input(c, 0.0, 0.1, 0.0, 1, 1)   # shift_up down
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.09)
	assert_true(Bootstrap.take_button(&"shift_up"), "shift_up is taken once")
	assert_true(not Bootstrap.take_button(&"shift_up"), "... and only once")
	assert_true(not Bootstrap.take_button(&"shift_down"), "shift_down was not pressed")
	_send_input(c, 0.0, 0.2, 0.0, 1, 2)   # still held: no new press
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.19)
	assert_true(not Bootstrap.take_button(&"shift_up"), "holding does not repeat")
	_send_input(c, 0.0, 0.3, 0.0, 0, 3)
	_send_input(c, 0.0, 0.4, 0.0, 3, 4)   # released, then shift_up + shift_down
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.39)
	assert_true(Bootstrap.take_button(&"shift_up") and Bootstrap.take_button(&"shift_down"), "a new press after a release")
	# DRS is a held button.
	assert_true(not Bootstrap.is_button_down(&"drs"), "drs up")
	_send_input(c, 0.0, 0.5, 0.0, 4, 5)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.49)
	assert_true(Bootstrap.is_button_down(&"drs") and not Bootstrap.take_button(&"shift_up"), "drs held")
	# Respawn is injected as the game's own input action, pressed then released.
	assert_true(not Input.is_action_pressed(&"respawn"), "respawn not pressed before")
	_send_input(c, 0.0, 0.6, 0.0, 8, 6)
	assert_true(await _until(func() -> bool: return Input.is_action_pressed(&"respawn")), "respawn action pressed by the phone")
	_send_input(c, 0.0, 0.6, 0.0, 0, 7)
	assert_true(await _until(func() -> bool: return not Input.is_action_pressed(&"respawn")), "... and released")
	# Unknown bits are dropped.
	_send_input(c, 0.0, 0.7, 0.0, 4096 + 2, 8)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.69)
	assert_true(not Bootstrap.is_button_down(&"drs"), "an out-of-range bitmask is clamped to the known buttons")
	# An unread press does not fire much later.
	_send_input(c, 0.0, 0.8, 0.0, 0, 9)
	_send_input(c, 0.0, 0.8, 0.0, 1, 10)
	var seq: Array[int] = [11]
	var until := Time.get_ticks_msec() + 400
	await _until(func() -> bool:
		_send_input(c, 0.0, 0.8, 0.0, 1, seq[0])
		seq[0] += 1
		return Time.get_ticks_msec() > until)
	assert_true(PhoneController.is_active() and not Bootstrap.take_button(&"shift_up"), "a press nobody read expires")
	_cleanup()

func test_failsafe_releases_inputs_after_silence() -> void:
	_start()
	var c: Client = await _paired()
	_send_input(c, 0.9, 1.0, 0.0, 4, 1)
	assert_true(await _until(func() -> bool: return Bootstrap.get_throttle() > 0.99), "full throttle from the phone")
	var t0 := Time.get_ticks_msec()
	# Silence (the socket stays open, as with a frozen browser or dead Wi-Fi).
	assert_true(await _until(func() -> bool: return not PhoneController.is_active(), 1.0), "inactive after silence")
	var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
	assert_between(elapsed, 0.2, 0.45, "failsafe delay (s)")
	assert_true(Bootstrap.get_throttle() == 0.0 and Bootstrap.get_brake() == 0.0 and Bootstrap.get_steer() == 0.0, "all inputs released")
	assert_true(not Bootstrap.is_button_down(&"drs"), "held buttons released")
	assert_true(PhoneController.status == PhoneController.Status.CONNECTED, "the phone is still paired")
	# It drives again as soon as input resumes; a button held through the gap is not a new press.
	_send_input(c, 0.0, 0.5, 0.0, 1, 2)
	assert_true(await _until(func() -> bool: return Bootstrap.get_throttle() > 0.49), "input resumes")
	assert_true(Bootstrap.take_button(&"shift_up"), "shift_up pressed")
	await _until(func() -> bool: return not PhoneController.is_active(), 1.0)
	_send_input(c, 0.0, 0.5, 0.0, 1 + 4, 3)
	assert_true(await _until(func() -> bool: return Bootstrap.is_button_down(&"drs")), "input resumes with the button still held")
	assert_true(not Bootstrap.take_button(&"shift_up"), "a button held through a stall does not fire again")
	# A phone that vanished without closing the socket (no data at all) is dropped.
	PhoneController.paired_silence_ms = 500
	assert_true(await _until(func() -> bool: return PhoneController.status == PhoneController.Status.WAITING, 2.0), "a silent paired phone is dropped")
	PhoneController.paired_silence_ms = 5000
	c = await _paired()
	_send_input(c, 0.0, 0.5, 0.0, 0, 1)
	assert_true(await _until(func() -> bool: return Bootstrap.get_throttle() > 0.49), "the phone pairs again")
	# A dropped connection releases at once and goes back to waiting.
	c.tcp.disconnect_from_host()
	assert_true(await _until(func() -> bool: return PhoneController.status == PhoneController.Status.WAITING, 1.0), "connection drop is noticed")
	assert_true(Bootstrap.get_throttle() == 0.0 and not PhoneController.is_active(), "inputs released when the connection drops")
	_cleanup()

func test_disabling_releases_everything() -> void:
	_start()
	var c: Client = await _paired()
	_send_input(c, 0.5, 1.0, 0.0, 0, 1)
	await _until(func() -> bool: return Bootstrap.get_throttle() > 0.99)
	Settings.set_value(SECTION, "phone_enabled", false)
	assert_true(Bootstrap.get_throttle() == 0.0 and Bootstrap.get_steer() == 0.0, "inputs are zero the moment the option is turned off")
	assert_true(Bootstrap.external_input == null, "hook released")
	var gone := func() -> bool:
		c.read_frames()
		return c.closed
	assert_true(await _until(gone, 1.0), "the phone is disconnected")
	_cleanup()

# ---------------------------------------------------------------------------- screen, addresses, QR

func test_controls_screen_section() -> void:
	_cleanup()
	var screen := spawn(SCREEN) as ControlsScreen
	await get_tree().process_frame
	await get_tree().process_frame
	var toggle := screen.find_child("PhoneSwitch", true, false) as CheckButton
	var details := screen.find_child("PhoneDetails", true, false) as Control
	var status := screen.find_child("PhoneStatus", true, false) as Label
	assert_true(toggle != null and details != null and status != null, "the phone section exists")
	assert_true(not toggle.button_pressed and not details.visible and status.text.begins_with("Off"), "off: one row")
	for key: String in ["phone_tilt_degrees", "phone_deadzone", "phone_smoothing"]:
		assert_true(screen.find_child(key, true, false) is HSlider, "slider %s" % key)
	_port = 20000 + randi() % 20000
	Settings.set_value(SECTION, "phone_port", _port)
	Settings.set_value(SECTION, "phone_https_port", 0)
	toggle.button_pressed = true
	await get_tree().process_frame
	assert_true(bool(Settings.get_value(SECTION, "phone_enabled")) and PhoneController.status == PhoneController.Status.WAITING, "the switch starts the server")
	assert_true(details.visible and status.text.begins_with("Waiting"), "on: details shown, waiting")
	var code_shown := ""
	for label: Label in details.find_children("*", "Label", true, false):
		if label.text.replace(" ", "") == PhoneController.pairing_code:
			code_shown = label.text
	assert_true(not code_shown.is_empty(), "the pairing code is shown")
	var qr := screen.find_child("QR0", true, false) as TextureRect
	if PhoneController.urls().is_empty():
		assert_true(not (qr.get_parent() as Control).visible, "no QR code without a network address")
	else:
		assert_true(qr.texture != null and qr.texture.get_width() > 100, "QR code of the address")
		assert_true(PhoneController.urls()[0].begins_with("http://") and PhoneController.urls()[0].ends_with(":%d" % _port), "address: http://<ip>:<port>")
	var slider := screen.find_child("phone_tilt_degrees", true, false) as HSlider
	slider.value = 30.0
	assert_between(float(Settings.get_value(SECTION, "phone_tilt_degrees")), 30.0, 30.0, "the slider writes the setting")
	var c: Client = await _paired()
	await get_tree().process_frame
	assert_true(status.text == "Phone connected", "status follows the connection: %s" % status.text)
	c.tcp.disconnect_from_host()
	# RESET restores bindings and tuning but leaves the phone controller running.
	Settings.set_value(SECTION, "key_steer_in_time", 0.7)
	screen._ask_reset()
	screen._on_dialog_ok()
	assert_between(float(Settings.get_value(SECTION, "phone_tilt_degrees")), 30.0, 30.0, "RESET restores the tilt range")
	assert_between(float(Settings.get_value(SECTION, "key_steer_in_time")), 0.4, 0.4, "... and the keyboard steering")
	assert_true(PhoneController.status != PhoneController.Status.OFF and int(Settings.get_value(SECTION, "phone_port")) == _port, "RESET does not switch the phone controller off")
	assert_true(not (screen.find_child("phone_smoothing", true, false) as HSlider).scrollable, "the mouse wheel scrolls the screen, not the sliders")
	toggle.button_pressed = false
	await get_tree().process_frame
	assert_true(PhoneController.status == PhoneController.Status.OFF and not details.visible, "the switch stops the server")
	screen.queue_free()
	await get_tree().process_frame
	_cleanup()

func test_lan_address_choice() -> void:
	assert_true(PhoneController.address_rank("192.168.1.20") == 0, "home Wi-Fi first")
	assert_true(PhoneController.address_rank("10.0.0.5") == 1 and PhoneController.address_rank("172.20.1.1") == 2, "other private ranges next")
	assert_true(PhoneController.address_rank("8.8.8.8") == 3 and PhoneController.address_rank("172.32.0.1") == 3, "public addresses last")
	for unusable: String in ["127.0.0.1", "169.254.3.4", "::1", "fe80::1", "0.0.0.0", "not an ip"]:
		assert_true(PhoneController.address_rank(unusable) < 0, "%s is never offered" % unusable)
	for addr in PhoneController.lan_addresses():
		assert_true(PhoneController.address_rank(addr) >= 0, "listed address is usable")

func test_qr_matches_reference_matrix() -> void:
	var qr := QRCode.encode(QR_TEXT, 2)
	assert_true(qr != null and qr.version == 2 and qr.size == 25, "version 2 (25 x 25) for a 24-byte URL")
	var rows := qr.to_rows()
	var diff := 0
	for y in QR_REFERENCE.size():
		if rows[y] != QR_REFERENCE[y]:
			diff += 1
	assert_true(rows.size() == QR_REFERENCE.size() and diff == 0, "matrix equals the reference (%d rows differ)" % diff)
	assert_true(qr.is_dark(0, 0) and not qr.is_dark(1, 1) and qr.is_dark(3, 3) and not qr.is_dark(7, 7), "finder pattern")
	assert_true(not qr.is_dark(-1, 0) and not qr.is_dark(25, 25), "outside is light")
	# The automatic choice is a valid mask, and the same symbol as forcing it.
	var auto := QRCode.encode(QR_TEXT)
	assert_true(auto.mask >= 0 and auto.mask <= 7, "automatic mask")
	assert_true("\n".join(QRCode.encode(QR_TEXT, auto.mask).to_rows()) == "\n".join(auto.to_rows()), "automatic = forced with the same mask")
	# Sizes: the version grows with the text; too long gives null instead of a bad code.
	assert_true(QRCode.encode("x").version == 1 and QRCode.encode("x".repeat(40)).version == 3, "version follows the length")
	assert_true(QRCode.encode("https://192.168.100.100:8443").version == 3, "longest address fits version 3")
	assert_true(QRCode.encode("x".repeat(QRCode.max_bytes())) != null and QRCode.encode("x".repeat(QRCode.max_bytes() + 1)) == null, "capacity limit")
	var img := qr.to_image(4, 4)
	assert_true(img.get_width() == (25 + 8) * 4 and img.get_height() == img.get_width(), "image with a quiet zone")
	assert_true(img.get_pixel(0, 0).r > 0.9 and img.get_pixel(4 * 4 + 1, 4 * 4 + 1).r < 0.1, "white border, dark finder corner")
