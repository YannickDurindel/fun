class_name MenuRouter
extends Control
## Root of scenes/menu/menu.tscn (the main scene). Shows one UIScreen at a time.
##   go("tracks")  push a screen;  back()  pop to the previous one;  current_name
## Screens are scenes whose root extends UIScreen. To replace a screen, replace its scene file.
## Dev flag: --screen=NAME opens on that screen. --track=ID skips the menu (see Game).

signal screen_changed(name: String)

const SCREENS: Dictionary = {
	"main": "res://scenes/menu/main_menu.tscn",
	"tracks": "res://scenes/menu/track_select.tscn",
	"race_options": "res://scenes/menu/race_options.tscn",
	"settings": "res://scenes/menu/settings.tscn",
	"controls": "res://scenes/menu/controls.tscn",
	"records": "res://scenes/menu/records.tscn",
}
const REF_SIZE := Vector2(1920, 1080)

var current_name: String = ""
var current: UIScreen
var _stack: Array[String] = []
var _show_tween: Tween

@onready var _holder: Control = $Screens

func _ready() -> void:
	get_viewport().size_changed.connect(_fit)
	_fit()
	if Game.skip_menu:
		Game.skip_menu = false
		Game.start_race()
		return
	var start := Bootstrap.start_screen
	if start.is_empty():
		start = Game.menu_start_screen
	Game.menu_start_screen = ""
	# Opening on a sub-screen still lets "back" return to the main menu.
	if not start.is_empty() and start != "main" and SCREENS.has(start):
		_stack = ["main"]
		if start == "race_options":
			_stack.append("tracks")
		_show(start)
	else:
		_show("main")

## Screens are designed at 1920x1080 and scaled uniformly to the window height.
func _fit() -> void:
	var vp := get_viewport_rect().size
	var k := vp.y / REF_SIZE.y
	_holder.scale = Vector2(k, k)
	_holder.size = Vector2(vp.x / k, REF_SIZE.y)
	_holder.position = Vector2.ZERO

func go(screen: String) -> void:
	if not SCREENS.has(screen):
		push_error("MenuRouter: unknown screen '%s'" % screen)
		return
	if not current_name.is_empty():
		_stack.append(current_name)
	_show(screen)

func back() -> void:
	if _stack.is_empty():
		return
	_show(_stack.pop_back())

func can_go_back() -> bool:
	return not _stack.is_empty()

## Swaps the screen at once (input is never blocked); the incoming screen fades and slides in
## over 0.15 s, except when transitions are instant (headless, short screenshot runs).
func _show(screen: String) -> void:
	if _show_tween != null:
		_show_tween.kill()
		_show_tween = null
	if current != null:
		_holder.remove_child(current)
		current.queue_free()
	var s := (load(SCREENS[screen]) as PackedScene).instantiate() as UIScreen
	s.router = self
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	current = s
	current_name = screen
	_holder.add_child(s)
	UISounds.screen_changed()   # the new screen's initial focus makes no tick
	if not Transitions.is_instant():
		s.modulate.a = 0.0
		s.position.x = 36.0
		_show_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_show_tween.tween_property(s, ^"modulate:a", 1.0, 0.15)
		_show_tween.tween_property(s, ^"position:x", 0.0, 0.15)
	screen_changed.emit(screen)
