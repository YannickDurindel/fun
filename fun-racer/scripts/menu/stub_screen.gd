extends UIScreen
## STUB screen used by the skeleton: a title and a column of buttons that navigate.
## Each real screen replaces its scene (and uses its own script).

@export var title: String = "TITLE"
@export var kind: String = "main"   ## which stub behaviour to build

func on_enter() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(140, 150)
	box.add_theme_constant_override(&"separation", 14)
	add_child(box)
	var t := Label.new()
	t.text = title
	t.theme_type_variation = &"TitleLabel"
	box.add_child(t)
	match kind:
		"main":
			_button(box, "PLAY", func() -> void: router.go("tracks"))
			_button(box, "RECORDS", func() -> void: router.go("records"))
			_button(box, "OPTIONS", func() -> void: router.go("settings"))
			_button(box, "QUIT", func() -> void: get_tree().quit())
		"tracks":
			for info in TrackCatalog.all():
				var b := _button(box, "%s  (%s, %.3f km)" % [info.name.to_upper(), info.country, info.length_m / 1000.0],
						func() -> void:
							Game.pending.track_id = info.id
							router.go("race_options"))
				b.disabled = not info.available
				if box.get_child_count() > 7:
					break
			_button(box, "BACK", on_back)
		"race_options":
			var info := TrackCatalog.find(Game.pending.track_id)
			var l := Label.new()
			l.text = info.name if info != null else "?"
			l.theme_type_variation = &"HeaderLabel"
			box.add_child(l)
			_button(box, "START", func() -> void: Game.start_race())
			_button(box, "BACK", on_back)
		"settings":
			_button(box, "CONTROLS", func() -> void: router.go("controls"))
			_button(box, "BACK", on_back)
		_:
			_button(box, "BACK", on_back)

func _button(parent: Node, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(520, 64)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(action)
	parent.add_child(b)
	return b
