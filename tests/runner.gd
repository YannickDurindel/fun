extends SceneTree
## Headless test runner: runs every res://tests/test_*.gd (a TestCase subclass).
## Usage: godot --headless -s res://tests/runner.gd [-- --filter=substring]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var filter := ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--filter="):
			filter = a.get_slice("=", 1)
	var files: Array[String] = []
	for f: String in DirAccess.get_files_at("res://tests"):
		if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd" and (filter.is_empty() or f.contains(filter)):
			files.append(f)
	files.sort()
	var passed := 0
	var failed := 0
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		var methods: Array[String] = []
		for m in script.get_script_method_list():
			var mname: String = m["name"]
			if mname.begins_with("test_") and not mname in methods:
				methods.append(mname)
		for mname in methods:
			# Race-scene tests drive immediately; test_race.gd re-enables the countdown itself.
			root.get_node("/root/Bootstrap").set(&"skip_countdown", true)
			var t: TestCase = script.new()
			root.add_child(t)
			await process_frame
			await t.call(mname)
			if t.failures.is_empty():
				passed += 1
				print("  PASS %s::%s" % [f, mname])
			else:
				failed += 1
				print("  FAIL %s::%s" % [f, mname])
				for msg in t.failures:
					print("       - " + msg)
			t.queue_free()
			await process_frame
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
