class_name NpcStateRoutineTask extends NpcState

@export var routine_target_path: NodePath
@export var routine_value_name: StringName = &""
@export var default_animation_name: StringName = &"routine_task"
@export var default_duration_seconds: float = 3.0
@export_range(0.0, 1440.0, 1.0, "suffix:min") var default_game_minutes: float = 30.0
@export_range(-100.0, 100.0, 0.1, "suffix:/h") var default_value_delta_per_game_hour: float = 0.0
@export var default_finish_when_value_sated: bool = true
@export var progress_tick_seconds: float = 1.0

var active_routine_target: Node2D
var routine_timer: float = 0.0
var total_routine_seconds: float = 0.0
var progress_elapsed: float = 0.0
var active_value_name: StringName = &""
var active_value_delta_per_game_hour: float = 0.0
var active_finish_when_value_sated: bool = true


func on_action_session_refreshed() -> void:
	active_routine_target = machine.get_routine_task_target()


func enter() -> void:
	super.enter()
	active_routine_target = _resolve_routine_target()
	progress_elapsed = 0.0

	if active_routine_target == null:
		routine_timer = 0.0
		machine.call_deferred("request_state", &"Idle", null, "missing_routine_task_spot", 20)
		return

	if not is_close_to(active_routine_target.global_position, machine.stop_distance):
		machine.call_deferred(
			"request_active_action_approach", action_session_id, "walk_to_routine_task", 20
		)
		return

	_begin_routine_task(active_routine_target)


func physics_process(delta: float) -> NpcState:
	if not action_session_is_current():
		return reconcile_invalid_action_session()
	stop_horizontal()

	if active_routine_target == null or not is_instance_valid(active_routine_target):
		active_routine_target = _resolve_routine_target()
		if active_routine_target == null:
			_clear_routine_target()
			return get_state(&"Idle")

	if not _target_can_be_used(active_routine_target):
		_clear_routine_target()
		active_routine_target = _resolve_routine_target()
		if active_routine_target == null:
			return get_state(&"Idle")

	if not is_close_to(active_routine_target.global_position, machine.stop_distance):
		machine.begin_active_action_approach(action_session_id)
		return get_state(&"MoveToTarget")

	if routine_timer <= 0.0:
		_begin_routine_task(active_routine_target)

	routine_timer -= delta
	_apply_routine_progress(delta)

	if routine_timer <= 0.0 or _routine_value_is_sated():
		_clear_routine_target()
		return get_state(&"Idle")

	return next_state


func _begin_routine_task(routine_target: Node2D) -> void:
	stop_horizontal()
	active_value_name = _get_task_value_name(routine_target)
	active_value_delta_per_game_hour = _get_task_value_delta_per_game_hour(routine_target)
	active_finish_when_value_sated = _get_task_finish_when_value_sated(routine_target)
	routine_timer = _get_task_duration_seconds(routine_target)
	total_routine_seconds = maxf(routine_timer, 0.001)
	_play_routine_animation(routine_target)


func _resolve_routine_target() -> Node2D:
	if machine == null:
		return null

	var assigned_target := machine.get_routine_task_target()
	if _target_can_be_used(assigned_target):
		return assigned_target

	if String(routine_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(routine_target_path) as Node2D
		if _target_can_be_used(configured_target):
			machine.set_action_target(&"RoutineTask", configured_target, action_session_id)
			return configured_target

	machine.set_action_target(&"RoutineTask", null, action_session_id)
	var closest_spot := find_closest_need_spot(&"RoutineTask", routine_value_name)
	if closest_spot != null:
		machine.set_action_target(&"RoutineTask", closest_spot, action_session_id)

	return closest_spot


func _target_can_be_used(routine_target: Node2D) -> bool:
	if routine_target == null or not is_instance_valid(routine_target):
		return false
	if routine_target.has_method("can_serve_npc_need"):
		return bool(routine_target.call(
			"can_serve_npc_need",
			npc,
			&"RoutineTask",
			active_value_name
		))

	return true


func _apply_routine_progress(delta: float) -> void:
	progress_elapsed += delta
	var tick_seconds := maxf(progress_tick_seconds, 0.0)
	if tick_seconds > 0.0 and progress_elapsed < tick_seconds:
		return

	var progress_delta := progress_elapsed
	progress_elapsed = 0.0
	if active_value_name == &"" or is_equal_approx(active_value_delta_per_game_hour, 0.0):
		return

	var game_hours := machine.get_game_hours_for_real_seconds(progress_delta)
	if game_hours <= 0.0:
		return

	machine.apply_value_delta(
		{String(active_value_name): active_value_delta_per_game_hour * game_hours},
		null,
		false
	)


func _routine_value_is_sated() -> bool:
	if not active_finish_when_value_sated or active_value_name == &"":
		return false
	if is_equal_approx(active_value_delta_per_game_hour, 0.0):
		return false

	var current_value := machine.get_value(active_value_name)
	if active_value_delta_per_game_hour < 0.0:
		return current_value <= _get_task_value_minimum(active_routine_target)

	return current_value >= _get_task_value_maximum(active_routine_target)


func _clear_routine_target() -> void:
	if machine != null:
		machine.set_action_target(&"RoutineTask", null, action_session_id)
	active_routine_target = null
	routine_timer = 0.0
	progress_elapsed = 0.0


func _play_routine_animation(routine_target: Node2D) -> void:
	var task_animation := _get_task_animation_name(routine_target)
	if task_animation != &"":
		play_animation(task_animation)


func _get_task_animation_name(routine_target: Node) -> StringName:
	var value = _call_or_get(routine_target, &"get_routine_task_animation_name", &"routine_animation_name", default_animation_name)
	var animation := StringName(String(value))
	if animation != &"":
		return animation
	return animation_name


func _get_task_duration_seconds(routine_target: Node) -> float:
	var game_minutes := float(_call_or_get(
		routine_target,
		&"get_routine_task_game_minutes",
		&"routine_game_minutes",
		default_game_minutes
	))
	return maxf(machine.get_real_seconds_for_game_minutes(game_minutes, default_duration_seconds), 0.001)


func _get_task_value_name(routine_target: Node) -> StringName:
	var value = _call_or_get(routine_target, &"get_routine_task_value_name", &"value_name", routine_value_name)
	return StringName(String(value))


func _get_task_value_delta_per_game_hour(routine_target: Node) -> float:
	return float(_call_or_get(
		routine_target,
		&"get_routine_task_value_delta_per_game_hour",
		&"routine_value_delta_per_game_hour",
		default_value_delta_per_game_hour
	))


func _get_task_finish_when_value_sated(routine_target: Node) -> bool:
	return bool(_call_or_get(
		routine_target,
		&"get_routine_task_finish_when_value_sated",
		&"routine_finish_when_value_sated",
		default_finish_when_value_sated
	))


func _get_task_value_minimum(routine_target: Node) -> float:
	return float(_get_property_if_present(routine_target, &"value_min", 0.0))


func _get_task_value_maximum(routine_target: Node) -> float:
	return float(_get_property_if_present(routine_target, &"value_max", 100.0))


func _call_or_get(object: Node, method_name: StringName, property_name: StringName, fallback):
	if object != null and object.has_method(method_name):
		return object.call(method_name)

	return _get_property_if_present(object, property_name, fallback)


func _get_property_if_present(object: Object, property_name: StringName, fallback):
	if object == null:
		return fallback

	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return object.get(property_name)

	return fallback
