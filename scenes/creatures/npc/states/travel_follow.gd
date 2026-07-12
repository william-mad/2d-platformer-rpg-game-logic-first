class_name NpcStateTravelFollow
extends NpcState

enum TransitionPhase {
	FOLLOWING,
	APPROACHING_TRANSITION,
	EXECUTING_JUMP,
	REPOSITIONING_AFTER_FAILURE,
	STUCK_RECOVERY,
}

@export var stop_distance: float = 64.0
@export_group("Distance-based Speed")
@export var minimum_speed_multiplier: float = 4.0
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
@export var development_jump_diagnostics: bool = true
@export var diagnostic_repeat_seconds: float = 1.5

@export_group("Visual Debug")
@export var show_follow_debug_paths: bool = true
@export_range(2, 8, 1) var debug_breadcrumb_count: int = 2

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

var _recorder: PlayerBreadcrumbRecorder
var _last_distance: float = INF
var _stuck_seconds: float = 0.0
var _jump_cooldown: float = 0.0
var _height_jump_cooldown: float = 0.0
var _last_jump_breadcrumb_msec: int = -1
var _transition_probe := NpcPlatformTransitionProbe.new()
var _transition_phase: TransitionPhase = TransitionPhase.FOLLOWING
var _transition_plan: Dictionary = {}
var _transition_recalculation_timer: float = 0.0
var _committed_jump_elapsed: float = 0.0
var _committed_jump_was_airborne: bool = false
var _traversal_sequence_initialized: bool = false
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
var _debug_overlay: NpcFollowDebugOverlay
var _air_ledge_assist_cast: ShapeCast2D
var _air_ledge_assist_used: bool = false


func enter() -> void:
	super.enter()
	_recorder = machine.get_tree().get_first_node_in_group(&"player_breadcrumb_recorder") as PlayerBreadcrumbRecorder
	_last_distance = INF
	_stuck_seconds = 0.0
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
	_air_ledge_assist_used = false
	_transition_phase = TransitionPhase.FOLLOWING
	_transition_plan.clear()
	_transition_recalculation_timer = 0.0
	_committed_jump_elapsed = 0.0
	_committed_jump_was_airborne = false
	_failure_reposition_plan.clear()
	_failure_reposition_elapsed = 0.0
	if not _traversal_sequence_initialized and _recorder != null:
		_last_completed_traversal_sequence = _recorder.get_latest_completed_traversal_sequence()
		_traversal_sequence_initialized = true
	_setup_debug_overlay()


func exit() -> void:
	if _transition_phase == TransitionPhase.EXECUTING_JUMP:
		_jump_diagnostic("jump aborted", "state interrupted")
	_transition_plan.clear()
	_failure_reposition_plan.clear()
	_transition_phase = TransitionPhase.FOLLOWING
	if _debug_overlay != null and is_instance_valid(_debug_overlay):
		_debug_overlay.visible = false
	if _air_ledge_assist_cast != null and is_instance_valid(_air_ledge_assist_cast):
		_air_ledge_assist_cast.enabled = false


func physics_process(delta: float) -> NpcState:
	_jump_cooldown = maxf(_jump_cooldown - delta, 0.0)
	_height_jump_cooldown = maxf(_height_jump_cooldown - delta, 0.0)
	_transition_recalculation_timer = maxf(_transition_recalculation_timer - delta, 0.0)
	if _recorder == null or not is_instance_valid(_recorder):
		return next_state
	_update_air_ledge_assist_cast()
	_update_debug_overlay()
	if _transition_phase == TransitionPhase.EXECUTING_JUMP:
		_process_committed_jump(delta)
		return next_state
	_refresh_active_traversal()
	var breadcrumb := _get_current_route_breadcrumb()
	if breadcrumb.is_empty():
		return next_state
	var target_position: Vector2 = breadcrumb.get("position", npc.global_position)
	if _try_air_ledge_assist(target_position):
		return next_state
	var offset := target_position - npc.global_position
	var distance := offset.length()
	_update_stuck(distance, delta)
	if _complete_drop_traversal_if_reached(target_position):
		return next_state
	if _transition_phase == TransitionPhase.REPOSITIONING_AFTER_FAILURE:
		_process_failure_reposition(delta, distance)
		return next_state
	_update_transition_plan(breadcrumb, target_position, offset)
	if _transition_phase == TransitionPhase.APPROACHING_TRANSITION:
		var takeoff_position: Vector2 = _transition_plan.get("takeoff_position", npc.global_position)
		var plan_age_seconds := (
			Time.get_ticks_msec() - int(_transition_plan.get("accepted_msec", 0))
		) / 1000.0
		if (
			npc.is_on_floor()
			and npc.global_position.distance_to(takeoff_position) <= takeoff_position_tolerance
			and plan_age_seconds >= takeoff_commit_delay_seconds
		):
			_jump_diagnostic("takeoff reached", "at %s" % takeoff_position)
			_execute_transition_jump()
			return next_state
		_move_toward_x(takeoff_position.x, delta, takeoff_position_tolerance)
		return next_state
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
		var speed_multiplier := _get_speed_multiplier(absf(offset.x))
		var target_speed := direction * machine.walk_speed * speed_multiplier
		npc.velocity.x = move_toward(npc.velocity.x, target_speed, horizontal_acceleration * delta)
		face_x_direction(direction)
	_process_extreme_recovery(distance)
	return next_state


func _update_transition_plan(
	breadcrumb: Dictionary,
	target_position: Vector2,
	offset: Vector2
) -> void:
	# While the player is airborne, the newest published breadcrumb is the
	# grounded takeoff. Wait for the completed landing segment instead of
	# inventing a weak same-height jump toward that intentionally stale point.
	if _active_traversal.is_empty() and _recorder.has_pending_traversal():
		_transition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		return
	if _transition_recalculation_timer > 0.0:
		return
	_transition_recalculation_timer = transition_recalculation_seconds
	var direction := signf(offset.x)
	if is_zero_approx(direction):
		direction = 1.0
	var local_probes := _transition_probe.inspect_local(direction)
	if _jump_is_temporarily_abandoned(target_position):
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_plan.clear()
		return
	var breadcrumb_msec := int(breadcrumb.get("recorded_msec", -1))
	var is_active_completed_jump := (
		not _active_traversal.is_empty()
		and String(_active_traversal.get("traversal_type", "")) == "jump"
	)
	var player_started_jump := (
		bool(breadcrumb.get("jump_started", false))
		and (is_active_completed_jump or breadcrumb_msec != _last_jump_breadcrumb_msec)
	)
	var player_started_drop := bool(breadcrumb.get("drop_started", false))
	var target_is_above := (
		-offset.y >= minimum_jump_height_difference
		and _height_jump_cooldown <= 0.0
	)
	# A recorded drop remains authoritative. Normal horizontal following lets
	# gravity carry Mom over the same ledge instead of converting it into a jump.
	if player_started_drop and offset.y > 0.0:
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_plan.clear()
		return
	var local_transition_detected := (
		bool(local_probes.get("chasm", false))
		or bool(local_probes.get("approaching_ledge", false))
		or bool(local_probes.get("short_obstacle", false))
		or bool(local_probes.get("raised_platform", false))
		or bool(local_probes.get("tall_wall", false))
	)
	var transition_needed := (
		player_started_jump
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
		_begin_failure_reposition(target_position)
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
		_begin_failure_reposition(target_position)
		return
	_transition_plan["route_jump"] = player_started_jump
	_transition_plan["breadcrumb_msec"] = breadcrumb_msec
	_transition_plan["accepted_msec"] = Time.get_ticks_msec()
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
		_begin_failure_reposition(failed_target)
		return
	npc.velocity = planned_velocity
	_jump_cooldown = jump_cooldown_seconds
	_height_jump_cooldown = height_jump_retry_seconds
	_stuck_seconds = 0.0
	_committed_jump_elapsed = 0.0
	_committed_jump_was_airborne = false
	_transition_phase = TransitionPhase.EXECUTING_JUMP
	_jump_diagnostic("jump executed", "velocity=%s" % planned_velocity)


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
		_begin_failure_reposition(intended_landing)
		_transition_plan.clear()
		_transition_recalculation_timer = transition_recalculation_seconds
		return
	_jump_diagnostic("landing success", "position=%s" % npc.global_position)
	_transition_plan.clear()
	_transition_recalculation_timer = transition_recalculation_seconds
	_mark_active_traversal_complete()
	_transition_phase = TransitionPhase.FOLLOWING


func _abort_committed_jump(reason: String) -> void:
	_jump_diagnostic("jump aborted", reason)
	var failed_landing: Vector2 = _transition_plan.get("landing_position", npc.global_position)
	_transition_plan.clear()
	_begin_failure_reposition(failed_landing)
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
	var newest_traversal := _recorder.get_next_completed_traversal_after(
		_last_completed_traversal_sequence
	)
	if newest_traversal.is_empty():
		return
	var newest_sequence := int(newest_traversal.get("sequence", 0))
	var active_sequence := int(_active_traversal.get("sequence", 0))
	if not _active_traversal.is_empty() and newest_sequence <= active_sequence:
		return
	_active_traversal = newest_traversal
	# A newer player landing supersedes an older uncommitted route target.
	_transition_plan.clear()
	_failure_reposition_plan.clear()
	_transition_phase = TransitionPhase.FOLLOWING
	_transition_recalculation_timer = 0.0


func _get_current_route_breadcrumb() -> Dictionary:
	if _active_traversal.is_empty():
		return _recorder.get_latest_breadcrumb()
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
	return true


func _begin_failure_reposition(failed_target: Vector2) -> void:
	_jump_give_up_until_msec = Time.get_ticks_msec() + int(maxf(jump_give_up_seconds, 0.0) * 1000.0)
	_jump_give_up_target = failed_target
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
	if _failure_reposition_plan.is_empty():
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_recalculation_timer = transition_recalculation_seconds
		return
	_transition_phase = TransitionPhase.REPOSITIONING_AFTER_FAILURE
	_jump_diagnostic(
		"jump abandoned",
		"repositioning on same height to %s" % _failure_reposition_plan.get("position", npc.global_position)
	)


func _process_failure_reposition(delta: float, player_distance: float) -> void:
	if _failure_reposition_plan.is_empty():
		_transition_phase = TransitionPhase.FOLLOWING
		return
	_failure_reposition_elapsed += delta
	if _failure_reposition_elapsed >= failure_reposition_timeout:
		_failure_reposition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_recalculation_timer = transition_recalculation_seconds
		_process_extreme_recovery(player_distance)
		return
	var reposition_target: Vector2 = _failure_reposition_plan.get("position", npc.global_position)
	if npc.is_on_floor() and npc.global_position.distance_to(reposition_target) <= failure_reposition_tolerance:
		_failure_reposition_plan.clear()
		_transition_phase = TransitionPhase.FOLLOWING
		_transition_recalculation_timer = transition_recalculation_seconds
		return
	_move_toward_x(reposition_target.x, delta, failure_reposition_tolerance)


func _jump_is_temporarily_abandoned(target_position: Vector2) -> bool:
	if not _active_traversal.is_empty():
		var active_sequence := int(_active_traversal.get("sequence", -1))
		if active_sequence != _abandoned_traversal_sequence:
			return false
	if target_position.distance_to(_jump_give_up_target) <= jump_give_up_target_change_distance:
		return true
	if Time.get_ticks_msec() >= _jump_give_up_until_msec:
		return false
	return true


func _move_toward_x(target_x: float, delta: float, tolerance: float) -> void:
	var x_offset := target_x - npc.global_position.x
	var horizontal_distance := absf(x_offset)
	var braking_distance := _get_braking_distance()
	if horizontal_distance <= tolerance or horizontal_distance <= tolerance + braking_distance:
		npc.velocity.x = move_toward(npc.velocity.x, 0.0, horizontal_deceleration * delta)
		return
	var direction := signf(x_offset)
	var speed_multiplier := _get_speed_multiplier(horizontal_distance)
	var target_speed := direction * machine.walk_speed * speed_multiplier
	npc.velocity.x = move_toward(npc.velocity.x, target_speed, horizontal_acceleration * delta)
	face_x_direction(direction)


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
	print("TravelFollow[%s] %s" % [npc.name if npc != null else "NPC", diagnostic_text])


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
	if npc == null:
		return
	_debug_overlay = npc.get_node_or_null("TravelFollowDebugOverlay") as NpcFollowDebugOverlay
	if _debug_overlay == null:
		_debug_overlay = NpcFollowDebugOverlay.new()
		_debug_overlay.name = "TravelFollowDebugOverlay"
		npc.add_child(_debug_overlay)
	_debug_overlay.maximum_breadcrumbs = debug_breadcrumb_count
	_debug_overlay.configure(npc, _recorder)
	_debug_overlay.visible = show_follow_debug_paths


func _update_debug_overlay() -> void:
	if _debug_overlay == null or not is_instance_valid(_debug_overlay):
		return
	_debug_overlay.visible = show_follow_debug_paths
	if not show_follow_debug_paths:
		return
	var debug_target := Vector2.ZERO
	var target_valid := false
	if not _active_traversal.is_empty():
		var active_route_target := _get_current_route_breadcrumb()
		debug_target = active_route_target.get("position", Vector2.ZERO)
		target_valid = true
	elif _recorder != null:
		var latest := _recorder.get_latest_breadcrumb()
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
	if distance >= extreme_recovery_distance and _stuck_seconds >= stuck_recovery_seconds and not _is_visible_to_camera():
		_transition_phase = TransitionPhase.STUCK_RECOVERY
		var safe := _recorder.get_recent_safe_floor_breadcrumb()
		if not safe.is_empty():
			npc.global_position = safe.get("position", npc.global_position)
			npc.velocity = Vector2.ZERO
			_stuck_seconds = 0.0
			_transition_phase = TransitionPhase.FOLLOWING
			_transition_plan.clear()
			if OS.is_debug_build():
				print("Travel companion recovered to a safe breadcrumb: ", npc.name)


func _update_stuck(distance: float, delta: float) -> void:
	if distance + 8.0 < _last_distance:
		_stuck_seconds = 0.0
	else:
		_stuck_seconds += delta
	_last_distance = distance


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
