class_name PhoneConnection
extends RefCounted
## One client of the phone-controller server: a tiny HTTP/1.1 request parser and, after
## `GET /ws`, an RFC 6455 WebSocket (server side: text frames, ping / pong, close).
## It works on any StreamPeer, so the same code serves plain TCP and TLS.
##
## Nothing here blocks: poll() reads what has arrived and writes what the socket accepts;
## the rest stays in a bounded buffer. Every limit below exists so a stranger on the
## network cannot make the game allocate or wait.

enum State { TLS_HANDSHAKE, HTTP, WEBSOCKET, CLOSING, CLOSED }

const MAX_REQUEST_BYTES := 8192       ## request line + headers
const MAX_MESSAGE_BYTES := 1024       ## one WebSocket message from the phone
const MAX_OUT_BYTES := 512 * 1024     ## unsent data kept for a slow client
const MAX_MESSAGES_PER_POLL := 64
const HANDSHAKE_TIMEOUT_MS := 5000    ## to finish TLS + the HTTP request
const CLOSE_TIMEOUT_MS := 2000        ## to flush the last bytes before dropping
const WS_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

var state: State = State.HTTP
## True once the phone has sent the right pairing code (set by PhoneController).
var paired: bool = false
var secure: bool = false
## Parsed request, valid once `request_ready` is true (and until the owner answers it).
var request_ready: bool = false
var method: String = ""
var path: String = ""
var headers: Dictionary = {}          # lower-case name -> value
var opened_msec: int = 0
## When the last WebSocket frame of any kind arrived (to notice a phone that just vanished).
var last_heard_msec: int = 0
## Address of the other end, to count wrong pairing codes and connections per device.
var remote: String = ""

var _tcp: StreamPeerTCP
var _stream: StreamPeer
var _in: PackedByteArray = PackedByteArray()
var _out: PackedByteArray = PackedByteArray()
var _closing_since: int = 0

func _init(tcp: StreamPeerTCP, tls: StreamPeerTLS = null) -> void:
	_tcp = tcp
	_tcp.set_no_delay(true)
	_stream = tls if tls != null else (tcp as StreamPeer)
	secure = tls != null
	state = State.TLS_HANDSHAKE if secure else State.HTTP
	opened_msec = Time.get_ticks_msec()
	last_heard_msec = opened_msec
	remote = tcp.get_connected_host()

func is_open() -> bool:
	return state != State.CLOSED

func is_websocket() -> bool:
	return state == State.WEBSOCKET

## Reads and writes what is possible right now. Returns the complete WebSocket text
## messages received since the last call.
func poll() -> PackedStringArray:
	var messages := PackedStringArray()
	if state == State.CLOSED:
		return messages
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_drop()
		return messages
	if secure:
		var tls := _stream as StreamPeerTLS
		tls.poll()
		var st := tls.get_status()
		if st == StreamPeerTLS.STATUS_HANDSHAKING:
			if Time.get_ticks_msec() - opened_msec > HANDSHAKE_TIMEOUT_MS:
				_drop()
			return messages
		if st != StreamPeerTLS.STATUS_CONNECTED:
			_drop()
			return messages
		if state == State.TLS_HANDSHAKE:
			state = State.HTTP
	_read()
	if state == State.HTTP and not request_ready:
		_parse_request()
		if state == State.HTTP and not request_ready and Time.get_ticks_msec() - opened_msec > HANDSHAKE_TIMEOUT_MS:
			_drop()
	elif state == State.WEBSOCKET:
		_parse_frames(messages)
	_flush()
	if state == State.CLOSING and (_out.is_empty() or Time.get_ticks_msec() - _closing_since > CLOSE_TIMEOUT_MS):
		_drop()
	return messages

## Sends a complete HTTP response and closes once it is written.
func respond(status: int, reason: String, content_type: String, body: PackedByteArray,
		extra_headers: PackedStringArray = PackedStringArray()) -> void:
	if state != State.HTTP:
		return
	var head := "HTTP/1.1 %d %s\r\n" % [status, reason]
	head += "Content-Type: %s\r\n" % content_type
	head += "Content-Length: %d\r\n" % body.size()
	head += "Connection: close\r\n"
	head += "Cache-Control: no-store\r\n"
	head += "X-Content-Type-Options: nosniff\r\n"
	head += "Referrer-Policy: no-referrer\r\n"
	for h in extra_headers:
		head += h + "\r\n"
	head += "\r\n"
	_out.append_array(head.to_utf8_buffer())
	_out.append_array(body)
	request_ready = false
	_begin_close()
	_flush()

func respond_text(status: int, reason: String) -> void:
	respond(status, reason, "text/plain; charset=utf-8", ("%d %s\n" % [status, reason]).to_utf8_buffer())

## Answers the pending `GET /ws` with the WebSocket handshake. False (and an HTTP error is
## sent) when the request is not a valid upgrade.
func accept_websocket() -> bool:
	if state != State.HTTP or not request_ready:
		return false
	var key := str(headers.get("sec-websocket-key", "")).strip_edges()
	var upgrade := str(headers.get("upgrade", "")).to_lower()
	if method != "GET" or not upgrade.contains("websocket") or key.is_empty() \
			or str(headers.get("sec-websocket-version", "")).strip_edges() != "13":
		respond(426, "Upgrade Required", "text/plain; charset=utf-8", "426 Upgrade Required\n".to_utf8_buffer(),
				PackedStringArray(["Sec-WebSocket-Version: 13"]))
		return false
	var sha := HashingContext.new()
	sha.start(HashingContext.HASH_SHA1)
	sha.update((key + WS_GUID).to_ascii_buffer())
	var accept := Marshalls.raw_to_base64(sha.finish())
	var head := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
	head += "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
	_out.append_array(head.to_ascii_buffer())
	request_ready = false
	state = State.WEBSOCKET
	_flush()
	return true

func send_text(text: String) -> void:
	if state == State.WEBSOCKET:
		_send_frame(0x1, text.to_utf8_buffer())

## Closes cleanly: a WebSocket gets a close frame, pending output is flushed first.
func close(code: int = 1000) -> void:
	if state == State.WEBSOCKET:
		_send_frame(0x8, PackedByteArray([(code >> 8) & 0xFF, code & 0xFF]))
	if state != State.CLOSED and state != State.CLOSING:
		_begin_close()
		_flush()

## Drops the connection immediately.
func abort() -> void:
	_drop()

# ---------------------------------------------------------------------------- internals

func _begin_close() -> void:
	state = State.CLOSING
	_closing_since = Time.get_ticks_msec()

func _drop() -> void:
	if state == State.CLOSED:
		return
	state = State.CLOSED
	request_ready = false
	_in.clear()
	_out.clear()
	if secure:
		(_stream as StreamPeerTLS).disconnect_from_stream()
	_tcp.disconnect_from_host()

func _read() -> void:
	if state != State.HTTP and state != State.WEBSOCKET:
		return
	var limit := MAX_REQUEST_BYTES if state == State.HTTP else MAX_MESSAGE_BYTES * MAX_MESSAGES_PER_POLL
	# TCP hands over everything at once. TLS only reports the record it has decrypted, and
	# every WebSocket message is its own record: keep going, or a phone sending faster than
	# the game's frame rate would queue up and its inputs would arrive later and later.
	for i in MAX_MESSAGES_PER_POLL:
		var available := _stream.get_available_bytes()
		var room := limit - _in.size()
		if available <= 0 or room <= 0:
			return
		var res: Array = _stream.get_partial_data(mini(available, room))
		if int(res[0]) != OK:
			_drop()
			return
		_in.append_array(res[1] as PackedByteArray)
		if not secure:
			return
		var tls := _stream as StreamPeerTLS
		tls.poll()   # decrypts the next record, if one has arrived
		if tls.get_status() != StreamPeerTLS.STATUS_CONNECTED:
			return   # the next poll() deals with it

func _flush() -> void:
	if _out.is_empty() or state == State.CLOSED or state == State.TLS_HANDSHAKE:
		return
	var res: Array = _stream.put_partial_data(_out)
	if int(res[0]) != OK:
		_drop()
		return
	var sent := int(res[1])
	if sent >= _out.size():
		_out.clear()
	elif sent > 0:
		_out = _out.slice(sent)

func _find_header_end() -> int:
	for i in range(0, _in.size() - 3):
		if _in[i] == 13 and _in[i + 1] == 10 and _in[i + 2] == 13 and _in[i + 3] == 10:
			return i
	return -1

func _parse_request() -> void:
	var end := _find_header_end()
	if end < 0:
		if _in.size() >= MAX_REQUEST_BYTES:
			respond_text(431, "Request Header Fields Too Large")
		return
	var head := _in.slice(0, end)
	_in = _in.slice(end + 4)
	for c in head:
		if (c < 0x20 or c > 0x7E) and c != 13 and c != 10 and c != 9:
			request_ready = true
			respond_text(400, "Bad Request")
			return
	var lines := head.get_string_from_ascii().split("\r\n")
	var parts := lines[0].split(" ", false) if lines.size() > 0 else PackedStringArray()
	if parts.size() != 3 or not parts[2].begins_with("HTTP/1.") or not parts[1].begins_with("/"):
		request_ready = true   # respond() needs the HTTP state; the owner never sees this one
		respond_text(400, "Bad Request")
		return
	method = parts[0]
	path = parts[1].get_slice("?", 0)
	headers.clear()
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon > 0:
			headers[lines[i].substr(0, colon).strip_edges().to_lower()] = lines[i].substr(colon + 1).strip_edges()
	request_ready = true

func _send_frame(opcode: int, payload: PackedByteArray) -> void:
	if _out.size() + payload.size() > MAX_OUT_BYTES:
		_drop()   # the client is not reading: give up on it rather than grow without bound
		return
	var n := payload.size()
	_out.append(0x80 | opcode)
	if n < 126:
		_out.append(n)
	elif n < 65536:
		_out.append(126)
		_out.append((n >> 8) & 0xFF)
		_out.append(n & 0xFF)
	else:
		_out.append(127)
		for shift in range(56, -8, -8):
			_out.append((n >> shift) & 0xFF)
	_out.append_array(payload)

## Decodes the complete frames in the input buffer. A protocol violation closes the socket.
func _parse_frames(messages: PackedStringArray) -> void:
	var pos := 0
	var count := 0
	while state == State.WEBSOCKET and count < MAX_MESSAGES_PER_POLL:
		var left := _in.size() - pos
		if left < 2:
			break
		var b0 := _in[pos]
		var b1 := _in[pos + 1]
		var fin := (b0 & 0x80) != 0
		var opcode := b0 & 0x0F
		var masked := (b1 & 0x80) != 0
		var length := b1 & 0x7F
		# Clients must mask; fragments, extensions and long frames are not needed here.
		if (b0 & 0x70) != 0 or not masked or not fin or opcode == 0x0 or length == 127:
			close(1002)
			break
		var header := 2
		if length == 126:
			if left < 4:
				break
			length = (_in[pos + 2] << 8) | _in[pos + 3]
			header = 4
		if length > MAX_MESSAGE_BYTES or (opcode >= 0x8 and length > 125):
			close(1009)
			break
		if left < header + 4 + length:
			break
		var payload := _in.slice(pos + header + 4, pos + header + 4 + length)
		var printable := true   # the protocol is plain ASCII JSON; anything else is ignored
		for i in length:
			var c := payload[i] ^ _in[pos + header + (i & 3)]
			payload[i] = c
			if c < 0x20 or c > 0x7E:
				printable = false
		pos += header + 4 + length
		count += 1
		match opcode:
			0x1:
				if printable:
					messages.append(payload.get_string_from_ascii())
			0x8:
				close(1000)
			0x9:
				_send_frame(0xA, payload)
			_:
				pass   # binary and pong frames are ignored
	if count > 0:
		last_heard_msec = Time.get_ticks_msec()
	if pos > 0 and state != State.CLOSED:
		_in = _in.slice(pos)
