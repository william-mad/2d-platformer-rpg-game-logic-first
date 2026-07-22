class_name NpcStateMoveToTarget extends NpcState

@export var target_node_path: NodePath
@export var speed_override: float = 0.0
@export var arrive_state_name: StringName = &"Idle"
@export var target_refresh_seconds: float = 0.12

@export_group("Movement Safeguards")
@export_range(0.05, 2.0, 0.05) var progress_sample_seconds: float = 0.4
@export_range(0.0, 32.0, 0.5) var minimum_progress_distance: float = 2.0
@export_range(0.5, 30.0, 0.5) var no_progress_timeout_seconds: float = 5.0
@export_range(1.0, 256.0, 1.0) var meaningful_target_change_distance: float = 24.0

var tracked_target: Node2D
var cached_target_position: Vector2
var refresh_timer: float = 0.0
var progress_sample_elapsed: float = 0.0
var no_progress_elapsed: float = 0.0
var best_distance_to_target_x: float = 0.0
var progress_target_position: Vector2
var movement_failure_reported: bool = false


func on_action_session_refreshed() -> void:
	tracked_target = _resolve_target()
	if tracked_target != null and is_instance_valid(tracked_target):
		cached_target_position = tracked_target.global_position
	_reset_progress_watchdog()


func enter() -> void:
	super.enter()
	tracked_target = _resolve_target()
	refresh_timer = 0.0

	if tracked_target != null and is_instance_valid(tracked_target):
		cached_target_position = tracked_target.global_position
	_reset_progress_watchdog()


func exit() -> void:
	stop_horizontal()


func physics_process(delta: float) -> NpcState:
	if not action_session_is_current():
		return reconcile_invalid_action_session()
	if tracked_target == null or not is_instance_valid(tracked_target):
		machine.fail_active_action(action_session_id, "movement_target_missing")
		return get_state(&"Idle")

	# Refresh the target position on a small interval instead of doing extra target work every frame.
	refresh_timer -= delta
	if refresh_timer <= 0.0:
		var refreshed_position := tracked_target.global_position
		var target_change_limit := maxf(meaningful_target_change_distance, 1.0)
		if (
			refreshed_position.distance_squared_to(progress_target_position)
			>= target_change_limit * target_change_limit
		):
			cached_target_position = refreshed_position
			_reset_progress_watchdog()
		else:
			cached_target_position = refreshed_position
		refresh_timer = target_refresh_seconds

	var speed := speed_override
	if speed <= 0.0:
		speed = machine.get_effective_walk_speed()

	var arrived_horizontally := move_toward_position(
		cached_target_position,
		speed,
		machine.stop_distance
	)
	if arrived_horizontally and not _target_uses_external_arrival_commit():
		return get_state(machine.finish_active_action_approach(action_session_id, arrive_state_name))
	if _update_progress_watchdog(delta):
		return _fail_stuck_movement()

	return next_state


func _resolve_target() -> Node2D:
	if machine == null:
		return null

	return machine.get_active_action_target()


func _target_uses_external_arrival_commit() -> bool:
	# Scene travel is committed transactionally by NpcTravelDoor when its Area2D
	# receives the NPC. Horizontal proximity must not start the destination action
	# while the NPC is still in the source scene.
	return (
		tracked_target != null
		and is_instance_valid(tracked_target)
		and tracked_target.is_in_group(&"npc_travel_door")
		and tracked_target.has_method(&"try_travel_npc")
	)


func _update_progress_watchdog(delta: float) -> bool:
	if (
		npc == null
		or movement_failure_reported
		or (
			DebugToolsConfig.TROUBLESHOOTING_MODE
			and DebugToolsConfig.DEBUG_DISABLE_NPC_MOVE_STUCK_WATCHDOG
		)
	):
		return false
	progress_sample_elapsed += maxf(delta, 0.0)
	var sample_interval := maxf(progress_sample_seconds, 0.05)
	if progress_sample_elapsed < sample_interval:
		return false

	var sampled_elapsed := progress_sample_elapsed
	progress_sample_elapsed = 0.0
	var current_distance := absf(cached_target_position.x - npc.global_position.x)
	var required_progress := maxf(minimum_progress_distance, 0.01)
	if current_distance <= best_distance_to_target_x - required_progress:
		best_distance_to_target_x = current_distance
		no_progress_elapsed = 0.0
	else:
		no_progress_elapsed += sampled_elapsed
	return no_progress_elapsed >= maxf(no_progress_timeout_seconds, 0.5)


func _reset_progress_watchdog() -> void:
	progress_sample_elapsed = 0.0
	no_progress_elapsed = 0.0
	best_distance_to_target_x = (
		absf(cached_target_position.x - npc.global_position.x)
		if npc != null
		else 0.0
	)
	progress_target_position = cached_target_position
	movement_failure_reported = false


func _fail_stuck_movement() -> NpcState:
	stop_horizontal()
	if not movement_failure_reported:
		movement_failure_reported = true
		var pending_cancelled := false
		var locations := get_node_or_null("/root/NpcLocations")
		if (
			locations != null
			and locations.has_method("get_npc_id")
			and locations.has_method("cancel_pending_scheduled_travel")
		):
			var npc_id := String(locations.call("get_npc_id", npc))
			if not npc_id.is_empty():
				pending_cancelled = bool(locations.call(
					"cancel_pending_scheduled_travel",
					npc_id,
					"movement_stuck",
					true,
					action_session_id
				))
		if not pending_cancelled:
			machine.fail_active_action(action_session_id, "movement_stuck")
	return get_state(&"Idle")
