class_name CarKit
extends RefCounted
## The look of a car per series: its body scene, where its wheels are drawn and whether the
## open-wheel parts (wishbones, uprights) show. Only the visuals change: the physics, the
## simulation spec and the autopilot envelope stay the F1 car's (Car.WHEEL_OFFSETS) for every kit.
##   CarKit.for_track(id)       kit id of a track's series ("f1" when the series has no kit)
##   CarKit.apply(car, kit)     dresses a Car (player or bot) after it entered the tree
##   CarKit.wheel_offsets(kit)  where the kit draws its four wheels (Car.WHEEL_OFFSETS order)
## The F1 kit changes nothing: a car built from scenes/car/car.tscn already is the F1 car.

const F1 := "f1"
const ENDURANCE := "endurance"

const KITS := {
	ENDURANCE: {
		# cad/body/endurance_body.py: 3.10 m wheelbase, the F1 car's track widths and wheels.
		"body": "res://scenes/car/endurance_body_visual.tscn",
		"wheel_offsets": [
			Vector3(-0.80, 0.0, -1.55), Vector3(0.80, 0.0, -1.55),
			Vector3(-0.78, 0.0, 1.55), Vector3(0.78, 0.0, 1.55),
		],
		"open_wheel_parts": false,   # the wheels are inside fenders
	},
}

const BODY_MOTION := preload("res://scripts/car/body_motion.gd")

## Kit of the series a track belongs to.
static func for_track(track_id: String) -> String:
	var info := TrackCatalog.find(track_id)
	if info != null and KITS.has(info.series):
		return info.series
	return F1

static func wheel_offsets(kit: String) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if KITS.has(kit):
		for v: Vector3 in KITS[kit]["wheel_offsets"]:
			out.append(v)
	else:
		out.assign(Car.WHEEL_OFFSETS)
	return out

## Swaps the body visual of `car` for the kit's, moves its wheel visuals and hides the
## open-wheel parts if the kit has none. Does nothing for the F1 kit.
static func apply(car: Car, kit: String) -> void:
	if car == null or not KITS.has(kit):
		return
	var k: Dictionary = KITS[kit]
	car.kit = kit
	car.visual_wheel_offsets = wheel_offsets(kit)
	var old := car.get_node_or_null(^"BodyVisual") as Node3D
	var body := (load(k["body"]) as PackedScene).instantiate() as Node3D
	body.set_script(BODY_MOTION)   # the driver's head moves as in car.tscn
	if old != null:
		body.transform = old.transform
		var at := old.get_index()
		car.remove_child(old)
		old.free()
		body.name = "BodyVisual"
		car.add_child(body)
		car.move_child(body, at)
	else:
		body.name = "BodyVisual"
		car.add_child(body)
	for wheel_name: String in ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]:
		var w := car.get_node_or_null(wheel_name) as Node3D
		if w == null:
			continue
		for part: String in ["Suspension", "Steer/Upright"]:
			var n := w.get_node_or_null(part) as Node3D
			if n != null:
				n.visible = bool(k["open_wheel_parts"])
