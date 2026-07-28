extends SceneTree

const ORB_SCENE := preload("res://scenes/activities/shared/controlled_orb.tscn")

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var world := Node2D.new()
	root.add_child(world)
	var source := InteractiveActivityInputSource.new()
	world.add_child(source)
	_expect(
		source.configure(InteractiveActivityInputProfile.new()),
		"default activity input profile configures"
	)
	source.set_activity_input_enabled(true)

	var orb := ORB_SCENE.instantiate() as ControlledActivityOrb
	world.add_child(orb)
	orb.set_input_source(source)
	_expect(
		orb.configure({
			"acceleration": 100.0,
			"drag": 0.0,
			"maximum_speed": 1000.0,
		}),
		"orb accepts valid movement configuration"
	)
	orb.set_movement_enabled(true)

	source._input(_action_event(&"right", true))
	orb._physics_process(0.5)
	_expect(
		orb.get_orb_velocity().is_equal_approx(Vector2(50.0, 0.0)),
		"supplied input changes velocity"
	)

	source._input(_action_event(&"right", false))
	orb.configure({
		"acceleration": 100.0,
		"drag": 10.0,
		"maximum_speed": 1000.0,
	})
	orb._physics_process(1.0)
	_expect(
		is_equal_approx(orb.get_orb_speed(), 40.0),
		"no input applies deterministic drag"
	)

	orb.reset_orb(Vector2.ZERO)
	orb.configure({
		"acceleration": 1000.0,
		"drag": 0.0,
		"maximum_speed": 100.0,
	})
	source._input(_action_event(&"right", true))
	orb._physics_process(1.0)
	_expect(
		orb.get_orb_speed() <= 100.001,
		"maximum speed is respected"
	)

	source._input(_action_event(&"right", false))
	orb.reset_orb(Vector2.ZERO)
	orb.set_external_force(Vector2(20.0, 0.0))
	orb._physics_process(0.5)
	_expect(
		orb.get_orb_position().x > 0.0 and orb.get_orb_velocity().x > 0.0,
		"external force moves the orb"
	)
	orb.reset_orb(Vector2(2.0, 3.0))
	_expect(
		orb.get_orb_position() == Vector2(2.0, 3.0)
		and orb.get_orb_velocity() == Vector2.ZERO,
		"reset changes position and clears velocity"
	)

	orb.set_movement_bounds(Rect2(-5.0, -5.0, 10.0, 10.0))
	orb.set_external_force(Vector2(1000.0, 1000.0))
	orb._physics_process(1.0)
	_expect(
		orb.get_orb_position().x <= 5.0
		and orb.get_orb_position().y <= 5.0,
		"configured movement bounds are respected"
	)

	var orb_source_text := FileAccess.get_file_as_string(
		"res://scripts/activities/shared/controlled_orb.gd"
	)
	_expect(
		orb_source_text.find("Input.") == -1
		and orb_source_text.find("Input.get_vector") == -1,
		"orb does not read global Input"
	)

	source.force_neutral()
	var other_orb := ORB_SCENE.instantiate() as ControlledActivityOrb
	world.add_child(other_orb)
	other_orb.configure({
		"acceleration": 0.0,
		"drag": 0.0,
		"maximum_speed": 1000.0,
	})
	other_orb.set_input_source(source)
	other_orb.set_movement_enabled(true)
	orb.clear_movement_bounds()
	orb.reset_orb(Vector2.ZERO)
	other_orb.reset_orb(Vector2.ZERO)
	orb.set_external_force(Vector2.RIGHT * 20.0)
	other_orb.set_external_force(Vector2.LEFT * 30.0)
	orb._physics_process(0.5)
	other_orb._physics_process(0.5)
	_expect(
		orb.get_orb_position().x > 0.0
		and other_orb.get_orb_position().x < 0.0
		and not orb.get_orb_velocity().is_equal_approx(other_orb.get_orb_velocity()),
		"multiple orb instances remain independent"
	)

	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("CONTROLLED_ACTIVITY_ORB_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _action_event(action: StringName, pressed: bool) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	return event


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
