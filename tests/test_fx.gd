extends TestCase
## Driving FX: skid marks appear when rear wheels slide, stay bounded, and none appear at grip.

## Runs after the car's physics tick and forces slip on the rear wheels.
class SlipForcer extends Node:
	var car: Car
	var slip: float = 1.0
	func _ready() -> void:
		process_physics_priority = 10
	func _physics_process(_delta: float) -> void:
		for i in [2, 3]:
			car.wheels[i].slip = slip
			car.wheels[i].contact = true
		car.is_drifting = slip > 0.0

var _prev_autodrive: bool

func _setup(slip: float) -> Array:
	_prev_autodrive = Bootstrap.autodrive
	Bootstrap.autodrive = true
	var main := spawn("res://scenes/main.tscn")
	var car := main.get_node("Car") as Car
	var fx := main.get_node("FX/DrivingFX")
	var forcer := SlipForcer.new()
	forcer.car = car
	forcer.slip = slip
	main.add_child(forcer)
	return [main, car, fx]

func _teardown() -> void:
	Bootstrap.autodrive = _prev_autodrive

func test_skid_marks_created_and_bounded() -> void:
	var r := _setup(1.0)
	var car: Car = r[1]
	var fx: Node = r[2]
	assert_true(fx != null, "DrivingFX missing under FX")
	if fx == null:
		_teardown()
		return
	var skid: Node = fx.skid_marks
	skid.configure(32, 4)   # tiny pool (128 segments) to force wrap-around quickly
	await physics_frames(240)
	assert_true(car.speed_kmh > 20.0, "car should be moving under autodrive (%.1f km/h)" % car.speed_kmh)
	assert_true(skid.total_segments_written > 0, "no skid segments created while sliding")
	assert_true(fx.tyre_smoke.alive_count() > 0, "no smoke puffs while sliding at speed")
	assert_true(fx.tyre_smoke.alive_count() <= fx.tyre_smoke.pool_size, "smoke pool exceeded")
	await physics_frames(1200)
	assert_true(skid.total_segments_written > skid.capacity,
		"expected wrap-around: written %d, capacity %d" % [skid.total_segments_written, skid.capacity])
	assert_true(skid.segment_count() <= skid.capacity,
		"live segments %d exceed capacity %d" % [skid.segment_count(), skid.capacity])
	assert_true(skid.segment_count() > 0, "live segments vanished")
	fx.clear()
	assert_true(skid.segment_count() == 0, "clear() should remove all marks")
	_teardown()

func test_no_marks_without_slip() -> void:
	var r := _setup(0.0)
	var car: Car = r[1]
	var fx: Node = r[2]
	await physics_frames(360)
	assert_true(car.speed_kmh > 20.0, "car should be moving under autodrive")
	assert_true(fx.skid_marks.total_segments_written == 0,
		"marks created without slip: %d" % fx.skid_marks.total_segments_written)
	assert_true(fx.tyre_smoke.alive_count() == 0, "smoke emitted without slip")
	_teardown()

func test_null_car_is_safe() -> void:
	var fx := spawn("res://scenes/fx/driving_fx.tscn")
	await physics_frames(30)
	assert_true(fx.car == null, "car should be null without car_path")
	assert_true(fx.skid_marks.segment_count() == 0, "no marks without a car")
