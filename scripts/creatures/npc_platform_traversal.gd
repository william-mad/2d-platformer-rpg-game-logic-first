class_name NpcPlatformTraversal
extends Node

enum TransitionPhase {
	FOLLOWING,
	APPROACHING_TRANSITION,
	EXECUTING_JUMP,
	REPOSITIONING_AFTER_FAILURE,
	STUCK_RECOVERY,
}

enum TraversalStatus {
	INACTIVE,
	MOVING,
	APPROACHING_TRANSITION,
	COMMITTED_JUMP,
	REPOSITIONING,
	RECOVERING,
	SETTLED,
	FAILED,
	TEMPORARILY_BLOCKED,
	TARGET_INVALID,
	NO_ROUTE,
	REPEATED_FAILURE,
	CANCELLED,
	SUPERSEDED,
}

class TraversalOptions:
	extends RefCounted

	var desired_stop_distance: float = 64.0
	var movement_speed_multiplier: float = 1.0
	var allow_jumps: bool = true
	var allow_hard_recovery: bool = true


class TraversalResult:
	extends RefCounted

	var status: TraversalStatus = TraversalStatus.INACTIVE
	var target_reached: bool = false
	var movement_active: bool = false
	var traversal_committed: bool = false
	var recovery_active: bool = false
	var navigation_failed: bool = false
	var reason: StringName = &""
	var target_position: Vector2 = Vector2.ZERO


@export var stop_distance: float = 64.0
@export_group("Distance-based Speed")
@export var minimum_speed_multiplier: float = 1.0
@export var maximum_speed_multiplier: float = 12.0
@export var speed_ramp_start_distance: float = 90.0
@export var full_speed_distance: float = 650.0
@export var horizontal_acceleration: float = 2600.0
@export var horizontal_deceleration: float = 3200.0

@export_group("Distance-based Jump")
@export var minimum_jump_height_difference: float = 56.0
@export var maximum_jump_height_difference: float = 420.0
@export var jump_height_overshoot: float = 24.0
@export var jump_velocity_safety_multiplier: float = 1.01
@export var minimum_jump_velocity: float = 390.0
@export var maximum_jump_velocity: float = 1050.0
@export var maximum_jump_route_distance: float = 600.0
@export var minimum_raised_jump_horizontal_speed: float = 320.0
@export var jump_cooldown_seconds: float = 1.2
@export var height_jump_retry_seconds: float = 2.0

@export_group("Air Ledge Assist")
@export var air_ledge_assist_enabled: bool = true
@export var air_ledge_assist_cast_path: NodePath = NodePath("AirLedgeAssistCast")
@export var air_ledge_assist_minimum_fall_speed: float = 20.0
@export var air_ledge_assist_minimum_target_height: float = 32.0
@export var air_ledge_assist_jump_velocity: float = 620.0
@export var air_ledge_assist_horizontal_speed: float = 380.0
@export var air_ledge_assist_extra_timeout: float = 0.9

@export_group("Local Platform Probes")
@export var leading_foot_probe_distance: float = 12.0
@export var far_floor_probe_distance: float = 96.0
@export var floor_probe_depth: float = 96.0
@export var obstacle_probe_distance: float = 34.0
@export var upward_clearance_probe_distance: float = 90.0
@export var landing_search_above: float = 150.0
@export var landing_search_below: float = 240.0
@export var landing_width_margin: float = 4.0
@export var maximum_supported_floor_difference: float = 18.0
@export_range(8, 12, 1) var ballistic_arc_samples: int = 10

@export_group("Transition Solver")
@export_flags_2d_physics var transition_collision_mask: int = 1
@export_range(0.35, 0.5, 0.01) var transition_recalculation_seconds: float = 0.35
@export var takeoff_position_tolerance: float = 28.0
@export var takeoff_commit_delay_seconds: float = 0.12
@export var committed_jump_timeout_margin: float = 0.8
@export var landing_horizontal_tolerance: float = 84.0
@export var landing_vertical_tolerance: float = 56.0
@export var development_jump_diagnostics: bool = false
@export var diagnostic_repeat_seconds: float = 1.5

@export_group("Visual Debug")
@export var debug_enabled: bool = false
@export_range(2, 8, 1) var debug_breadcrumb_count: int = 2
@export_range(0.05, 0.5, 0.01) var debug_refresh_seconds: float = 0.1

@export_group("Failed Jump Reposition")
@export var failure_reposition_step: float = 120.0
@export var failure_reposition_maximum_distance: float = 280.0
@export var failure_reposition_tolerance: float = 36.0
@export var failure_reposition_timeout: float = 3.0
@export var jump_give_up_seconds: float = 5.0
@export var jump_give_up_target_change_distance: float = 180.0

@export_group("Recovery")
@export var extreme_recovery_distance: float = 1500.0
@export var stuck_retry_seconds: float = 3.0
@export var stuck_recovery_seconds: float = 5.0
@export var hard_recovery_requires_offscreen: bool = true
@export_range(1, 10, 1) var maximum_navigation_failures: int = 3
@export_range(0.1, 1.0, 0.05) var recorder_reacquire_seconds: float = 0.25
@export_range(0.1, 1.0, 0.05) var stuck_progress_sample_seconds: float = 0.4
@export_range(1.0, 64.0, 1.0) var stuck_minimum_progress_distance: float = 8.0

var _recorder: Node
var _recorder_reacquire_timer: float = 0.0
var _last_distance: float = INF
var _stuck_seconds: float = 0.0
var _stuck_progress_elapsed: float = 0.0
var _jump_cooldown: float = 0.0
var _height_jump_cooldown: float = 0.0
var _last_jump_breadcrumb_msec: int = -1
var _transition_probe := NpcPlatformTransitionProbe.new()
var _transition_phase: TransitionPhase = TransitionPhase.FOLLOWING
var _transition_plan: Dictionary = {}
var _transition_recalculation_timer: float = 0.0
var _committed_jump_elapsed: float = 0.0
var _committed_jump_was_airborne: bool = false
var _takeoff_anticipation_elapsed: float = 0.0
var _last_completed_traversal_sequence: int = 0
var _active_traversal: Dictionary = {}
var _failure_reposition_plan: Dictionary = {}
var _failure_reposition_elapsed: float = 0.0
var _failure_reposition_sign: float = 1.0
var _jump_give_up_until_msec: int = -1
var _jump_give_up_target: Vector2 = Vector2.INF
var _abandoned_traversal_sequence: int = -1
var _last_diagnostic_text: String = ""
var _last_diagnostic_msec: int = -100000
var _debug_overlay: NpcPlatformTraversalDebugOverlay
var _debug_overlay_refresh_timer: float = 0.0
var _air_ledge_assist_cast: ShapeCast2D
var _air_ledge_assist_used: bool = false
var _forward_floor_hazard_was_detected: bool = false
var _last_forward_probe_direction: float = 0.0
var _hold_for_forward_hazard: bool = false
var npc: CharacterBody2D
var machine: NpcStateMachine
var _airborne_animation_controller: Node
var _target_actor_ref: WeakRef
var _fixed_target_position: Vector2 = Vector2.ZERO
var _has_fixed_target: bool = false
var _target_generation: int = 0
var _target_failure_reason: StringName = &""
var _last_result := TraversalResult.new()
var _active_options := TraversalOptions.new()
var _owner_ref: WeakRef
var _session_serial: int = 0
var _active_session_id: int = 0
var _acquisition_reason: StringName = &""
var _last_context_reset_reason: StringName = &""
var _last_rejected_operation: StringName = &""
var _last_rejected_reason: StringName = &""
var _last_velocity_update_physics_frame: int = -1
var _last_velocity_update_session_id: int = 0
var _consecutive_navigation_failures: int = 0
var _last_failure_reason: StringName = &""
var _terminal_failure_reason: StringName = &""
var _failure_target_position: Vector2 = Vector2.INF


func _ready() -> void:
	var parent_character := get_parent() as CharacterBody2D
	if parent_character != null:
		bind_character(
			parent_character,
			parent_character.get_node_or_null("NpcStateMachine") as NpcStateMachine
		)


func _physics_process(_delta: float) -> void:
	_cleanup_freed_owner()


func _exit_tree() -> void:
	_invalidate_all_internal(&"scene_unload", TraversalStatus.CANCELLED)


func bind_character(character: CharacterBody2D, state_machine: NpcStateMachine) -> bool:
	if character == null or state_machine == null:
		return false
	var binding_changed := npc != character or machine != state_machine
	if binding_changed:
		_invalidate_all_internal(&"character_rebound", TraversalStatus.CANCELLED)
	npc = character
	machine = state_machine
	_configure_for_character()
	return true


func _configure_for_character() -> void:
	_recorder_reacquire_timer = 0.0
	_reset_stuck_tracking()
	_jump_cooldown = 0.0
	_height_jump_cooldown = 0.0
	_last_jump_breadcrumb_msec = -1
	_transition_probe.configure(npc, transition_collision_mask)
	_transition_probe.near_foot_distance = leading_foot_probe_distance
	_transition_probe.far_floor_distance = far_floor_probe_distance
	_transition_probe.floor_probe_depth = floor_probe_depth
	_transition_probe.obstacle_probe_distance = obstacle_probe_distance
	_transition_probe.upward_clearance_distance = upward_clearance_probe_distance
	_transition_probe.landing_search_above = landing_search_above
	_transition_probe.landing_search_below = landing_search_below
	_transition_probe.landing_margin = landing_width_margin
	_transition_probe.maximum_supported_floor_difference = maximum_supported_floor_difference
	_transition_probe.arc_samples = ballistic_arc_samples
	_air_ledge_assist_cast = npc.get_node_or_null(air_ledge_assist_cast_path) as ShapeCast2D
	_airborne_animation_controller = npc.get_node_or_null("NpcAnimationController")
	_air_ledge_assist_used = false
	_transition_phase = TransitionPhase.FOLLOWING
	_transition_plan.clear()
	_transition_recalculation_timer = 0.0
	_committed_jump_elapsed = 0.0
	_committed_jump_was_airborne = false
	_takeoff_anticipation_elapsed = 0.0
	_failure_reposition_plan.clear()
	_failure_reposition_elapsed = 0.0
	_forward_floor_hazard_was_detected = false
	_last_forward_probe_direction = 0.0
	_hold_for_forward_hazard = false
	_debug_overlay_refresh_timer = 0.0
	if debug_enabled:
		_setup_debug_overlay()
	elif _debug_overlay != null and is_instance_valid(_debug_overlay):
		_debug_overlay.visible = false


func acquire(owner: Object, reason: StringName = &"") -> int:
	_cleanup_freed_owner()
	if owner == null or not is_instance_valid(owner):
		_reject_operation(&"acquire", &"invalid_owner")
		return 0
	var superseding_owner := _active_session_id > 0 and _get_owner() != null
	_session_serial += 1
	_cancel_internal(
		&"ownership_superseded" if superseding_owner else &"ownership_acquired",
		true,
		TraversalStatus.SUPERSEDED if superseding_owner else TraversalStatus.INACTIVE
	)
	_owner_ref = weakref(owner)
	_active_session_id = _session_serial
	_acquisition_reason = reason
	_last_rejected_operation = &""
	_last_rejected_reason = &""
	return _active_session_id


func is_owned_by(owner: Object, session_id: int) -> bool:
	_cleanup_freed_owner()
	if owner == null or not is_instance_valid(owner):
		return false
	var current_owner := _get_owner()
	return (
		current_owner == owner
		and session_id > 0
		and session_id == _active_session_id
	)


func has_owner() -> bool:
	_cleanup_freed_owner()
	return _get_owner() != null and _active_session_id > 0


func get_current_session_id() -> int:
	_cleanup_freed_owner()
	return _active_session_id


func release(
	owner: Object,
	session_id: int,
	reason: StringName = &""
) -> bool:
	if not _authorize(owner, session_id, &"release"):
		return false
	_cancel_internal(
		reason if reason != &"" else &"ownership_released",
		true,
		TraversalStatus.CANCELLED
	)
	_owner_ref = null
	_active_session_id = 0
	_acquisition_reason = &""
	return true


func set_target_actor(owner: Object, session_id: int, target: Node2D) -> bool:
	if not _authorize(owner, session_id, &"set_target_actor"):
		return false
	if target == null or not is_instance_valid(target):
		_clear_target_internal(&"invalid_target_actor")
		return false
	var current := get_target_actor()
	if current == target and not _has_fixed_target:
		return true
	_target_actor_ref = weakref(target)
	_has_fixed_target = false
	_target_generation += 1
	_target_failure_reason = &""
	_reset_route_for_target_change()
	return true


func get_target_actor() -> Node2D:
	if _target_actor_ref == null:
		return null
	var target := _target_actor_ref.get_ref() as Node2D
	if target == null or not is_instance_valid(target) or target.is_queued_for_deletion():
		_target_actor_ref = null
		_target_failure_reason = &"target_freed"
		return null
	return target


func set_target_position(
	owner: Object,
	session_id: int,
	target_position: Vector2
) -> bool:
	if not _authorize(owner, session_id, &"set_target_position"):
		return false
	if _has_fixed_target and _fixed_target_position.is_equal_approx(target_position):
		return true
	_target_actor_ref = null
	_fixed_target_position = target_position
	_has_fixed_target = true
	_target_generation += 1
	_target_failure_reason = &""
	_reset_route_for_target_change()
	return true


func clear_target(
	owner: Object,
	session_id: int,
	reason: StringName = &""
) -> bool:
	if not _authorize(owner, session_id, &"clear_target"):
		return false
	_clear_target_internal(reason)
	return true


func _clear_target_internal(reason: StringName = &"") -> void:
	_target_actor_ref = null
	_has_fixed_target = false
	_target_failure_reason = reason
	_target_generation += 1
	_clear_route_state()
	if npc != null:
		npc.velocity.x = 0.0


func has_target() -> bool:
	return _has_fixed_target or get_target_actor() != null


func set_breadcrumb_provider(
	owner: Object,
	session_id: int,
	provider: Node
) -> bool:
	if not _authorize(owner, session_id, &"set_breadcrumb_provider"):
		return false
	if provider != null and not _provider_supports_trail(provider):
		_bind_breadcrumb_recorder(null)
		_last_failure_reason = &"invalid_breadcrumb_provider"
		return false
	_bind_breadcrumb_recorder(provider)
	return true


func clear_breadcrumb_provider(owner: Object, session_id: int) -> bool:
	if not _authorize(owner, session_id, &"clear_breadcrumb_provider"):
		return false
	_bind_breadcrumb_recorder(null)
	return true


func reset_for_context(
	requester: Object,
	reason: StringName = &"context_reset"
) -> bool:
	_cleanup_freed_owner()
	if requester == null or not is_instance_valid(requester):
		_reject_operation(&"reset_for_context", &"invalid_requester")
		return false
	if has_owner():
		_reject_operation(&"reset_for_context", &"context_reset_while_owned")
		return false
	_session_serial += 1
	_last_context_reset_reason = reason
	_invalidate_all_internal(reason, TraversalStatus.CANCELLED)
	return true


func cancel(owner: Object, session_id: int, reason: StringName) -> bool:
	if not _authorize(owner, session_id, &"cancel"):
		return false
	_cancel_internal(reason, true, TraversalStatus.CANCELLED)
	return true


func _cancel_internal(
	reason: StringName,
	clear_provider: bool,
	status: TraversalStatus
) -> void:
	if _transition_phase == TransitionPhase.EXECUTING_JUMP:
		_jump_diagnostic("jump aborted", String(reason))
	if npc != null:
		npc.velocity.x = 0.0
	_target_actor_ref = null
	_has_fixed_target = false
	_target_failure_reason = reason
	_clear_route_state()
	if clear_provider:
		_bind_breadcrumb_recorder(null)
	if _debug_overlay != null and is_instance_valid(_debug_overlay):
		_debug_overlay.visible = false
	if _air_ledge_assist_cast != null and is_instance_valid(_air_ledge_assist_cast):
		_air_ledge_assist_cast.enabled = false
	_last_result = _build_result(
		status,
		false,
		false,
		reason
	)


func _invalidate_all_internal(reason: StringName, status: TraversalStatus) -> void:
	_cancel_internal(reason, true, status)
	_owner_ref = null
	_active_session_id = 0
	_acquisition_reason = &""


func _get_owner() -> Object:
	if _owner_ref == null:
		return null
	var owner: Object = _owner_ref.get_ref()
	if owner == null or not is_instance_valid(owner):
		return null
	return owner


func _cleanup_freed_owner() -> void:
	if _owner_ref == null:
		return
	if _get_owner() != null:
		return
	_invalidate_all_internal(&"owner_freed", TraversalStatus.CANCELLED)
	_last_failure_reason = &"owner_freed"


func _authorize(owner: Object, session_id: int, operation: StringName) -> bool:
	_cleanup_freed_owner()
	var current_owner := _get_owner()
	if current_owner == null or _active_session_id <= 0:
		_reject_operation(operation, &"traversal_unowned")
		return false
	if owner == null or not is_instance_valid(owner) or current_owner != owner:
		_reject_operation(operation, &"wrong_owner")
		return false
	if session_id != _active_session_id:
		_reject_operation(operation, &"stale_session")
		return false
	return true


func _reject_operation(operation: StringName, reason: StringName) -> void:
	_last_rejected_operation = operation
	_last_rejected_reason = reason


func _build_rejected_result(reason: StringName) -> TraversalResult:
	var result := TraversalResult.new()
	result.status = TraversalStatus.SUPERSEDED
	result.navigation_failed = true
	result.reason = reason
	var target_position := _resolve_target_position()
	result.target_position = target_position if target_position != Vector2.INF else Vector2.ZERO
	return result


func _clear_route_state() -> void:
	_cancel_takeoff_anticipation()
	_active_traversal.clear()
	_transition_plan.clear()
	_failure_reposition_plan.clear()
	_transition_phase = TransitionPhase.FOLLOWING
	_committed_jump_elapsed = 0.0
	_committed_jump_was_airborne = false
	_takeoff_anticipation_elapsed = 0.0
	_clear_jump_abandonment()
	_reset_stuck_tracking()
	_hold_for_forward_hazard = false
	_clear_navigation_failure()


func _reset_route_for_target_change() -> void:
	_clear_route_state()
	_transition_recalculation_timer = 0.0
	_forward_floor_hazard_was_detected = false
	_last_forward_probe_direction = 0.0


func _ensure_breadcrumb_recorder() -> bool:
	if _recorder != null and is_instance_valid(_recorder):
		return true
	if _recorder != null:
		_bind_breadcrumb_recorder(null)
	return false


func _bind_breadcrumb_recorder(new_recorder: Node) -> void:
	if (
		new_recorder != null
		and _recorder != null
		and is_instance_valid(_recorder)
		and _recorder == new_recorder
	):
		return
	if new_recorder == null and _recorder == null:
		return
	_recorder = new_recorder
	_active_traversal.clear()
	_transition_plan.clear()
	_failure_reposition_plan.clear()
	_transition_phase = TransitionPhase.FOLLOWING
	_reset_stuck_tracking()
	_clear_navigation_failure()
	if _recorder != null:
		_last_completed_traversal_sequence = int(
			_recorder.call("get_latest_completed_traversal_sequence")
		)
	else:
		_last_completed_traversal_sequence = 0
	if _debug_overlay != null and is_instance_valid(_debug_overlay):
		_debug_overlay.configure(npc, _recorder)


func is_traversal_committed() -> bool:
	return (
		_transition_phase != TransitionPhase.FOLLOWING
		or not _transition_plan.is_empty()
		or not _failure_reposition_plan.is_empty()
	)


func has_pending_traversal() -> bool:
	if is_traversal_committed() or not _active_traversal.is_empty():
		return true
	if _recorder == null or not is_instance_valid(_recorder):
		return false
	if bool(_recorder.call("has_pending_traversal")):
		return true
	return (
		int(_recorder.call("get_latest_completed_traversal_sequence"))
		> _last_completed_traversal_sequence
	)


func is_recovering() -> bool:
	return _transition_phase in [
		TransitionPhase.REPOSITIONING_AFTER_FAILURE,
		TransitionPhase.STUCK_RECOVERY,
	]


func is_settled() -> bool:
	return can_release_target() and has_target() and _target_is_within_stop_distance()


func can_release_target() -> bool:
	return (
		npc != null
		and npc.is_on_floor()
		and not has_pending_traversal()
		and _transition_phase == TransitionPhase.FOLLOWING
		and _active_traversal.is_empty()
		and _transition_plan.is_empty()
		and _failure_reposition_plan.is_empty()
		and _stuck_seconds < stuck_retry_seconds
		and not _hold_for_forward_hazard
	)


func physics_update(
	owner: Object,
	session_id: int,
	delta: float,
	options: TraversalOptions = null
) -> TraversalResult:
	if not _authorize(owner, session_id, &"physics_update"):
		return _build_rejected_result(_last_rejected_reason)
	var physics_frame := Engine.get_physics_frames()
	if (
		_last_velocity_update_physics_frame == physics_frame
		and _last_velocity_update_session_id > 0
		and _last_velocity_update_session_id != session_id
	):
		_reject_operation(&"physics_update", &"owner_changed_during_physics_frame")
		return _build_rejected_result(&"owner_changed_during_physics_frame")
	_last_velocity_update_physics_frame = physics_frame
	_last_velocity_update_session_id = session_id
	if options != null:
		_active_options = options
	stop_distance = maxf(_active_options.desired_stop_distance, 0.0)
	_jump_cooldown = maxf(_jump_cooldown - delta, 0.0)
	_height_jump_cooldown = maxf(_height_jump_cooldown - delta, 0.0)
	_transition_recalculation_timer = maxf(_transition_recalculation_timer - delta, 0.0)
	_recorder_reacquire_timer = maxf(_recorder_reacquire_timer - delta, 0.0)
	_debug_overlay_refresh_timer = maxf(_debug_overlay_refresh_timer - delta, 0.0)
	if npc == null or machine == null:
		return _build_result(
			TraversalStatus.FAILED, false, false, &"character_not_bound", true
		)
	if not has_target():
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
		var missing_reason := _target_failure_reason if _target_failure_reason != &"" else &"target_missing"
		_clear_route_state()
		return _build_result(
			TraversalStatus.TARGET_INVALID, false, false, missing_reason, true
		)
	_ensure_breadcrumb_recorder()
	if _recorder == null:
		_active_traversal.clear()
	if not _target_is_valid():
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
		return _build_result(
			TraversalStatus.TARGET_INVALID, false, false, &"target_freed", true
		)
	_update_air_ledge_assist_cast()
	if _transition_phase == TransitionPhase.EXECUTING_JUMP:
		_update_debug_overlay()
		_process_committed_jump(delta)
		return _build_result(
			TraversalStatus.COMMITTED_JUMP, false, true, &"jump_committed"
		)
	if _recorder != null:
		_refresh_active_traversal()
	_update_debug_overlay()
	var breadcrumb := _get_current_route_breadcrumb()
	if breadcrumb.is_empty():
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
		return _build_result(
			TraversalStatus.FAILED, false, false, &"target_position_unavailable", true
		)
	var target_position: Vector2 = breadcrumb.get("position", npc.global_position)
	_clear_terminal_failure_if_target_changed(target_position)
	if _terminal_failure_reason != &"":
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
		return _build_result(
			TraversalStatus.REPEATED_FAILURE,
			false,
			false,
			_terminal_failure_reason,
			true
		)
	if _try_air_ledge_assist(target_position):
		return _build_result(
			TraversalStatus.COMMITTED_JUMP, false, true, &"air_ledge_assist"
		)
	var offset := target_position - npc.global_position
	var distance := offset.length()
	_update_stuck(distance, delta)
	if _complete_drop_traversal_if_reached(target_position):
		return _build_result(
			TraversalStatus.MOVING, false, not is_zero_approx(npc.velocity.x), &"drop_completed"
		)
	if _transition_phase == TransitionPhase.REPOSITIONING_AFTER_FAILURE:
		_process_failure_reposition(delta, distance)
		return _build_result(
			TraversalStatus.REPOSITIONING, false, true, &"repositioning_after_failure"
		)
	if _active_options.allow_jumps:
		_update_transition_plan(breadcrumb, target_position, offset)
	elif _transition_phase == TransitionPhase.APPROACHING_TRANSITION:
		_transition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		_hold_for_forward_hazard = false
	if _transition_phase == TransitionPhase.REPOSITIONING_AFTER_FAILURE:
		_process_failure_reposition(delta, distance)
		return _build_result(
			TraversalStatus.REPOSITIONING, false, true, &"repositioning_after_failure"
		)
	if _transition_phase == TransitionPhase.APPROACHING_TRANSITION:
		var takeoff_position: Vector2 = _transition_plan.get("takeoff_position", npc.global_position)
		var at_takeoff := (
			npc.is_on_floor()
			and npc.global_position.distance_to(takeoff_position) <= takeoff_position_tolerance
		)
		if at_takeoff:
			var takeoff_delay := maxf(takeoff_commit_delay_seconds, 0.0)
			_takeoff_anticipation_elapsed = minf(
				_takeoff_anticipation_elapsed + maxf(delta, 0.0),
				takeoff_delay
			)
			_preview_takeoff_anticipation(
				1.0 if takeoff_delay <= 0.0 else _takeoff_anticipation_elapsed / takeoff_delay
			)
			if _takeoff_anticipation_elapsed >= takeoff_delay:
				_jump_diagnostic("takeoff reached", "at %s" % takeoff_position)
				_execute_transition_jump()
				return _build_result(
					TraversalStatus.COMMITTED_JUMP, false, true, &"jump_started"
				)
		else:
			_takeoff_anticipation_elapsed = 0.0
			_cancel_takeoff_anticipation()
		_move_toward_x(takeoff_position.x, delta, takeoff_position_tolerance)
		return _build_result(
			TraversalStatus.APPROACHING_TRANSITION,
			false,
			not is_zero_approx(npc.velocity.x),
			&"approaching_takeoff"
		)
	if _hold_for_forward_hazard:
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
		if _active_options.allow_hard_recovery:
			_process_extreme_recovery(distance)
		if _terminal_failure_reason != &"":
			return _build_result(
				TraversalStatus.REPEATED_FAILURE,
				false,
				false,
				_terminal_failure_reason,
				true
			)
		var blocked_status := (
			TraversalStatus.NO_ROUTE
			if _last_failure_reason == &"no_route_found"
			else TraversalStatus.TEMPORARILY_BLOCKED
		)
		return _build_result(
			blocked_status,
			false,
			false,
			_last_failure_reason if _last_failure_reason != &"" else &"temporarily_blocked",
			blocked_status == TraversalStatus.NO_ROUTE
		)
	var horizontal_distance := absf(offset.x)
	var braking_distance := _get_braking_distance()
	var moving_toward_target := (
		not is_zero_approx(npc.velocity.x)
		and signf(npc.velocity.x) == signf(offset.x)
	)
	if horizontal_distance <= stop_distance or (
		moving_toward_target
		and horizontal_distance <= stop_distance + braking_distance
	):
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
	else:
		var direction := signf(offset.x)
		var speed_multiplier := (
			_get_speed_multiplier(absf(offset.x))
			* maxf(_active_options.movement_speed_multiplier, 0.0)
		)
		var target_speed := direction * machine.walk_speed * speed_multiplier
		npc.velocity.x = move_toward(npc.velocity.x, target_speed, horizontal_acceleration * delta)
		machine.face_x_direction(direction)
	if _active_options.allow_hard_recovery:
		_process_extreme_recovery(distance)
	var reached := horizontal_distance <= stop_distance
	return _build_result(
		TraversalStatus.SETTLED if reached and can_release_target() else TraversalStatus.MOVING,
		reached,
		not is_zero_approx(npc.velocity.x),
		&"target_reached" if reached else &"moving_to_target"
	)


func _update_transition_plan(
	breadcrumb: Dictionary,
	target_position: Vector2,
	offset: Vector2
) -> void:
	_hold_for_forward_hazard = false
	var direction := signf(offset.x)
	if is_zero_approx(direction):
		direction = 1.0
	if (
		not is_zero_approx(_last_forward_probe_direction)
		and direction != _last_forward_probe_direction
	):
		_forward_floor_hazard_was_detected = false
	_last_forward_probe_direction = direction
	var forward_floor := (
		_transition_probe.inspect_forward_floor(direction, absf(offset.x))
		if npc.is_on_floor()
		else {}
	)
	var floor_hazard := bool(forward_floor.get("floor_hazard", false))
	var hazard_became_urgent := floor_hazard and not _forward_floor_hazard_was_detected
	_forward_floor_hazard_was_detected = floor_hazard
	if _jump_is_temporarily_abandoned(target_position):
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_plan.clear()
		_hold_for_forward_hazard = floor_hazard or _last_failure_reason != &""
		return
	# While a trailed target is airborne, the newest published breadcrumb is the
	# grounded takeoff. Wait for the completed landing segment instead of
	# inventing a weak same-height jump toward that intentionally stale point.
	if (
		_active_traversal.is_empty()
		and _recorder != null
		and bool(_recorder.call("has_pending_traversal"))
	):
		_transition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		_hold_for_forward_hazard = floor_hazard
		return
	if _transition_recalculation_timer > 0.0 and not hazard_became_urgent:
		return
	_transition_recalculation_timer = transition_recalculation_seconds
	var local_probes := _transition_probe.inspect_local(direction)
	var breadcrumb_msec := int(breadcrumb.get("recorded_msec", -1))
	var is_active_completed_jump := (
		not _active_traversal.is_empty()
		and String(_active_traversal.get("traversal_type", "")) == "jump"
	)
	var route_started_jump := (
		bool(breadcrumb.get("jump_started", false))
		and (is_active_completed_jump or breadcrumb_msec != _last_jump_breadcrumb_msec)
	)
	var route_started_drop := bool(breadcrumb.get("drop_started", false))
	var target_is_above := (
		-offset.y >= minimum_jump_height_difference
		and _height_jump_cooldown <= 0.0
	)
	# A recorded drop remains authoritative. Normal horizontal following lets
	# gravity carry Mom over the same ledge instead of converting it into a jump.
	if route_started_drop and offset.y > 0.0:
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_plan.clear()
		return
	var local_transition_detected := (
		floor_hazard
		or bool(local_probes.get("chasm", false))
		or bool(local_probes.get("approaching_ledge", false))
		or bool(local_probes.get("short_obstacle", false))
		or bool(local_probes.get("raised_platform", false))
		or bool(local_probes.get("tall_wall", false))
	)
	var transition_needed := (
		route_started_jump
		or target_is_above
		or local_transition_detected
		or _stuck_seconds >= stuck_retry_seconds
	)
	if not transition_needed:
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_plan.clear()
		return
	var target_is_nearly_overhead := absf(offset.x) <= _transition_probe.body_half_size.x + landing_width_margin
	if bool(local_probes.get("ceiling_blocked", false)) and target_is_above and target_is_nearly_overhead:
		_jump_diagnostic("jump aborted", "solid ceiling blocks target; giving up")
		_hold_for_forward_hazard = floor_hazard
		_begin_failure_reposition(target_position, &"ceiling_blocked")
		return
	var height_difference := maxf(-offset.y, 0.0)
	var preferred_jump_velocity := (
		_get_jump_velocity(height_difference)
		if target_is_above or is_active_completed_jump
		else minimum_jump_velocity
	)
	var maximum_horizontal_speed := machine.walk_speed * maximum_speed_multiplier
	_transition_plan = _transition_probe.solve_transition(
		target_position,
		minimum_jump_velocity,
		preferred_jump_velocity,
		maximum_jump_velocity,
		maximum_horizontal_speed,
		maximum_jump_route_distance,
		machine.gravity,
		minimum_raised_jump_horizontal_speed
	)
	if _transition_plan.is_empty() and is_active_completed_jump:
		_transition_plan = _transition_probe.build_completed_traversal_fallback(
			target_position,
			preferred_jump_velocity,
			maximum_horizontal_speed,
			machine.gravity,
			minimum_raised_jump_horizontal_speed
		)
	if _transition_plan.is_empty():
		_jump_diagnostic("jump aborted", "no direct arc to %s; giving up" % target_position)
		_hold_for_forward_hazard = floor_hazard
		_begin_failure_reposition(target_position, &"no_route_found")
		return
	_transition_plan["route_jump"] = route_started_jump
	_transition_plan["breadcrumb_msec"] = breadcrumb_msec
	_transition_plan["accepted_msec"] = Time.get_ticks_msec()
	_takeoff_anticipation_elapsed = 0.0
	_transition_phase = TransitionPhase.APPROACHING_TRANSITION
	_jump_diagnostic(
		"jump plan accepted",
		"takeoff=%s landing=%s velocity=%s relaxed=%s" % [
			_transition_plan.get("takeoff_position", Vector2.ZERO),
			_transition_plan.get("landing_position", Vector2.ZERO),
			_transition_plan.get("velocity", Vector2.ZERO),
			_transition_plan.get("relaxed_completed_traversal", false),
		]
	)


func _execute_transition_jump() -> void:
	if _transition_plan.is_empty() or _jump_cooldown > 0.0:
		return
	var planned_velocity: Vector2 = _transition_plan.get("velocity", Vector2.ZERO)
	if planned_velocity.y >= 0.0:
		var failed_target: Vector2 = _transition_plan.get("landing_position", npc.global_position)
		_begin_failure_reposition(failed_target, &"invalid_jump_plan")
		return
	npc.velocity = planned_velocity
	_commit_takeoff_anticipation(planned_velocity.y)
	_jump_cooldown = jump_cooldown_seconds
	_height_jump_cooldown = height_jump_retry_seconds
	_reset_stuck_tracking()
	_committed_jump_elapsed = 0.0
	_committed_jump_was_airborne = false
	_transition_phase = TransitionPhase.EXECUTING_JUMP
	_jump_diagnostic("jump executed", "velocity=%s" % planned_velocity)


func _preview_takeoff_anticipation(progress: float) -> void:
	if (
		_airborne_animation_controller != null
		and is_instance_valid(_airborne_animation_controller)
		and _airborne_animation_controller.has_method("preview_grounded_takeoff")
	):
		_airborne_animation_controller.call("preview_grounded_takeoff", progress)


func _commit_takeoff_anticipation(vertical_velocity: float) -> void:
	if (
		_airborne_animation_controller != null
		and is_instance_valid(_airborne_animation_controller)
		and _airborne_animation_controller.has_method("commit_grounded_takeoff")
	):
		_airborne_animation_controller.call("commit_grounded_takeoff", vertical_velocity)


func _cancel_takeoff_anticipation() -> void:
	if (
		_airborne_animation_controller != null
		and is_instance_valid(_airborne_animation_controller)
		and _airborne_animation_controller.has_method("cancel_grounded_takeoff")
	):
		_airborne_animation_controller.call("cancel_grounded_takeoff")


func _process_committed_jump(delta: float) -> void:
	_committed_jump_elapsed += delta
	var intended_landing: Vector2 = _transition_plan.get("landing_position", npc.global_position)
	if _try_air_ledge_assist(intended_landing):
		_transition_plan["flight_time"] = float(_transition_plan.get("flight_time", 0.0)) + air_ledge_assist_extra_timeout
		return
	var planned_velocity: Vector2 = _transition_plan.get("velocity", npc.velocity)
	npc.velocity.x = move_toward(
		npc.velocity.x,
		planned_velocity.x,
		horizontal_acceleration * delta
	)
	if not npc.is_on_floor():
		_committed_jump_was_airborne = true
	var planned_flight_time := float(_transition_plan.get("flight_time", 0.0))
	if _committed_jump_was_airborne and npc.is_on_floor():
		_finish_committed_jump_landing()
		return
	if _committed_jump_was_airborne and _committed_jump_has_blocking_collision():
		_abort_committed_jump("blocking collision")
		return
	if _committed_jump_elapsed > planned_flight_time + committed_jump_timeout_margin:
		_abort_committed_jump("safety timeout")


func _finish_committed_jump_landing() -> void:
	var intended_landing: Vector2 = _transition_plan.get("landing_position", npc.global_position)
	var landing_offset := npc.global_position - intended_landing
	var reached_intended_platform := (
		absf(landing_offset.x) <= landing_horizontal_tolerance
		and absf(landing_offset.y) <= landing_vertical_tolerance
	)
	if not reached_intended_platform:
		_jump_diagnostic("jump aborted", "landed away from target offset=%s" % landing_offset)
		_begin_failure_reposition(intended_landing, &"landing_missed")
		_transition_plan.clear()
		_transition_recalculation_timer = transition_recalculation_seconds
		return
	_jump_diagnostic("landing success", "position=%s" % npc.global_position)
	_transition_plan.clear()
	_transition_recalculation_timer = transition_recalculation_seconds
	_mark_active_traversal_complete()
	_transition_phase = TransitionPhase.FOLLOWING
	_forward_floor_hazard_was_detected = false
	_clear_navigation_failure()


func _abort_committed_jump(reason: String) -> void:
	_jump_diagnostic("jump aborted", reason)
	var failed_landing: Vector2 = _transition_plan.get("landing_position", npc.global_position)
	_transition_plan.clear()
	_begin_failure_reposition(failed_landing, StringName(reason))
	_transition_recalculation_timer = transition_recalculation_seconds


func _committed_jump_has_blocking_collision() -> bool:
	var planned_velocity: Vector2 = _transition_plan.get("velocity", Vector2.ZERO)
	for collision_index in npc.get_slide_collision_count():
		var collision := npc.get_slide_collision(collision_index)
		if collision == null:
			continue
		var normal := collision.get_normal()
		if absf(normal.x) >= 0.55 and signf(planned_velocity.x) == -signf(normal.x):
			return true
	return false


func _refresh_active_traversal() -> void:
	var newest_value = _recorder.call(
		"get_next_completed_traversal_after",
		_last_completed_traversal_sequence
	)
	var newest_traversal: Dictionary = newest_value if newest_value is Dictionary else {}
	if newest_traversal.is_empty():
		return
	var newest_sequence := int(newest_traversal.get("sequence", 0))
	var active_sequence := int(_active_traversal.get("sequence", 0))
	if not _active_traversal.is_empty() and newest_sequence <= active_sequence:
		return
	_active_traversal = newest_traversal
	if newest_sequence != _abandoned_traversal_sequence:
		_clear_jump_abandonment()
	# A newer provider landing supersedes an older uncommitted route target.
	_transition_plan.clear()
	_failure_reposition_plan.clear()
	_transition_phase = TransitionPhase.FOLLOWING
	_transition_recalculation_timer = 0.0
	_forward_floor_hazard_was_detected = false


func _get_current_route_breadcrumb() -> Dictionary:
	if _has_fixed_target:
		return {"position": _fixed_target_position}
	if _active_traversal.is_empty():
		if _recorder != null:
			var recorded_value = _recorder.call("get_latest_breadcrumb")
			var recorded: Dictionary = recorded_value if recorded_value is Dictionary else {}
			if not recorded.is_empty():
				return recorded
		var direct_target := _resolve_target_position()
		return {"position": direct_target} if direct_target != Vector2.INF else {}
	var route_target := _active_traversal.duplicate(true)
	route_target["position"] = _active_traversal.get(
		"landing_position",
		_active_traversal.get("position", npc.global_position)
	)
	return route_target


func _mark_active_traversal_complete() -> void:
	if _active_traversal.is_empty():
		return
	_last_jump_breadcrumb_msec = int(_active_traversal.get("recorded_msec", _last_jump_breadcrumb_msec))
	_last_completed_traversal_sequence = maxi(
		_last_completed_traversal_sequence,
		int(_active_traversal.get("sequence", 0))
	)
	_active_traversal.clear()


func _complete_drop_traversal_if_reached(target_position: Vector2) -> bool:
	if _active_traversal.is_empty():
		return false
	if String(_active_traversal.get("traversal_type", "")) != "drop":
		return false
	if not npc.is_on_floor():
		return false
	var offset := npc.global_position - target_position
	if absf(offset.x) > landing_horizontal_tolerance or absf(offset.y) > landing_vertical_tolerance:
		return false
	_mark_active_traversal_complete()
	_transition_phase = TransitionPhase.FOLLOWING
	_transition_recalculation_timer = 0.0
	_forward_floor_hazard_was_detected = false
	_clear_navigation_failure()
	return true


func _begin_failure_reposition(
	failed_target: Vector2,
	failure_reason: StringName = &"transition_failed"
) -> void:
	_record_navigation_failure(failure_reason, failed_target)
	_jump_give_up_until_msec = Time.get_ticks_msec() + int(maxf(jump_give_up_seconds, 0.0) * 1000.0)
	_jump_give_up_target = failed_target
	_abandoned_traversal_sequence = -1
	if not _active_traversal.is_empty():
		_abandoned_traversal_sequence = int(_active_traversal.get("sequence", -1))
		_jump_diagnostic("jump abandoned", "completed traversal will not be retried")
		_mark_active_traversal_complete()
	var target_direction := signf(failed_target.x - npc.global_position.x)
	if is_zero_approx(target_direction):
		target_direction = 1.0
	_failure_reposition_sign *= -1.0
	_failure_reposition_plan = _transition_probe.find_nearby_same_height_spot(
		target_direction * _failure_reposition_sign,
		failure_reposition_step,
		failure_reposition_maximum_distance
	)
	_failure_reposition_elapsed = 0.0
	_transition_plan.clear()
	if _terminal_failure_reason != &"":
		_failure_reposition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		_hold_for_forward_hazard = true
		return
	if _failure_reposition_plan.is_empty():
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_recalculation_timer = transition_recalculation_seconds
		_hold_for_forward_hazard = true
		return
	_transition_phase = TransitionPhase.REPOSITIONING_AFTER_FAILURE
	_jump_diagnostic(
		"jump abandoned",
		"repositioning on same height to %s" % _failure_reposition_plan.get("position", npc.global_position)
	)


func _record_navigation_failure(reason: StringName, failed_target: Vector2) -> void:
	_consecutive_navigation_failures += 1
	_last_failure_reason = reason
	_failure_target_position = failed_target
	if _consecutive_navigation_failures >= maxi(maximum_navigation_failures, 1):
		_terminal_failure_reason = &"repeated_navigation_failure"


func _clear_navigation_failure() -> void:
	_consecutive_navigation_failures = 0
	_last_failure_reason = &""
	_terminal_failure_reason = &""
	_failure_target_position = Vector2.INF


func _clear_terminal_failure_if_target_changed(target_position: Vector2) -> void:
	if _failure_target_position == Vector2.INF:
		return
	if target_position.distance_to(_failure_target_position) <= jump_give_up_target_change_distance:
		return
	_clear_navigation_failure()
	_clear_jump_abandonment()
	_hold_for_forward_hazard = false
	_transition_recalculation_timer = 0.0


func _process_failure_reposition(delta: float, target_distance: float) -> void:
	if _failure_reposition_plan.is_empty():
		_transition_phase = TransitionPhase.FOLLOWING
		return
	_failure_reposition_elapsed += delta
	if _failure_reposition_elapsed >= failure_reposition_timeout:
		_failure_reposition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_recalculation_timer = transition_recalculation_seconds
		_process_extreme_recovery(target_distance)
		return
	var reposition_target: Vector2 = _failure_reposition_plan.get("position", npc.global_position)
	if npc.is_on_floor() and npc.global_position.distance_to(reposition_target) <= failure_reposition_tolerance:
		_failure_reposition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_recalculation_timer = transition_recalculation_seconds
		return
	_move_toward_x(reposition_target.x, delta, failure_reposition_tolerance)


func _jump_is_temporarily_abandoned(target_position: Vector2) -> bool:
	if _jump_give_up_until_msec < 0 or _jump_give_up_target == Vector2.INF:
		return false
	if not _active_traversal.is_empty():
		var active_sequence := int(_active_traversal.get("sequence", -1))
		if active_sequence != _abandoned_traversal_sequence:
			_clear_jump_abandonment()
			return false
	if target_position.distance_to(_jump_give_up_target) > jump_give_up_target_change_distance:
		_clear_jump_abandonment()
		return false
	if Time.get_ticks_msec() >= _jump_give_up_until_msec:
		_clear_jump_abandonment()
		return false
	return true


func _clear_jump_abandonment() -> void:
	_jump_give_up_until_msec = -1
	_jump_give_up_target = Vector2.INF
	_abandoned_traversal_sequence = -1


func _move_toward_x(target_x: float, delta: float, tolerance: float) -> void:
	var x_offset := target_x - npc.global_position.x
	var horizontal_distance := absf(x_offset)
	var braking_distance := _get_braking_distance()
	if horizontal_distance <= tolerance or horizontal_distance <= tolerance + braking_distance:
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
		return
	var direction := signf(x_offset)
	var speed_multiplier := (
		_get_speed_multiplier(horizontal_distance)
		* maxf(_active_options.movement_speed_multiplier, 0.0)
	)
	var target_speed := direction * machine.walk_speed * speed_multiplier
	npc.velocity.x = move_toward(npc.velocity.x, target_speed, horizontal_acceleration * delta)
	machine.face_x_direction(direction)


func _jump_diagnostic(event_name: String, detail: String) -> void:
	if not development_jump_diagnostics or not OS.is_debug_build():
		return
	var diagnostic_text := "%s: %s" % [event_name, detail]
	var now := Time.get_ticks_msec()
	if (
		diagnostic_text == _last_diagnostic_text
		and now - _last_diagnostic_msec < int(maxf(diagnostic_repeat_seconds, 0.0) * 1000.0)
	):
		return
	_last_diagnostic_text = diagnostic_text
	_last_diagnostic_msec = now
	print("NpcPlatformTraversal[%s] %s" % [npc.name if npc != null else "NPC", diagnostic_text])


func _update_air_ledge_assist_cast() -> void:
	if _air_ledge_assist_cast == null or not is_instance_valid(_air_ledge_assist_cast):
		return
	var airborne := not npc.is_on_floor()
	_air_ledge_assist_cast.enabled = air_ledge_assist_enabled and airborne
	if not airborne:
		_air_ledge_assist_used = false


func _try_air_ledge_assist(target_position: Vector2) -> bool:
	if not air_ledge_assist_enabled or _air_ledge_assist_used:
		return false
	if _air_ledge_assist_cast == null or not is_instance_valid(_air_ledge_assist_cast):
		return false
	if npc.is_on_floor() or npc.velocity.y < air_ledge_assist_minimum_fall_speed:
		return false
	var offset := target_position - npc.global_position
	if -offset.y < air_ledge_assist_minimum_target_height:
		return false
	_air_ledge_assist_cast.force_shapecast_update()
	if not _air_ledge_assist_cast.is_colliding():
		return false
	var direction := signf(offset.x)
	if is_zero_approx(direction):
		direction = signf(npc.velocity.x)
	if is_zero_approx(direction):
		direction = 1.0
	var required_velocity := _get_jump_velocity(maxf(-offset.y, minimum_jump_height_difference))
	npc.velocity.y = -minf(maxf(required_velocity, air_ledge_assist_jump_velocity), maximum_jump_velocity)
	npc.velocity.x = direction * minf(
		maxf(air_ledge_assist_horizontal_speed, absf(npc.velocity.x)),
		machine.walk_speed * maximum_speed_multiplier
	)
	_air_ledge_assist_used = true
	_jump_diagnostic("ledge assist", "edge contact; boost velocity=%s" % npc.velocity)
	return true


func _setup_debug_overlay() -> void:
	if not debug_enabled or npc == null or not has_owner():
		if _debug_overlay != null and is_instance_valid(_debug_overlay):
			_debug_overlay.visible = false
		return
	if not npc.is_node_ready():
		call_deferred("_setup_debug_overlay")
		return
	_debug_overlay = npc.get_node_or_null(
		"NpcPlatformTraversalDebugOverlay"
	) as NpcPlatformTraversalDebugOverlay
	if _debug_overlay == null:
		_debug_overlay = NpcPlatformTraversalDebugOverlay.new()
		_debug_overlay.name = "NpcPlatformTraversalDebugOverlay"
		npc.add_child(_debug_overlay)
	_debug_overlay.maximum_breadcrumbs = debug_breadcrumb_count
	_debug_overlay.configure(npc, _recorder)
	_debug_overlay.visible = debug_enabled


func _update_debug_overlay() -> void:
	if not debug_enabled:
		if _debug_overlay != null and is_instance_valid(_debug_overlay):
			_debug_overlay.visible = false
		return
	if _debug_overlay == null or not is_instance_valid(_debug_overlay):
		_setup_debug_overlay()
	if _debug_overlay == null or not is_instance_valid(_debug_overlay):
		return
	_debug_overlay.visible = true
	if _debug_overlay_refresh_timer > 0.0:
		return
	_debug_overlay_refresh_timer = maxf(debug_refresh_seconds, 0.05)
	var debug_target := Vector2.ZERO
	var target_valid := false
	if not _active_traversal.is_empty():
		var active_route_target := _get_current_route_breadcrumb()
		debug_target = active_route_target.get("position", Vector2.ZERO)
		target_valid = true
	elif _recorder != null:
		var latest_value = _recorder.call("get_latest_breadcrumb")
		var latest: Dictionary = latest_value if latest_value is Dictionary else {}
		if not latest.is_empty():
			debug_target = latest.get("position", Vector2.ZERO)
			target_valid = true
	var phase_names := TransitionPhase.keys()
	var phase_text := String(phase_names[int(_transition_phase)])
	_debug_overlay.update_state(
		debug_target,
		target_valid,
		_active_traversal,
		_transition_plan,
		_failure_reposition_plan,
		_jump_give_up_target,
		phase_text,
		machine.gravity
	)


func _process_extreme_recovery(distance: float) -> void:
	if (
		_active_options.allow_hard_recovery
		and _recorder != null
		and distance >= extreme_recovery_distance
		and _stuck_seconds >= stuck_recovery_seconds
		and (
			not hard_recovery_requires_offscreen
			or not _is_visible_to_camera()
		)
	):
		_transition_phase = TransitionPhase.STUCK_RECOVERY
		var safe_value = _recorder.call("get_recent_safe_floor_breadcrumb")
		var safe: Dictionary = safe_value if safe_value is Dictionary else {}
		if not safe.is_empty():
			npc.global_position = safe.get("position", npc.global_position)
			npc.velocity = Vector2.ZERO
			_reset_stuck_tracking()
			_clear_navigation_failure()
			_transition_phase = TransitionPhase.FOLLOWING
			_transition_plan.clear()
			if OS.is_debug_build():
				print("NPC platform traversal recovered to a safe breadcrumb: ", npc.name)


func _update_stuck(distance: float, delta: float) -> void:
	if distance <= stop_distance:
		_reset_stuck_tracking(distance)
		return
	if is_inf(_last_distance):
		_last_distance = distance
		_stuck_progress_elapsed = 0.0
		return
	_stuck_progress_elapsed += delta
	if _stuck_progress_elapsed < maxf(stuck_progress_sample_seconds, 0.1):
		return
	var sample_elapsed := _stuck_progress_elapsed
	var progress := _last_distance - distance
	_last_distance = distance
	_stuck_progress_elapsed = 0.0
	if progress >= stuck_minimum_progress_distance:
		_stuck_seconds = 0.0
	else:
		_stuck_seconds += sample_elapsed


func _reset_stuck_tracking(distance: float = INF) -> void:
	_last_distance = distance
	_stuck_seconds = 0.0
	_stuck_progress_elapsed = 0.0


func _get_speed_multiplier(horizontal_distance: float) -> float:
	var ramp_width := maxf(full_speed_distance - speed_ramp_start_distance, 0.001)
	var weight := clampf(
		(horizontal_distance - speed_ramp_start_distance) / ramp_width,
		0.0,
		1.0
	)
	return lerpf(minimum_speed_multiplier, maximum_speed_multiplier, weight)


func _get_braking_distance() -> float:
	var deceleration := maxf(horizontal_deceleration, 0.001)
	return (npc.velocity.x * npc.velocity.x) / (2.0 * deceleration)


func _get_jump_velocity(height_difference: float) -> float:
	# v = sqrt(2gh): reach the target height, then rise by the configured
	# overshoot so the follower approaches a platform while descending.
	var clamped_height := clampf(
		height_difference,
		minimum_jump_height_difference,
		maximum_jump_height_difference
	)
	var desired_rise := clamped_height + maxf(jump_height_overshoot, 0.0)
	var gravity_strength := maxf(machine.gravity if machine != null else 1200.0, 0.001)
	var calculated_velocity := sqrt(2.0 * gravity_strength * desired_rise)
	calculated_velocity *= maxf(jump_velocity_safety_multiplier, 1.0)
	return clampf(
		calculated_velocity,
		minimum_jump_velocity,
		maximum_jump_velocity
	)


func _is_visible_to_camera() -> bool:
	var camera := npc.get_viewport().get_camera_2d()
	if camera == null:
		return true
	var screen_position := npc.get_canvas_transform() * npc.global_position
	return npc.get_viewport_rect().grow(160.0).has_point(screen_position)


func _provider_supports_trail(provider: Node) -> bool:
	if provider == null:
		return false
	for method_name in [
		&"get_latest_completed_traversal_sequence",
		&"has_pending_traversal",
		&"get_next_completed_traversal_after",
		&"get_latest_breadcrumb",
		&"get_recent_safe_floor_breadcrumb",
	]:
		if not provider.has_method(method_name):
			return false
	return true


func get_last_result() -> TraversalResult:
	return _last_result


func get_debug_snapshot() -> Dictionary:
	_cleanup_freed_owner()
	var current_owner := _get_owner()
	return {
		"owner_description": _describe_owner(current_owner),
		"session_id": _active_session_id,
		"session_serial": _session_serial,
		"acquisition_reason": _acquisition_reason,
		"owner_valid": current_owner != null,
		"last_context_reset_reason": _last_context_reset_reason,
		"last_rejected_operation": _last_rejected_operation,
		"last_rejected_reason": _last_rejected_reason,
		"has_target": has_target(),
		"target_type": (
			"fixed_position"
			if _has_fixed_target
			else ("actor" if get_target_actor() != null else "none")
		),
		"target_actor": get_target_actor(),
		"target_position": _resolve_target_position(),
		"target_generation": _target_generation,
		"status": _last_result.status,
		"status_name": TraversalStatus.keys()[int(_last_result.status)],
		"reason": _last_result.reason,
		"failure_reason": (
			_terminal_failure_reason
			if _terminal_failure_reason != &""
			else _last_failure_reason
		),
		"consecutive_navigation_failures": _consecutive_navigation_failures,
		"phase": TransitionPhase.keys()[int(_transition_phase)],
		"pending_traversal": has_pending_traversal(),
		"committed": is_traversal_committed(),
		"recovering": is_recovering(),
		"settled": is_settled(),
		"breadcrumb_provider_valid": _recorder != null and is_instance_valid(_recorder),
	}


func _describe_owner(owner: Object) -> String:
	if owner == null or not is_instance_valid(owner):
		return "none"
	var owner_node := owner as Node
	if owner_node != null:
		return "%s:%s" % [owner_node.get_class(), owner_node.name]
	return owner.get_class()


func _target_is_valid() -> bool:
	return _has_fixed_target or get_target_actor() != null


func _resolve_target_position() -> Vector2:
	if _has_fixed_target:
		return _fixed_target_position
	var actor := get_target_actor()
	return actor.global_position if actor != null else Vector2.INF


func _target_is_within_stop_distance() -> bool:
	if npc == null:
		return false
	var target_position := _resolve_target_position()
	if target_position == Vector2.INF:
		return false
	return (
		absf(target_position.x - npc.global_position.x) <= stop_distance
		and absf(target_position.y - npc.global_position.y) <= landing_vertical_tolerance
	)


func _build_result(
	status: TraversalStatus,
	target_reached: bool,
	movement_active: bool,
	reason: StringName,
	navigation_failed: bool = false
) -> TraversalResult:
	var result := TraversalResult.new()
	result.status = status
	result.target_reached = target_reached
	result.movement_active = movement_active
	result.traversal_committed = is_traversal_committed()
	result.recovery_active = is_recovering()
	result.navigation_failed = navigation_failed
	result.reason = reason
	var target_position := _resolve_target_position()
	result.target_position = target_position if target_position != Vector2.INF else Vector2.ZERO
	_last_result = result
	return result
