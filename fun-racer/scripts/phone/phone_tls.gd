class_name PhoneTLS
extends RefCounted
## The self-signed certificate of the phone controller's HTTPS port.
##
## iPhones (and some Android browsers) only give a web page the motion sensors over HTTPS,
## so the game also serves the controller page with TLS. The key and certificate are made on
## this machine by Godot's Crypto class the first time they are needed and kept in user://;
## nothing is downloaded and nothing leaves the computer. The certificate is self-signed, so
## the phone's browser shows a warning once, which the player accepts.
##
## Making a 2048-bit RSA key can take a second, so it happens on a worker thread:
## request() returns null until the pair is ready; call it again later.

const KEY_PATH := "user://phone_tls.key"
const CERT_PATH := "user://phone_tls.crt"
## Browsers refuse server certificates valid for more than about 13 months.
const VALID_DAYS := 390
const RENEW_AFTER_DAYS := 330
const SUBJECT := "CN=Fun Racer phone controller,O=Fun Racer"

static var _cached: TLSOptions = null
static var _thread: Thread = null
static var _failed: bool = false

## Server-side TLS options, or null while they are being made (or if that failed: see
## failed()). `use_disk` false keeps everything in memory (tests and other automated runs).
static func request(use_disk: bool) -> TLSOptions:
	if _cached != null:
		return _cached
	if _thread == null:
		_cached = _load() if use_disk else null
		if _cached != null:
			return _cached
		_failed = false
		_thread = Thread.new()
		if _thread.start(_generate.bind(use_disk)) != OK:
			_thread = null
			_failed = true
		return null
	if _thread.is_alive():
		return null
	_cached = _thread.wait_to_finish() as TLSOptions
	_thread = null
	_failed = _cached == null
	return _cached

## True when the last attempt could not make a key or a certificate.
static func failed() -> bool:
	return _failed and _cached == null and _thread == null

## Waits for a running generation to end (call before the game quits).
static func finish() -> void:
	if _thread != null:
		_cached = _thread.wait_to_finish() as TLSOptions
		_thread = null

## The saved pair, if there is one and it is not about to expire.
static func _load() -> TLSOptions:
	if not (FileAccess.file_exists(KEY_PATH) and FileAccess.file_exists(CERT_PATH)):
		return null
	var age_days := (Time.get_unix_time_from_system() - float(FileAccess.get_modified_time(CERT_PATH))) / 86400.0
	if age_days < 0.0 or age_days >= RENEW_AFTER_DAYS:
		return null
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(KEY_PATH) != OK or cert.load(CERT_PATH) != OK:
		return null
	return TLSOptions.server(key, cert)

## Runs on the worker thread.
static func _generate(use_disk: bool) -> TLSOptions:
	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	if key == null:
		return null
	var now := Time.get_unix_time_from_system()
	var cert := crypto.generate_self_signed_certificate(key, SUBJECT, _stamp(now - 86400.0), _stamp(now + VALID_DAYS * 86400.0))
	if cert == null:
		return null
	if use_disk:
		# If saving fails the pair still works for this session.
		if key.save(KEY_PATH) == OK:
			FileAccess.set_unix_permissions(KEY_PATH, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
		cert.save(CERT_PATH)
	return TLSOptions.server(key, cert)

## YYYYMMDDhhmmss (UTC), the format generate_self_signed_certificate() expects.
static func _stamp(unix: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(unix))
	return "%04d%02d%02d%02d%02d%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"], d["second"]]
