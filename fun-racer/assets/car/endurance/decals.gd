extends Node3D
## Decals of the endurance car (race-number roundels, sponsors, pinstripes; see
## scenes/car/endurance_body_visual.tscn). Only the player's car keeps them: each decal costs
## every car it lies on a pass over its pixels on the Mobile renderer (about 4 ms on the
## HD 520 with ten bots), and the bots, recoloured by BotManager, would all wear the #50 livery.
## Outside a race (menu, renders) the decals stay.

func _ready() -> void:
	await get_tree().process_frame   # BotManager gives a bot its driver after dressing it
	if not is_instance_valid(self):
		return
	var n := get_parent()
	while n != null and not (n is Car):
		n = n.get_parent()
	if n == null:
		return
	for c: Node in n.get_children():
		if c is BotDriver:
			queue_free()
			return
