extends SceneTree
## Renders the CC0 tree models cached by cad/track/fetch_cc0_assets.py into billboard
## impostors for the realistic track look (TrackDressing): for every model, two orthographic
## side views (0 and 90 degrees round the trunk) on a transparent background, side by side
## in one 1024 x 512 PNG, lit by a flat ambient light only so the game can shade the card
## itself. Writes assets/tracks/_shared/look_detailed/trees/<id>.png and trees.json:
##   {"<id>": {"file": "res://...", "height": m, "width": m, "crop_w": f, "crop_h": f}}
##   width, height: of one view square, the model's base at the bottom edge, its trunk at the
##   horizontal centre; crop_w / crop_h: share of the square the model really covers (width
##   centred, height from the base), so the game draws a quad no bigger than the tree.
## Needs a window (rendering): tools/bin/godot --path . -s cad/track/bake_impostors.gd

const MODELS := ["island_tree_01", "island_tree_02", "tree_small_02", "shrub_04"]
const OUT := "res://assets/tracks/_shared/look_detailed/trees"
const VIEW_PX := 512

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var cache := OS.get_environment("HOME").path_join(".cache/fun-racer/cc0/models")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var vp := SubViewport.new()
	vp.size = Vector2i(VIEW_PX, VIEW_PX)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = e
	vp.add_child(env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)
	var table := {}
	for id: String in MODELS:
		var path := cache.path_join(id).path_join(id + ".gltf")
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) != OK:
			push_error("cannot read %s" % path)
			continue
		var scene := doc.generate_scene(state) as Node3D
		vp.add_child(scene)
		var box := AABB()
		var first := true
		for n: Node in scene.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			var b := mi.global_transform * mi.get_aabb()
			box = b if first else box.merge(b)
			first = false
		var size := maxf(box.size.y, maxf(box.size.x, box.size.z)) * 1.02
		cam.size = size
		var center_x := box.get_center().x
		var center_z := box.get_center().z
		var img := Image.create(VIEW_PX * 2, VIEW_PX, false, Image.FORMAT_RGBA8)
		for v in 2:
			var ang := v * PI * 0.5
			var dir := Vector3(sin(ang), 0.0, cos(ang))
			var target := Vector3(center_x, box.position.y + size * 0.5, center_z)
			cam.global_position = target + dir * (size * 2.0)
			cam.look_at(target, Vector3.UP)
			cam.near = 0.05
			cam.far = size * 4.0
			for _f in 4:
				await process_frame
			await RenderingServer.frame_post_draw
			var shot := vp.get_texture().get_image()
			shot.convert(Image.FORMAT_RGBA8)
			img.blit_rect(shot, Rect2i(0, 0, VIEW_PX, VIEW_PX), Vector2i(v * VIEW_PX, 0))
		var file := OUT.path_join(id + ".png")
		img.save_png(file)
		var used := img.get_used_rect()   # alpha > 0, over both views
		var half := 0.0
		for v in 2:
			var cx := v * VIEW_PX + VIEW_PX * 0.5
			for y in VIEW_PX:
				for x in VIEW_PX:
					if img.get_pixel(v * VIEW_PX + x, y).a > 0.02:
						half = maxf(half, absf(v * VIEW_PX + x + 0.5 - cx))
		table[id] = {"file": file, "height": size, "width": size,
				"crop_w": snappedf(minf(1.0, 2.0 * half / VIEW_PX + 0.02), 0.001),
				"crop_h": snappedf(minf(1.0, float(VIEW_PX - used.position.y) / VIEW_PX + 0.01), 0.001)}
		print("%s: %.1f m" % [id, size])
		scene.queue_free()
		await process_frame
	var f := FileAccess.open(OUT.path_join("trees.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(table, "  ") + "\n")
	f.close()
	quit()
