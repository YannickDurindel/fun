extends TestCase
## Chase camera and driving FX on the Red Bull Ring hills: clearance over the climb to
## Remus, car framed like on the flat, gentle pitch over the crest, skid marks on the slope.

const RACE := "res://scenes/race_red_bull_ring.tscn"

var _prev_autodrive: bool
var _prev_spawn_s: float

func _begin(scene: String, spawn_s: float) -> Node:
	_prev_autodrive = Bootstrap.autodrive
	_prev_spawn_s = Bootstrap.spawn_s
	Bootstrap.autodrive = true
	Bootstrap.spawn_s = spawn_s
	var root := spawn(scene)
	var cam := root.get_node("ChaseCamera") as Camera3D
	cam.call("set_mode", 1)
	return root

func _end() -> void:
	Bootstrap.autodrive = _prev_autodrive
	Bootstrap.spawn_s = _prev_spawn_s

## Gives the car an initial speed along the track so tests do not wait for it to accelerate.
func _launch(root: Node, s: float, speed: float) -> void:
	var track := root.get_node("Track") as Track
	var car := root.get_node("Car") as Car
	car.linear_velocity = track.data.tangent_at(s) * speed

## Height of the camera above the surface directly below it (car excluded).
func _clearance(cam: Camera3D, car: Car) -> float:
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position + Vector3.UP * 30.0
	var q := PhysicsRayQueryParameters3D.create(from, cam.global_position + Vector3.DOWN * 60.0)
	q.exclude = [car.get_rid()]
	var hit := space.intersect_ray(q)
	return INF if hit.is_empty() else cam.global_position.y - (hit["position"] as Vector3).y

func _screen_y_frac(cam: Camera3D, car: Car) -> float:
	var h := cam.get_viewport().get_visible_rect().size.y
	return cam.unproject_position(car.global_position).y / h

func _view_pitch(cam: Camera3D) -> float:
	return asin(clampf(-cam.global_transform.basis.z.y, -1.0, 1.0))

## Samples framing for `n` rendered frames; returns [min clearance, min frac, max frac].
func _sample_framing(root: Node, n: int) -> Array[float]:
	var cam := root.get_node("ChaseCamera") as Camera3D
	var car := root.get_node("Car") as Car
	var min_c := INF
	var lo := INF
	var hi := -INF
	for i in n:
		await physics_frames(4)
		await get_tree().process_frame
		min_c = minf(min_c, _clearance(cam, car))
		var f := _screen_y_frac(cam, car)
		lo = minf(lo, f)
		hi = maxf(hi, f)
	return [min_c, lo, hi]

func test_climb_to_remus_framing() -> void:
	var root := _begin(RACE, 1200.0)
	await physics_frames(2)
	_launch(root, 1200.0, 30.0)
	await physics_frames(60)   # settle the springs on the slope
	var car := root.get_node("Car") as Car
	var r := await _sample_framing(root, 60)
	var track := root.get_node("Track") as Track
	var s := track.data.closest_s(car.global_position)
	assert_true(track.data.grade_at(s) > 0.08, "car should still be on the steep climb (s=%.0f, grade %.3f)" % [s, track.data.grade_at(s)])
	assert_true(r[0] >= 0.5, "camera too close to the road on the climb (min clearance %.2f m)" % r[0])
	assert_between(r[1], 0.45, 0.8, "car screen y fraction on climb (min)")
	assert_between(r[2], 0.45, 0.8, "car screen y fraction on climb (max)")
	_end()

func test_flat_framing() -> void:
	var root := _begin("res://scenes/main.tscn", -1.0)
	await physics_frames(120)
	var r := await _sample_framing(root, 30)
	assert_true(r[0] >= 0.5, "camera too close to the ground on the flat (min clearance %.2f m)" % r[0])
	assert_between(r[1], 0.45, 0.8, "car screen y fraction on flat (min)")
	assert_between(r[2], 0.45, 0.8, "car screen y fraction on flat (max)")
	_end()

func test_crest_pitch_rate() -> void:
	# Over the top after Remus (grade +2 % -> -8 % between s 1480 and 1680).
	var root := _begin(RACE, 1470.0)
	await physics_frames(2)
	_launch(root, 1470.0, 32.0)
	var cam := root.get_node("ChaseCamera") as Camera3D
	var car := root.get_node("Car") as Car
	var track := root.get_node("Track") as Track
	await get_tree().process_frame
	var max_rate := 0.0
	var min_c := INF
	var prev := _view_pitch(cam)
	var t := 0.0
	var s := 1470.0
	for i in 160:
		await physics_frames(6)   # 25 ms windows
		await get_tree().process_frame
		var p := _view_pitch(cam)
		max_rate = maxf(max_rate, absf(p - prev) / 0.025)
		prev = p
		min_c = minf(min_c, _clearance(cam, car))
		s = track.data.closest_s(car.global_position, s)
	assert_true(s > 1620.0, "car should have crossed the crest (s=%.0f)" % s)
	assert_true(max_rate < 0.8, "camera pitch rate over the crest too high (%.2f rad/s)" % max_rate)
	assert_true(min_c >= 0.5, "camera too close to the road over the crest (%.2f m)" % min_c)
	_end()

## Forces rear-wheel slip after the car's physics tick.
class SlipForcer extends Node:
	var car: Car
	func _ready() -> void:
		process_physics_priority = 10
	func _physics_process(_delta: float) -> void:
		for i in [2, 3]:
			car.wheels[i].slip = 1.0

func test_skid_marks_on_slope() -> void:
	var root := _begin(RACE, 1250.0)
	var car := root.get_node("Car") as Car
	var fx: Node = root.get_node("FX/DrivingFX")
	await physics_frames(2)
	_launch(root, 1250.0, 20.0)
	await physics_frames(30)
	var forcer := SlipForcer.new()
	forcer.car = car
	root.add_child(forcer)
	await physics_frames(120)
	var skid: Node = fx.skid_marks
	assert_true(skid.total_segments_written > 4, "no skid marks laid on the slope")
	var space := car.get_world_3d().direct_space_state
	var checked := 0
	var sloped := 0
	var worst := 0.0
	for c: Variant in skid.get("_chunks"):
		var verts: PackedVector3Array = c.verts
		var normals: PackedVector3Array = c.normals
		for k in int(c.count) * 4:
			var v := verts[k]
			var n := normals[k]
			if n.y < 0.997:
				sloped += 1
			var q := PhysicsRayQueryParameters3D.create(v + n * 0.5, v - n * 0.5)
			q.exclude = [car.get_rid()]
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			var d := absf((v - (hit["position"] as Vector3)).dot(hit["normal"] as Vector3))
			worst = maxf(worst, d)
			checked += 1
	assert_true(checked > 8, "too few skid vertices over the road (%d)" % checked)
	assert_true(sloped > checked / 2, "skid strips are not oriented to the slope (%d of %d tilted)" % [sloped, checked])
	assert_true(worst < 0.03, "skid vertex %.3f m off the surface along the normal" % worst)
	_end()
