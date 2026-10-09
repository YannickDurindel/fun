class_name WheelState
extends RefCounted
## Per-wheel state published by Car every physics tick (read-only for other systems).

var contact: bool = false
var contact_point: Vector3 = Vector3.ZERO   ## world space
var contact_normal: Vector3 = Vector3.UP    ## world space
var slip: float = 0.0          ## 0 = full grip, 1 = fully sliding (lateral+longitudinal)
var spin_angle: float = 0.0    ## radians, accumulated rolling rotation about the axle
var steer_angle: float = 0.0   ## radians, positive = turning left (rotation about +Y)
var compression: float = 0.0   ## metres of suspension travel compressed from rest (+ = compressed)
## Surface under the wheel from the collider's `surface` meta: &"asphalt", &"kerb", &"grass",
## &"gravel" (asphalt when untagged). Keeps the last value while airborne.
var surface: StringName = &"asphalt"
# ---- simulation handling only (left at these defaults by the arcade model)
var load: float = 0.0          ## N, vertical load on the tyre
var slip_ratio: float = 0.0    ## (wheel surface speed - road speed) / road speed; + = wheelspin, -1 = locked
var slip_angle: float = 0.0    ## rad between the wheel's heading and its direction of travel
var temperature: float = 90.0  ## deg C, tyre tread
var wear: float = 0.0          ## 0 = new, 1 = worn out
var locked: bool = false       ## the brake has stopped the wheel while the car is moving
