class_name QRCode
extends RefCounted
## A small QR-code encoder: byte mode, error correction level M, versions 1 to 6 (up to 106
## bytes, far more than the phone controller's `http://192.168.1.20:8080`). Everything is
## computed here; nothing is fetched from anywhere.
##
##   var qr := QRCode.encode("http://192.168.1.20:8080")   # null if the text is too long
##   qr.size                 modules per side (21 + 4 * (version - 1))
##   qr.is_dark(x, y)        one module, x = column, y = row
##   qr.to_image(8)          black-on-white Image with a 4-module quiet zone
##
## The mask is chosen by the standard penalty rules; `mask` forces one (0..7), which the
## tests use to compare against reference matrices.

## Per version (index = version): [data codewords, error-correction codewords per block, blocks].
const _LEVEL_M: Array[Array] = [
	[], [16, 10, 1], [28, 16, 1], [44, 26, 1], [64, 18, 2], [86, 24, 2], [108, 16, 4],
]
const MAX_VERSION := 6

var version: int = 0
var size: int = 0
var mask: int = 0
## size * size bytes, row by row: 1 = dark.
var modules: PackedByteArray = PackedByteArray()

var _reserved: PackedByteArray = PackedByteArray()   # 1 = function module (not data)

## Largest text (in UTF-8 bytes) that fits.
static func max_bytes() -> int:
	return int(_LEVEL_M[MAX_VERSION][0]) - 2

static func encode(text: String, forced_mask: int = -1) -> QRCode:
	var data := text.to_utf8_buffer()
	var v := 1
	while v <= MAX_VERSION and data.size() > int(_LEVEL_M[v][0]) - 2:
		v += 1
	if v > MAX_VERSION:
		return null
	var qr := QRCode.new()
	qr.version = v
	qr.size = 17 + 4 * v
	var codewords := _interleave(_data_codewords(data, v), v)
	qr._draw_function_patterns()
	qr._place(codewords)
	if forced_mask >= 0 and forced_mask <= 7:
		qr._apply_mask(forced_mask)
		qr.mask = forced_mask
	else:
		var best := -1
		var best_penalty := 0
		for m in 8:
			qr._apply_mask(m)
			qr._draw_format(m)
			var p := qr._penalty()
			if best < 0 or p < best_penalty:
				best = m
				best_penalty = p
			qr._apply_mask(m)   # XOR again: undo
		qr._apply_mask(best)
		qr.mask = best
	qr._draw_format(qr.mask)
	return qr

func is_dark(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < size and y < size and modules[y * size + x] == 1

## Rows of '#' (dark) and '.' (light), for tests and debugging.
func to_rows() -> PackedStringArray:
	var rows := PackedStringArray()
	for y in size:
		var s := ""
		for x in size:
			s += "#" if modules[y * size + x] == 1 else "."
		rows.append(s)
	return rows

## Black modules on white, `scale` pixels per module, with a quiet zone of `border` modules.
func to_image(scale: int = 8, border: int = 4) -> Image:
	scale = maxi(scale, 1)
	var px := (size + border * 2) * scale
	var img := Image.create(px, px, false, Image.FORMAT_L8)
	img.fill(Color.WHITE)
	for y in size:
		for x in size:
			if modules[y * size + x] == 1:
				img.fill_rect(Rect2i((x + border) * scale, (y + border) * scale, scale, scale), Color.BLACK)
	return img

# ---------------------------------------------------------------------------- data

## Mode + length + bytes + terminator + padding, as the version's data codewords.
static func _data_codewords(data: PackedByteArray, v: int) -> PackedByteArray:
	var capacity := int(_LEVEL_M[v][0])
	var bits := PackedByteArray()
	_push_bits(bits, 0b0100, 4)          # byte mode
	_push_bits(bits, data.size(), 8)     # character count (8 bits up to version 9)
	for b in data:
		_push_bits(bits, b, 8)
	_push_bits(bits, 0, mini(4, capacity * 8 - bits.size()))   # terminator
	while bits.size() % 8 != 0:
		bits.append(0)
	var out := PackedByteArray()
	for i in range(0, bits.size(), 8):
		var byte := 0
		for j in 8:
			byte = (byte << 1) | bits[i + j]
		out.append(byte)
	var pad := 0xEC
	while out.size() < capacity:
		out.append(pad)
		pad = 0x11 if pad == 0xEC else 0xEC
	return out

static func _push_bits(bits: PackedByteArray, value: int, count: int) -> void:
	for i in range(count - 1, -1, -1):
		bits.append((value >> i) & 1)

## Splits the data into blocks, adds Reed-Solomon codewords, and interleaves both.
static func _interleave(data: PackedByteArray, v: int) -> PackedByteArray:
	var ec_len := int(_LEVEL_M[v][1])
	var block_count := int(_LEVEL_M[v][2])
	var block_len := data.size() / block_count   # equal blocks for every supported version
	var generator := _rs_generator(ec_len)
	var blocks: Array[PackedByteArray] = []
	var ec_blocks: Array[PackedByteArray] = []
	for b in block_count:
		var block := data.slice(b * block_len, (b + 1) * block_len)
		blocks.append(block)
		ec_blocks.append(_rs_remainder(block, generator))
	var out := PackedByteArray()
	for i in block_len:
		for b in block_count:
			out.append(blocks[b][i])
	for i in ec_len:
		for b in block_count:
			out.append(ec_blocks[b][i])
	return out

## GF(256) multiplication, reduction polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D).
static func _gf_mul(a: int, b: int) -> int:
	var r := 0
	for i in range(7, -1, -1):
		r = (r << 1) ^ ((r >> 7) * 0x11D)
		r ^= ((b >> i) & 1) * a
	return r & 0xFF

## Coefficients of the degree-`degree` generator polynomial, highest power first, without the
## leading 1.
static func _rs_generator(degree: int) -> PackedByteArray:
	var g := PackedByteArray()
	g.resize(degree)
	g[degree - 1] = 1
	var root := 1
	for i in degree:
		for j in degree:
			g[j] = _gf_mul(g[j], root)
			if j + 1 < degree:
				g[j] = g[j] ^ g[j + 1]
		root = _gf_mul(root, 2)
	return g

static func _rs_remainder(data: PackedByteArray, generator: PackedByteArray) -> PackedByteArray:
	var n := generator.size()
	var rem := PackedByteArray()
	rem.resize(n)
	for b in data:
		var factor := b ^ rem[0]
		for i in n - 1:
			rem[i] = rem[i + 1]
		rem[n - 1] = 0
		for i in n:
			rem[i] = rem[i] ^ _gf_mul(generator[i], factor)
	return rem

# ---------------------------------------------------------------------------- matrix

func _set_function(x: int, y: int, dark: bool) -> void:
	modules[y * size + x] = 1 if dark else 0
	_reserved[y * size + x] = 1

func _draw_function_patterns() -> void:
	modules.resize(size * size)
	modules.fill(0)
	_reserved.resize(size * size)
	_reserved.fill(0)
	# Timing patterns.
	for i in size:
		_set_function(6, i, i % 2 == 0)
		_set_function(i, 6, i % 2 == 0)
	# Finder patterns with their separators (they overwrite the ends of the timing lines).
	for c: Vector2i in [Vector2i(3, 3), Vector2i(size - 4, 3), Vector2i(3, size - 4)]:
		for dy in range(-4, 5):
			for dx in range(-4, 5):
				var x := c.x + dx
				var y := c.y + dy
				if x < 0 or y < 0 or x >= size or y >= size:
					continue
				var d := maxi(absi(dx), absi(dy))
				_set_function(x, y, d != 2 and d != 4)
	# One alignment pattern (versions 2 to 6), centred 6 modules from the bottom-right edges.
	if version >= 2:
		var a := size - 7
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				_set_function(a + dx, a + dy, maxi(absi(dx), absi(dy)) != 1)
	# Format information (drawn for real once the mask is known) and the dark module.
	_draw_format(0)

## The 15 format bits (level M + mask, BCH-protected), in both of their places.
func _draw_format(mask_id: int) -> void:
	var data := mask_id   # level M is 0b00, so the 5 data bits are just the mask
	var rem := data
	for i in 10:
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	var bits := ((data << 10) | rem) ^ 0x5412
	for i in 6:
		_set_function(8, i, (bits >> i) & 1 == 1)
	_set_function(8, 7, (bits >> 6) & 1 == 1)
	_set_function(8, 8, (bits >> 7) & 1 == 1)
	_set_function(7, 8, (bits >> 8) & 1 == 1)
	for i in range(9, 15):
		_set_function(14 - i, 8, (bits >> i) & 1 == 1)
	for i in 8:
		_set_function(size - 1 - i, 8, (bits >> i) & 1 == 1)
	for i in range(8, 15):
		_set_function(8, size - 15 + i, (bits >> i) & 1 == 1)
	_set_function(8, size - 8, true)

## Writes the codeword bits in the zigzag order, two columns at a time from the right.
func _place(codewords: PackedByteArray) -> void:
	var i := 0
	var total := codewords.size() * 8
	var right := size - 1
	while right >= 1:
		if right == 6:
			right = 5   # the vertical timing column is skipped
		for vert in size:
			for j in 2:
				var x := right - j
				var upward := ((right + 1) & 2) == 0
				var y := (size - 1 - vert) if upward else vert
				if _reserved[y * size + x] == 0 and i < total:
					modules[y * size + x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1
					i += 1
		right -= 2

func _apply_mask(mask_id: int) -> void:
	for y in size:
		for x in size:
			if _reserved[y * size + x] == 1:
				continue
			var invert := false
			match mask_id:
				0: invert = (x + y) % 2 == 0
				1: invert = y % 2 == 0
				2: invert = x % 3 == 0
				3: invert = (x + y) % 3 == 0
				4: invert = (x / 3 + y / 2) % 2 == 0
				5: invert = x * y % 2 + x * y % 3 == 0
				6: invert = (x * y % 2 + x * y % 3) % 2 == 0
				7: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
			if invert:
				modules[y * size + x] = modules[y * size + x] ^ 1

## The standard's four penalty rules (lower is better).
func _penalty() -> int:
	var result := 0
	for pass_id in 2:
		for a in size:
			var run_color := -1
			var run := 0
			var history := 0   # the last 11 modules of the line, as bits
			for b in size:
				var c: int = modules[a * size + b] if pass_id == 0 else modules[b * size + a]
				if c == run_color:
					run += 1
					if run == 5:
						result += 3
					elif run > 5:
						result += 1
				else:
					run_color = c
					run = 1
				history = ((history << 1) | c) & 0x7FF
				# Finder-like 1:1:3:1:1 with four light modules on one side.
				if b >= 10 and (history == 0b10111010000 or history == 0b00001011101):
					result += 40
	for y in size - 1:
		for x in size - 1:
			var c := modules[y * size + x]
			if c == modules[y * size + x + 1] and c == modules[(y + 1) * size + x] and c == modules[(y + 1) * size + x + 1]:
				result += 3
	var dark := 0
	for m in modules:
		dark += m
	var total := size * size
	# 10 points for every 5 % the dark share is away from 50 %.
	result += 10 * (absi(dark * 20 - total * 10) / total)
	return result
