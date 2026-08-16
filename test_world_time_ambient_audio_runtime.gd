extends SceneTree

const BIRDS_STREAM := preload("res://sounds/birds.mp3")
const CRICKETS_STREAM := preload("res://sounds/night cricket ambience.mp3")

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var world_time := root.get_node_or_null("WorldTime")
	if world_time == null:
		push_error("World-time ambient audio test requires WorldTime.")
		quit(1)
		return

	var original_total_hours := float(world_time.call("get_total_hours"))
	world_time.call("set_total_hours", 5.0)
	var birds := WorldTimeAmbientAudio.new()
	birds.name = "TestMorningBirds"
	birds.stream = BIRDS_STREAM
	birds.fade_seconds = 0.1
	birds.allowed_scene_paths = PackedStringArray([
		"res://scenes/testscenes/realhometest.tscn",
		"res://scenes/testscenes/realtest1.tscn",
	])
	root.add_child(birds)
	birds.call("_apply_scene_path", "res://scenes/testscenes/realhometest.tscn")
	await process_frame

	_expect(not birds.playing, "morning birds stay silent before 06:00")
	_expect(is_equal_approx(birds.volume_ratio, 0.5), "morning birds target 50 percent linear volume")

	world_time.call("set_total_hours", 6.0)
	await process_frame
	_expect(birds.playing, "morning birds start at 06:00")
	_expect(birds.volume_linear < 0.5, "morning birds fade in instead of cutting to full volume")
	await create_timer(0.15).timeout
	_expect(is_equal_approx(birds.volume_linear, 0.5), "morning birds reach 50 percent after fading in")
	_expect(birds.stream == load("res://sounds/birds.mp3"), "morning ambience uses the existing birds recording")
	var fade_before_transition: Tween = birds.get("_fade_tween")
	birds.call("_apply_scene_path", "res://scenes/testscenes/realtest1.tscn")
	await process_frame
	_expect(birds.playing and is_equal_approx(birds.volume_linear, 0.5), "home-to-yard transition keeps morning birds playing")
	_expect(birds.get("_fade_tween") == fade_before_transition, "home-to-yard transition starts no new fade")

	world_time.call("set_total_hours", 12.99)
	await process_frame
	_expect(birds.playing, "morning birds continue until 13:00")
	birds.stop()
	birds.call("_on_finished")
	_expect(birds.playing, "morning birds restart when the recording finishes inside the window")

	world_time.call("set_total_hours", 13.0)
	await process_frame
	_expect(birds.playing and birds.volume_linear > 0.0, "morning birds fade out instead of cutting off at 13:00")
	await create_timer(0.15).timeout
	_expect(not birds.playing and is_zero_approx(birds.volume_linear), "morning birds stop after fading out at 13:00")

	await _validate_night_crickets(world_time)
	_validate_persistent_wiring()
	birds.free()
	world_time.call("set_total_hours", original_total_hours)
	await process_frame
	_finish()


func _validate_night_crickets(world_time: Node) -> void:
	world_time.call("set_total_hours", 18.0)
	var crickets := WorldTimeAmbientAudio.new()
	crickets.name = "TestNightCrickets"
	crickets.stream = CRICKETS_STREAM
	crickets.start_hour = 19.0
	crickets.end_hour = 5.0
	crickets.volume_ratio = 0.5
	crickets.fade_seconds = 0.1
	crickets.allowed_scene_paths = PackedStringArray([
		"res://scenes/testscenes/realhometest.tscn",
		"res://scenes/testscenes/realtest1.tscn",
	])
	root.add_child(crickets)
	crickets.call("_apply_scene_path", "res://scenes/testscenes/realhometest.tscn")
	await process_frame
	_expect(not crickets.playing, "night crickets stay silent before 19:00")

	world_time.call("set_total_hours", 19.0)
	await process_frame
	_expect(crickets.playing and crickets.volume_linear < 0.5, "night crickets fade in at 19:00")
	await create_timer(0.15).timeout
	_expect(is_equal_approx(crickets.volume_linear, 0.5), "night crickets reach 50 percent after fading in")

	world_time.call("set_total_hours", 28.99)
	await process_frame
	_expect(crickets.playing, "night crickets remain active through 04:59")

	world_time.call("set_total_hours", 29.0)
	await process_frame
	_expect(crickets.playing and crickets.volume_linear > 0.0, "night crickets fade out at 05:00")
	await create_timer(0.15).timeout
	_expect(not crickets.playing and is_zero_approx(crickets.volume_linear), "night crickets stop after the 05:00 fade")
	crickets.free()


func _validate_persistent_wiring() -> void:
	var persistent_birds := root.get_node_or_null("MorningBirds") as WorldTimeAmbientAudio
	_expect(persistent_birds != null, "morning birds run from one persistent autoload")
	if persistent_birds != null:
		_expect(
			is_equal_approx(persistent_birds.start_hour, 6.0)
			and is_equal_approx(persistent_birds.end_hour, 13.0)
			and is_equal_approx(persistent_birds.volume_ratio, 0.5)
			and is_equal_approx(persistent_birds.fade_seconds, 12.0),
			"persistent morning birds inherit the authored time, volume, and fade"
		)
		_expect(
			persistent_birds.allowed_scene_paths.has("res://scenes/testscenes/realhometest.tscn")
			and persistent_birds.allowed_scene_paths.has("res://scenes/testscenes/realtest1.tscn"),
			"persistent morning birds cover realhometest and realtest1"
		)

	var persistent_crickets := root.get_node_or_null("NightCrickets") as WorldTimeAmbientAudio
	_expect(persistent_crickets != null, "night crickets run from one persistent autoload")
	if persistent_crickets != null:
		_expect(
			is_equal_approx(persistent_crickets.start_hour, 19.0)
			and is_equal_approx(persistent_crickets.end_hour, 5.0)
			and is_equal_approx(persistent_crickets.volume_ratio, 0.5)
			and is_equal_approx(persistent_crickets.fade_seconds, 12.0),
			"persistent night crickets inherit the authored overnight window, volume, and fade"
		)
		_expect(persistent_crickets.stream == CRICKETS_STREAM, "night ambience uses the authored cricket recording")
		_expect(
			persistent_crickets.allowed_scene_paths.has("res://scenes/testscenes/realhometest.tscn")
			and persistent_crickets.allowed_scene_paths.has("res://scenes/testscenes/realtest1.tscn"),
			"persistent night crickets cover realhometest and realtest1"
		)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _finish() -> void:
	if failures.is_empty():
		print("WORLD_TIME_AMBIENT_AUDIO_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
