class_name MenuBackdrop
extends Control
## Live 3D backdrop shared by every menu screen: the F1 car on a dark showroom floor with a
## slowly orbiting camera, rendered in its own SubViewport (own world, reduced resolution),
## under a dark gradient / vignette overlay that keeps the menu text readable.
##   set_dim(amount)   0 = full view (main menu) .. 1 = black; sub-screens dim it more.
## Follows MenuRouter.screen_changed by itself when its parent is the router.

const BODY_SCENE := preload("res://scenes/car/car_body_visual.tscn")
const WHEEL_SCENE := preload("res://scenes/car/wheel_visual.tscn")
const SKY_SHADER := preload("res://shaders/menu_sky.gdshader")
const FLOOR_SHADER := preload("res://shaders/menu_floor.gdshader")
const OVERLAY_SHADER := preload("res://shaders/menu_backdrop_overlay.gdshader")

## Dim per kind of screen (see _on_screen_changed).
const DIM_MAIN: float = 0.0
const DIM_SUB: float = 0.62
const DIM_OPAQUE: float = 1.0
const DIM_TIME: float = 0.35
## Above this the 3D view is invisible, so the viewport stops rendering.
const DIM_HIDDEN: float = 0.985

## The car body rests with the ground at local y = -0.36 (see Car).
const FLOOR_Y: float = -0.36
const LAYER_CAR: int = 1
const LAYER_MIRROR: int = 2
## The floor is lit by the key light only, so the coloured rim lights do not stain it.
const LAYER_FLOOR: int = 4

## Fraction of the window resolution the 3D view is rendered at (cheap on integrated GPUs).
## Multiplied by the player's graphics/render_scale setting.
@export_range(0.25, 1.0) var render_scale: float = 0.75
@export var orbit_speed: float = 0.11          ## rad/s
@export var orbit_radius: float = 9.5
@export var orbit_height: float = 1.7
@export var orbit_start: float = 0.72          ## rad; 0 = straight ahead of the car's nose
## Shifts the car to the right of the frame, clear of the menu column (m, at the car).
@export var frame_shift: float = 1.5

var dim: float = 0.0
var viewport: SubViewport
var camera: Camera3D
var car_root: Node3D

var _angle: float = 0.0
var _overlay_mat: ShaderMaterial
var _dim_tween: Tween
var _key_light: DirectionalLight3D

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_angle = orbit_start
	# --track=ID boots straight into the race: the router leaves at once, build nothing.
	if Game.skip_menu:
		set_process(false)
		return
	_build_view()
	_build_world()
	_build_overlay()
	_place_camera()
	_apply_graphics_settings()
	Settings.changed.connect(_on_setting_changed)
	var router := get_parent() as MenuRouter
	if router != null:
		router.screen_changed.connect(_on_screen_changed.bind(router))

## 0 = full view, 1 = fully dark. Animated unless `instant`.
func set_dim(amount: float, instant: bool = false) -> void:
	amount = clampf(amount, 0.0, 1.0)
	if _dim_tween != null:
		_dim_tween.kill()
		_dim_tween = null
	if amount < DIM_HIDDEN:
		_set_rendering(true)
	if instant or not is_inside_tree():
		_apply_dim(amount)
		return
	_dim_tween = create_tween()
	_dim_tween.tween_method(_apply_dim, dim, amount, DIM_TIME).set_trans(Tween.TRANS_SINE)

func _apply_dim(amount: float) -> void:
	dim = amount
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter(&"dim", amount)
	if amount >= DIM_HIDDEN:
		_set_rendering(false)

func _set_rendering(on: bool) -> void:
	if viewport == null:
		return
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	set_process(on)

func _on_screen_changed(screen: String, router: MenuRouter) -> void:
	var target := DIM_SUB
	if screen == "main":
		target = DIM_MAIN
	elif router.current != null and router.current.opaque_background:
		target = DIM_OPAQUE
	set_dim(target)

func _on_setting_changed(section: String, _key: String) -> void:
	if section == "graphics":
		_apply_graphics_settings()

## The SubViewport has its own world and does not inherit the root viewport's quality, so the
## player's graphics options are applied here (MSAA is capped at 2x: this is only a backdrop).
func _apply_graphics_settings() -> void:
	if viewport == null:
		return
	var msaa: int = clampi(int(Settings.get_value("graphics", "msaa")), Viewport.MSAA_DISABLED, Viewport.MSAA_2X)
	viewport.msaa_3d = msaa as Viewport.MSAA
	viewport.scaling_3d_scale = clampf(render_scale * float(Settings.get_value("graphics", "render_scale")), 0.25, 1.0)
	if _key_light != null:
		_key_light.shadow_enabled = int(Settings.get_value("graphics", "shadows")) > 0

func _process(delta: float) -> void:
	_angle = fposmod(_angle + orbit_speed * delta, TAU)
	_place_camera()

func _place_camera() -> void:
	if camera == null:
		return
	var h := orbit_height + 0.25 * sin(_angle * 2.0)
	var target := Vector3(0.0, 0.05, 0.0)
	var pos := Vector3(sin(_angle) * orbit_radius, h, -cos(_angle) * orbit_radius)
	camera.look_at_from_position(pos, target, Vector3.UP)
	camera.h_offset = -frame_shift

func _build_view() -> void:
	var holder := SubViewportContainer.new()
	holder.name = "View"
	holder.stretch = true
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(holder)
	viewport = SubViewport.new()
	viewport.name = "Viewport"
	viewport.own_world_3d = true
	viewport.handle_input_locally = false
	viewport.gui_disable_input = true
	viewport.positional_shadow_atlas_size = 0
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	holder.add_child(viewport)

func _build_world() -> void:
	var world := Node3D.new()
	world.name = "World"
	viewport.add_child(world)

	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	world.add_child(world_env)

	# Key light with the only shadow; the mirrored twin lights the reflection from below.
	var key_dir := Vector3(-0.45, -1.0, -0.35).normalized()
	_key_light = _sun(world, "KeyLight", key_dir, Color(1.0, 0.96, 0.9), 1.5, LAYER_CAR | LAYER_FLOOR, true)
	_sun(world, "KeyLightMirror", key_dir * Vector3(1, -1, 1), Color(1.0, 0.96, 0.9), 0.9, LAYER_MIRROR, false)
	# Coloured rim lights in the UI accent colours.
	for side: float in [-1.0, 1.0]:
		var col := UIScreen.COL_ACCENT if side < 0.0 else UIScreen.COL_HILITE
		var pos := Vector3(4.2 * side, 1.4, 3.6 * side)
		_rim(world, "Rim%s" % ("Blue" if side < 0.0 else "Red"), pos, col, LAYER_CAR)
		_rim(world, "Rim%sMirror" % ("Blue" if side < 0.0 else "Red"), _mirror(pos), col, LAYER_MIRROR)

	var floor_mat := ShaderMaterial.new()
	floor_mat.shader = FLOOR_SHADER
	var plane := PlaneMesh.new()
	plane.size = Vector2(90.0, 90.0)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Floor"
	floor_mesh.mesh = plane
	floor_mesh.material_override = floor_mat
	floor_mesh.position = Vector3(0.0, FLOOR_Y, 0.0)
	floor_mesh.layers = LAYER_FLOOR
	floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(floor_mesh)

	car_root = _build_car("Car")
	world.add_child(car_root)
	# Cheap planar reflection: the same car mirrored under the translucent floor.
	var mirror := _build_car("CarMirror")
	mirror.scale = Vector3(1.0, -1.0, 1.0)
	mirror.position = Vector3(0.0, 2.0 * FLOOR_Y, 0.0)
	world.add_child(mirror)
	_set_layers(mirror, LAYER_MIRROR, false)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 38.0
	camera.near = 0.2
	camera.far = 120.0
	world.add_child(camera)
	camera.current = true

func _mirror(p: Vector3) -> Vector3:
	return Vector3(p.x, 2.0 * FLOOR_Y - p.y, p.z)

## Body + four wheels, laid out like scenes/car/car.tscn but with no physics.
func _build_car(node_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.add_child(BODY_SCENE.instantiate())
	for i in Car.WHEEL_OFFSETS.size():
		var wheel := WHEEL_SCENE.instantiate() as Node3D
		wheel.name = "Wheel%d" % i
		wheel.set(&"wheel_index", i)
		# Without a Car ancestor the wheel visual never moves itself: rest it on the floor.
		var radius := Car.FRONT_WHEEL_RADIUS if i < 2 else Car.REAR_WHEEL_RADIUS
		wheel.position = Car.WHEEL_OFFSETS[i] + Vector3(0.0, FLOOR_Y + radius, 0.0)
		# It has nothing to read without a Car, so there is no need to tick it.
		wheel.process_mode = Node.PROCESS_MODE_DISABLED
		root.add_child(wheel)
	return root

func _set_layers(node: Node, layers: int, shadows: bool) -> void:
	var gi := node as GeometryInstance3D
	if gi != null:
		gi.layers = layers
		if not shadows:
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_set_layers(child, layers, shadows)

func _sun(parent: Node, node_name: String, dir: Vector3, color: Color, energy: float, mask: int, shadow: bool) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = node_name
	light.light_color = color
	light.light_energy = energy
	light.light_cull_mask = mask
	light.shadow_enabled = shadow
	if shadow:
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		light.directional_shadow_max_distance = 24.0
		light.shadow_blur = 2.0
	parent.add_child(light)
	light.look_at_from_position(Vector3.ZERO, dir, Vector3.RIGHT)
	return light

func _rim(parent: Node, node_name: String, pos: Vector3, color: Color, mask: int) -> void:
	var light := OmniLight3D.new()
	light.name = node_name
	light.light_color = color
	light.light_energy = 5.0
	light.omni_range = 9.0
	light.light_cull_mask = mask
	light.shadow_enabled = false
	light.position = pos
	parent.add_child(light)

func _build_overlay() -> void:
	_overlay_mat = ShaderMaterial.new()
	_overlay_mat.shader = OVERLAY_SHADER
	_overlay_mat.set_shader_parameter(&"dim", dim)
	var overlay := ColorRect.new()
	overlay.name = "Overlay"
	overlay.material = _overlay_mat
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
