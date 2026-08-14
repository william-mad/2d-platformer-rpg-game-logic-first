extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var player_scene := load("res://player/player.tscn") as PackedScene
	var player := player_scene.instantiate() as Player
	root.add_child(player)
	player.set_process(false)
	player.set_physics_process(false)

	var animation_player := player.animation_player
	animation_player.play(&"run")
	_expect(
		is_equal_approx(animation_player.speed_scale, 0.65),
		"Run begins below its old 1.0 playback speed"
	)
	_expect(
		is_equal_approx(player._get_run_animation_target_scale(260.0), 1.0),
		"level-one run speed targets normal playback"
	)
	_expect(
		is_equal_approx(player._get_run_animation_target_scale(520.0), 1.65),
		"faster actual movement remains capped at 1.65 playback"
	)

	player.velocity = Vector2(260.0, 0.0)
	player.move_and_slide()
	player._update_run_animation_playback(0.1)
	_expect(
		animation_player.speed_scale > 0.65
		and animation_player.speed_scale < 1.0,
		"Run playback accelerates smoothly toward the actual-speed target"
	)
	animation_player.play(&"idle")
	_expect(
		is_equal_approx(animation_player.speed_scale, 1.0),
		"leaving Run resets shared AnimationPlayer speed"
	)

	player.queue_free()
	await process_frame
	if _failures.is_empty():
		print("PLAYER_RUN_ANIMATION_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
