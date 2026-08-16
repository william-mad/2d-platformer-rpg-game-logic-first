extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame

	var box_scene := load("res://scenes/things/movable_big_box_hidden_spot.tscn") as PackedScene
	var box := box_scene.instantiate() as MovableHiddenObject
	root.add_child(box)
	await process_frame
	box.set_physics_process(false)

	var animation_player := box.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var sprite := box.get_node_or_null("BoxBig/Sprite2D") as Sprite2D
	_expect(animation_player != null, "movable box has an AnimationPlayer")
	_expect(sprite != null, "movable box exposes its animated sprite")
	if animation_player != null:
		_expect(animation_player.has_animation(&"idle"), "movable box has an idle clip")
		_expect(animation_player.has_animation(&"move"), "movable box has a move clip")

	box.set_hidden_move_velocity_x(90.0)
	box._physics_process(1.0 / 60.0)
	_expect(
		animation_player != null and animation_player.current_animation == &"move",
		"hidden rightward movement plays the moving-box animation"
	)
	_expect(sprite != null and not sprite.flip_h, "rightward hidden movement uses the source facing")

	for _step in 3:
		box.set_hidden_move_velocity_x(-90.0)
		box._physics_process(1.0 / 60.0)
	_expect(
		animation_player != null and animation_player.current_animation == &"move",
		"hidden leftward movement keeps the moving-box animation active"
	)
	_expect(sprite != null and sprite.flip_h, "leftward hidden movement flips the moving-box animation")

	box.stop_hidden_control()
	_expect(
		animation_player != null and animation_player.current_animation == &"idle",
		"leaving hidden movement restores the idle box"
	)

	box.queue_free()
	await process_frame
	if _failures.is_empty():
		print("Movable hidden object animation runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
