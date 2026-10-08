class_name TestCase
extends Node
## Base for tests. Methods named test_* are run in order; they may `await`.
## The test node is added to the SceneTree root, so physics runs normally.

var failures: Array[String] = []

func assert_true(cond: bool, msg: String = "assertion failed") -> void:
	if not cond:
		failures.append(msg)

func assert_between(value: float, lo: float, hi: float, what: String) -> void:
	assert_true(value >= lo and value <= hi, "%s = %.3f, expected in [%.3f, %.3f]" % [what, value, lo, hi])

func physics_frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## Instances a scene under this test node and returns it.
func spawn(path: String) -> Node:
	var n: Node = (load(path) as PackedScene).instantiate()
	add_child(n)
	return n
