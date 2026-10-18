extends TestCase
## Grandstand spectators and flags (scripts/track/scenery_crowd.gd, crowd.gdshader,
## flag.gdshader): seats found on the treads of stand_seats surfaces, facing the front of the
## stand, partly taken; flags on the highest face over the top row; the meshes are wound
## the way their normals point. Also on the survey Le Mans landmark grandstands.

const LANDMARKS := "res://assets/tracks/wec_le_mans_survey/landmarks/"

## A stepped stand like cad/track/scenery_glb.py grandstand: `rows` treads 0.85 m deep and
## 0.45 m apart in height, 20 m long along +X, rising towards +Z (so it faces -Z), UV in
## metres (u along the row, v the depth from the front), a riser between treads and a flat
## roof 3 m over the top row.
func _stand(rows: int) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in rows:
		var y := 1.2 + 0.45 * k
		var z0 := 0.85 * k
		var z1 := z0 + 0.85
		var tread: Array[Vector3] = [Vector3(0, y, z0), Vector3(20, y, z0), Vector3(20, y, z1), Vector3(0, y, z1)]
		for i: int in [0, 1, 2, 0, 2, 3]:
			st.set_uv(Vector2(tread[i].x, tread[i].z))
			st.add_vertex(tread[i])
		if k > 0:
			var riser: Array[Vector3] = [Vector3(0, y - 0.45, z0), Vector3(20, y - 0.45, z0), Vector3(20, y, z0), Vector3(0, y, z0)]
			for i: int in [0, 1, 2, 0, 2, 3]:
				st.set_uv(Vector2(riser[i].x, z0))
				st.add_vertex(riser[i])
	var seats := StandardMaterial3D.new()
	seats.resource_name = "stand_seats"
	st.set_material(seats)
	var mesh := st.commit()
	var roof := SurfaceTool.new()
	roof.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top := 1.2 + 0.45 * (rows - 1) + 3.0
	for p: Vector3 in [Vector3(-1, top, -2), Vector3(21, top, -2), Vector3(21, top, 0.85 * rows + 1),
			Vector3(-1, top, -2), Vector3(21, top, 0.85 * rows + 1), Vector3(-1, top, 0.85 * rows + 1)]:
		roof.add_vertex(p)
	var roof_mat := StandardMaterial3D.new()
	roof_mat.resource_name = "building_roof"
	roof.set_material(roof_mat)
	roof.commit(mesh)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi

func test_seats_on_treads_face_the_front() -> void:
	var mi := _stand(6)
	var spots := SceneryCrowd.seat_spots(mi, Transform3D.IDENTITY)
	# 20 m / 0.55 m per seat, six rows; risers carry no one.
	var per_row := int(20.0 / SceneryCrowd.SEAT_WIDTH)
	assert_between(spots.size(), per_row * 6 - 6, per_row * 6 + 6, "seats on six treads")
	for spot: Array in spots:
		var p: Vector3 = spot[0]
		var facing: Vector3 = spot[1]
		assert_true(facing.distance_to(Vector3(0, 0, -1)) < 0.01, "seat faces the front: %s" % facing)
		var row := roundi((p.y - 1.2) / 0.45)
		assert_true(absf(p.y - (1.2 + 0.45 * row)) < 0.01 and absf(p.z - (0.85 * row + 0.425)) < 0.01,
				"seat in the middle of its tread: %s" % p)
	# Turned and moved stands keep the facing in world space.
	var xf := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(100, 5, -40))
	var turned := SceneryCrowd.seat_spots(mi, xf)
	assert_true(turned.size() == spots.size(), "same seats turned")
	var f: Vector3 = turned[0][1]
	assert_true(f.distance_to(xf.basis * Vector3(0, 0, -1)) < 0.01, "facing turns with the stand: %s" % f)
	mi.free()

func test_partial_fill_in_cells() -> void:
	var mi := _stand(20)
	var spots := SceneryCrowd.seat_spots(mi, Transform3D.IDENTITY)
	var cells := SceneryCrowd.spectators(spots, 0.6)
	var taken := 0
	for key: Vector2i in cells:
		var buf: PackedFloat32Array = cells[key]
		assert_true(buf.size() % 16 == 0, "3x4 transform + custom per spectator")
		for i in range(0, buf.size(), 16):
			taken += 1
			var shirt := Color(buf[i + 12], buf[i + 13], buf[i + 14])
			assert_true(shirt.r >= 0.0 and shirt.r <= 1.0 and buf[i + 15] >= 0.0 and buf[i + 15] < 1.0, "custom data")
	var share := float(taken) / spots.size()
	assert_between(share, 0.4, 0.8, "share of seats taken at crowd 0.6")
	assert_true(SceneryCrowd.spectators(spots, 0.0).is_empty(), "nobody at crowd 0")
	# Same seats, same spectators (deterministic).
	assert_true(SceneryCrowd.spectators(spots, 0.6) == cells, "deterministic")
	mi.free()

func test_flags_stand_on_the_roof() -> void:
	var mi := _stand(8)
	var spots := SceneryCrowd.seat_spots(mi, Transform3D.IDENTITY)
	var flags := SceneryCrowd.flag_spots(spots)
	assert_true(flags.size() >= 1 and flags.size() <= 2, "one flag per stretch: %d" % flags.size())
	var top_row := 1.2 + 0.45 * 7
	var points: Array[Vector3] = []
	for f: Array in flags:
		assert_true(absf((f[0] as Vector3).y - top_row) < 0.01, "flag spot on the top row")
		assert_true(absf((f[2] as Vector3).y - 1.2) < 0.01, "and the front row")
		points.append(f[0])
	var tops := SceneryCrowd.highest_over(mi, Transform3D.IDENTITY, points)
	for y in tops:
		assert_true(absf(y - (top_row + 3.0)) < 0.01, "flag on the roof: %.2f" % y)
	mi.free()

## Every triangle's winding agrees with its normal (Godot: front faces clockwise).
func _wound_like_normals(mesh: ArrayMesh, surf: int) -> bool:
	var arrays := mesh.surface_get_arrays(surf)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for t in range(0, v.size(), 3):
		if (v[t + 2] - v[t]).cross(v[t + 1] - v[t]).dot(n[t]) <= 0.0:
			return false
	return true

func test_meshes() -> void:
	for lod in 2:
		var m := SceneryCrowd.spectator_mesh(lod)
		assert_true(_wound_like_normals(m, 0), "spectator lod %d wound like its normals" % lod)
		var tris := (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		assert_true(tris <= (48 if lod == 0 else 6), "spectator lod %d is small: %d triangles" % [lod, tris])
		var box := m.get_aabb()
		assert_between(box.end.y, 1.1, 1.4, "seated height")
	var flag := SceneryCrowd.flag_mesh()
	assert_true(flag.get_surface_count() == 2 and _wound_like_normals(flag, 0), "pole and cloth")
	for d: Array in SceneryCrowd.FLAGS:
		assert_true(int(d[0]) >= 0 and int(d[0]) <= 5 and d[1] is Color, "flag design %s" % str(d))
	var crowd := ShaderMaterial.new()
	crowd.shader = SceneryCrowd.CROWD_SHADER
	assert_true(crowd.shader.get_mode() == Shader.MODE_SPATIAL, "crowd shader loads")
	assert_true(SceneryCrowd.FLAG_SHADER.get_mode() == Shader.MODE_SPATIAL, "flag shader loads")

func test_le_mans_landmark_stands_get_spectators() -> void:
	var total := 0
	for model: String in ["pits", "stands_pit", "stands_main", "stands_north", "stand_dunlop"]:
		var root := Scenery.load_glb(LANDMARKS + model + ".glb")
		assert_true(root != null, "%s.glb loads" % model)
		if root == null:
			continue
		var seats := 0
		var flags := 0
		for mi in Scenery.mesh_instances(root):
			var spots := SceneryCrowd.seat_spots(mi, Transform3D.IDENTITY)
			seats += spots.size()
			flags += SceneryCrowd.flag_spots(spots).size()
		assert_true(seats >= 200, "%s has seat rows: %d seats" % [model, seats])
		assert_true(flags >= 1, "%s gets a flag" % model)
		total += seats
		root.free()
	assert_true(total < SceneryCrowd.LIMIT, "within the budget: %d seats" % total)
