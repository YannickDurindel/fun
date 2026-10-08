extends TestCase
## Smoke test: main scene loads and the car contract is populated.

func test_main_scene_runs() -> void:
	var main := spawn("res://scenes/main.tscn")
	await physics_frames(60)
	var car := main.get_node("Car") as Car
	assert_true(car != null, "Car node missing")
	assert_true(car.wheels.size() == 4, "car.wheels must have 4 entries")
	assert_true(car.global_position.y > -1.0, "car fell through the ground")
