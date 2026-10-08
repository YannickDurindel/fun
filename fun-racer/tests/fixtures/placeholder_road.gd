extends Node3D
## TEST FIXTURE: the original placeholder road (runtime ribbon + shoulders + trimesh collision),
## kept so tests can swap a simple, known road into the Track's Road slot.

@export var shoulder_width: float = 35.0
@export var stride: int = 2   ## centreline points per mesh segment

func _ready() -> void:
	var track := get_parent() as Track
	if track == null or track.data == null:
		return
	var d := track.data
	var road := _ribbon(d, -0.5, 0.5, 0.0, Color(0.32, 0.33, 0.35))
	var left := _ribbon(d, -0.5, -0.5, -shoulder_width, Color(0.25, 0.42, 0.18), -0.25)
	var right := _ribbon(d, 0.5, 0.5, shoulder_width, Color(0.25, 0.42, 0.18), -0.25)
	for m: ArrayMesh in [road, left, right]:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		add_child(mi)
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = m.create_trimesh_shape()
		body.add_child(cs)
		add_child(body)

## Strip between lateral offsets (a*width + extra_a) and (b*width + extra_b).
func _ribbon(d: TrackData, a: float, b: float, extra_b: float, col: Color, drop: float = 0.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.9
	st.set_material(mat)
	var n := d.points.size()
	var prev: Array = []
	for k in range(0, n + stride, stride):
		var s := float(k % n) * d.step
		var xf := d.sample(s)
		var w := d.width_at(s)
		var pa := xf.origin + xf.basis.x * (a * w)
		var pb := xf.origin + xf.basis.x * (b * w + extra_b) + xf.basis.y * drop
		if not prev.is_empty():
			var qa: Vector3 = prev[0]
			var qb: Vector3 = prev[1]
			# Wind so the top face points up whichever side the strip is on.
			if (pb - pa).dot(xf.basis.x) >= 0.0:
				st.add_vertex(qa); st.add_vertex(pa); st.add_vertex(qb)
				st.add_vertex(qb); st.add_vertex(pa); st.add_vertex(pb)
			else:
				st.add_vertex(qa); st.add_vertex(qb); st.add_vertex(pa)
				st.add_vertex(qb); st.add_vertex(pb); st.add_vertex(pa)
		prev = [pa, pb]
	st.generate_normals()
	return st.commit()
