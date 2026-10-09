class_name SimAero
extends RefCounted
## Aerodynamics of the simulation car. Every tick writes state.downforce_front,
## state.downforce_rear, state.drag (N) and state.drs_open.
##
## Model: dynamic pressure times coefficient-areas, in three elements.
##   - Front wing and rear wing: scale with CarSpec.wing_level (Monza .. Monaco trim).
##   - Floor (ground effect): gains downforce as the car runs lower, up to an optimum, then
##     loses it (the floor chokes). Its centre of pressure moves forward when the nose dives.
## All three lose downforce with yaw (body slip) and in the wake of another car (state.tow);
## the tow also cuts drag. DRS opens the rear-wing flap: less drag, less rear downforce.
##
## Ride heights come from state.compression through a short low-pass filter so the aero load
## never chases the dampers; the slope of downforce against ride height is well below the
## spring rate, so the loop with the suspension is statically stable too.
##
## DRS logic: the flap opens while state.drs_request is true. Braking (state.brake > 0) or a
## lift (driver throttle below drs_close_throttle) closes an open flap, and it then stays
## closed until the request is dropped and made again, as on the real car. A request made
## while braking or coasting is kept: the flap opens once the driver is back on the throttle.
##
## Reference numbers used to tune the default (medium wing) spec:
##   - Downforce equals the weight at about 150 km/h and is "three or four times" the weight
##     at the end of the longest straight: Mercedes-AMG F1, "Downforce in Formula One,
##     explained", https://www.mercedesamgf1.com/news/feature-downforce-in-formula-one-explained
##     (formula1-dictionary.net gives 130 km/h, dfstudios.co.uk about 160 km/h).
##   - Drag: Cd about 0.7-1.1 depending on the wing level, CdA about 1.2 m^2:
##     https://formula1-dictionary.net/drag.html . The spec uses 1.30 m^2 at the medium wing,
##     which with this car's 740 kW gives the 330-350 km/h top speed of the reference table.
##   - DRS: 10-12 km/h by the end of the zone (FIA estimate),
##     https://en.wikipedia.org/wiki/Drag_reduction_system ; 13-20 km/h measured at Spa 2023,
##     https://www.planetf1.com/news/red-bull-belgian-gp-drs-gain

## Flap position, 0 closed .. 1 fully open (read-only for others).
var drs_position: float = 0.0
## Share of the downforce on the front axle this tick (read-only; the design balance while
## there is no downforce).
var balance_front: float = 0.0
## Filtered axle compressions the aero sees (m, read-only).
var compression_front: float = 0.0
var compression_rear: float = 0.0

var _drs_closed_by_driver: bool = false

func setup(_spec: CarSpec) -> void:
	pass

func reset(state: SimState, spec: CarSpec) -> void:
	state.drs_open = false
	state.downforce_front = 0.0
	state.downforce_rear = 0.0
	state.drag = 0.0
	drs_position = 0.0
	balance_front = spec.aero_balance_front
	compression_front = 0.5 * (state.compression[0] + state.compression[1])
	compression_rear = 0.5 * (state.compression[2] + state.compression[3])
	_drs_closed_by_driver = false

## Floor downforce relative to the design ride height, for a mean axle compression `c` (m).
## Rises to 1 + floor_gain at the optimum with a flat top, falls beyond it. Above the design
## ride height the loss is linear (the slope never grows), down to floor_min_factor.
func floor_factor(spec: CarSpec, c: float) -> float:
	var x := c / maxf(spec.floor_optimal_compression, 1e-4)
	var f: float
	if x <= 0.0:
		f = 1.0 + 2.0 * spec.floor_gain * x
	elif x <= 1.0:
		f = 1.0 + spec.floor_gain * (1.0 - (1.0 - x) * (1.0 - x))
	else:
		f = 1.0 + spec.floor_gain - spec.floor_stall_loss * (x - 1.0) * (x - 1.0)
	return maxf(f, spec.floor_min_factor)

## Called every tick after the suspension.
func step(state: SimState, spec: CarSpec, dt: float) -> void:
	# ---- DRS flap
	if not state.drs_request:
		_drs_closed_by_driver = false
	elif drs_position > 0.0 and (state.brake > 0.0 or state.in_throttle < spec.drs_close_throttle):
		_drs_closed_by_driver = true
	var open := state.drs_request and not _drs_closed_by_driver \
			and state.brake <= 0.0 and state.in_throttle >= spec.drs_close_throttle
	var travel := dt / spec.drs_actuation_time if spec.drs_actuation_time > 0.0 else 1.0
	drs_position = move_toward(drs_position, 1.0 if open else 0.0, travel)
	state.drs_open = open

	# ---- ride heights (filtered)
	var blend := 1.0 - exp(-dt / spec.ride_height_filter_time) if spec.ride_height_filter_time > 0.0 else 1.0
	compression_front += (0.5 * (state.compression[0] + state.compression[1]) - compression_front) * blend
	compression_rear += (0.5 * (state.compression[2] + state.compression[3]) - compression_rear) * blend

	# ---- coefficient-areas of the three elements
	var trim := 2.0 * clampf(spec.wing_level, 0.0, 1.0) - 1.0
	var wing_scale := 1.0 + spec.wing_downforce_range * trim
	var floor_design := spec.cl_a * spec.floor_share
	var front_wing := maxf(spec.cl_a * spec.aero_balance_front - floor_design * spec.floor_balance_front, 0.0) * wing_scale
	var rear_wing := maxf(spec.cl_a * (1.0 - spec.aero_balance_front) - floor_design * (1.0 - spec.floor_balance_front), 0.0) * wing_scale
	var floor_cl_a := floor_design * floor_factor(spec, 0.5 * (compression_front + compression_rear))
	var cop_shift := clampf(spec.floor_cop_per_rake * (compression_front - compression_rear),
			-spec.floor_cop_shift_max, spec.floor_cop_shift_max)
	var floor_front := clampf(spec.floor_balance_front + cop_shift, 0.0, 1.0)

	# ---- yaw and tow
	var yaw := minf(absf(state.body_slip) / maxf(spec.yaw_reference_angle, 1e-3), 1.0)
	yaw *= yaw
	var tow := clampf(state.tow, 0.0, 1.0)

	# ---- forces. Downforce needs air coming from the front: none when rolling backwards.
	# It uses the airspeed along the car (v_long), so a sliding car already loses the cosine
	# squared of its slip; yaw_downforce_loss is the further loss from the crooked flow.
	var v_ahead := maxf(state.v_long, 0.0)
	var q_down := 0.5 * spec.air_density * v_ahead * v_ahead * (1.0 - spec.yaw_downforce_loss * yaw)
	var q_drag := 0.5 * spec.air_density * state.speed * state.speed
	state.downforce_front = q_down * (front_wing + floor_cl_a * floor_front) \
			* (1.0 - tow * spec.tow_downforce_loss_front)
	state.downforce_rear = q_down * (rear_wing + floor_cl_a * (1.0 - floor_front)) \
			* lerpf(1.0, spec.drs_downforce_factor, drs_position) \
			* (1.0 - tow * spec.tow_downforce_loss_rear)
	state.drag = q_drag * spec.cd_a * (1.0 + spec.wing_drag_range * trim) \
			* lerpf(1.0, spec.drs_drag_factor, drs_position) \
			* (1.0 + spec.yaw_drag_gain * yaw) \
			* (1.0 - tow * spec.tow_drag_loss)
	var total := state.downforce_front + state.downforce_rear
	balance_front = state.downforce_front / total if total > 0.0 else spec.aero_balance_front
