extends TestCase
## Infinite ground: collision far from the origin and visuals following the camera.

const WORLD := "res://scenes/world/world.tscn"


func test_ground_catches_body_far_from_origin() -> void:
	spawn(WORLD)
	var body := RigidBody3D.new()
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	shape.shape = sphere
	body.add_child(shape)
	add_child(body)
	body.global_position = Vector3(5000.0, 3.0, -4200.0)
	await physics_frames(480)
	assert_between(body.global_position.y, 0.45, 0.55, "sphere centre height at x=5000")
	assert_between(body.global_position.x, 4999.9, 5000.1, "sphere x drift")


func test_visible_ground_follows_camera() -> void:
	var world := spawn(WORLD)
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.global_position = Vector3(5013.0, 3.0, -12345.0)
	for i in 3:
		await get_tree().process_frame
	var mesh := world.get_node("Ground/Mesh") as MeshInstance3D
	var p := mesh.global_position
	assert_true(absf(p.y) < 0.001, "ground top surface must stay at y = 0 (got %.3f)" % p.y)
	assert_between(absf(p.x - cam.global_position.x), 0.0, 16.0, "ground |dx| to camera")
	assert_between(absf(p.z - cam.global_position.z), 0.0, 16.0, "ground |dz| to camera")
	assert_true(is_equal_approx(fposmod(p.x, 32.0), 0.0) and is_equal_approx(fposmod(p.z, 32.0), 0.0),
		"ground must snap to the 32 m tile grid")
	var mat := mesh.get_active_material(0) as ShaderMaterial
	var off: Vector2 = mat.get_shader_parameter(&"pattern_offset")
	assert_true(is_equal_approx(off.x, fposmod(p.x, 1024.0)) and is_equal_approx(off.y, fposmod(p.z, 1024.0)),
		"pattern_offset must equal the mesh origin modulo 1024 (got %s)" % off)
	var horizon := world.get_node("Horizon") as Node3D
	var hp := horizon.global_position
	assert_true(Vector2(hp.x, hp.z).distance_to(Vector2(cam.global_position.x, cam.global_position.z)) < 0.01,
		"horizon ring must be centred on the camera")
	# Move on: the mesh must keep up.
	cam.global_position = Vector3(-30000.0, 3.0, 777.0)
	for i in 2:
		await get_tree().process_frame
	p = mesh.global_position
	assert_between(absf(p.x - cam.global_position.x), 0.0, 16.0, "ground |dx| after move")
	assert_between(absf(p.z - cam.global_position.z), 0.0, 16.0, "ground |dz| after move")
