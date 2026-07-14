class_name NpcStateWork extends NpcState

@export var work_target_path: NodePath
@export var work_value_name: StringName = &"boredom"
@export var boredom_drop_per_full_work: float = 60.0
@export var fallback_work_needed_capacity: float = 100.0
@export var work_progress_tick_seconds: float = 3.0

var active_work_target: Node2D
var work_progress_elapsed: float = 0.0


func enter() -> void:
	# Work now clears the area's own work_needed value instead of waiting on a fixed timer.
	# Resolve the spot-specific clip before playback; super.enter() would play the generic
	# work clip first and then immediately replace it.
	begin_enter_without_animation()
	active_work_target = _resolve_work_target()
	work_progress_elapsed = 0.0

	if active_work_target == null:
		next_state = get_state(&"Idle")
		stop_horizontal()
		return

	_play_work_animation(active_work_target)

	if not is_close_to(active_work_target.global_position, machine.stop_distance):
		_walk_to_work_target(active_work_target)
		return

	if _target_work_is_done(active_work_target):
		next_state = get_state(&"Idle")
		stop_horizontal()
		return

	stop_horizontal()


func _play_work_animation(work_target: Node2D) -> bool:
	var target_animation := animation_name
	if work_target != null and work_target.has_method("get_routine_task_animation_name"):
		var configured_animation := StringName(String(
			work_target.call("get_routine_task_animation_name")
		))
		if configured_animation != &"":
			target_animation = configured_animation

	if target_animation != &"":
		return play_animation(target_animation)
	return false


func physics_process(delta: float) -> NpcState:
	# Every frame of successful work lowers both the spot's work and the NPC's boredom.
	stop_horizontal()

	if next_state != null:
		return next_state

	if active_work_target == null or not is_instance_valid(active_work_target):
		active_work_target = _resolve_work_target()

	if active_work_target == null:
		return get_state(&"Idle")

	if not _target_can_be_worked(active_work_target):
		machine.work_target = null
		active_work_target = _resolve_work_target()
		if active_work_target == null:
			return get_state(&"Idle")

	if not is_close_to(active_work_target.global_position, machine.stop_distance):
		machine.move_target = active_work_target
		machine.state_after_move = &"Work"
		return get_state(&"MoveToTarget")

	if _target_work_is_done(active_work_target):
		return get_state(&"Idle")

	_apply_work_progress(delta, active_work_target)
	if _target_work_is_done(active_work_target):
		return get_state(&"Idle")

	return next_state


func can_continue_during_talk() -> bool:
	var work_target := active_work_target
	if work_target == null or not is_instance_valid(work_target):
		work_target = _resolve_work_target()

	return (
		work_target != null
		and is_instance_valid(work_target)
		and _target_can_be_worked(work_target)
		and is_close_to(work_target.global_position, machine.stop_distance)
		and not _target_work_is_done(work_target)
	)


func process_talk_overlay(delta: float) -> StringName:
	stop_horizontal()

	if active_work_target == null or not is_instance_valid(active_work_target):
		active_work_target = _resolve_work_target()

	if active_work_target == null:
		return &"Idle"

	if _target_work_is_done(active_work_target):
		return &"Idle"

	if not _target_can_be_worked(active_work_target):
		machine.work_target = null
		return &"Idle"

	if not is_close_to(active_work_target.global_position, machine.stop_distance):
		machine.move_target = active_work_target
		machine.state_after_move = &"Work"
		return &"MoveToTarget"

	_apply_work_progress(delta, active_work_target)
	if _target_work_is_done(active_work_target):
		return &"Idle"

	return &"Work"


func resume_presentation_after_talk_overlay() -> void:
	_play_work_animation(active_work_target)


func _apply_work_progress(delta: float, work_target: Node2D) -> void:
	# The area's actual clamped work change determines how much boredom can fall.
	work_progress_elapsed += delta
	var tick_seconds := maxf(work_progress_tick_seconds, 0.0)
	if tick_seconds > 0.0 and work_progress_elapsed < tick_seconds:
		return

	var progress_delta := work_progress_elapsed
	work_progress_elapsed = 0.0

	var work_capacity := _get_target_work_capacity(work_target)
	var actual_work_delta := _apply_worker_work_progress(work_target, progress_delta)

	if is_equal_approx(actual_work_delta, 0.0):
		return

	_record_watchdog_marker(
		&"npc:work_progress",
		"%s %.2f" % [work_target.name, actual_work_delta]
	)

	if work_value_name == &"":
		return

	var progress_fraction := absf(actual_work_delta) / work_capacity
	var value_drop := _get_value_drop_per_full_work(work_target)
	var boredom_delta := -value_drop * progress_fraction
	if is_equal_approx(boredom_delta, 0.0):
		return

	machine.apply_value_delta({String(work_value_name): boredom_delta}, null, false)


func _resolve_work_target() -> Node2D:
	# Target priority: exported path, assigned spot, then closest matching Work spot.
	if machine == null:
		return null

	if String(work_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(work_target_path) as Node2D
		if _target_can_be_worked(configured_target):
			return configured_target

	if _target_can_be_worked(machine.work_target):
		return machine.work_target

	machine.work_target = null
	var closest_spot := find_closest_need_spot(&"Work", work_value_name)
	if closest_spot != null:
		machine.work_target = closest_spot
		return closest_spot

	return null


func _walk_to_work_target(work_target: Node2D) -> void:
	# MoveToTarget will return to Work, where progress can start once the NPC arrives.
	machine.move_target = work_target
	machine.state_after_move = &"Work"
	machine.call_deferred("request_state", &"MoveToTarget", work_target, "walk_to_work", 20)


func _target_can_be_worked(work_target: Node2D) -> bool:
	if work_target == null or not is_instance_valid(work_target):
		return false

	if work_target.has_method("can_serve_npc_need"):
		return bool(work_target.call("can_serve_npc_need", npc, &"Work", work_value_name))

	if work_target.has_method("has_work_needed"):
		return bool(work_target.call("has_work_needed"))

	return false


func _target_work_is_done(work_target: Node2D) -> bool:
	if work_target == null or not is_instance_valid(work_target):
		return true

	if work_target.has_method("is_work_complete"):
		return bool(work_target.call("is_work_complete"))

	if work_target.has_method("has_work_needed"):
		return not bool(work_target.call("has_work_needed"))

	return true


func _apply_target_work_delta(work_target: Node2D, requested_delta: float) -> float:
	if work_target != null and work_target.has_method("apply_work_needed_delta"):
		return float(work_target.call("apply_work_needed_delta", requested_delta))

	return 0.0


func _apply_worker_work_progress(work_target: Node2D, progress_delta: float) -> float:
	if work_target != null and work_target.has_method("apply_worker_work_progress"):
		return float(work_target.call("apply_worker_work_progress", npc, progress_delta, 1.0))

	var full_work_seconds := _get_seconds_to_clear_full_work(work_target)
	var work_capacity := _get_target_work_capacity(work_target)
	var requested_work_delta := -(work_capacity / full_work_seconds) * progress_delta
	return _apply_target_work_delta(work_target, requested_work_delta)


func _get_target_work_capacity(work_target: Node2D) -> float:
	if work_target != null and work_target.has_method("get_work_needed_capacity"):
		return maxf(float(work_target.call("get_work_needed_capacity")), 0.001)

	return maxf(fallback_work_needed_capacity, 0.001)


func _get_seconds_to_clear_full_work(work_target: Node2D) -> float:
	# Prefer the spot's rate so short chores and long jobs can share the same Work state.
	if work_target != null and work_target.has_method("get_full_work_real_seconds"):
		var spot_seconds := float(work_target.call("get_full_work_real_seconds"))
		if spot_seconds > 0.0:
			return maxf(spot_seconds, 0.001)

	if machine == null:
		return maxf(fallback_work_needed_capacity, 0.001)

	var game_hours := machine.default_work_game_hours
	if work_target != null and work_target.has_method("get_full_work_game_hours"):
		var spot_game_hours := float(work_target.call("get_full_work_game_hours"))
		if spot_game_hours > 0.0:
			game_hours = spot_game_hours

	return maxf(
		machine.get_real_seconds_for_game_hours(
			game_hours,
			machine.default_work_time
		),
		0.001
	)


func _get_value_drop_per_full_work(work_target: Node2D) -> float:
	if work_target != null and work_target.has_method("get_value_drop_per_full_work"):
		var spot_value_drop := float(work_target.call(
			"get_value_drop_per_full_work",
			work_value_name
		))
		if spot_value_drop >= 0.0:
			return spot_value_drop

	return absf(boredom_drop_per_full_work)


func _record_watchdog_marker(source: StringName, detail: String = "") -> void:
	var watchdog := get_node_or_null("/root/PerformanceWatchdog")
	if watchdog != null and watchdog.has_method("record_marker"):
		watchdog.call("record_marker", source, detail)
