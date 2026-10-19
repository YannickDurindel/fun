class_name CarKit
extends RefCounted
## A car per series: its body scene, where its wheels are drawn, whether the open-wheel parts
## (wishbones, uprights) show, and its physics: the contact points (wheelbase), the simulation
## spec (assets/car/specs/<kit>.tres, which the autopilot's CarEnvelope follows) and the arcade
## tuning exports of the Car. The F1 kit is the plain car.tscn.
##   CarKit.for_track(id)       kit id of a track's series ("f1" when the series has no kit)
##   CarKit.apply(car, kit)     dresses a Car (player or bot) after it entered the tree
##   CarKit.wheel_offsets(kit)  where the kit draws its four wheels (Car.WHEEL_OFFSETS order)
## The F1 kit changes nothing: a car built from scenes/car/car.tscn already is the F1 car.

const F1 := "f1"
const ENDURANCE := "endurance"
const JUNIOR := "junior"

const TOURING := "touring"
const GERMAN_TOURING := "german_touring"
const AUS_TOURING := "aus_touring"
## The touring car (cad/body/touring_body.py, a generic four-door racing saloon), shared by the
## three touring series: 2.70 m wheelbase, the F1 car's track widths and wheels.
const TOURING_KIT := {
	"body": "res://scenes/car/touring_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.80, 0.0, -1.35), Vector3(0.80, 0.0, -1.35),
		Vector3(-0.78, 0.0, 1.35), Vector3(0.78, 0.0, 1.35),
	],
	"open_wheel_parts": false,   # the wheels are inside the arches
	"sim_spec": "res://assets/car/specs/touring.tres",
	"collision_length": 4.4,
	# The Car's arcade tuning of a touring car: about 1250 kg with the driver, about 300 kW,
	# 0-100 km/h in about 4.5 s, 265 km/h flat out, a little downforce from splitter and wing,
	# softer springs and bars than the prototypes (it leans in the corners).
	"arcade": {
		"mass": 1250.0,
		"center_of_mass": Vector3(0.0, -0.06, 0.05),
		"spring_rate": 110000.0, "damper_bump": 7000.0, "damper_rebound": 8500.0,
		"travel_up": 0.07, "travel_down": 0.09,
		"bump_stop_rate": 1500000.0, "anti_roll_rate": 32000.0, "anti_pitch_rate": 45000.0,
		"downforce_coef": 0.08, "downforce_max": 3500.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 240, 265, 280, 400],
		"accel_curve_ms2": [8.5, 7.6, 5.8, 4.0, 2.4, 1.1, 0.3, 0.0, 0.0],
		"gear_top_kmh": [75, 115, 155, 195, 235, 275],
		"brake_decel": 13.5, "coast_decel": 0.9, "drag_decel_coef": 5.0e-5,
		"lateral_grip_g": 2.3, "aero_grip_g": 6.0e-5,
		"drift_lateral_grip_g": 1.7, "drift_aero_grip_g": 6.0e-5,
	},
}

const GT := "gt"
const SUPER_GT := "super_gt"
## The GT3-style coupe (cad/body/gt_body.py, a generic front-engine racing coupe), shared by
## the GT and Japanese GT series: 2.65 m wheelbase, 2.04 m wide, the F1 car's wheels.
const GT_KIT := {
	"body": "res://scenes/car/gt_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.84, 0.0, -1.325), Vector3(0.84, 0.0, -1.325),
		Vector3(-0.82, 0.0, 1.325), Vector3(0.82, 0.0, 1.325),
	],
	"open_wheel_parts": false,
	"sim_spec": "res://assets/car/specs/gt.tres",
	"collision_length": 4.6,
	# The Car's arcade tuning of a GT3 car (about 1300 kg, 410 kW / 550 hp, no hybrid, little
	# downforce and a lot of drag, about 285 km/h flat out, 0-100 km/h in about 3.2 s).
	"arcade": {
		"mass": 1300.0,
		"center_of_mass": Vector3(0.0, -0.06, 0.05),
		"spring_rate": 190000.0, "damper_bump": 11000.0, "damper_rebound": 13000.0,
		"bump_stop_rate": 2200000.0, "anti_roll_rate": 85000.0, "anti_pitch_rate": 85000.0,
		"downforce_coef": 0.22, "downforce_max": 7000.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 280, 295, 400],
		"accel_curve_ms2": [9.5, 9.0, 7.6, 5.6, 3.5, 1.6, 0.55, 0.0, 0.0],
		"gear_top_kmh": [85, 125, 165, 205, 245, 300],
		"brake_decel": 14.0, "coast_decel": 0.9, "drag_decel_coef": 5.0e-5,
		"lateral_grip_g": 2.4, "aero_grip_g": 1.0e-4,
		"drift_lateral_grip_g": 1.7, "drift_aero_grip_g": 1.0e-4,
	},
}

const KITS := {
	ENDURANCE: {
		# cad/body/endurance_body.py: 3.10 m wheelbase, the F1 car's track widths and wheels.
		"body": "res://scenes/car/endurance_body_visual.tscn",
		"wheel_offsets": [
			Vector3(-0.80, 0.0, -1.55), Vector3(0.80, 0.0, -1.55),
			Vector3(-0.78, 0.0, 1.55), Vector3(0.78, 0.0, 1.55),
		],
		"open_wheel_parts": false,   # the wheels are inside fenders
		"sim_spec": "res://assets/car/specs/endurance.tres",
		# The chassis box keeps the F1 car's overhang past the axles (0.9 m): the shorter
		# wheelbase would else let the nose and tail scrape crests and dips.
		"collision_length": 5.0,
		# The Car's arcade tuning of a Le Mans Hypercar (regulation minimum 1030 kg, about 520 kW,
		# L/D fixed near 4 so about 60 % of an F1 car's downforce and more drag, 340 km/h on the
		# Mulsanne, 0-100 km/h in about 2.6 s). The F1 car's values are the Car's defaults.
		"arcade": {
			"mass": 1030.0,
			"center_of_mass": Vector3(0.0, -0.11, 0.124),
			"spring_rate": 180000.0, "damper_bump": 9700.0, "damper_rebound": 11600.0,
			"bump_stop_rate": 1900000.0, "anti_roll_rate": 77000.0, "anti_pitch_rate": 77000.0,
			"downforce_coef": 0.35, "downforce_max": 12000.0,
			"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 300, 330, 345, 400],
			"accel_curve_ms2": [12.5, 11.8, 10.0, 7.8, 5.4, 3.4, 1.7, 0.6, 0.0, 0.0],
			"gear_top_kmh": [80, 120, 160, 205, 250, 300, 360],
			"brake_decel": 17.0, "coast_decel": 0.9, "drag_decel_coef": 4.5e-5,
			"lateral_grip_g": 2.8, "aero_grip_g": 2.0e-4,
			"drift_lateral_grip_g": 2.0, "drift_aero_grip_g": 2.0e-4,
		},
	},
	JUNIOR: {
		# cad/body/f1_body.py --junior: the F1 tub and wheels with cheaper aero (two-element
		# wings, no beam wing, no fin) and a light blue / white / yellow livery.
		"body": "res://scenes/car/junior_body_visual.tscn",
		"wheel_offsets": [
			Vector3(-0.80, 0.0, -1.80), Vector3(0.80, 0.0, -1.80),
			Vector3(-0.78, 0.0, 1.80), Vector3(0.78, 0.0, 1.80),
		],
		"open_wheel_parts": true,
		"sim_spec": "res://assets/car/specs/junior.tres",
		"collision_length": 5.4,
		# The Car's arcade tuning of a feeder single-seater (795 kg with driver, about 460 kW
		# from a turbo V6 and no hybrid, roughly two thirds of an F1 car's downforce, about
		# 335 km/h at Monza with DRS, 0-100 km/h in about 2.9 s).
		"arcade": {
			"mass": 795.0,
			"downforce_coef": 0.38, "downforce_max": 12000.0,
			"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 300, 320, 335, 350],
			"accel_curve_ms2": [13.5, 12.5, 10.2, 7.6, 5.1, 3.3, 2.0, 1.4, 0.7, 0.0],
			"gear_top_kmh": [90, 135, 180, 230, 285, 345],
			"brake_decel": 16.5, "coast_decel": 0.85, "drag_decel_coef": 3.6e-5,
			"lateral_grip_g": 2.8, "aero_grip_g": 1.8e-4,
			"drift_lateral_grip_g": 2.0, "drift_aero_grip_g": 1.8e-4,
		},
	},
	TOURING: TOURING_KIT,
	GERMAN_TOURING: TOURING_KIT,
	AUS_TOURING: TOURING_KIT,
	GT: GT_KIT,
	SUPER_GT: GT_KIT,
}

const BODY_MOTION := preload("res://scripts/car/body_motion.gd")

## Kit of the series a track belongs to.
static func for_track(track_id: String) -> String:
	var info := TrackCatalog.find(track_id)
	if info != null and KITS.has(info.series):
		return info.series
	return F1

## Kit whose simulation spec is `spec_path` (F1 when none): CarEnvelope dresses its rig with it.
static func for_spec(spec_path: String) -> String:
	for kit: String in KITS:
		if KITS[kit]["sim_spec"] == spec_path:
			return kit
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
	car.kit = kit
	apply_physics(car, kit)
	car.visual_wheel_offsets = wheel_offsets(kit)
	dress(car, kit, true)

## Swaps the body visual of `root` (a Car, or the GhostCar of the ghost replay) for the kit's
## and hides the open-wheel parts. The wheels' positions are the caller's (a Car follows
## visual_wheel_offsets, the ghost places them itself). `head_motion`: the Car's driver head.
static func dress(root: Node3D, kit: String, head_motion: bool) -> void:
	if root == null or not KITS.has(kit):
		return
	var k: Dictionary = KITS[kit]
	var car := root
	var old := car.get_node_or_null(^"BodyVisual") as Node3D
	var body := (load(k["body"]) as PackedScene).instantiate() as Node3D
	if head_motion:
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

## The kit's physics: wheel contacts, wheelbase, arcade tuning, simulation spec. Safe before
## the car enters the tree (the rig of CarEnvelope) and after (the sim model is rebuilt).
static func apply_physics(car: Car, kit: String) -> void:
	if car == null or not KITS.has(kit):
		return
	var k: Dictionary = KITS[kit]
	car.wheel_offsets = wheel_offsets(kit)
	car.wheelbase = car.wheel_offsets[2].z - car.wheel_offsets[0].z
	for prop: String in k["arcade"]:
		var v: Variant = k["arcade"][prop]
		car.set(prop, PackedFloat32Array(v) if v is Array else v)
	var box := car.get_node_or_null(^"Collision") as CollisionShape3D
	if box != null and box.shape is BoxShape3D:
		box.shape = box.shape.duplicate()   # the scene's shape is shared by every car
		(box.shape as BoxShape3D).size.z = float(k["collision_length"])
	car.set_sim_spec(k["sim_spec"])
