extends Node3D
## Motion of the body visual that the physics does not already give, for the simulation car.
##
## The simulation's rigid body itself pitches and rolls on its suspension, and this node is a
## child of it, so the bodywork already moves by the real amount: a fraction of a degree to
## about one degree, as on a real Formula 1 car. Nothing is added to that on purpose.
## What the rigid body cannot show is the driver: the helmet (and visor) lean against the
## acceleration, out of the corner and forward under braking, a few degrees at most.
## An arcade car is left exactly as it was (this node stops processing on its first frame).

## Pivot of the head, at the base of the helmet (body frame, m).
const NECK := Vector3(0.0, 0.215, -0.05)
const G: float = 9.81
## Lean out of a corner: degrees per g of lateral acceleration, and the most the belts allow.
const LEAN_DEG_PER_G: float = 1.8
const LEAN_MAX_DEG: float = 7.0
## Nod under braking (forward) and acceleration (back, into the headrest).
const NOD_DEG_PER_G: float = 1.1
const NOD_FORWARD_MAX_DEG: float = 5.0
const NOD_BACK_MAX_DEG: float = 1.2
## The neck follows the load with this time constant (s).
const RESPONSE_TIME: float = 0.09
const HEAD_NODES: Array[String] = ["Body/Helmet", "Body/Visor"]

## Current head angles (rad): lean + = towards the car's left, nod + = backwards.
var head_lean: float = 0.0
var head_nod: float = 0.0

var _car: Car
var _head: Array[Node3D] = []

func _ready() -> void:
	var n: Node = get_parent()
	while n != null and not (n is Car):
		n = n.get_parent()
	_car = n as Car
	for path in HEAD_NODES:
		var h := get_node_or_null(path) as Node3D
		if h != null:
			_head.append(h)
	if _car != null:
		_car.respawned.connect(_on_respawned)
	# Car._ready has not run yet (children are readied first), so the handling model is
	# not known here: _process decides on the first frame.
	set_process(_car != null and not _head.is_empty())

func _on_respawned() -> void:
	if head_lean == 0.0 and head_nod == 0.0:
		return
	head_lean = 0.0
	head_nod = 0.0
	_apply()

func _process(delta: float) -> void:
	if _car.sim == null or _car.sim.state == null:
		set_process(false)   # arcade: nothing to do, ever
		return
	var st := _car.sim.state
	# accel_lat is + to the right: the head is thrown left, a + rotation about the car's +Z.
	var lean_t := clampf(deg_to_rad(LEAN_DEG_PER_G) * st.accel_lat / G,
			-deg_to_rad(LEAN_MAX_DEG), deg_to_rad(LEAN_MAX_DEG))
	# accel_long is - under braking: the head nods forward, a - rotation about +X.
	var nod_t := clampf(deg_to_rad(NOD_DEG_PER_G) * st.accel_long / G,
			-deg_to_rad(NOD_FORWARD_MAX_DEG), deg_to_rad(NOD_BACK_MAX_DEG))
	var k := 1.0 - exp(-delta / RESPONSE_TIME)
	var lean := lerpf(head_lean, lean_t, k)
	var nod := lerpf(head_nod, nod_t, k)
	if absf(lean - head_lean) < 1e-5 and absf(nod - head_nod) < 1e-5:
		return
	head_lean = lean
	head_nod = nod
	_apply()

func _apply() -> void:
	var b := Basis(Vector3.BACK, head_lean) * Basis(Vector3.RIGHT, head_nod)
	var xf := Transform3D(b, NECK - b * NECK)
	for h in _head:
		h.transform = xf
