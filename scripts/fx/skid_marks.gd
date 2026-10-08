extends Node3D
## Pooled world-space skid-mark ribbons.
##
## Segments live in a fixed ring buffer split into CHUNK_COUNT ArrayMesh chunks, so memory is
## bounded and only the chunk(s) touched this frame are re-uploaded. The oldest chunks fade out
## (shader, by segment serial) before they are overwritten. One strip per wheel; a strip is a
## chain of quads that share edges, oriented perpendicular to the direction of travel.
## Nearly-collinear steps are merged into the previous quad, so long arcs stay cheap.

const MIN_STEP: float = 0.2          ## metres of travel between new ribbon points
const BREAK_STEP: float = 4.0        ## a jump larger than this (teleport/respawn) ends the strip
const MERGE_COS: float = 0.99939     ## cos(2 deg): steps straighter than this extend the last quad
const MERGE_MAX_LEN: float = 2.5     ## ...as long as that quad stays shorter than this
const MERGE_MAX_ALPHA_DELTA: float = 0.06
const LIFT: float = 0.012            ## raise above the surface (plus a depth pull in the shader)
const START_ALPHA_SCALE: float = 0.35 ## soft fade-in / fade-out at strip ends

var chunk_segments: int = 512
var chunk_count: int = 12
var capacity: int = chunk_segments * chunk_count

var material: ShaderMaterial = _make_material()

static func _make_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/fx_skid_mark.gdshader")
	return m

## Monotonic count of segments ever created (merges do not count).
var total_segments_written: int = 0

class Strip:
	var active: bool = false        ## a ribbon is in progress (has an anchor point)
	var anchor: Vector3             ## last ribbon point (end of last quad)
	var left: Vector3               ## end edge of last quad (or anchor edge before the first quad)
	var right: Vector3
	var alpha: float = 0.0
	var v: float = 0.0              ## distance along the strip (texture V)
	var seg_serial: int = -1        ## serial of the last quad, -1 if none yet
	var seg_start: Vector3          ## start point of the last quad (for merging)
	var seg_start_v: float = 0.0
	var seg_dir: Vector3

class Chunk:
	var mesh: ArrayMesh
	var instance: MeshInstance3D
	var count: int = 0
	var dirty: bool = false
	var verts: PackedVector3Array
	var normals: PackedVector3Array
	var colors: PackedColorArray
	var uvs: PackedVector2Array
	var uv2s: PackedVector2Array
	var indices: PackedInt32Array

var _strips: Array[Strip] = []
var _chunks: Array[Chunk] = []

func _ready() -> void:
	_build()

## Re-creates the pool with a new size (clears all marks). Used by tests to force wrap-around.
func configure(segments_per_chunk: int, chunks: int) -> void:
	chunk_segments = maxi(segments_per_chunk, 4)
	chunk_count = maxi(chunks, 3)
	capacity = chunk_segments * chunk_count
	_build()

func _build() -> void:
	for c in _chunks:
		c.instance.queue_free()
	_chunks.clear()
	_strips.clear()
	total_segments_written = 0
	for i in 4:
		_strips.append(Strip.new())
	for i in chunk_count:
		var c := Chunk.new()
		c.mesh = ArrayMesh.new()
		c.instance = MeshInstance3D.new()
		c.instance.name = "SkidChunk%d" % i
		c.instance.mesh = c.mesh
		c.instance.material_override = material
		c.instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		c.instance.top_level = true   # vertices are world-space
		c.instance.transform = Transform3D.IDENTITY
		var n := chunk_segments * 4
		c.verts.resize(n)
		c.normals.resize(n)
		c.colors.resize(n)
		c.uvs.resize(n)
		c.uv2s.resize(n)
		c.indices.resize(chunk_segments * 6)
		for s in chunk_segments:
			var b := s * 4
			var k := s * 6
			c.indices[k] = b
			c.indices[k + 1] = b + 1
			c.indices[k + 2] = b + 2
			c.indices[k + 3] = b + 2
			c.indices[k + 4] = b + 1
			c.indices[k + 5] = b + 3
		_chunks.append(c)
		add_child(c.instance)
	_update_fade_uniforms()

## Removes every mark (e.g. on map restart).
func clear() -> void:
	for c in _chunks:
		c.count = 0
		c.dirty = false
		c.mesh.clear_surfaces()
	for s in _strips:
		s.active = false
		s.seg_serial = -1
	total_segments_written = 0
	_update_fade_uniforms()

## Number of segments currently stored (bounded by `capacity`).
func segment_count() -> int:
	var n := 0
	for c in _chunks:
		n += c.count
	return n

## Feeds the current contact of wheel `wheel` while it is sliding.
## `alpha` in 0..1 is the mark opacity, `width` the tyre width in metres.
func add_point(wheel: int, point: Vector3, normal: Vector3, width: float, alpha: float) -> void:
	var s := _strips[wheel]
	var n := normal.normalized() if normal.length_squared() > 0.01 else Vector3.UP
	var p := point + n * LIFT
	if not s.active:
		s.active = true
		s.anchor = p
		s.alpha = alpha
		s.seg_serial = -1
		s.v = 0.0
		return
	var step := p - s.anchor
	step -= n * step.dot(n)   # travel on the surface plane
	var dist := step.length()
	if dist > BREAK_STEP:
		end_strip(wheel)
		add_point(wheel, point, normal, width, alpha)
		return
	if dist < MIN_STEP:
		return
	var dir := step / dist
	var side := n.cross(dir).normalized() * (width * 0.5)
	var new_left := p + side
	var new_right := p - side

	# Merge into the previous quad when the path is (nearly) straight.
	if s.seg_serial >= 0 and total_segments_written - 1 - s.seg_serial < capacity - chunk_segments:
		var merged_vec := p - s.seg_start
		merged_vec -= n * merged_vec.dot(n)
		var merged_len := merged_vec.length()
		if dir.dot(s.seg_dir) > MERGE_COS and merged_len < MERGE_MAX_LEN \
				and absf(alpha - s.alpha) < MERGE_MAX_ALPHA_DELTA:
			var mv := s.seg_start_v + merged_len
			_write_end_edge(s.seg_serial, new_left, new_right, n, alpha, mv)
			s.anchor = p
			s.left = new_left
			s.right = new_right
			s.v = mv
			s.seg_dir = merged_vec / merged_len
			return

	var start_left := s.left
	var start_right := s.right
	var start_alpha := s.alpha
	if s.seg_serial < 0:
		# First quad of the strip: start edge uses the first travel direction, faded in.
		start_left = s.anchor + side
		start_right = s.anchor - side
		start_alpha = alpha * START_ALPHA_SCALE
	var serial := total_segments_written
	total_segments_written += 1
	_write_segment(serial, start_left, start_right, new_left, new_right, n, start_alpha, alpha, s.v, s.v + dist)
	s.seg_serial = serial
	s.seg_start = s.anchor
	s.seg_start_v = s.v
	s.seg_dir = dir
	s.anchor = p
	s.left = new_left
	s.right = new_right
	s.alpha = alpha
	s.v += dist

## Ends the ribbon of `wheel` (contact or slip lost); the tail fades out softly.
func end_strip(wheel: int) -> void:
	var s := _strips[wheel]
	if s.active and s.seg_serial >= 0 and total_segments_written - 1 - s.seg_serial < capacity - chunk_segments:
		var slot := s.seg_serial % capacity
		var c := _chunks[slot / chunk_segments]
		var b := (slot % chunk_segments) * 4
		for k in [2, 3]:
			var col := c.colors[b + k]
			col.a *= START_ALPHA_SCALE
			c.colors[b + k] = col
		c.dirty = true
	s.active = false
	s.seg_serial = -1

func end_all_strips() -> void:
	for i in _strips.size():
		end_strip(i)

func is_strip_active(wheel: int) -> bool:
	return _strips[wheel].active

func _write_segment(serial: int, l0: Vector3, r0: Vector3, l1: Vector3, r1: Vector3, n: Vector3,
		a0: float, a1: float, v0: float, v1: float) -> void:
	var slot := serial % capacity
	var ci := slot / chunk_segments
	var local := slot % chunk_segments
	var c := _chunks[ci]
	if local == 0:
		c.count = 0   # recycling the oldest chunk
	c.count = local + 1
	var b := local * 4
	c.verts[b] = l0
	c.verts[b + 1] = r0
	c.verts[b + 2] = l1
	c.verts[b + 3] = r1
	var ser := Vector2(float(serial), 0.0)
	for k in 4:
		c.normals[b + k] = n
		c.uv2s[b + k] = ser
	c.colors[b] = Color(1, 1, 1, a0)
	c.colors[b + 1] = Color(1, 1, 1, a0)
	c.colors[b + 2] = Color(1, 1, 1, a1)
	c.colors[b + 3] = Color(1, 1, 1, a1)
	c.uvs[b] = Vector2(0.0, v0)
	c.uvs[b + 1] = Vector2(1.0, v0)
	c.uvs[b + 2] = Vector2(0.0, v1)
	c.uvs[b + 3] = Vector2(1.0, v1)
	c.dirty = true

func _write_end_edge(serial: int, l1: Vector3, r1: Vector3, n: Vector3, a1: float, v1: float) -> void:
	var slot := serial % capacity
	var c := _chunks[slot / chunk_segments]
	var b := (slot % chunk_segments) * 4
	c.verts[b + 2] = l1
	c.verts[b + 3] = r1
	c.normals[b + 2] = n
	c.normals[b + 3] = n
	c.colors[b + 2] = Color(1, 1, 1, a1)
	c.colors[b + 3] = Color(1, 1, 1, a1)
	c.uvs[b + 2] = Vector2(0.0, v1)
	c.uvs[b + 3] = Vector2(1.0, v1)
	c.dirty = true

func _process(_delta: float) -> void:
	for c in _chunks:
		if c.dirty:
			_upload(c)
	_update_fade_uniforms()

func _upload(c: Chunk) -> void:
	c.dirty = false
	c.mesh.clear_surfaces()
	if c.count == 0:
		return
	var nv := c.count * 4
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = c.verts.slice(0, nv)
	arrays[Mesh.ARRAY_NORMAL] = c.normals.slice(0, nv)
	arrays[Mesh.ARRAY_COLOR] = c.colors.slice(0, nv)
	arrays[Mesh.ARRAY_TEX_UV] = c.uvs.slice(0, nv)
	arrays[Mesh.ARRAY_TEX_UV2] = c.uv2s.slice(0, nv)
	arrays[Mesh.ARRAY_INDEX] = c.indices.slice(0, c.count * 6)
	c.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

## Segments older than (chunk_count - 1) chunks are about to be recycled: fade them over the
## two chunks before that so overwriting is invisible.
func _update_fade_uniforms() -> void:
	material.set_shader_parameter("head_serial", float(total_segments_written))
	material.set_shader_parameter("fade_start", float((chunk_count - 3) * chunk_segments))
	material.set_shader_parameter("fade_end", float((chunk_count - 1) * chunk_segments))
