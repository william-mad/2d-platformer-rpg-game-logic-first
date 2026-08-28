extends SceneTree

const RUNE_WEAVING_SCENE := preload(
	"res://scenes/activities/rune_weaving/rune_weaving_module.tscn"
)

var failures: Array[String] = []
var result_change_count: int = 0
var controller_correct_count: int = 0
var controller_incorrect_count: int = 0
var controller_completion_count: int = 0


func _initialize() -> void:
	await process_frame
	var world := Node.new()
	root.add_child(world)
	var source := InteractiveActivityInputSource.new()
	world.add_child(source)
	_expect(
		source.configure(InteractiveActivityInputProfile.new()),
		"default reusable activity input profile configures"
	)
	source.set_activity_input_enabled(true)

	_test_reusable_cursor(world, source)
	_test_reusable_sequence_controller(world)

	var invalid_module := RUNE_WEAVING_SCENE.instantiate() as RuneWeavingModule
	world.add_child(invalid_module)
	var invalid_config := _make_config()
	invalid_config.minimum_target_spacing = invalid_config.activation_radius * 2.0
	_expect(
		not invalid_module.configure(
			_make_context("invalid-rune-config", invalid_config),
			source
		),
		"overlapping target activation areas are rejected"
	)
	invalid_module.queue_free()
	await process_frame

	var config := _make_config()
	var module := RUNE_WEAVING_SCENE.instantiate() as RuneWeavingModule
	world.add_child(module)
	_expect(
		module.configure(_make_context("rune-rules-session", config), source),
		"valid Rune Weaving configuration is accepted"
	)
	module.result_changed.connect(_on_result_changed)
	module.start_activity()
	var first_targets := module.get_current_targets()
	_expect(
		module.is_running()
		and first_targets.size() == config.starting_node_count
		and module.preview_line.visible
		and not module.is_sequence_hidden(),
		"first round starts with its complete order visible"
	)
	_expect(
		_pattern_is_possible(first_targets, config),
		"generated targets stay in bounds with non-overlapping spacing"
	)

	var deterministic_module := RUNE_WEAVING_SCENE.instantiate() as RuneWeavingModule
	world.add_child(deterministic_module)
	_expect(
		deterministic_module.configure(
			_make_context("rune-rules-session", config),
			source
		),
		"deterministic comparison module configures"
	)
	deterministic_module.start_activity()
	_expect(
		deterministic_module.get_current_targets() == first_targets,
		"session seed produces a deterministic first rune"
	)
	deterministic_module.stop_activity(&"determinism_checked")
	deterministic_module.queue_free()

	for target_index in first_targets.size():
		var target := first_targets[target_index]
		module.get_activity_cursor().reset_cursor(
			target + Vector2(config.activation_radius * 0.5, 0.0)
			if target_index == 0
			else target
		)
		_press_confirm(source, module, 0.05)
		if target_index == 0:
			_expect(
				module.get_activity_cursor().get_cursor_position().is_equal_approx(target),
				"correct activation settles the cursor onto the linked node"
			)
	var first_result := module.get_result()
	var first_score := float(first_result.get("score", 0.0))
	_expect(
		int(first_result.get("attempts", 0)) == first_targets.size()
		and int(first_result.get("successes", 0)) == 1
		and int(first_result.get("failures", 0)) == 0
		and first_score > config.base_completion_score,
		"a correctly woven rune records attempts, success, and speed-weighted score"
	)

	module._physics_process(0.0)
	var second_targets := module.get_current_targets()
	_expect(
		second_targets.size() == config.starting_node_count + 1
		and module.is_sequence_hidden()
		and not module.preview_line.visible,
		"difficulty increase adds a node and hides the order after preview"
	)
	_expect(
		_pattern_is_possible(second_targets, config),
		"higher-difficulty targets remain possible and correctly spaced"
	)

	module.get_activity_cursor().reset_cursor(
		config.get_cursor_bounds().end - Vector2.ONE
	)
	_press_confirm(source, module, 0.05)
	var mistake_result := module.get_result()
	_expect(
		int(mistake_result.get("attempts", 0)) == first_targets.size() + 1
		and int(mistake_result.get("failures", 0)) == 1
		and is_equal_approx(
			float(mistake_result.get("score", 0.0)),
			maxf(0.0, first_score - config.mistake_penalty)
		),
		"confirming away from the required node counts one penalized mistake"
	)

	for target in second_targets:
		module.get_activity_cursor().reset_cursor(target)
		_press_confirm(source, module, 0.05)
	var completed_result := module.get_result()
	var details: Dictionary = completed_result.get("details", {})
	_expect(
		int(completed_result.get("attempts", 0))
			== first_targets.size() + second_targets.size() + 1
		and int(completed_result.get("successes", 0)) == 2
		and int(completed_result.get("failures", 0)) == 1,
		"exercise continues after a mistake and completes the next rune"
	)
	_expect(
		int(details.get("completed_runes", 0)) == 2
		and int(details.get("total_correct_nodes", 0))
			== first_targets.size() + second_targets.size()
		and int(details.get("total_mistakes", 0)) == 1
		and int(details.get("best_streak", 0)) == 1
		and float(details.get("fastest_rune_completion", 0.0)) > 0.0
		and int(details.get("highest_node_count_reached", 0))
			== config.starting_node_count + 1,
		"standard details preserve Rune Weaving performance metrics"
	)

	var changes_before_idle_ticks := result_change_count
	for _index in 25:
		module._physics_process(0.001)
	_expect(
		result_change_count - changes_before_idle_ticks < 25,
		"result_changed is not emitted every physics tick"
	)
	var first_stop := module.stop_activity(&"lesson_completed")
	var repeated_stop := module.stop_activity(&"ignored_repeat")
	_expect(first_stop == repeated_stop, "stop is idempotent")
	_expect(
		_has_standard_result_fields(first_stop),
		"final Rune Weaving result contains the standard activity contract"
	)

	var module_source := FileAccess.get_file_as_string(
		"res://scripts/activities/rune_weaving/rune_weaving_module.gd"
	)
	_expect(
		module_source.find("GameplayFlow") == -1
		and module_source.find("ProgressionSystem") == -1
		and module_source.find("NpcWorldSimulation") == -1
		and module_source.find("MagicLessonSpot") == -1
		and module_source.find("Input.") == -1,
		"Rune Weaving remains independent from class authority and global input"
	)
	var cursor_source := FileAccess.get_file_as_string(
		"res://scripts/activities/shared/activity_cursor.gd"
	)
	var controller_source := FileAccess.get_file_as_string(
		"res://scripts/activities/shared/sequential_target_controller.gd"
	)
	_expect(
		cursor_source.to_lower().find("rune") == -1
		and cursor_source.to_lower().find("magic") == -1
		and controller_source.to_lower().find("rune") == -1
		and controller_source.to_lower().find("magic") == -1
		and controller_source.find("ProgressionSystem") == -1,
		"shared cursor and sequence controller contain no Rune Weaving authority"
	)

	world.queue_free()
	await process_frame
	if failures.is_empty():
		print("RUNE_WEAVING_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_reusable_cursor(
	world: Node,
	source: InteractiveActivityInputSource
) -> void:
	var cursor := ActivityCursor.new()
	world.add_child(cursor)
	_expect(
		cursor.configure({
			"acceleration": 100.0,
			"drag": 100.0,
			"maximum_speed": 100.0,
			"turn_acceleration_multiplier": 2.0,
			"stop_speed_threshold": 1.0,
		}),
		"reusable cursor accepts valid movement configuration"
	)
	cursor.set_input_source(source)
	cursor.set_movement_bounds(Rect2(-Vector2.ONE * 10.0, Vector2.ONE * 20.0))
	cursor.reset_cursor(Vector2.ZERO)
	cursor.set_movement_enabled(true)
	source._input(_action_event(&"right", true))
	cursor._physics_process(0.25)
	_expect(
		is_equal_approx(cursor.get_cursor_velocity().x, 25.0),
		"reusable cursor accelerates smoothly instead of jumping to full speed"
	)
	source._input(_action_event(&"right", false))
	source._input(_action_event(&"left", true))
	cursor._physics_process(0.125)
	_expect(
		is_zero_approx(cursor.get_cursor_velocity().x),
		"reusable cursor applies stronger response when reversing direction"
	)
	source._input(_action_event(&"left", false))
	cursor.reset_cursor(Vector2(9.0, 0.0))
	source._input(_action_event(&"right", true))
	cursor._physics_process(1.0)
	_expect(
		cursor.get_cursor_position().x <= 10.0
		and is_zero_approx(cursor.get_cursor_velocity().x),
		"reusable cursor still clamps motion cleanly at configured bounds"
	)
	source._input(_action_event(&"right", false))
	source.clear_one_frame_states()
	cursor.set_movement_enabled(false)
	cursor.queue_free()


func _test_reusable_sequence_controller(world: Node) -> void:
	var controller := SequentialTargetController.new()
	world.add_child(controller)
	controller.target_activated.connect(_on_controller_target_activated)
	controller.incorrect_activation.connect(_on_controller_incorrect_activation)
	controller.sequence_completed.connect(_on_controller_sequence_completed)
	_expect(
		controller.configure(
			PackedVector2Array([Vector2.ZERO, Vector2(50.0, 0.0)]),
			10.0
		),
		"generic sequence controller accepts ordered spatial targets"
	)
	_expect(
		not controller.try_activate(Vector2(25.0, 0.0))
		and controller.get_current_index() == 0,
		"incorrect generic activation leaves the required index unchanged"
	)
	_expect(
		controller.try_activate(Vector2(5.0, 0.0))
		and controller.get_current_index() == 1,
		"correct generic activation advances exactly one target"
	)
	_expect(
		controller.try_activate(Vector2(50.0, 0.0))
		and controller.is_complete()
		and controller_correct_count == 2
		and controller_incorrect_count == 1
		and controller_completion_count == 1,
		"generic sequence completion emits correct and terminal signals once"
	)
	controller.reset()
	_expect(
		controller.get_current_index() == 0 and controller.has_pending_target(),
		"generic sequence reset preserves targets and returns to the first node"
	)
	controller.queue_free()


func _make_context(session_id: String, config: RuneWeavingConfig) -> Dictionary:
	return {
		"session_id": session_id,
		"activity_id": "rune_weaving",
		"module_config": config,
	}


func _make_config() -> RuneWeavingConfig:
	var config := RuneWeavingConfig.new()
	config.cursor_speed = 200.0
	config.cursor_acceleration = 800.0
	config.cursor_drag = 1000.0
	config.cursor_turn_acceleration_multiplier = 1.6
	config.cursor_stop_speed_threshold = 2.0
	config.activation_radius = 15.0
	config.snap_cursor_to_activated_node = true
	config.starting_node_count = 3
	config.maximum_node_count = 4
	config.field_size = Vector2(240.0, 160.0)
	config.target_margin = 20.0
	config.minimum_target_spacing = 60.0
	config.preview_duration = 0.0
	config.minimum_preview_duration = 0.0
	config.preview_reduction_per_difficulty = 0.0
	config.rounds_with_visible_sequence = 1
	config.mistake_penalty = 15.0
	config.base_completion_score = 100.0
	config.speed_bonus = 50.0
	config.target_seconds_per_node = 1.0
	config.streak_multiplier = 0.25
	config.difficulty_increase_interval = 1
	config.round_transition_delay = 0.0
	config.feedback_duration = 0.0
	return config


func _press_confirm(
	source: InteractiveActivityInputSource,
	module: RuneWeavingModule,
	delta: float
) -> void:
	source.clear_one_frame_states()
	source._input(_action_event(&"attack", true))
	module._process(delta)
	module._physics_process(delta)
	source._input(_action_event(&"attack", false))
	source.clear_one_frame_states()


func _pattern_is_possible(
	targets: PackedVector2Array,
	config: RuneWeavingConfig
) -> bool:
	if targets.size() < config.starting_node_count:
		return false
	var bounds := config.get_target_bounds().grow(0.01)
	for target in targets:
		if not bounds.has_point(target):
			return false
	for first_index in targets.size():
		for second_index in range(first_index + 1, targets.size()):
			if (
				targets[first_index].distance_to(targets[second_index])
				< config.minimum_target_spacing - 0.01
			):
				return false
	return true


func _has_standard_result_fields(result: Dictionary) -> bool:
	for key in [
		"activity_id",
		"session_id",
		"status",
		"finish_reason",
		"elapsed_seconds",
		"score",
		"attempts",
		"successes",
		"failures",
		"details",
	]:
		if not result.has(key):
			return false
	var details: Dictionary = result.get("details", {})
	return (
		details.has("completed_runes")
		and details.has("total_correct_nodes")
		and details.has("total_mistakes")
		and details.has("best_streak")
		and details.has("fastest_rune_completion")
		and details.has("highest_node_count_reached")
	)


func _action_event(action: StringName, pressed: bool) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	return event


func _on_result_changed(_result: Dictionary) -> void:
	result_change_count += 1


func _on_controller_target_activated(_index: int, _position: Vector2) -> void:
	controller_correct_count += 1


func _on_controller_incorrect_activation(
	_attempted_position: Vector2,
	_required_index: int,
	_required_position: Vector2,
	_distance: float
) -> void:
	controller_incorrect_count += 1


func _on_controller_sequence_completed() -> void:
	controller_completion_count += 1


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
