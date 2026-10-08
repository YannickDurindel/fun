extends TestCase
## Wheel visuals follow their WheelState and use the right meshes / mirroring per corner.

func _visuals(car: Car) -> Array[Node3D]:
	var out: Array[Node3D] = []
	for name: String in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		out.append(car.get_node(name) as Node3D)
	return out

func test_wheels_follow_state() -> void:
	var main := spawn("res://scenes/main.tscn")
	await physics_frames(30)
	var car := main.get_node("Car") as Car
	var vis := _visuals(car)
	for i in 4:
		var wv := vis[i]
		var w := car.wheels[i]
		w.steer_angle = 0.3 if i < 2 else 0.0
		w.spin_angle = 12.5 + i
		w.compression = 0.04
		wv._process(1.0 / 60.0)
		var steer := wv.get_node("Steer") as Node3D
		var spin := wv.get_node("Steer/Spin") as Node3D
		assert_true(steer.basis.is_equal_approx(Basis(Vector3.UP, w.steer_angle)),
			"wheel %d: Steer does not follow steer_angle" % i)
		assert_true(spin.basis.is_equal_approx(Basis(Vector3.RIGHT, -w.spin_angle)),
			"wheel %d: Spin does not follow spin_angle" % i)
		assert_true(wv.position.is_equal_approx(Car.WHEEL_OFFSETS[i] + Vector3(0, 0.04, 0)),
			"wheel %d: position does not follow compression" % i)
		# Outer ball joint (end of the arms) must still meet the hub and the (steered) upright.
		var g: Dictionary = wv.geometry(i < 2)
		var joint_model := Vector3(g["joint_x"], 0, 0)
		var pivot := wv.get_node("Suspension/Pivot") as Node3D
		var arms := wv.get_node("Suspension/Pivot/Arms") as Node3D
		var upright := wv.get_node("Steer/Upright") as Node3D
		var joint_on_arms := car.to_local(arms.global_transform * joint_model)
		var joint_on_upright := car.to_local(upright.global_transform * joint_model)
		assert_between(joint_on_arms.distance_to(joint_on_upright), 0.0, 0.002,
			"wheel %d: arm outer joint to upright distance" % i)
		assert_between(absf(joint_on_arms.y - car.to_local(wv.global_position).y), 0.0, 0.002,
			"wheel %d: arm outer joint height vs hub" % i)
		# Chassis end stays at the unsprung height.
		assert_between(car.to_local(pivot.global_position).y, -0.001, 0.001, "wheel %d pickup y" % i)

func test_meshes_and_mirroring() -> void:
	var geo := load("res://assets/car/wheel_geometry.json") as JSON
	assert_true(geo != null and geo.data is Dictionary and geo.data.has("front") and geo.data.has("rear"),
		"wheel_geometry.json (written by cad/wheels/f1_wheels.py) missing or malformed")
	var main := spawn("res://scenes/main.tscn")
	await physics_frames(5)
	var car := main.get_node("Car") as Car
	var vis := _visuals(car)
	for i in 4:
		var wv := vis[i]
		var front := i < 2
		var wheel := wv.get_node("Steer/Spin/Wheel") as Node3D
		var want := "front" if front else "rear"
		for holder: String in ["Steer/Spin/Wheel", "Steer/Upright", "Suspension/Pivot/Arms"]:
			var h := wv.get_node(holder)
			assert_true(h.get_child_count() == 1 and String(h.get_child(0).name).ends_with(want),
				"wheel %d: %s should hold exactly the %s mesh" % [i, holder, want])
		var side := -1.0 if i % 2 == 0 else 1.0
		assert_true(is_equal_approx(wheel.scale.x, side), "wheel %d: tyre not mirrored to its side" % i)
		assert_true(is_equal_approx((wv.get_node("Suspension") as Node3D).scale.x, side),
			"wheel %d: suspension not mirrored to its side" % i)
		# The rim's outer face (+X in model space) must point away from the car centre.
		var outward := wheel.global_transform.basis.x
		assert_true(car.global_transform.basis.x.dot(outward) * side > 0.5,
			"wheel %d: rim face points inward" % i)
		# Tyre size matches the physics radius.
		var mesh := _first_mesh(wheel)
		assert_true(mesh != null, "wheel %d: no tyre mesh" % i)
		if mesh:
			var r := mesh.get_aabb().size.y * 0.5
			assert_between(r, car.wheel_radius(i) - 0.005, car.wheel_radius(i) + 0.005, "wheel %d radius" % i)

func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _first_mesh(c)
		if m:
			return m
	return null
