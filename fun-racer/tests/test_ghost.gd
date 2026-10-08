extends TestCase
## Ghost car: recording, the .ghost file format, playback, and the records screen.
## Everything is written to a temporary folder (never user://) that each test removes.

const SCENE := "res://scenes/race_red_bull_ring.tscn"
const RECORDS := "res://scenes/menu/records.tscn"
const TRACK := "red_bull_ring"

var _tmp: String = ""
var _scene: Node
var race: RaceManager
var car: Car
var player: GhostPlayer
var recorder: GhostRecorder
var _old_ghost: bool = true
var _old_autodrive: bool = false

func _begin() -> void:
	_tmp = OS.get_temp_dir().path_join("fun_racer_ghost_test_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(_tmp)
	GhostData.dir_override = _tmp.path_join("ghosts")
	_old_ghost = Game.config.ghost
	_old_autodrive = Bootstrap.autodrive
	Bootstrap.autodrive = false

func _end() -> void:
	GhostData.dir_override = ""
	Game.config.ghost = _old_ghost
	Bootstrap.autodrive = _old_autodrive
	_remove_dir(_tmp)
	assert_true(not DirAccess.dir_exists_absolute(_tmp), "temporary folder removed")

func _remove_dir(path: String) -> void:
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_remove_dir(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)

func _spawn_race(ghost_on: bool = true) -> void:
	Game.config.ghost = ghost_on
	_scene = spawn(SCENE)
	race = _scene.get_node("Track/Race") as RaceManager
	car = _scene.get_node("Car") as Car
	player = _scene.get_node("Ghost") as GhostPlayer
	recorder = player.recorder
	race.persist_best = false   # no best_<id>.json in user://
	race.clear_best()

## Teleports the frozen car along the centreline (see test_race.gd).
func _drive(s_from: float, s_to: float, step: float) -> void:
	car.simulate = false
	car.linear_velocity = Vector3.ZERO
	var x := s_from
	while x < s_to:
		x = minf(x + step, s_to)
		car.global_transform = race.track.spawn_transform(x)
		await get_tree().physics_frame

## A ghost along the first metres of the track: one sample every 0.1 s, 5 m apart.
func _line_ghost(count: int = 40) -> GhostData:
	var data := TrackData.load_track(TrackCatalog.find(TRACK).track_json)
	var g := GhostData.new()
	g.track_id = TRACK
	g.sample_interval = 0.1
	for i in count:
		var xf := data.sample(120.0 + i * 5.0)
		xf.origin += Vector3.UP * 0.4
		g.add_sample(i * 0.1, xf, 50.0, 0.05)
	g.lap_time = g.duration()
	g.date = 1700000000
	return g

func test_recorder_captures_samples() -> void:
	_begin()
	_spawn_race()
	assert_true(race.state == RaceManager.State.RACING, "racing (countdown skipped)")
	car.set_input_override(1.0, 0.0, 0.0)
	await physics_frames(240)
	car.clear_input_override()
	var buf := recorder.buffer
	assert_true(buf != null, "recording while racing")
	if buf != null:
		assert_between(buf.size(), 28.0, 32.0, "samples after 1 s at 30 Hz")
		assert_true(buf.track_id == TRACK, "buffer knows its track")
		for i in range(1, buf.size()):
			assert_true(buf.times[i] > buf.times[i - 1], "sample times ascend")
		assert_between(buf.times[1] - buf.times[0], 0.033, 0.034, "sample spacing")
		assert_true(buf.position(buf.size() - 1).distance_to(buf.position(0)) > 5.0, "the drive was captured")
		assert_true(buf.position(buf.size() - 1).distance_to(car.global_position) < 3.0, "last sample is near the car")
		assert_true(buf.speeds[buf.size() - 1] > 10.0, "forward speed recorded")
	assert_true(not GhostData.exists(TRACK), "nothing saved without a completed lap")
	_end()

func test_save_load_round_trip() -> void:
	_begin()
	var g := GhostData.new()
	g.track_id = TRACK
	g.lap_time = 67.4821
	g.date = 1791000000
	for i in 2000:
		var a := i * 0.013
		var xf := Transform3D(Basis.from_euler(Vector3(sin(a) * 0.2, a, cos(a) * 0.1)),
				Vector3(1800.0 * sin(a), 40.0 * cos(a * 3.0), -1500.0 * cos(a)))
		g.add_sample(i / 30.0, xf, 80.0 * sin(a), 0.3 * cos(a))
	assert_true(g.save(), "saved")
	assert_true(GhostData.exists(TRACK), "file exists")
	var bytes := FileAccess.get_file_as_bytes(GhostData.path_for(TRACK)).size()
	assert_between(bytes, 1000.0, 200.0 * 1024.0, "file size in bytes")
	var r := GhostData.load_for(TRACK)
	assert_true(r != null, "loaded")
	if r != null:
		assert_between(r.lap_time, 67.482, 67.4822, "lap time kept")
		assert_true(r.size() == g.size(), "sample count kept (%d)" % r.size())
		assert_true(r.date == g.date and r.track_id == TRACK, "header kept")
		var worst := 0.0
		var worst_angle := 0.0
		for i in r.size():
			worst = maxf(worst, r.position(i).distance_to(g.position(i)))
			worst_angle = maxf(worst_angle, r.rotation(i).angle_to(g.rotation(i)))
		assert_between(worst, 0.0, 0.02, "position error (m)")
		assert_between(worst_angle, 0.0, 0.002, "rotation error (rad)")
		assert_between(absf(r.speeds[100] - g.speeds[100]), 0.0, 0.01, "speed error")
		assert_between(absf(r.steers[100] - g.steers[100]), 0.0, 0.001, "steer error")
	# The header alone (records screen) carries the lap time and date, no samples.
	var head := GhostData.load_header(TRACK)
	assert_true(head != null and head.size() == 0, "header loads without samples")
	if head != null:
		assert_between(head.lap_time, 67.482, 67.4822, "header lap time")
		assert_true(head.date == g.date, "header date")
	# The longest lap the recorder keeps still fits the size budget.
	var big := _line_ghost(2)
	while big.size() < GhostData.MAX_SAMPLES:
		big.add_sample(big.size() * 0.1, Transform3D.IDENTITY, 0.0, 0.0)
	assert_between(big.to_bytes().size(), 0.0, 200.0 * 1024.0, "largest file (bytes)")
	big.decimate()
	assert_true(big.size() == GhostData.MAX_SAMPLES / 2, "decimate halves the samples")
	assert_true(GhostData.delete(TRACK) and not GhostData.exists(TRACK), "deleted")
	_end()

func test_corrupt_file_is_ignored() -> void:
	_begin()
	var good := _line_ghost()
	assert_true(good.save(), "saved")
	var path := GhostData.path_for(TRACK)
	var bytes := FileAccess.get_file_as_bytes(path)
	assert_true(GhostData.from_bytes(bytes) != null, "the intact file loads")
	var cases := {}
	cases["empty"] = PackedByteArray()
	cases["garbage"] = "this is not a ghost file at all, just some text".to_utf8_buffer()
	cases["truncated"] = bytes.slice(0, bytes.size() - 37)
	cases["extra bytes"] = bytes + PackedByteArray([1, 2, 3])
	var version := bytes.duplicate()
	version.encode_u16(4, GhostData.VERSION + 1)
	cases["other version"] = version
	var header := GhostData.HEADER_BYTES + TRACK.length()
	var nan := bytes.duplicate()
	nan.encode_float(header + good.size() * 4 + 8, NAN)
	cases["NaN position"] = nan
	var back := bytes.duplicate()
	back.encode_float(header + 4 * 5, 0.0)
	cases["time going backwards"] = back
	var count := bytes.duplicate()
	count.encode_u32(header - 4, 0x7fffffff)
	cases["absurd sample count"] = count
	for label: String in cases:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(cases[label])
		f.close()
		assert_true(GhostData.load_for(TRACK) == null, "%s file is ignored" % label)
	# A valid ghost of another track under this track's name is not used either.
	var other := _line_ghost()
	other.track_id = "monza"
	var f2 := FileAccess.open(path, FileAccess.WRITE)
	f2.store_buffer(other.to_bytes())
	f2.close()
	assert_true(GhostData.load_for(TRACK) == null, "another track's ghost is ignored")
	# A corrupt file never breaks the race: the ghost just stays hidden.
	_spawn_race()
	await physics_frames(20)
	await get_tree().process_frame
	assert_true(player.data == null and not player.is_ghost_visible(), "race runs without a ghost")
	_end()

func test_player_interpolates() -> void:
	_begin()
	var g := _line_ghost()
	assert_true(g.save(), "saved")
	_spawn_race()
	await physics_frames(24)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(player.data != null and player.data.size() == g.size(), "the track's ghost was loaded")
	assert_true(player.is_ghost_visible(), "ghost shown while racing")
	if player.data == null:
		_end()
		return
	# In step with the lap clock.
	assert_true(race.lap_time() > 0.05, "lap clock running")
	player._process(0.0)
	var expected := player.data.pose_at(player.render_lap_time()).origin
	assert_between(player.ghost_car.global_position.distance_to(expected), 0.0, 0.01, "ghost follows the lap clock (m)")
	assert_between(player.render_lap_time() - race.lap_time(), 0.0, 1.0 / 240.0 + 1e-6, "render time is within a tick of the lap clock")
	for i: int in [0, 7, 21, 38]:
		var t := (g.times[i] + g.times[i + 1]) * 0.5
		player.show_at(t)
		var mid := g.position(i).lerp(g.position(i + 1), 0.5)
		assert_between(player.ghost_car.global_position.distance_to(mid), 0.0, 0.01, "midpoint %d position error" % i)
		var q := g.rotation(i).slerp(g.rotation(i + 1), 0.5)
		var got := player.ghost_car.global_transform.basis.get_rotation_quaternion()
		assert_between(got.angle_to(q), 0.0, 0.002, "midpoint %d rotation error" % i)
	player.show_at(g.times[10] * 0.75 + g.times[11] * 0.25)
	assert_between(player.ghost_car.global_position.distance_to(g.position(10).lerp(g.position(11), 0.25)), 0.0, 0.01, "quarter point")
	# Front wheels steer, wheels spin with the recorded speed.
	var steer := player.ghost_car.get_node("WheelFL/Steer") as Node3D
	assert_between(steer.rotation.y, 0.049, 0.051, "front steer angle")
	var spin := player.ghost_car.get_node("WheelRL/Steer/Spin") as Node3D
	var before := spin.rotation.x
	player.show_at(1.0, 0.01)
	assert_true(absf(spin.rotation.x - before) > 0.5, "wheels spin")
	# After its lap the ghost fades and hides.
	player.show_at(g.duration() + 0.1)
	assert_true(player.is_ghost_visible(), "still fading just after the line")
	player.show_at(g.duration() + 2.0)
	assert_true(not player.is_ghost_visible(), "hidden once its lap is over")
	# Hidden during the countdown.
	Bootstrap.skip_countdown = false
	race.restart()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(race.state == RaceManager.State.COUNTDOWN and not player.is_ghost_visible(), "hidden in the countdown")
	Bootstrap.skip_countdown = true
	_end()

func test_respawn_does_not_slide() -> void:
	# A lap with a respawn in it: the ghost jumps like the car did instead of sliding there.
	var g := GhostData.new()
	g.track_id = TRACK
	g.add_sample(0.0, Transform3D(Basis.IDENTITY, Vector3(0, 0, 0)), 50.0, 0.0)
	g.add_sample(0.1, Transform3D(Basis.IDENTITY, Vector3(0, 0, -5)), 50.0, 0.0)
	g.add_sample(0.2, Transform3D(Basis.IDENTITY, Vector3(300, 0, 200)), 0.0, 0.0)
	g.add_sample(0.3, Transform3D(Basis.IDENTITY, Vector3(300, 0, 195)), 20.0, 0.0)
	assert_between(g.pose_at(0.05).origin.z, -2.51, -2.49, "normal driving is interpolated")
	assert_true(g.pose_at(0.15).origin.is_equal_approx(Vector3(0, 0, -5)), "holds before the respawn")
	assert_true(g.pose_at(0.199).origin.is_equal_approx(Vector3(0, 0, -5)), "no sliding across the map")
	assert_true(g.pose_at(0.2).origin.is_equal_approx(Vector3(300, 0, 200)), "then appears at the respawn point")
	assert_between(g.pose_at(0.25).origin.z, 197.49, 197.51, "and drives on")
	assert_true(g.pose_at(9.0).origin.is_equal_approx(Vector3(300, 0, 195)), "clamped past the end")

func test_ghost_has_no_collision() -> void:
	_begin()
	_spawn_race()
	await physics_frames(2)
	assert_true(player.find_children("*", "CollisionObject3D", true, false).is_empty(), "no collision objects")
	assert_true(player.find_children("*", "CollisionShape3D", true, false).is_empty(), "no collision shapes")
	var meshes := player.ghost_car.find_children("*", "MeshInstance3D", true, false)
	assert_true(meshes.size() >= 8, "body and wheel meshes present (%d)" % meshes.size())
	for m: MeshInstance3D in meshes:
		if m.name == &"BlurDisc":
			assert_true(not m.visible, "speed blur disc hidden")
			continue
		var mat := m.material_override as ShaderMaterial
		assert_true(mat != null and mat.shader == GhostPlayer.SHADER, "%s uses the ghost shader" % m.name)
		assert_true(m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s casts no shadow" % m.name)
	# Driving straight through the ghost does not disturb the car.
	var g := GhostData.new()
	g.track_id = TRACK
	var ahead := car.global_transform.translated_local(Vector3(0, 0, -6.0))
	g.add_sample(0.0, ahead, 0.0, 0.0)
	g.add_sample(100.0, ahead, 0.0, 0.0)
	player.data = g
	player._loaded_track = TRACK
	car.set_input_override(1.0, 0.0, 0.0)
	await physics_frames(600)
	car.clear_input_override()
	assert_true(car.global_position.distance_to(ahead.origin) > 15.0, "car drove through the ghost")
	assert_true(car.speed_kmh > 60.0, "no speed lost on the ghost (%.0f km/h)" % car.speed_kmh)
	_end()

func test_hidden_when_disabled_or_missing() -> void:
	_begin()
	# No file for the track.
	_spawn_race(true)
	await physics_frames(20)
	await get_tree().process_frame
	assert_true(player.data == null, "no ghost data without a file")
	assert_true(not player.is_ghost_visible(), "hidden without a file")
	_scene.queue_free()
	await get_tree().process_frame
	# A file, but the option is off.
	assert_true(_line_ghost().save(), "saved")
	_spawn_race(false)
	await physics_frames(20)
	await get_tree().process_frame
	assert_true(not player.is_ghost_visible(), "hidden when config.ghost is false")
	# Turning the option on shows it.
	Game.config.ghost = true
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(player.is_ghost_visible(), "shown when config.ghost is true")
	_end()

func test_best_lap_is_saved_but_not_the_autopilots() -> void:
	_begin()
	_spawn_race()
	recorder.force_save = true
	var bests: Array[GhostData] = []
	recorder.best_recorded.connect(func(g: GhostData) -> void: bests.append(g))
	# The autopilot's lap: a best for the RaceManager, never a ghost.
	Bootstrap.autodrive = true
	await _drive(race.s, race.data.length + 20.0, 25.0)
	assert_true(race.laps_completed == 1, "autopilot lap completed")
	assert_true(bests.is_empty() and not GhostData.exists(TRACK), "autopilot lap is not saved")
	assert_true(player.data == null, "autopilot lap is not replayed")
	# The player's lap.
	Bootstrap.autodrive = false
	race.clear_best()
	race.restart()
	await physics_frames(2)
	await _drive(race.s, race.data.length + 20.0, 25.0)
	assert_true(race.laps_completed == 1 and race.best_lap > 0.0, "player lap completed")
	assert_true(bests.size() == 1, "best lap recorded (%d)" % bests.size())
	assert_true(GhostData.exists(TRACK), "ghost file written")
	var saved := GhostData.load_for(TRACK)
	assert_true(saved != null, "ghost file loads")
	if saved != null:
		assert_between(saved.lap_time, race.best_lap - 0.0005, race.best_lap + 0.0005, "ghost lap time")
		assert_true(saved.size() >= 15, "samples saved (%d)" % saved.size())
		assert_true(saved.duration() >= saved.lap_time - 0.001, "the ghost covers the whole lap")
		var grid := race.track.spawn_transform(race.data.start_s - 8.0, -2.5).origin
		assert_between(saved.position(0).distance_to(grid), 0.0, 30.0, "lap 1 ghost starts on the grid (m)")
		assert_between(race.data.closest_s(saved.position(saved.size() - 1)), 0.0, 60.0, "ghost ends just past the line (s)")
	assert_true(player.data != null and player.data == bests[0], "the new best is the ghost from the next lap on")
	# A slower lap changes nothing.
	var first_time := saved.lap_time if saved != null else 0.0
	await _drive(20.0, race.data.length + 20.0, 12.0)
	assert_true(race.laps_completed == 2, "second lap completed")
	assert_true(bests.size() == 1, "a slower lap is not a new ghost")
	var kept := GhostData.load_for(TRACK)
	assert_true(kept != null and absf(kept.lap_time - first_time) < 1e-5, "file unchanged by the slower lap")
	# A faster one replaces it.
	await _drive(20.0, race.data.length + 20.0, 40.0)
	assert_true(bests.size() == 2, "a faster lap is the new ghost")
	var faster := GhostData.load_for(TRACK)
	assert_true(faster != null and faster.lap_time < first_time, "file replaced by the faster lap")
	if faster != null:
		assert_between(race.data.closest_s(faster.position(0)), 0.0, 80.0, "flying lap ghost starts at the line (s)")
	_end()

func test_records_screen() -> void:
	_begin()
	var info := TrackCatalog.find(TRACK)
	var best_file := _tmp.path_join("best_%s.json" % TRACK)
	var f := FileAccess.open(best_file, FileAccess.WRITE)
	f.store_string(JSON.stringify({"track": info.name, "length": info.length_m, "checkpoints": [],
			"best_lap": 67.482, "best_splits": [], "best_sectors": [17.204, 30.611, 19.5]}))
	f.close()
	var g := _line_ghost()
	g.lap_time = 67.482
	assert_true(g.save(), "ghost saved")
	var old_pending := Game.pending.track_id
	Game.pending.track_id = "somewhere_else"
	var screen := (load(RECORDS) as PackedScene).instantiate() as UIScreen
	screen.set(&"best_dir", _tmp)
	add_child(screen)
	await get_tree().process_frame
	await get_tree().process_frame
	var ids: Array[String] = screen.call(&"get_track_ids")
	assert_true(ids.has(TRACK), "Red Bull Ring listed")
	assert_true(not ids.has("monza"), "coming-soon tracks are not listed")
	var row: String = screen.call(&"get_row_text", TRACK)
	assert_true(row.contains("RED BULL RING") and row.contains("1:07.482"), "row shows the best lap: " + row)
	assert_true(screen.call(&"get_selected") == TRACK, "first track selected")
	assert_true(screen.call(&"get_best_text") == "1:07.482", "details show the best lap")
	assert_true(not screen.call(&"is_empty_state_shown"), "no empty state with a record")
	var rec: Dictionary = screen.call(&"read_record", info)
	assert_between(rec["theoretical"], 67.314, 67.316, "theoretical best = sum of the sector bests")
	assert_true(rec["has_ghost"] and rec["date"] == 1700000000, "ghost and its date found")
	# A ghost file that cannot be loaded is not reported as a ghost (but can still be deleted).
	var raw := FileAccess.get_file_as_bytes(GhostData.path_for(TRACK))
	var broken := FileAccess.open(GhostData.path_for(TRACK), FileAccess.WRITE)
	broken.store_buffer(raw.slice(0, raw.size() - 11))
	broken.close()
	var rec2: Dictionary = screen.call(&"read_record", info)
	assert_true(not rec2["has_ghost"] and rec2["has_file"], "a corrupt ghost is not shown as saved")
	assert_true(g.save(), "ghost saved again")
	var focus := get_viewport().gui_get_focus_owner()
	assert_true(focus != null and screen.is_ancestor_of(focus), "a control has focus (keyboard / gamepad)")
	# DELETE asks first.
	screen.call(&"request_delete")
	assert_true(screen.call(&"is_confirming"), "confirmation shown")
	assert_true(FileAccess.file_exists(best_file) and GhostData.exists(TRACK), "nothing deleted before confirming")
	screen.call(&"on_back")
	assert_true(not screen.call(&"is_confirming"), "back cancels the confirmation")
	assert_true(FileAccess.file_exists(best_file) and GhostData.exists(TRACK), "nothing deleted on cancel")
	screen.call(&"request_delete")
	screen.call(&"confirm_delete")
	assert_true(not FileAccess.file_exists(best_file), "best file deleted")
	assert_true(not GhostData.exists(TRACK), "ghost deleted")
	assert_true(screen.call(&"is_empty_state_shown"), "NO TIMES SET YET shown")
	row = screen.call(&"get_row_text", TRACK)
	assert_true(not row.contains("1:07.482"), "row cleared: " + row)
	screen.call(&"request_delete")
	assert_true(not screen.call(&"is_confirming"), "nothing to delete any more")
	# RACE THIS TRACK hands the track to the race options.
	screen.call(&"race_selected")
	assert_true(Game.pending.track_id == TRACK, "RACE THIS TRACK sets the pending track")
	Game.pending.track_id = old_pending
	_end()
