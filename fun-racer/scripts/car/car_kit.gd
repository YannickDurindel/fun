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

const INDYCAR := "indycar"

const NASCAR := "nascar"
## The stock car (cad/body/stock_body.py, a generic American oval racer with a fastback roof
## and a blade spoiler) of the NASCAR series: 2.80 m wheelbase, the F1 car's track widths and
## wheels.
const STOCK_KIT := {
	"body": "res://scenes/car/stock_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.80, 0.0, -1.40), Vector3(0.80, 0.0, -1.40),
		Vector3(-0.78, 0.0, 1.40), Vector3(0.78, 0.0, 1.40),
	],
	"open_wheel_parts": false,   # the wheels are inside the fenders
	"sim_spec": "res://assets/car/specs/stock.tres",
	"collision_length": 4.8,
	# The Car's arcade tuning of a stock car: about 1550 kg with the driver, about 500 kW from a
	# big V8, 0-100 km/h in about 3.6 s, about 320 km/h flat out in the draft-free air, a lot of
	# drag and little downforce, soft springs and a soft bar on a high centre of mass (it leans
	# hard on the banking and slides before it grips).
	"arcade": {
		"mass": 1550.0,
		"center_of_mass": Vector3(0.0, -0.02, 0.0),
		"spring_rate": 95000.0, "damper_bump": 6500.0, "damper_rebound": 8000.0,
		"travel_up": 0.08, "travel_down": 0.10,
		"bump_stop_rate": 1400000.0, "anti_roll_rate": 22000.0, "anti_pitch_rate": 35000.0,
		"downforce_coef": 0.10, "downforce_max": 3500.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 285, 305, 320, 400],
		"accel_curve_ms2": [9.0, 8.4, 7.0, 5.2, 3.4, 1.9, 0.9, 0.3, 0.0, 0.0],
		"gear_top_kmh": [120, 170, 225, 275, 335],
		"brake_decel": 12.5, "coast_decel": 0.9, "drag_decel_coef": 6.0e-5,
		"lateral_grip_g": 2.0, "aero_grip_g": 4.0e-5,
		"drift_lateral_grip_g": 1.5, "drift_aero_grip_g": 4.0e-5,
	},
}

const RALLY := "rally"
const RALLYCROSS := "rallycross"
## The rally hatchback (cad/body/rally_body.py, a generic three-door 4WD rally car with a roof
## scoop and mud flaps, 2.50 m wheelbase, high off the ground). The Car has no drive layout: its
## four-wheel drive is expressed through the tuning only (traction kept on gravel and grass, and
## most of the drive kept in a slide, so it pulls itself straight out of one).
const RALLY_KIT := {
	"body": "res://scenes/car/rally_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.80, 0.0, -1.25), Vector3(0.80, 0.0, -1.25),
		Vector3(-0.78, 0.0, 1.25), Vector3(0.78, 0.0, 1.25),
	],
	"open_wheel_parts": false,   # the wheels are inside the arches
	"sim_spec": "res://assets/car/specs/rally.tres",
	"collision_length": 4.0,
	# The Car's arcade tuning of a top-class rally car: about 1180 kg with the crew, about 280 kW,
	# 0-100 km/h in about 3 s, short gearing for about 205 km/h, long soft suspension, a high
	# centre of mass, little downforce. Built for loose surfaces: gravel and grass keep most of
	# the grip, a slide starts easily (brake and steer from 50 km/h), carries its speed and lasts
	# a little after the brake is released, then the grip comes back quickly.
	"arcade": {
		"mass": 1180.0,
		"center_of_mass": Vector3(0.0, -0.02, 0.0),
		"spring_rate": 60000.0, "damper_bump": 4500.0, "damper_rebound": 6000.0,
		"travel_up": 0.12, "travel_down": 0.15, "bump_stop_start": 0.09,
		"bump_stop_rate": 1100000.0, "anti_roll_rate": 16000.0, "anti_pitch_rate": 22000.0,
		"downforce_coef": 0.05, "downforce_max": 2000.0,
		"accel_curve_kmh": [0, 50, 100, 150, 180, 200, 205, 400],
		"accel_curve_ms2": [10.0, 9.2, 7.0, 4.3, 2.5, 0.7, 0.0, 0.0],
		"gear_top_kmh": [70, 105, 140, 175, 210],
		"brake_decel": 12.0, "coast_decel": 1.0, "drag_decel_coef": 6.0e-5,
		"max_steer_angle": 0.55,
		"lateral_grip_g": 2.0, "aero_grip_g": 3.0e-5,
		"drift_min_speed_kmh": 50.0, "drift_entry_time": 0.2, "overdrive_min_speed_kmh": 40.0,
		"drift_lateral_grip_g": 1.6, "drift_aero_grip_g": 3.0e-5,
		"drift_drive_factor": 0.85, "drift_speed_retention": 0.6, "drift_brake_release_time": 0.6,
		"drift_base_angle_deg": 22.0, "drift_steer_angle_deg": 15.0,
		"drift_recover_time": 0.15, "drift_recover_grip": 0.8,
		"grass_grip": 0.8, "gravel_grip": 0.8, "grass_drag": 0.6, "gravel_drag": 1.2,
	},
}
## The rallycross car: the rally hatchback (cad/body/rally_body.py --rallycross) with wider
## arches over a wider track, a big wing, a lower stance and more power. Four-wheel drive by
## tuning only, as the rally car.
const RALLYCROSS_KIT := {
	"body": "res://scenes/car/rallycross_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.84, 0.0, -1.25), Vector3(0.84, 0.0, -1.25),
		Vector3(-0.82, 0.0, 1.25), Vector3(0.82, 0.0, 1.25),
	],
	"open_wheel_parts": false,
	"sim_spec": "res://assets/car/specs/rallycross.tres",
	"collision_length": 4.1,
	# The Car's arcade tuning of a rallycross supercar: about 1300 kg, about 370 kW, 0-100 km/h
	# in about 2 s (four-wheel-drive launch), about 240 km/h flat out, stiffer and lower than the
	# rally car, the same loose-surface grip and forgiving slides.
	"arcade": {
		"mass": 1300.0,
		"center_of_mass": Vector3(0.0, -0.03, 0.0),
		"spring_rate": 70000.0, "damper_bump": 5000.0, "damper_rebound": 6500.0,
		"travel_up": 0.11, "travel_down": 0.13, "bump_stop_start": 0.08,
		"bump_stop_rate": 1300000.0, "anti_roll_rate": 22000.0, "anti_pitch_rate": 28000.0,
		"downforce_coef": 0.08, "downforce_max": 3000.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 230, 240, 400],
		"accel_curve_ms2": [15.5, 14.5, 11.5, 7.0, 3.2, 1.0, 0.0, 0.0],
		"gear_top_kmh": [80, 120, 160, 200, 245],
		"brake_decel": 13.0, "coast_decel": 1.0, "drag_decel_coef": 6.0e-5,
		"max_steer_angle": 0.55,
		"lateral_grip_g": 2.2, "aero_grip_g": 5.0e-5,
		"drift_min_speed_kmh": 50.0, "drift_entry_time": 0.2, "overdrive_min_speed_kmh": 40.0,
		"drift_lateral_grip_g": 1.7, "drift_aero_grip_g": 5.0e-5,
		"drift_drive_factor": 0.85, "drift_speed_retention": 0.6, "drift_brake_release_time": 0.6,
		"drift_base_angle_deg": 22.0, "drift_steer_angle_deg": 15.0,
		"drift_recover_time": 0.15, "drift_recover_grip": 0.8,
		"grass_grip": 0.8, "gravel_grip": 0.8, "grass_drag": 0.6, "gravel_drag": 1.2,
	},
}

const HILL_CLIMB := "hill_climb"
## The hill-climb prototype (cad/body/hillclimb_body.py, a generic open-cockpit sports racer
## with enclosed wheels, a roll hoop, dive planes and a big rear wing): 2.60 m wheelbase.
const HILL_CLIMB_KIT := {
	"body": "res://scenes/car/hillclimb_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.82, 0.0, -1.30), Vector3(0.82, 0.0, -1.30),
		Vector3(-0.80, 0.0, 1.30), Vector3(0.80, 0.0, 1.30),
	],
	"open_wheel_parts": false,   # the wheels are inside fenders
	"sim_spec": "res://assets/car/specs/hill_climb.tres",
	"collision_length": 4.4,
	# The Car's arcade tuning of a hill-climb prototype: about 650 kg with the driver, about
	# 400 kW, high downforce for its weight, 0-100 km/h in about 2.3 s, short gearing for about
	# 275 km/h, a big steering lock for the hairpins.
	"arcade": {
		"mass": 650.0,
		"center_of_mass": Vector3(0.0, -0.10, 0.10),
		"spring_rate": 150000.0, "damper_bump": 8000.0, "damper_rebound": 9500.0,
		"bump_stop_rate": 1600000.0, "anti_roll_rate": 70000.0, "anti_pitch_rate": 70000.0,
		"downforce_coef": 0.40, "downforce_max": 11000.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 270, 280, 400],
		"accel_curve_ms2": [14.5, 13.5, 11.5, 8.5, 5.4, 2.4, 0.8, 0.0, 0.0],
		"gear_top_kmh": [95, 135, 170, 205, 240, 280],
		"brake_decel": 17.0, "coast_decel": 0.9, "drag_decel_coef": 4.5e-5,
		"max_steer_angle": 0.6,
		"lateral_grip_g": 2.9, "aero_grip_g": 2.4e-4,
		"drift_lateral_grip_g": 2.1, "drift_aero_grip_g": 2.4e-4,
	},
}

const DRIFT := "drift"
## The drift coupe (cad/body/drift_body.py, a generic front-engine coupe with bolt-on wide
## arches, a big front lip and a wing on tall stands): 2.60 m wheelbase. Rear-wheel drive by
## tuning only (the Car has no drive layout): a huge steering lock, low sliding friction at the
## rear, most of the power kept in a slide, and a slide that lasts as long as the steering is
## held (no brake needed to keep it).
const DRIFT_KIT := {
	"body": "res://scenes/car/drift_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.84, 0.0, -1.30), Vector3(0.84, 0.0, -1.30),
		Vector3(-0.84, 0.0, 1.30), Vector3(0.84, 0.0, 1.30),
	],
	"open_wheel_parts": false,
	"sim_spec": "res://assets/car/specs/drift.tres",
	"collision_length": 4.4,
	# The Car's arcade tuning of a pro drift car: about 1300 kg, about 550 kW from a big V8,
	# 0-100 km/h in about 3 s (traction limited), about 270 km/h flat out, little downforce.
	"arcade": {
		"mass": 1300.0,
		"center_of_mass": Vector3(0.0, -0.05, 0.0),
		"spring_rate": 100000.0, "damper_bump": 6500.0, "damper_rebound": 8000.0,
		"travel_up": 0.07, "travel_down": 0.09,
		"bump_stop_rate": 1500000.0, "anti_roll_rate": 40000.0, "anti_pitch_rate": 45000.0,
		"downforce_coef": 0.08, "downforce_max": 3000.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 240, 260, 270, 400],
		"accel_curve_ms2": [10.5, 10.0, 8.6, 6.6, 4.4, 2.2, 0.8, 0.0, 0.0],
		"gear_top_kmh": [80, 120, 160, 200, 240, 275],
		"brake_decel": 13.0, "coast_decel": 0.9, "drag_decel_coef": 5.5e-5,
		"max_steer_angle": 0.8,
		"lateral_grip_g": 2.1, "aero_grip_g": 5.0e-5,
		"drift_min_speed_kmh": 35.0, "drift_entry_time": 0.15, "drift_brake_threshold": 0.2,
		"overdrive_min_speed_kmh": 30.0, "overdrive_entry_time": 0.3, "overdrive_slide_scale": 0.7,
		"drift_lateral_grip_g": 1.25, "drift_aero_grip_g": 5.0e-5,
		"drift_drive_factor": 0.9, "drift_speed_retention": 0.75, "drift_brake_factor": 0.3,
		"drift_brake_release_time": 0.0,
		"drift_base_angle_deg": 35.0, "drift_steer_angle_deg": 20.0, "drift_min_angle_deg": 12.0,
		"drift_angle_time": 0.35, "drift_yaw_time": 0.11, "drift_min_time": 0.5,
		"drift_recover_grip": 0.75,
	},
}

const FORMULA_E := "formula_e"
## The electric single-seater (cad/body/formula_body.py --formula-e, a generic street racer
## from the F1 tub: 2.97 m wheelbase, narrower track, fairings over the wheels, halo) of the
## Formula E series. Single-speed: one gear in the arcade and the simulation (the motor turns
## to 18,000 rpm at about 330 km/h).
const FORMULA_E_KIT := {
	"body": "res://scenes/car/formula_e_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.72, 0.0, -1.485), Vector3(0.72, 0.0, -1.485),
		Vector3(-0.702, 0.0, 1.485), Vector3(0.702, 0.0, 1.485),
	],
	"open_wheel_parts": true,
	"sound": "electric",   # electric drivetrain whine instead of the combustion engine
	"sim_spec": "res://assets/car/specs/formula_e.tres",
	"collision_length": 4.9,
	# The Car's arcade tuning of an electric street racer (860 kg with the driver, 350 kW, no
	# gearbox, 0-100 km/h in about 2.8 s, about 320 km/h flat out, little downforce and
	# all-weather treaded tyres: clearly less grip than F1, a bit more give on street bumps).
	"arcade": {
		"mass": 860.0,
		"spring_rate": 115000.0, "damper_bump": 6500.0, "damper_rebound": 8000.0,
		"travel_up": 0.07, "travel_down": 0.09,
		"downforce_coef": 0.16, "downforce_max": 5500.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 280, 300, 320, 400],
		"accel_curve_ms2": [11.5, 11.0, 9.4, 6.6, 4.6, 2.9, 1.9, 1.0, 0.0, 0.0],
		"gear_top_kmh": [330],
		"idle_rpm": 2000.0, "launch_rpm": 3000.0,
		"brake_decel": 14.5, "coast_decel": 1.4, "drag_decel_coef": 3.6e-5,
		"lateral_grip_g": 2.5, "aero_grip_g": 7.0e-5,
		"drift_lateral_grip_g": 1.8, "drift_aero_grip_g": 7.0e-5,
	},
}

const SUPER_FORMULA := "super_formula"
## The Japanese single-seater (cad/body/formula_body.py --super-formula, a generic
## high-downforce car from the F1 tub and aero: 3.165 m wheelbase, 1.90 m wide, halo) of the
## Super Formula series.
const SUPER_FORMULA_KIT := {
	"body": "res://scenes/car/super_formula_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.76, 0.0, -1.5825), Vector3(0.76, 0.0, -1.5825),
		Vector3(-0.741, 0.0, 1.5825), Vector3(0.741, 0.0, 1.5825),
	],
	"open_wheel_parts": true,
	"sim_spec": "res://assets/car/specs/super_formula.tres",
	"collision_length": 5.1,
	# The Car's arcade tuning of a Japanese top-formula car (750 kg with the driver, about
	# 410 kW from a 2-litre turbo four, no hybrid, close to an F1 car's downforce and grip for
	# a lighter car, about 300 km/h flat out, 0-100 km/h in about 2.8 s).
	"arcade": {
		"mass": 750.0,
		"downforce_coef": 0.50, "downforce_max": 15000.0,
		"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 280, 305, 400],
		"accel_curve_ms2": [13.5, 12.8, 10.6, 7.8, 5.0, 2.6, 1.2, 0.0, 0.0],
		"gear_top_kmh": [100, 145, 185, 225, 265, 315],
		"brake_decel": 17.0, "coast_decel": 0.85, "drag_decel_coef": 4.0e-5,
		"lateral_grip_g": 3.1, "aero_grip_g": 2.3e-4,
		"drift_lateral_grip_g": 2.1, "drift_aero_grip_g": 2.3e-4,
	},
}

const RALLY_RAID := "rally_raid"
## The desert-raid prototype (cad/body/rally_raid_body.py, a generic T1-style 4WD pickup with
## a roof scoop, an open bed and two spare wheels standing in it) of the rally-raid series:
## 2.95 m wheelbase, 1.92 m track, 2.26 m wide, 1.90 m tall. Its own wheels (R 0.47 m
## all-terrain tyres on beadlock rims, kit key "wheels"), drawn at their size: the physics keeps
## the F1 car's ray-cast contacts and ride height (Car.ride_ground_y), so the body sits on
## them with 33 cm of ground clearance. Four-wheel drive by tuning only (the Car has no drive
## layout): loose surfaces keep most of the grip and a slide keeps most of the drive.
const RALLY_RAID_KIT := {
	"body": "res://scenes/car/rally_raid_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.96, 0.0, -1.475), Vector3(0.96, 0.0, -1.475),
		Vector3(-0.96, 0.0, 1.475), Vector3(0.96, 0.0, 1.475),
	],
	"wheels": {
		"front": {"scene": "res://assets/car/rally_raid/wheel.glb", "radius": 0.47, "rim_radius": 0.216, "rim_face_x": 0.14},
		"rear": {"scene": "res://assets/car/rally_raid/wheel.glb", "radius": 0.47, "rim_radius": 0.216, "rim_face_x": 0.14},
	},
	"open_wheel_parts": false,   # the wheels are inside the arches
	"sim_spec": "res://assets/car/specs/rally_raid.tres",
	"collision_length": 4.6,
	# The chassis box of a tall truck: from 21 cm above the ground (the floor is at 33 cm, the
	# long travel must not put the box on the road first) to the belt line.
	"collision_box": Vector3(2.0, 1.1, 4.6),
	"collision_y": 0.40,
	# The chase camera sits higher and further back, over the roof, and the cockpit view is
	# the driver's (left seat).
	"camera": {
		"low_distance": 6.6, "low_height": 2.35, "low_look_height": 1.2, "low_look_ahead": 8.0,
		"high_distance": 10.5, "high_height": 4.0, "high_look_height": 1.0, "high_look_ahead": 13.0,
		"cockpit_offset": Vector3(-0.40, 1.16, 0.20),
	},
	# The Car's arcade tuning of a desert-raid prototype: about 2000 kg with the crew, about
	# 270 kW from a restricted V6, 0-100 km/h in about 5.5 s, a 180 km/h limiter, huge soft
	# suspension travel, no downforce and a lot of drag. Sand, gravel and grass keep most of
	# the grip; a slide starts easily and keeps most of the drive.
	"arcade": {
		"mass": 2000.0,
		"inertia": Vector3(2900.0, 3300.0, 850.0),
		"center_of_mass": Vector3(0.0, 0.15, 0.0),
		"spring_rate": 45000.0, "damper_bump": 5500.0, "damper_rebound": 7000.0,
		"travel_up": 0.22, "travel_down": 0.18, "bump_stop_start": 0.17,
		"bump_stop_rate": 900000.0, "anti_roll_rate": 18000.0, "anti_pitch_rate": 20000.0,
		"downforce_coef": 0.0, "downforce_max": 0.0,
		"accel_curve_kmh": [0, 50, 100, 140, 165, 178, 182, 400],
		"accel_curve_ms2": [6.5, 6.0, 4.2, 2.8, 1.6, 0.6, 0.0, 0.0],
		"gear_top_kmh": [50, 80, 110, 140, 165, 185],
		"brake_decel": 10.5, "coast_decel": 1.3, "drag_decel_coef": 1.0e-4,
		"max_steer_angle": 0.55,
		"lateral_grip_g": 1.6, "aero_grip_g": 0.0,
		"drift_min_speed_kmh": 60.0, "overdrive_min_speed_kmh": 40.0,
		"drift_lateral_grip_g": 1.25, "drift_aero_grip_g": 0.0,
		"drift_drive_factor": 0.8, "drift_speed_retention": 0.5,
		"grass_grip": 0.85, "gravel_grip": 0.85, "grass_drag": 0.5, "gravel_drag": 0.9,
	},
}

const KART := "karting"
## The racing kart (cad/body/kart_body.py, a generic direct-drive sprint kart with the driver
## sitting in the open) of the karting series: 1.05 m wheelbase, 1.16 / 1.24 m track, 1.86 m
## long. Its own tiny wheels (10 / 11 in slicks on 5 in rims, kit key "wheels") drawn at their
## size on the F1 car's ray-cast contacts and ride height: the body is modelled round that
## (the car's origin is at the driver's chest). No suspension: very stiff springs, short
## travel; one gear.
const KART_KIT := {
	"body": "res://scenes/car/kart_body_visual.tscn",
	"wheel_offsets": [
		Vector3(-0.58, 0.0, -0.525), Vector3(0.58, 0.0, -0.525),
		Vector3(-0.62, 0.0, 0.525), Vector3(0.62, 0.0, 0.525),
	],
	"wheels": {
		"front": {"scene": "res://assets/car/kart/wheel_front.glb", "radius": 0.127, "rim_radius": 0.0635, "rim_face_x": 0.0375},
		"rear": {"scene": "res://assets/car/kart/wheel_rear.glb", "radius": 0.140, "rim_radius": 0.0635, "rim_face_x": 0.07},
	},
	"open_wheel_parts": false,   # no wishbones or uprights: stub axles and a live rear axle
	"sim_spec": "res://assets/car/specs/kart.tres",
	"collision_length": 1.8,
	# The chassis box of a kart: bumper to bumper, 6 cm to 46 cm above the ground.
	"collision_box": Vector3(1.3, 0.4, 1.8),
	"collision_y": -0.10,
	# The chase camera close and low behind the kart; the cockpit view from the driver's helmet.
	"camera": {
		"low_distance": 3.3, "low_height": 0.85, "low_look_height": 0.35, "low_look_ahead": 5.0,
		"high_distance": 6.0, "high_height": 2.0, "high_look_height": 0.3, "high_look_ahead": 9.0,
		"cockpit_offset": Vector3(-0.03, 0.43, 0.18),
	},
	# The Car's arcade tuning of a sprint kart: 165 kg with the driver, about 22 kW from a 125 cc
	# single, one gear, about 130 km/h flat out, 0-100 km/h in about 5 s, no downforce, a lot of
	# mechanical grip for its weight, rear brakes only. Grass and gravel are hopeless.
	"arcade": {
		"mass": 165.0,
		"inertia": Vector3(40.0, 55.0, 22.0),
		"center_of_mass": Vector3(0.0, -0.12, 0.08),
		"spring_rate": 40000.0, "damper_bump": 1500.0, "damper_rebound": 1800.0,
		"travel_up": 0.025, "travel_down": 0.03, "bump_stop_start": 0.015,
		"bump_stop_rate": 300000.0, "anti_roll_rate": 15000.0, "anti_pitch_rate": 15000.0,
		"downforce_coef": 0.0, "downforce_max": 0.0,
		"accel_curve_kmh": [0, 40, 80, 110, 125, 132, 400],
		"accel_curve_ms2": [8.0, 7.0, 5.0, 2.8, 1.3, 0.0, 0.0],
		"gear_top_kmh": [135],
		"brake_decel": 11.0, "coast_decel": 1.0, "drag_decel_coef": 2.7e-4,
		"reverse_max_kmh": 20.0,
		"lateral_grip_g": 2.6, "aero_grip_g": 0.0,
		"drift_min_speed_kmh": 50.0, "overdrive_min_speed_kmh": 35.0,
		"drift_lateral_grip_g": 1.9, "drift_aero_grip_g": 0.0,
		"grass_grip": 0.45, "gravel_grip": 0.3, "grass_drag": 2.5, "gravel_drag": 7.0,
		"launch_spin_speed": 4.0, "drift_spin_speed": 5.0,
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
	INDYCAR: {
		# cad/body/f1_body.py --indycar: the F1 tub and wheels in American oval trim: aeroscreen
		# on the halo, small flat wings, no beam wing, guards behind the rear wheels; a teal /
		# white / magenta livery.
		"body": "res://scenes/car/indycar_body_visual.tscn",
		"wheel_offsets": [
			Vector3(-0.80, 0.0, -1.80), Vector3(0.80, 0.0, -1.80),
			Vector3(-0.78, 0.0, 1.80), Vector3(0.78, 0.0, 1.80),
		],
		"open_wheel_parts": true,
		"sim_spec": "res://assets/car/specs/indycar.tres",
		"collision_length": 5.4,
		# The Car's arcade tuning of an IndyCar on the ovals (about 805 kg with the driver, about
		# 550 kW from a turbo V6 on oval boost, low-drag wings: half an F1 car's downforce, about
		# 380 km/h on a superspeedway, 0-100 km/h in about 3 s).
		"arcade": {
			"mass": 805.0,
			"downforce_coef": 0.30, "downforce_max": 11000.0,
			"accel_curve_kmh": [0, 50, 100, 150, 200, 250, 300, 340, 370, 385, 400],
			"accel_curve_ms2": [13.0, 12.2, 10.0, 7.6, 5.4, 3.8, 2.5, 1.5, 0.6, 0.0, 0.0],
			"gear_top_kmh": [115, 165, 215, 265, 320, 395],
			"brake_decel": 16.0, "coast_decel": 0.85, "drag_decel_coef": 3.0e-5,
			"lateral_grip_g": 2.7, "aero_grip_g": 1.4e-4,
			"drift_lateral_grip_g": 1.9, "drift_aero_grip_g": 1.4e-4,
		},
	},
	NASCAR: STOCK_KIT,
	TOURING: TOURING_KIT,
	GERMAN_TOURING: TOURING_KIT,
	AUS_TOURING: TOURING_KIT,
	GT: GT_KIT,
	SUPER_GT: GT_KIT,
	RALLY: RALLY_KIT,
	RALLYCROSS: RALLYCROSS_KIT,
	HILL_CLIMB: HILL_CLIMB_KIT,
	DRIFT: DRIFT_KIT,
	FORMULA_E: FORMULA_E_KIT,
	SUPER_FORMULA: SUPER_FORMULA_KIT,
	RALLY_RAID: RALLY_RAID_KIT,
	KART: KART_KIT,
}

const BODY_MOTION := preload("res://scripts/car/body_motion.gd")

## CarKit "sound" profile of an electric drivetrain (engine_audio.gd -> electric_synth.gd).
const SOUND_ELECTRIC := "electric"

## The kit's sound profile: "" for the combustion engine (every kit without "sound"),
## SOUND_ELECTRIC for an electric car.
static func sound(kit: String) -> String:
	if KITS.has(kit):
		return String(KITS[kit].get("sound", ""))
	return ""

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

## Tyre radius of wheel i (Car.WHEEL_OFFSETS order) as the kit draws it. The physics always
## runs on Car.wheel_radius (the F1 car's): a kit with wheels of its own ("wheels") draws them
## at their size, raised by the difference so they stand on the road (visual_wheel_offsets).
static func wheel_radius(kit: String, i: int) -> float:
	if KITS.has(kit) and KITS[kit].has("wheels"):
		return float(KITS[kit]["wheels"]["front" if i < 2 else "rear"]["radius"])
	return Car.FRONT_WHEEL_RADIUS if i < 2 else Car.REAR_WHEEL_RADIUS

## Where the kit draws its wheel centres (Car.visual_wheel_offsets): its contacts, raised by
## how much its tyres are bigger than the F1 car's (lowered when smaller).
static func visual_wheel_offsets(kit: String) -> Array[Vector3]:
	var out := wheel_offsets(kit)
	for i in out.size():
		out[i].y += wheel_radius(kit, i) - (Car.FRONT_WHEEL_RADIUS if i < 2 else Car.REAR_WHEEL_RADIUS)
	return out

## The kit's chase-camera overrides (ChaseCamera export names -> values), empty for most kits.
static func camera(kit: String) -> Dictionary:
	if KITS.has(kit):
		return KITS[kit].get("camera", {})
	return {}

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
	car.visual_wheel_offsets = visual_wheel_offsets(kit)
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
		if k.has("wheels") and w.has_method(&"use_kit_wheel"):
			# A kit with wheels of its own size (rally raid, kart): their meshes replace the F1's.
			var spec: Dictionary = k["wheels"]["front" if wheel_name.begins_with("WheelF") else "rear"]
			w.call(&"use_kit_wheel", load(spec["scene"]) as PackedScene, float(spec["radius"]),
					float(spec["rim_radius"]), float(spec["rim_face_x"]))

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
		if k.has("collision_box"):   # a car much taller or smaller than the F1 car
			(box.shape as BoxShape3D).size = k["collision_box"]
			box.position.y = float(k["collision_y"])
	car.set_sim_spec(k["sim_spec"])
