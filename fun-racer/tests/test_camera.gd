extends TestCase
## Chase camera: stays behind / above the car, FOV widens with speed,
## modes change the offset, respawn snaps instantly.

var _main: Node
var _car: Car
var _cam: Camera3D

func _setup() -> void:
	Bootstrap.autodrive = true
	_main = spawn("res://scenes/main.tscn")
	_car = _main.get_node("Car") as Car
	_cam = _main.get_node("ChaseCamera") as Camera3D
	_cam.call("set_mode", 1)

func _teardown() -> void:
	Bootstrap.autodrive = false

func process_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

## Car->camera vector expressed in car space, flattened onto the ground plane.
func _behind_dot() -> float:
	var to_cam := _cam.global_position - _car.global_position
	to_cam.y = 0.0
	var back := _car.global_transform.basis.z
	back.y = 0.0
	return to_cam.normalized().dot(back.normalized())

func test_follows_behind_and_above() -> void:
	_setup()
	for m in [1, 2]:
		_cam.call("set_mode", m)
		var min_dot := 1.0
		var min_y := 100.0
		var min_d := 1000.0
		var max_d := 0.0
		for i in 40:
			await physics_frames(6)
			await process_frames(1)
			min_dot = minf(min_dot, _behind_dot())
			min_y = minf(min_y, _cam.global_position.y)
			var d := _cam.global_position.distance_to(_car.global_position)
			min_d = minf(min_d, d)
			max_d = maxf(max_d, d)
		assert_true(min_dot > 0.0, "cam %d not behind the car (min dot %.3f)" % [m, min_dot])
		assert_true(min_y > 0.3, "cam %d went below ground (y=%.3f)" % [m, min_y])
		assert_between(min_d, 3.0, 20.0, "cam %d min distance" % m)
		assert_between(max_d, 3.0, 20.0, "cam %d max distance" % m)
	assert_true(_car.speed_kmh > 20.0, "car did not accelerate (%.1f km/h)" % _car.speed_kmh)
	_teardown()

func test_fov_increases_with_speed() -> void:
	_setup()
	await process_frames(2)
	var fov_rest := _cam.fov
	await physics_frames(480)
	await process_frames(2)
	assert_true(_car.speed_kmh > 50.0, "car too slow for FOV test (%.1f km/h)" % _car.speed_kmh)
	assert_true(_cam.fov > fov_rest + 1.0, "FOV did not widen: rest %.2f, moving %.2f" % [fov_rest, _cam.fov])
	assert_between(_cam.fov, 60.0, 95.0, "fov")
	_teardown()

func test_modes_change_offset() -> void:
	_setup()
	await physics_frames(30)
	var offsets: Array[Vector3] = []
	for m in [1, 2, 3]:
		_cam.call("set_mode", m)
		offsets.append(_car.global_transform.affine_inverse() * _cam.global_position)
	assert_true(offsets[0].distance_to(offsets[1]) > 1.0, "cam 1 and 2 share an offset")
	assert_true(offsets[1].y > offsets[0].y and offsets[1].z > offsets[0].z, "cam 2 should be higher and further back")
	assert_true(offsets[2].distance_to(_cam.get("cockpit_offset")) < 0.3, "cockpit offset wrong: %s" % offsets[2])
	# Cockpit looks straight ahead along the car.
	var fwd_dot := (-_cam.global_transform.basis.z).dot(-_car.global_transform.basis.z)
	assert_true(fwd_dot > 0.99, "cockpit not looking forward (%.3f)" % fwd_dot)
	_teardown()

func test_respawn_snaps() -> void:
	_setup()
	await process_frames(2)
	var rest_offset := _car.global_transform.affine_inverse() * _cam.global_position
	await physics_frames(600)
	await process_frames(1)
	assert_true(_car.global_position.distance_to(_car.spawn_transform.origin) > 20.0, "car did not move away")
	_car.respawn()
	await process_frames(1)
	var offset := _car.global_transform.affine_inverse() * _cam.global_position
	assert_true(offset.distance_to(rest_offset) < 0.5,
		"camera did not snap on respawn: %s vs rest %s" % [offset, rest_offset])
	# ...and it must not swoop back towards the old position on the following frames.
	for i in 5:
		await process_frames(1)
		offset = _car.global_transform.affine_inverse() * _cam.global_position
		assert_true(offset.distance_to(rest_offset) < 0.75,
			"camera swooped after respawn (frame %d): %s vs rest %s" % [i, offset, rest_offset])
	_teardown()
