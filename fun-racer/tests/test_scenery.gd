extends TestCase
## Scenery runtime (scripts/track/scenery.gd, track_environment.gd, the land cover in
## terrain.gd) on the synthetic fixture tests/fixtures/tracks/scenery_oval (the test oval's
## lap plus every scenery file, made by make_scenery_fixture.py):
##   * buildings, trees, water, landmarks and collision are built from the files;
##   * environment.json reaches the sun, sky, fog, kerbs and verges, and a night shows lamps;
##   * the `scenery` graphics setting changes what is drawn, live;
##   * a track folder without scenery files builds exactly what it built before.

const GENERIC := "res://scenes/tracks/track.tscn"
const SKY := "res://scenes/world/sky_environment.tscn"
const SCENERY_DIR := "res://tests/fixtures/tracks/scenery_oval"
const PLAIN_DIR := "res://tests/fixtures/tracks/test_oval"

var _world: Node3D
var _sky: Node3D
var _original_environment: Environment

## A sky scene and a track of folder `dir` side by side, as in the race scene.
func _track(dir: String, with_sky: bool = true) -> Track:
	_world = Node3D.new()
	add_child(_world)
	_sky = null
	if with_sky:
		_sky = (load(SKY) as PackedScene).instantiate() as Node3D
		_world.add_child(_sky)
		_original_environment = (_sky.get_node("Environment") as WorldEnvironment).environment
	var track := (load(GENERIC) as PackedScene).instantiate() as Track
	track.track_dir = dir
	_world.add_child(track)
	return track

func _done() -> void:
	Bootstrap.time_override = ""
	Settings.reset("graphics")
	if is_instance_valid(_world):
		_world.free()
	_world = null

func _trackside_built(track: Track) -> Trackside:
	var ts := track.get_node("Trackside") as Trackside
	var frames := 0
	while not ts.is_built and frames < 600:
		await get_tree().physics_frame
		frames += 1
	assert_true(ts.is_built, "Trackside finished building")
	return ts

func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01

## Instances drawn by the far-copy tree MultiMeshes (every tree is in exactly one of them).
func _drawn_trees(scenery: Scenery) -> int:
	var total := 0
	var trees := scenery.get_node_or_null("Trees")
	if trees == null:
		return 0
	for c in trees.get_children():
		if String(c.name).ends_with("lod1"):
			total += (c as MultiMeshInstance3D).multimesh.instance_count
	return total

# ------------------------------------------------------------------ the fixture builds
func test_fixture_builds_everything() -> void:
	var track := _track(SCENERY_DIR)
	var scenery := track.scenery
	assert_true(scenery != null and scenery.is_built, "Scenery is built when the track is ready")
	assert_true(scenery.get_parent() == track and scenery.get_index() == track.get_child_count() - 1,
			"Scenery is the track's last child")
	assert_true(scenery.build_msec < 1500, "scenery built in %d ms" % scenery.build_msec)
	# Buildings: the baked chunks, with the materials made at runtime.
	var buildings := scenery.get_node_or_null("Buildings")
	assert_true(buildings != null and scenery.building_chunks >= 2, "building chunks: %d" % scenery.building_chunks)
	var seen := {}
	for mi in Scenery.mesh_instances(buildings):
		assert_true(String(mi.name).begins_with("chunk_"), "chunk node name: %s" % mi.name)
		for surf in mi.mesh.get_surface_count():
			var mat_name := Scenery.surface_name(mi.mesh, surf)
			seen[mat_name] = true
			assert_true(mi.get_surface_override_material(surf) == scenery.materials.get(mat_name),
					"%s uses the runtime material" % mat_name)
	for want: String in ["building_wall", "building_roof", "building_glass", "stand_seats", "stand_structure",
			"concrete", "metal", "emissive_window", "emissive_light"]:
		assert_true(seen.has(want), "the fixture has a %s surface" % want)
	assert_true((scenery.materials["building_wall"] as ShaderMaterial).shader == Scenery.FACADE_SHADER, "facade shader")
	# Collision: only what stands beside the road (the pit building), tagged like a barrier.
	assert_true(scenery.collision_bodies >= 1 and scenery.collision_faces >= 8,
			"collision bodies %d, faces %d" % [scenery.collision_bodies, scenery.collision_faces])
	var total_faces := 0
	for mi in Scenery.mesh_instances(buildings):
		total_faces += mi.mesh.get_faces().size() / 3
	assert_true(scenery.collision_faces < total_faces / 4, "far buildings get no collision (%d of %d faces)" % [scenery.collision_faces, total_faces])
	await _trackside_built(track)   # the bodies wait for Trackside's ray-snapping
	var bodies := 0
	for c in scenery.get_children():
		if c is StaticBody3D:
			bodies += 1
			assert_true(c.get_meta("surface") == "asphalt", "scenery bodies are 'asphalt'")
	assert_true(bodies == scenery.collision_bodies, "bodies in the tree: %d" % bodies)
	# Trees: every record of the file, one MultiMesh per chunk, species and level of detail.
	var bytes := FileAccess.get_file_as_bytes(SCENERY_DIR + "/scenery_points.bin")
	assert_true(scenery.tree_total == bytes.size() / 20 and scenery.tree_total > 100, "tree records: %d" % scenery.tree_total)
	assert_true(scenery.tree_instances == scenery.tree_total, "medium shows every tree (%d of %d)" % [scenery.tree_instances, scenery.tree_total])
	assert_true(_drawn_trees(scenery) == scenery.tree_instances, "MultiMesh instances add up: %d" % _drawn_trees(scenery))
	assert_true(scenery.tree_multimeshes == scenery.get_node("Trees").get_child_count(), "MultiMesh count")
	# Species ids are the pipeline's (0 broadleaved, 1 needleleaved, 2 palm, 3 bush).
	var records := bytes.to_float32_array()
	var drawn_as: Array[String] = ["broadleaf", "conifer", "palm", "bush"]
	var kinds := 0
	for id in drawn_as.size():
		var in_file := 0
		for n in scenery.tree_total:
			if int(records[n * 5 + 4]) == id:
				in_file += 1
		var drawn := 0
		for c in scenery.get_node("Trees").get_children():
			if String(c.name).ends_with("_%s_lod1" % drawn_as[id]):
				drawn += (c as MultiMeshInstance3D).multimesh.instance_count
		assert_true(drawn == in_file, "species id %d is drawn as %s: %d of %d" % [id, drawn_as[id], drawn, in_file])
		if in_file > 0:
			kinds += 1
	assert_true(kinds >= 2, "the fixture has several species")
	for species in TrackEnvironment.SPECIES.size():
		assert_true(SceneryTrees.triangle_count(species, 0) <= 160 and SceneryTrees.triangle_count(species, 1) <= 60,
				"%s is low-poly: %d / %d triangles" % [TrackEnvironment.SPECIES[species],
				SceneryTrees.triangle_count(species, 0), SceneryTrees.triangle_count(species, 1)])
		assert_true(SceneryTrees.triangle_count(species, 1) <= SceneryTrees.triangle_count(species, 0), "far copy is not heavier")
	# Water: one mesh with both bodies, and the ground under it is lowered.
	var water := scenery.get_node_or_null("Water") as MeshInstance3D
	assert_true(water != null and scenery.water_bodies == 2, "water plane with %d bodies" % scenery.water_bodies)
	var terrain := track.get_node("Terrain") as Terrain
	assert_true(terrain.has_landcover and terrain.sunk_vertices > 0, "land cover in use, %d vertices under water" % terrain.sunk_vertices)
	assert_true(terrain.material.get_shader_parameter("has_landcover") == true, "terrain shader paints the classes")
	assert_true(terrain.material.get_shader_parameter("lc_near") is Texture2D, "near land-cover texture set")
	var meta: Dictionary = track.scenery_meta
	var lake: Dictionary = (meta["water"] as Array)[1]
	assert_true((lake["triangles"] as PackedInt32Array).size() == ((lake["polygon"] as PackedVector2Array).size() - 2) * 3,
			"baked water triangles are read")
	assert_true(((meta["water"] as Array)[0]["triangles"] as PackedInt32Array).is_empty(), "the sea is triangulated at runtime")
	assert_true((water.mesh.get_faces().size() / 3) > (lake["triangles"] as PackedInt32Array).size() / 3, "both bodies are in the water mesh")
	var mid := Vector2.ZERO
	for p: Vector2 in lake["polygon"]:
		mid += p / (lake["polygon"] as PackedVector2Array).size()
	assert_true(terrain.class_at(mid.x, mid.y) == Terrain.CLASS_WATER, "the lake's centre is a water cell")
	# Landmarks: both entries, the first one placed from the lap.
	assert_true(scenery.landmark_count == 2, "landmarks: %d" % scenery.landmark_count)
	var first := scenery.get_node("Landmarks").get_child(0) as Node3D
	var lateral := track.data.lateral_offset(first.global_position)
	assert_between(lateral, -47.0, -43.0, "landmark placed 45 m left of the centreline")
	var kept := false
	for mi in Scenery.mesh_instances(first):
		for surf in mi.mesh.get_surface_count():
			if Scenery.surface_name(mi.mesh, surf) == "landmark_red":
				kept = mi.get_surface_override_material(surf) == null
	assert_true(kept, "a landmark's own material is kept")
	_done()

# ------------------------------------------------------------------ environment
func test_environment_reaches_sky_kerbs_and_verges() -> void:
	var track := _track(SCENERY_DIR)
	var env := track.environment
	assert_true(env.active and env.time == "day", "the fixture has a day environment.json")
	var world_env := _sky.get_node("Environment") as WorldEnvironment
	var e := world_env.environment
	assert_true(e != _original_environment, "the Environment resource is a copy")
	assert_true(e.sky != _original_environment.sky and e.sky.sky_material != _original_environment.sky.sky_material,
			"sky and sky material are copies too")
	assert_true(_close(e.ambient_light_color, env.color("ambient", "color")), "ambient colour applied")
	assert_between(e.fog_depth_end, env.number("fog", "end") - 1.0, env.number("fog", "end") + 1.0, "fog end")
	assert_true(_close(e.fog_light_color, env.color("sky", "horizon")), "fog colour is the horizon's")
	assert_true(_close((e.sky.sky_material as ProceduralSkyMaterial).sky_top_color, env.color("sky", "top")), "sky colour applied")
	var sun := _sky.get_node("Sun") as DirectionalLight3D
	assert_true(sun.global_basis.z.distance_to(env.sun_direction()) < 0.01, "sun aimed by azimuth and elevation")
	assert_between(sun.light_energy, env.number("sun", "energy") - 0.01, env.number("sun", "energy") + 0.01, "sun energy")
	# The default sun of the sky scene is azimuth 60, elevation 45.
	assert_true(TrackEnvironment.direction(60.0, 45.0).distance_to(Vector3(0.612, 0.707, -0.354)) < 0.01, "bearing convention")
	# Kerbs and verges take the track's colours.
	var ts := await _trackside_built(track)
	var mats: Array = ts.get("_mats")
	var kerb := mats[Trackside.Mat.KERB_RW] as ShaderMaterial
	assert_true(_close(kerb.get_shader_parameter("color_a"), Color(0.05, 0.25, 0.75)), "kerb colour a from environment.json")
	var sausage := mats[Trackside.Mat.KERB_YELLOW] as ShaderMaterial
	assert_true(_close(sausage.get_shader_parameter("color_a"), Color(0.95, 0.45, 0.05)), "sausage kerb colour")
	var verges := 0
	for mi in Scenery.mesh_instances(track.get_node("Road")):
		for surf in mi.mesh.get_surface_count():
			if Scenery.surface_name(mi.mesh, surf) != "grass":
				continue
			var mat := mi.get_surface_override_material(surf)
			assert_true(mat != null and mat != mi.mesh.surface_get_material(surf), "verge material is an override copy")
			var colour: Color = (mat as ShaderMaterial).get_shader_parameter("grass_color") if mat is ShaderMaterial \
					else (mat as BaseMaterial3D).albedo_color
			assert_true(_close(colour, Color(0.24, 0.40, 0.12)), "verge colour from environment.json")
			verges += 1
	assert_true(verges > 0, "the road has grass verges")
	# Freed track: the sky scene has its own Environment and sun back.
	_world.remove_child(track)
	assert_true(world_env.environment == _original_environment, "Environment restored when the track leaves")
	assert_true(sun.global_basis.z.distance_to(Vector3(0.612, 0.707, -0.354)) < 0.01, "sun restored")
	track.free()
	_done()

func test_night_is_dark_with_lit_lamps() -> void:
	var day := _track(SCENERY_DIR)
	var day_ambient := (_sky.get_node("Environment") as WorldEnvironment).environment.ambient_light_energy
	var day_sun := (_sky.get_node("Sun") as DirectionalLight3D).light_energy
	assert_true(day.scenery.lamp_count == 0 and day.get_node_or_null(TrackEnvironment.EXTRA_LIGHT) == null, "no lamps by day")
	_done()
	Bootstrap.time_override = "night"
	var track := _track(SCENERY_DIR)
	var env := track.environment
	assert_true(env.time == "night" and env.floodlit(), "--time=night gives a floodlit night")
	var e := (_sky.get_node("Environment") as WorldEnvironment).environment
	assert_true(e.ambient_light_energy < day_ambient * 0.5, "night ambient %.2f is well below day %.2f" % [e.ambient_light_energy, day_ambient])
	assert_true(e.ambient_light_color.b > e.ambient_light_color.r, "night ambient is cool")
	assert_true(e.sky.sky_material is ShaderMaterial, "night sky shader (stars, glow)")
	assert_true(_close(e.fog_light_color, env.color("sky", "horizon")), "night fog matches the horizon")
	# The shadow caster is the floodlight key (track corridor only), the extra light the moon.
	var sun := _sky.get_node("Sun") as DirectionalLight3D
	assert_true(sun.light_cull_mask & TrackEnvironment.LAYER_FAR == 0, "floodlight key skips the far layer")
	assert_true(sun.light_energy > 1.0, "the road is lit brightly: key energy %.2f" % sun.light_energy)
	var moon := track.get_node_or_null(TrackEnvironment.EXTRA_LIGHT) as DirectionalLight3D
	assert_true(moon != null and not moon.shadow_enabled and moon.light_energy < day_sun * 0.3, "weak moon")
	var terrain := track.get_node("Terrain") as Terrain
	assert_true((terrain.get_child(0) as MeshInstance3D).layers == TrackEnvironment.LAYER_FAR, "terrain is outside the floodlights")
	assert_true((terrain.material.get_shader_parameter("flood") as Vector3).length() > 0.5, "terrain shader adds the floodlight near the track")
	# Lamps and windows glow.
	var scenery := track.scenery
	assert_true(scenery.lamp_count >= 4 and scenery.get_node_or_null("Floodlights") != null, "floodlight masts: %d" % scenery.lamp_count)
	assert_true((scenery.materials["emissive_light"] as StandardMaterial3D).emission_enabled, "lamp heads are emissive")
	assert_true(float((scenery.materials["building_wall"] as ShaderMaterial).get_shader_parameter("night")) > 0.9, "windows are lit")
	_done()

func test_presets_and_defaults() -> void:
	var plain := TrackEnvironment.load_file("")
	assert_true(not plain.active and plain.time == "day" and not plain.floodlit(), "no file: inactive defaults")
	assert_true(plain.palette(0).size() == TrackEnvironment.CLASSES.size(), "a palette colour for every class")
	for preset: String in ["temperate_day", "desert", "floodlit_night"]:
		var path := TrackEnvironment.PRESET_DIR.path_join(preset + ".json")
		assert_true(FileAccess.file_exists(path), "preset %s exists" % preset)
		var env := TrackEnvironment.load_file(path)
		assert_true(env.active, "%s loads" % preset)
		for key: String in TrackEnvironment.DEFAULTS:
			assert_true(env.values.has(key), "%s has a value for %s" % [preset, key])
	var desert := TrackEnvironment.load_file(TrackEnvironment.PRESET_DIR.path_join("desert.json"))
	assert_true(not desert.mowing_stripes() and desert.tree_mix()[2] > 0.0, "desert: no mowing stripes, palms")
	assert_true(desert.color("verge", "grass_color").r > desert.color("verge", "grass_color").g, "desert verges are sand")
	var night := TrackEnvironment.load_file(TrackEnvironment.PRESET_DIR.path_join("floodlit_night.json"))
	assert_true(night.is_night() and night.floodlit() and night.number("ambient", "energy") < 0.5, "floodlit night preset")
	assert_true(_close(TrackEnvironment.to_color("#ff8000"), Color(1.0, 0.5, 0.0)), "colours may be #rrggbb")
	# A day preset on a dusk track: dusk lighting, the preset's ground, the file's own keys.
	var path := "user://test_scenery_environment.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string('{"preset": "desert", "time": "dusk", "ambient": {"energy": 0.5}}')
	f.close()
	var dusk := TrackEnvironment.load_file(path)
	assert_true(dusk.time == "dusk" and dusk.number("sun", "elevation_deg") < 20.0, "dusk sun is low")
	assert_between(dusk.number("ambient", "energy"), 0.49, 0.51, "the file's own value wins")
	assert_true(not dusk.mowing_stripes(), "the preset's ground is kept")
	assert_true(TrackEnvironment.load_file(path, "night").is_night(), "a time override wins over the file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

# ------------------------------------------------------------------ settings
func test_scenery_setting_changes_what_is_drawn() -> void:
	var track := _track(SCENERY_DIR)
	var scenery := track.scenery
	var medium := scenery.tree_instances
	assert_true(scenery.quality == 1 and scenery.hidden_chunks == 0, "medium by default, nothing hidden")
	Settings.set_value("graphics", "scenery", 0)
	assert_true(scenery.quality == 0, "the node follows the setting")
	assert_between(float(scenery.tree_instances), medium * 0.35, medium * 0.65, "low draws about half the trees")
	assert_true(_drawn_trees(scenery) == scenery.tree_instances, "MultiMeshes rebuilt: %d" % _drawn_trees(scenery))
	assert_true(scenery.hidden_chunks > 0, "low hides the far skyline (%d chunks)" % scenery.hidden_chunks)
	assert_true(float((scenery.materials["building_wall"] as ShaderMaterial).get_shader_parameter("detail")) < 0.5, "low: flat facades")
	assert_between(float((scenery.materials["tree"] as ShaderMaterial).get_shader_parameter("fade_end")), 250.0, 350.0, "low: no trees beyond ~300 m")
	Settings.set_value("graphics", "scenery", 2)
	assert_true(scenery.tree_instances == medium and scenery.hidden_chunks == 0, "high shows everything again")
	# Tree shadows only with shadows on high.
	var near_copy: MultiMeshInstance3D = null
	for c in scenery.get_node("Trees").get_children():
		if String(c.name).ends_with("lod0"):
			near_copy = c
			break
	Settings.set_value("graphics", "shadows", 2)
	assert_true(near_copy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no tree shadows on medium")
	Settings.set_value("graphics", "shadows", 3)
	assert_true(near_copy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "tree shadows on high")
	assert_true(SettingsApply.PRESETS["low"]["scenery"] == 0 and SettingsApply.PRESETS["high"]["scenery"] == 2, "presets set it")
	_done()

# ------------------------------------------------------------------ no scenery files
func test_track_without_scenery_files_is_unchanged() -> void:
	var track := _track(PLAIN_DIR)
	var scenery := track.scenery
	assert_true(scenery != null and scenery.is_built and scenery.get_child_count() == 0, "an empty Scenery node")
	assert_true(scenery.building_chunks == 0 and scenery.tree_total == 0 and scenery.water_bodies == 0
			and scenery.landmark_count == 0 and scenery.lamp_count == 0 and scenery.collision_bodies == 0, "nothing built")
	assert_true(not track.environment.active and track.scenery_meta.is_empty(), "no environment, no scenery.json")
	var world_env := _sky.get_node("Environment") as WorldEnvironment
	assert_true(world_env.environment == _original_environment, "the sky scene is not touched")
	assert_true(track.get_node_or_null(TrackEnvironment.EXTRA_LIGHT) == null, "no extra light")
	var terrain := track.get_node("Terrain") as Terrain
	assert_true(not terrain.has_landcover and terrain.sunk_vertices == 0, "plain terrain")
	for param: String in ["has_landcover", "lc_near", "pal_a", "grass_a", "stripe_strength", "flood"]:
		assert_true(terrain.material.get_shader_parameter(param) == null, "terrain shader keeps its default %s" % param)
	for c in terrain.get_children():
		if c is MeshInstance3D:
			assert_true((c as MeshInstance3D).layers == 1, "terrain on the default render layer")
	var ts := await _trackside_built(track)
	var mats: Array = ts.get("_mats")
	assert_true(_close((mats[Trackside.Mat.KERB_RW] as ShaderMaterial).get_shader_parameter("color_a"), Color(0.78, 0.07, 0.06)), "red kerbs")
	assert_true(_close((mats[Trackside.Mat.KERB_RW] as ShaderMaterial).get_shader_parameter("color_b"), Color(0.93, 0.93, 0.91)), "white kerbs")
	assert_true(_close((mats[Trackside.Mat.KERB_YELLOW] as ShaderMaterial).get_shader_parameter("color_a"), Color(0.95, 0.78, 0.05)), "yellow sausage kerbs")
	for mi in Scenery.mesh_instances(track.get_node("Road")):
		for surf in mi.mesh.get_surface_count():
			assert_true(mi.get_surface_override_material(surf) == null, "road materials are not overridden")
	_done()
