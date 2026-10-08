class_name UIScreen
extends Control
## Base class of every menu screen (one scene per screen, swapped by MenuRouter).
##   * `router` is set before the screen enters the tree: router.go("name"), router.back().
##   * Override on_enter() to refresh content each time the screen is shown.
##   * ui_cancel (Esc / pad B) goes back; override on_back() to change that.
##   * The first focusable control (or `initial_focus`) gets focus, so keyboard and gamepad work.
## Layout: design at 1920x1080; the router scales the screen to the window height.

const COL_BG := Color(0.03, 0.035, 0.05, 0.82)
const COL_ACCENT := Color(0.16, 0.45, 1.0)
const COL_HILITE := Color(0.93, 0.16, 0.16)
const COL_TEXT := Color(1, 1, 1)
const COL_TEXT_DIM := Color(1, 1, 1, 0.6)

## Set to true if the screen should hide the shared 3D backdrop / dim it more.
@export var opaque_background: bool = false
@export var initial_focus: NodePath

var router: MenuRouter

func _ready() -> void:
	on_enter()
	_grab_initial_focus.call_deferred()

## Called when the screen is shown (after _ready).
func on_enter() -> void:
	pass

## Called on ui_cancel. Default: back to the previous screen.
func on_back() -> void:
	if router != null:
		router.back()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		on_back()

func _grab_initial_focus() -> void:
	if not is_inside_tree():
		return
	var n := get_node_or_null(initial_focus) as Control
	if n == null:
		n = find_next_valid_focus()
	if n != null:
		n.grab_focus()
