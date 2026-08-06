class_name MagicLessonSpot extends Node2D

signal lesson_invitation_started(mom: Node2D, player: Node2D)
signal lesson_started(mom: Node2D, player: Node2D)
signal lesson_completed(mom: Node2D, player: Node2D)
signal lesson_score_finalized(mom: Node2D, player: Node2D, score: float, result: Dictionary)
signal lesson_cancelled(reason: StringName)
signal lesson_declined(mom: Node2D, player: Node2D)

const STATE_IDLE := &"idle"
const STATE_INVITING := &"inviting"
const STATE_RUNNING := &"running"
const STATE_COMPLETED := &"completed"
const STATE_DECLINED := &"declined"
const STATE_CANCELLED := &"cancelled"
const STATE_FAILED := &"failed"

@export var spot_id: StringName = &"mom_magic_lesson"
@export var world_definition: NpcSpotDefinition
@export var lesson_enabled: bool = true
@export var lesson_id: StringName = &"mom_magic_lesson"
@export_range(0.5, 120.0, 0.1, "suffix:s") var lesson_duration_seconds: float = 6.0
@export_range(0.05, 24.0, 0.05, "suffix:h") var fallback_lesson_game_hours: float = 1.0
@export_range(0.0, 10000.0, 0.1, "suffix:/h") var lesson_progress_per_game_hour: float = 100.0
@export_range(0.0, 10000.0, 0.1) var lesson_progress_max: float = 100.0
@export_range(0.0, 20.0, 0.01) var lesson_progress_multiplier: float = 1.0
@export_range(0.5, 60.0, 0.1, "suffix:s") var prompt_timeout_seconds: float = 20.0
@export var prompt_title: String = "Study magic with Mom?"
@export var prompt_options: PackedStringArray = ["Yes", "Not now"]
@export var mom_marker_path: NodePath = NodePath("MomLessonPosition")
@export var player_marker_path: NodePath = NodePath("PlayerLessonPosition")
@export var lesson_zone_half_extents: Vector2 = Vector2(256.0, 88.0)
@export var require_player_in_lesson_zone: bool = true
@export var lock_player_during_lesson: bool = false
@export var label_prefix: String = "Magic Lesson"
@export var show_owner_debug_label: bool = true
@export var ready_color: Color = Color(0.18, 0.82, 0.28, 0.46)
@export var busy_color: Color = Color(0.95, 0.12, 0.08, 0.54)
@export var unavailable_color: Color = Color(0.45, 0.45, 0.45, 0.32)
@export var player_reward_meta: StringName = &"magic_xp"
@export var player_reward_amount: float = 1.0
@export var mom_reward_delta: Dictionary = {
	"trust": 2.0,
	"boredom": -8.0,
}
@export var mark_spot_unavailable_after_attempt: bool = true
@export_group("Interactive Activity")
@export var interactive_activity_definitions: Array[InteractiveActivityDefinition] = []
@export var interactive_activity_launch_options: InteractiveActivityLaunchOptions
@export var interactive_activity_host_scene: PackedScene = preload(
	"res://scenes/activities/interactive_activity_host.tscn"
)
@export var interactive_presentation_parent_path: NodePath
@export var interactive_world_anchor_path: NodePath

var state: StringName = STATE_IDLE
var active_mom: Node2D
var active_player: Node2D
var lesson_timer: float = 0.0
var lesson_progress: float = 0.0
var availability_value: float = 0.0
var last_lesson_result: Dictionary = {}
var player_action_mode: StringName = &""
var reward_applied: bool = false
var active_action_session_id: String = ""
var active_mom_id: String = ""
var completed_day: int = -1
var skipped_day: int = -1
var interactive_activity_runner: InteractiveActivityRunner
var interactive_activity_active: bool = false
var zone_visual: Polygon2D
var label: Label


func _ready() -> void:
	add_to_group("magic_lesson_spot")
	if world_definition != null and spot_id == &"":
		spot_id = world_definition.spot_id
	_ensure_visual_nodes()
	_setup_lesson_state_values()
	if not lesson_enabled:
		_register_live_spot()
		_breadcrumb("magic_lesson:disabled_ready", String(spot_id))
		_update_visual()
		set_process(false)
		return
	if _magic_lesson_disabled():
		_breadcrumb("magic_lesson:disabled_ready", String(spot_id))
		_update_visual()
		set_process(false)
		return
	_register_live_spot()
	_update_visual()


func _exit_tree() -> void:
	if state == STATE_RUNNING and OS.is_debug_build():
		print("Magic lesson controller unloaded resumably: npc=%s session=%s phase=running" % [
			active_mom_id, active_action_session_id
		])
	_shutdown_interactive_activity_local(&"lesson_scene_unloaded")
	_unlock_participants()
	_unregister_live_spot()


func get_invitation_animation_name() -> StringName:
	if world_definition == null:
		return &""
	return world_definition.routine_animation_name


func _process(delta: float) -> void:
	if _magic_lesson_disabled():
		cancel_lesson(&"debug_disabled")
		set_process(false)
		return

	if state not in [STATE_INVITING, STATE_RUNNING]:
		return
	if state == STATE_INVITING:
		if not _lesson_schedule_is_active():
			cancel_lesson(&"schedule_ended")
			return
		if not _participants_valid():
			cancel_lesson(&"invalid_participant")
			return
		return

	if not _participants_valid():
		cancel_lesson(&"invalid_participant")
		return

	if not _lesson_schedule_is_active():
		complete_lesson()
		return

	_hold_participants()
	lesson_timer -= delta
	if _schedule_fallback_timer_is_done():
		complete_lesson()
		return

	if _participants_are_counting_progress():
		_apply_lesson_progress(delta)
	else:
		_update_visual()


func can_start_lesson(mom: Node2D, player: Node2D) -> bool:
	if _magic_lesson_disabled():
		_breadcrumb("magic_lesson:can_start_disabled", String(spot_id))
		return false
	if mom == null or player == null:
		return false
	if not is_instance_valid(mom) or not is_instance_valid(player):
		return false
	if state == STATE_INVITING or state == STATE_RUNNING:
		return mom == active_mom and player == active_player
	if _attempt_already_used_today():
		return false
	if not _world_spot_is_available():
		return false

	return mom.is_inside_tree() and player.is_inside_tree() and is_inside_tree()


func begin_invitation(mom: Node2D, player: Node2D) -> bool:
	var invitation_reason := _validate_invitation_start(mom, player)
	if not invitation_reason.is_empty():
		_log_lesson_transition(String(state), "inviting", false, invitation_reason)
		return false
	if state == STATE_INVITING and mom == active_mom and player == active_player:
		return true

	var interactor := _get_player_prompt_interactor(player)
	if interactor == null or not interactor.has_method("show_npc_prompt"):
		_log_lesson_transition(String(state), "inviting", false, "prompt_interactor_missing")
		return false

	active_mom = mom
	active_player = player
	var machine := mom.get_node_or_null("NpcStateMachine")
	active_action_session_id = (
		String(machine.call("get_active_action_session_id"))
		if machine != null and machine.has_method("get_active_action_session_id")
		else ""
	)
	active_mom_id = _get_npc_id(mom)
	if active_action_session_id.is_empty() or active_mom_id.is_empty():
		_log_lesson_transition(String(state), "inviting", false, "lesson_identity_missing")
		_clear_participants()
		state = STATE_IDLE
		return false
	state = STATE_INVITING
	reward_applied = false
	lesson_timer = 0.0

	var shown := bool(interactor.call(
		"show_npc_prompt",
		mom,
		lesson_id,
		prompt_title,
		prompt_options,
		self,
		&"accept_lesson",
		&"decline_lesson",
		prompt_timeout_seconds
	))
	if not shown:
		_clear_participants()
		state = STATE_IDLE
		return false

	lesson_invitation_started.emit(mom, player)
	return true


func accept_lesson(mom: Node2D, player: Node2D, _prompt_id: StringName = &"") -> bool:
	if state != STATE_INVITING:
		return false
	if mom != active_mom or player != active_player:
		return false
	var handoff_result := _transition_activity({
		"expected_lesson_phases": ["inviting", "accepted"],
		"lesson_phase": "handoff",
		"last_total_hours": _get_current_total_hours(),
	})
	if not bool(handoff_result.get("accepted", false)):
		_log_lesson_transition("inviting", "handoff", false, String(handoff_result.get(
			"reason", "handoff_rejected"
		)))
		return false
	var start_result := start_lesson(mom, player, active_action_session_id)
	return bool(start_result.get("accepted", false))


func decline_lesson(mom: Node2D, player: Node2D, _prompt_id: StringName = &"") -> void:
	if state != STATE_INVITING:
		return
	if mom != active_mom or player != active_player:
		return

	if not _terminal_session_is_current(active_action_session_id):
		_log_lesson_transition("inviting", "declined", false, "stale_terminal_session")
		return
	if not _finish_scheduled_activity_to_saved_origin(active_action_session_id):
		return
	skipped_day = _get_current_day()
	state = STATE_DECLINED
	lesson_declined.emit(mom, player)
	_mark_attempt_consumed()
	_clear_participants()


func start_lesson(
	mom: Node2D,
	player: Node2D,
	expected_session_id: String = ""
) -> Dictionary:
	var validation_reason := _validate_lesson_start(mom, player, expected_session_id)
	if not validation_reason.is_empty():
		_log_lesson_transition(
			_get_persistent_lesson_phase(), "running", false, validation_reason
		)
		return {"accepted": false, "reason": validation_reason}
	if (
		state == STATE_RUNNING
		and active_action_session_id == expected_session_id
		and mom == active_mom
		and player == active_player
	):
		return {"accepted": true, "reason": "already_running"}
	active_mom_id = _get_npc_id(mom)
	active_action_session_id = expected_session_id
	var valid_activity_definitions := _get_valid_interactive_activity_definitions()
	var interactive_prepared := false
	if not valid_activity_definitions.is_empty():
		var prepare_result := _prepare_interactive_activity(
			mom,
			player,
			expected_session_id,
			valid_activity_definitions
		)
		if not bool(prepare_result.get("accepted", false)):
			var prepare_reason := String(prepare_result.get(
				"reason", "interactive_activity_prepare_rejected"
			))
			_log_lesson_transition(
				_get_persistent_lesson_phase(), "running", false, prepare_reason
			)
			return {"accepted": false, "reason": prepare_reason}
		interactive_prepared = true
	var previous_phase := _get_persistent_lesson_phase()
	var transition_result := _transition_activity({
		"expected_lesson_phases": ["handoff", "accepted", "running"],
		"lesson_phase": "running",
		"last_total_hours": _get_current_total_hours(),
	})
	if not bool(transition_result.get("accepted", false)):
		if interactive_prepared:
			_shutdown_interactive_activity_local(&"persistent_running_transition_rejected")
		var transition_reason := String(transition_result.get("reason", "running_transition_rejected"))
		_log_lesson_transition(previous_phase, "running", false, transition_reason)
		return {"accepted": false, "reason": transition_reason}
	active_mom = mom
	active_player = player
	state = STATE_RUNNING
	reward_applied = false
	last_lesson_result = {}
	lesson_progress = _get_lesson_progress_floor()
	lesson_timer = _get_lesson_real_seconds()
	interactive_activity_active = interactive_prepared
	_place_participants()
	if interactive_activity_active:
		if (
			interactive_activity_runner == null
			or not interactive_activity_runner.commit_activity()
		):
			cancel_lesson(&"interactive_activity_commit_rejected", expected_session_id)
			return {
				"accepted": false,
				"reason": "interactive_activity_commit_rejected",
			}
	else:
		_lock_participants()
	_update_visual()
	lesson_started.emit(mom, player)
	_log_lesson_transition(previous_phase, "running", true, "local_start_accepted")
	return {"accepted": true, "reason": "started"}


func complete_lesson(expected_session_id: String = "") -> bool:
	var expected_session := (
		expected_session_id if not expected_session_id.is_empty() else active_action_session_id
	)
	if state != STATE_RUNNING or not _terminal_session_is_current(expected_session):
		_log_lesson_transition(String(state), "completed", false, "stale_or_inactive_completion")
		return false

	var completed_mom := active_mom
	var completed_player := active_player
	var interactive_result := _finish_interactive_activity(&"lesson_completed")
	_finalize_lesson_score(completed_mom, completed_player, interactive_result)
	if not _finish_local_lesson_activity(expected_session, true):
		return false
	_apply_reward_once()
	completed_day = _get_current_day()
	state = STATE_COMPLETED
	_unlock_participants()
	_mark_attempt_consumed()
	_update_visual()
	lesson_completed.emit(completed_mom, completed_player)
	_clear_participants()
	return true


func cancel_lesson(reason: StringName, expected_session_id: String = "") -> bool:
	if state in [STATE_IDLE, STATE_COMPLETED, STATE_DECLINED, STATE_CANCELLED, STATE_FAILED]:
		return false
	var expected_session := (
		expected_session_id if not expected_session_id.is_empty() else active_action_session_id
	)
	if not _terminal_session_is_current(expected_session):
		_log_lesson_transition(String(state), "cancelled", false, "stale_terminal_session")
		return false
	_cancel_interactive_activity(reason)
	var lesson_was_running := state == STATE_RUNNING
	var activity_finished := (
		_finish_local_lesson_activity(expected_session, false)
		if lesson_was_running
		else _finish_scheduled_activity_to_saved_origin(expected_session)
	)
	if not activity_finished:
		return false
	state = STATE_CANCELLED
	_unlock_participants()
	lesson_cancelled.emit(reason)
	_update_visual()
	_clear_participants()
	return true


func is_invitation_pending_for(mom: Node2D, player: Node2D) -> bool:
	return state == STATE_INVITING and mom == active_mom and player == active_player


func is_lesson_active_for(mom: Node2D, player: Node2D) -> bool:
	return state == STATE_RUNNING and mom == active_mom and player == active_player


func lesson_is_done_for(_mom: Node2D, _player: Node2D) -> bool:
	var current_day := _get_current_day()
	return (
		(state == STATE_COMPLETED and completed_day == current_day)
		or (state == STATE_DECLINED and skipped_day == current_day)
	)


func get_lesson_state() -> StringName:
	return state


func get_active_lesson_session_id() -> String:
	return active_action_session_id if state == STATE_RUNNING else ""


func get_lesson_progress() -> float:
	return lesson_progress


func get_last_lesson_result() -> Dictionary:
	return last_lesson_result.duplicate(true)


func is_lesson_spot_enabled() -> bool:
	return not _magic_lesson_disabled()


func apply_world_spot_value(changed_spot_id: StringName, new_value: float) -> void:
	if changed_spot_id != spot_id:
		return

	availability_value = _clamp_availability_value(new_value)
	_update_visual()


func _place_participants() -> void:
	var mom_position := _get_marker_position(mom_marker_path, global_position + Vector2(-28.0, 0.0))
	var player_position := _get_marker_position(player_marker_path, global_position + Vector2(28.0, 0.0))

	if active_mom != null and is_instance_valid(active_mom):
		# Lesson staging is temporary. The location setter also changes the NPC's
		# persistent home position, so it must remain reserved for restoration.
		active_mom.global_position = mom_position
		var mom_body := active_mom as CharacterBody2D
		if mom_body != null:
			mom_body.velocity = Vector2.ZERO

	if active_player != null and is_instance_valid(active_player):
		active_player.global_position = player_position
		_stop_body(active_player)


func _lock_participants() -> void:
	player_action_mode = &""
	if active_player != null and is_instance_valid(active_player):
		if lock_player_during_lesson and active_player.has_method("begin_movement_lock"):
			active_player.call("begin_movement_lock", self, &"magic_lesson")
			player_action_mode = &"movement_lock"
		elif active_player.has_method("begin_spot_action"):
			active_player.call("begin_spot_action", self, &"magic_lesson")
			player_action_mode = &"spot_action"


func _unlock_participants() -> void:
	if active_player != null and is_instance_valid(active_player):
		if player_action_mode == &"movement_lock" and active_player.has_method("end_movement_lock"):
			active_player.call("end_movement_lock", self, &"magic_lesson", state == STATE_COMPLETED)
		elif player_action_mode == &"spot_action" and active_player.has_method("end_spot_action"):
			active_player.call("end_spot_action", self, &"magic_lesson", state == STATE_COMPLETED)
	player_action_mode = &""


func _hold_participants() -> void:
	if active_mom != null and is_instance_valid(active_mom):
		_stop_body(active_mom)
	if lock_player_during_lesson and active_player != null and is_instance_valid(active_player):
		_stop_body(active_player)


func _stop_body(body: Node) -> void:
	var character := body as CharacterBody2D
	if character != null:
		character.velocity.x = 0.0


func _apply_reward_once() -> void:
	if reward_applied:
		return
	reward_applied = true

	if active_player != null and is_instance_valid(active_player) and player_reward_meta != &"":
		var key := String(player_reward_meta)
		var previous_value := 0.0
		if active_player.has_meta(key):
			previous_value = float(active_player.get_meta(key))
		active_player.set_meta(key, previous_value + player_reward_amount)

	if active_mom != null and is_instance_valid(active_mom) and not mom_reward_delta.is_empty():
		if active_mom.has_method("apply_social_event"):
			active_mom.call("apply_social_event", mom_reward_delta, active_player, false)
		else:
			var machine := active_mom.get_node_or_null("NpcStateMachine")
			if machine != null and machine.has_method("apply_social_event"):
				machine.call(
					"apply_social_event",
					mom_reward_delta,
					active_player,
					false,
					"magic_lesson_reward",
					{"source": "magic_lesson"}
				)


func _finalize_lesson_score(
	mom: Node2D,
	player: Node2D,
	interactive_result: Dictionary = {}
) -> void:
	last_lesson_result = {
		"lesson_id": String(lesson_id),
		"spot_id": String(spot_id),
		"score": lesson_progress,
		"completed_day": _get_current_day(),
		"completed_total_hours": _get_current_total_hours(),
		"progress_multiplier": _get_lesson_progress_multiplier(),
	}
	if not interactive_result.is_empty():
		last_lesson_result["interactive_activity"] = interactive_result.duplicate(true)
	if player != null and is_instance_valid(player):
		player.set_meta("last_magic_lesson_score", lesson_progress)
		player.set_meta("last_magic_lesson_result", last_lesson_result.duplicate(true))
	if mom != null and is_instance_valid(mom):
		mom.set_meta("last_magic_lesson_score", lesson_progress)
		_set_activity_lesson_score(lesson_progress)

	var result_text := JSON.stringify(last_lesson_result)
	print("magic_lesson_result: %s" % result_text)
	_breadcrumb("magic_lesson:score", result_text)
	if mom != null and is_instance_valid(mom) and player != null and is_instance_valid(player):
		lesson_score_finalized.emit(mom, player, lesson_progress, last_lesson_result.duplicate(true))


func _mark_attempt_consumed() -> void:
	if not mark_spot_unavailable_after_attempt:
		return

	_set_availability_value(_get_lesson_done_threshold())


func _transition_activity(updates: Dictionary) -> Dictionary:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("transition_scheduled_activity"):
		return {"accepted": false, "reason": "activity_transition_service_missing"}
	if active_mom_id.is_empty() or active_action_session_id.is_empty():
		return {"accepted": false, "reason": "lesson_identity_missing"}
	return locations.call(
		"transition_scheduled_activity",
		StringName(active_mom_id),
		StringName(active_action_session_id),
		updates
	)


func _set_activity_lesson_score(score: float) -> void:
	_transition_activity({
		"expected_lesson_phases": ["running"],
		"lesson_score": score,
		"last_total_hours": _get_current_total_hours(),
	})


func _set_availability_value(new_value: float) -> void:
	var clamped_value := _clamp_availability_value(new_value)
	availability_value = clamped_value
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if world_definition != null and simulator != null and simulator.has_method("set_spot_value"):
		simulator.call("set_spot_value", spot_id, clamped_value, false)
		return

	_update_visual()


func _apply_lesson_progress(delta: float) -> void:
	var game_hours := _get_game_hours_for_real_seconds(delta)
	if game_hours <= 0.0:
		return

	var delta_value := _get_lesson_delta_per_game_hour() * game_hours
	if is_equal_approx(delta_value, 0.0):
		return

	lesson_progress = _clamp_lesson_progress(lesson_progress + delta_value)
	_award_lesson_time_xp(delta)
	_update_visual()


func _award_lesson_time_xp(delta: float) -> void:
	var progression := get_node_or_null("/root/ProgressionSystem")
	if progression == null or not progression.has_method("add_time_xp"):
		return

	progression.call("add_time_xp", &"class.magic_basics", delta, {
		"lesson_id": String(lesson_id),
		"spot_id": String(spot_id),
	})


func _finish_local_lesson_activity(
	expected_session_id: String,
	completed: bool
) -> bool:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("finish_scheduled_activity"):
		return false
	if active_mom_id.is_empty() or expected_session_id.is_empty():
		return false

	var finish_scene_path := _get_current_scene_path()
	var finish_position := (
		active_mom.global_position
		if active_mom != null and is_instance_valid(active_mom)
		else global_position
	)
	var finished := bool(locations.call(
		"finish_scheduled_activity",
		active_mom_id,
		finish_scene_path,
		finish_position,
		expected_session_id
	))
	if not finished:
		return false
	_reconcile_finished_local_action(expected_session_id, completed)
	return true


func _reconcile_finished_local_action(expected_session_id: String, completed: bool) -> void:
	if active_mom == null or not is_instance_valid(active_mom):
		return
	var machine := active_mom.get_node_or_null("NpcStateMachine")
	if (
		machine == null
		or not machine.has_method("get_active_action_session_id")
		or String(machine.call("get_active_action_session_id")) != expected_session_id
	):
		return

	var terminal_accepted := false
	if completed and machine.has_method("complete_active_action"):
		terminal_accepted = bool(machine.call(
			"complete_active_action", expected_session_id, "magic_lesson_completed"
		))
	elif not completed and machine.has_method("cancel_active_action"):
		terminal_accepted = bool(machine.call(
			"cancel_active_action", expected_session_id, "magic_lesson_cancelled"
		))
	if terminal_accepted and machine.has_method("clear_terminal_action"):
		machine.call("clear_terminal_action", expected_session_id)


func _finish_scheduled_activity_to_saved_origin(expected_session_id: String) -> bool:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("finish_scheduled_activity"):
		return false
	if active_mom_id.is_empty() or expected_session_id.is_empty():
		return false
	var return_scene_path := _get_current_scene_path()
	var return_position := (
		active_mom.global_position
		if active_mom != null and is_instance_valid(active_mom)
		else global_position
	)
	if locations.has_method("get_record_snapshot"):
		var record: Dictionary = locations.call("get_record_snapshot", active_mom_id)
		var activity = record.get("activity", {})
		if activity is Dictionary:
			return_scene_path = String(activity.get("return_scene_path", return_scene_path))
			var saved_return_position = activity.get("return_position", return_position)
			if saved_return_position is Vector2:
				return_position = saved_return_position
	return bool(locations.call(
		"finish_scheduled_activity",
		active_mom_id,
		return_scene_path,
		return_position,
		expected_session_id
	))


func get_interactive_activity_runner() -> InteractiveActivityRunner:
	return interactive_activity_runner


func is_interactive_lesson_active() -> bool:
	return (
		interactive_activity_active
		and interactive_activity_runner != null
		and interactive_activity_runner.is_active()
	)


func _get_valid_interactive_activity_definitions() -> Array[InteractiveActivityDefinition]:
	var valid: Array[InteractiveActivityDefinition] = []
	for definition in interactive_activity_definitions:
		if definition != null and definition.is_valid_definition():
			valid.append(definition)
	return valid


func _prepare_interactive_activity(
	mom: Node2D,
	player: Node2D,
	expected_session_id: String,
	definitions: Array[InteractiveActivityDefinition]
) -> Dictionary:
	var runner := _get_or_create_interactive_activity_runner()
	if runner == null:
		return {"accepted": false, "reason": "interactive_activity_runner_missing"}
	var context := {
		"session_id": expected_session_id,
		"owner_kind": "magic_lesson",
		"lesson_id": String(lesson_id),
		"spot_id": String(spot_id),
		"npc_id": _get_npc_id(mom),
		"scene_path": _get_current_scene_path(),
	}
	return runner.prepare_activity(
		player,
		definitions,
		context,
		_get_interactive_presentation_parent(),
		_get_interactive_world_anchor(),
		interactive_activity_launch_options
	)


func _get_or_create_interactive_activity_runner() -> InteractiveActivityRunner:
	if (
		interactive_activity_runner != null
		and is_instance_valid(interactive_activity_runner)
	):
		interactive_activity_runner.host_scene = interactive_activity_host_scene
		return interactive_activity_runner
	interactive_activity_runner = InteractiveActivityRunner.new()
	interactive_activity_runner.name = "InteractiveActivityRunner"
	interactive_activity_runner.host_scene = interactive_activity_host_scene
	add_child(interactive_activity_runner)
	return interactive_activity_runner


func _get_interactive_presentation_parent() -> Node:
	var configured_parent := get_node_or_null(interactive_presentation_parent_path)
	if (
		configured_parent != null
		and configured_parent != self
		and not is_ancestor_of(configured_parent)
	):
		return configured_parent
	return get_tree().current_scene


func _get_interactive_world_anchor() -> Vector2:
	var anchor := get_node_or_null(interactive_world_anchor_path) as Node2D
	return anchor.global_position if anchor != null else global_position


func _finish_interactive_activity(reason: StringName) -> Dictionary:
	if not interactive_activity_active or interactive_activity_runner == null:
		return {}
	return interactive_activity_runner.finish_activity(reason)


func _cancel_interactive_activity(reason: StringName) -> void:
	if not interactive_activity_active or interactive_activity_runner == null:
		return
	interactive_activity_runner.cancel_activity(reason)


func _shutdown_interactive_activity_local(reason: StringName) -> void:
	if interactive_activity_runner == null or not is_instance_valid(interactive_activity_runner):
		interactive_activity_active = false
		return
	interactive_activity_runner.shutdown_local(reason)
	interactive_activity_active = false


func _register_live_spot() -> void:
	if _magic_lesson_debug_disabled():
		_breadcrumb("magic_lesson:register_disabled", String(spot_id))
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("register_live_spot"):
		simulator.call("register_live_spot", spot_id, self)


func _unregister_live_spot() -> void:
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("unregister_live_spot"):
		simulator.call("unregister_live_spot", spot_id, self)


func _get_player_prompt_interactor(player: Node2D) -> Node:
	if player == null or not is_instance_valid(player):
		return null
	if player.has_method("show_npc_prompt"):
		return player

	return player.get_node_or_null("NpcTalkInteractor")


func _get_marker_position(marker_path: NodePath, fallback: Vector2) -> Vector2:
	var marker := get_node_or_null(marker_path) as Node2D
	if marker == null:
		return fallback

	return marker.global_position


func _participants_valid() -> bool:
	return (
		active_mom != null
		and is_instance_valid(active_mom)
		and active_player != null
		and is_instance_valid(active_player)
	)


func _validate_lesson_start(
	mom: Node2D,
	player: Node2D,
	expected_session_id: String
) -> String:
	if _magic_lesson_disabled():
		return "lesson_disabled"
	if expected_session_id.strip_edges().is_empty():
		return "expected_session_missing"
	if mom == null or player == null or not is_instance_valid(mom) or not is_instance_valid(player):
		return "invalid_participant"
	if not mom.is_inside_tree() or not player.is_inside_tree() or not is_inside_tree():
		return "participant_not_in_tree"
	if state == STATE_RUNNING and active_action_session_id != expected_session_id:
		return "lesson_spot_owned_by_other_session"
	var npc_id := _get_npc_id(mom)
	if npc_id.is_empty():
		return "mom_id_missing"
	var machine := mom.get_node_or_null("NpcStateMachine")
	if machine == null or not machine.has_method("get_active_action_session_id"):
		return "mom_action_machine_missing"
	if String(machine.call("get_active_action_session_id")) != expected_session_id:
		return "mom_active_session_mismatch"
	if machine.has_method("get_active_action_descriptor"):
		var active_descriptor: Dictionary = machine.call("get_active_action_descriptor")
		if String(active_descriptor.get("action_kind", "")) != "InvitePlayer":
			return "mom_action_kind_mismatch"

	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_record_snapshot"):
		return "npc_locations_missing"
	var record: Dictionary = locations.call("get_record_snapshot", npc_id)
	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return "scheduled_activity_missing"
	if NpcActionSession._descriptor_session_id(activity) != expected_session_id:
		return "persistent_activity_session_mismatch"
	var action = record.get("action", {})
	if action is Dictionary and not action.is_empty():
		if NpcActionSession._descriptor_session_id(action) != expected_session_id:
			return "persistent_action_session_mismatch"
		var metadata = action.get("metadata", {})
		if metadata is Dictionary and metadata.has("lesson_phase"):
			if String(metadata.get("lesson_phase", "")) != String(activity.get("lesson_phase", "")):
				return "lesson_phase_metadata_mismatch"
	var lesson_phase := String(activity.get("lesson_phase", "inviting"))
	if lesson_phase not in ["handoff", "accepted", "running"]:
		return "lesson_phase_not_startable"
	if not _lesson_schedule_is_active():
		return "lesson_schedule_inactive"
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("session_owns_spot"):
		return "reservation_service_missing"
	if not bool(simulator.call(
		"session_owns_spot",
		StringName(npc_id),
		expected_session_id,
		spot_id,
		StringName(String(activity.get("reservation_purpose", "activity")))
	)):
		return "lesson_reservation_missing"
	return ""


func _validate_invitation_start(mom: Node2D, player: Node2D) -> String:
	if _magic_lesson_disabled():
		return "lesson_disabled"
	if mom == null or player == null or not is_instance_valid(mom) or not is_instance_valid(player):
		return "invalid_participant"
	if state == STATE_INVITING:
		return "" if mom == active_mom and player == active_player else "invitation_owned_by_other_participants"
	if state == STATE_RUNNING:
		return "lesson_already_running"
	if _attempt_already_used_today():
		return "lesson_attempt_already_used"
	if not _world_spot_is_available():
		return "lesson_spot_unavailable"
	if not mom.is_inside_tree() or not player.is_inside_tree() or not is_inside_tree():
		return "participant_not_in_tree"
	return ""


func _terminal_session_is_current(expected_session_id: String) -> bool:
	if (
		expected_session_id.is_empty()
		or expected_session_id != active_action_session_id
		or active_mom_id.is_empty()
	):
		return false
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_record_snapshot"):
		return false
	var record: Dictionary = locations.call("get_record_snapshot", active_mom_id)
	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return false
	if NpcActionSession._descriptor_session_id(activity) != expected_session_id:
		return false
	var action = record.get("action", {})
	return (
		not (action is Dictionary)
		or action.is_empty()
		or NpcActionSession._descriptor_session_id(action) == expected_session_id
	)


func _get_persistent_lesson_phase() -> String:
	if active_mom_id.is_empty():
		return ""
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_record_snapshot"):
		return ""
	var record: Dictionary = locations.call("get_record_snapshot", active_mom_id)
	var activity = record.get("activity", {})
	return String(activity.get("lesson_phase", "")) if activity is Dictionary else ""


func _get_npc_id(candidate: Node) -> String:
	if candidate == null or not is_instance_valid(candidate):
		return ""
	if candidate.has_method("get_npc_location_id"):
		return String(candidate.call("get_npc_location_id")).strip_edges()
	if candidate.has_meta("npc_location_id"):
		return String(candidate.get_meta("npc_location_id")).strip_edges()
	return ""


func _log_lesson_transition(
	old_phase: String,
	new_phase: String,
	accepted: bool,
	reason: String
) -> void:
	if not OS.is_debug_build():
		return
	var reservation_ids = []
	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("get_record_snapshot") and not active_mom_id.is_empty():
		var record: Dictionary = locations.call("get_record_snapshot", active_mom_id)
		var activity = record.get("activity", {})
		if activity is Dictionary:
			reservation_ids = activity.get("reservation_ids", [])
	print("Magic lesson local: npc=%s session=%s phase=%s->%s scene=%s reservation=%s accepted=%s reason=%s" % [
		active_mom_id, active_action_session_id, old_phase, new_phase,
		_get_current_scene_path(), str(reservation_ids), str(accepted), reason,
	])


func _clear_participants() -> void:
	active_mom = null
	active_player = null
	lesson_timer = 0.0
	interactive_activity_active = false


func _attempt_already_used_today() -> bool:
	var current_day := _get_current_day()
	return completed_day == current_day or skipped_day == current_day


func _world_spot_is_available() -> bool:
	_refresh_availability_value()
	return availability_value > _get_lesson_done_threshold()


func _setup_lesson_state_values() -> void:
	lesson_progress = _get_lesson_progress_floor()
	_refresh_availability_value()


func _refresh_availability_value() -> void:
	availability_value = _get_availability_default()
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if world_definition != null and simulator != null and simulator.has_method("get_spot_value"):
		availability_value = float(simulator.call(
			"get_spot_value",
			spot_id,
			_get_availability_default()
		))
	availability_value = _clamp_availability_value(availability_value)


func _get_availability_default() -> float:
	if world_definition == null:
		return 100.0

	return world_definition.spot_value_initial


func _get_lesson_done_threshold() -> float:
	if world_definition == null:
		return 0.0

	return world_definition.spot_value_done_threshold


func _get_lesson_progress_floor() -> float:
	return 0.0


func _get_lesson_progress_ceiling() -> float:
	return maxf(lesson_progress_max, _get_lesson_progress_floor())


func _get_lesson_delta_per_game_hour() -> float:
	return lesson_progress_per_game_hour * _get_lesson_progress_multiplier()


func _get_lesson_progress_multiplier() -> float:
	var multiplier := maxf(lesson_progress_multiplier, 0.0)
	if active_mom != null and is_instance_valid(active_mom):
		if active_mom.has_method("get_magic_lesson_progress_multiplier"):
			multiplier *= maxf(float(active_mom.call("get_magic_lesson_progress_multiplier")), 0.0)
	if active_player != null and is_instance_valid(active_player):
		if active_player.has_method("get_magic_lesson_progress_multiplier"):
			multiplier *= maxf(float(active_player.call("get_magic_lesson_progress_multiplier")), 0.0)
	return multiplier

func _clamp_lesson_progress(value: float) -> float:
	return clampf(value, _get_lesson_progress_floor(), _get_lesson_progress_ceiling())


func _clamp_availability_value(value: float) -> float:
	if world_definition == null:
		return clampf(value, 0.0, 100.0)

	return clampf(
		value,
		minf(world_definition.spot_value_minimum, world_definition.spot_value_maximum),
		maxf(world_definition.spot_value_minimum, world_definition.spot_value_maximum)
	)


func _lesson_attempt_is_unavailable() -> bool:
	return availability_value <= _get_lesson_done_threshold()


func _get_lesson_real_seconds() -> float:
	var game_hours := _get_lesson_game_hours()
	var real_seconds_per_day := _get_real_seconds_per_day()
	if game_hours > 0.0 and real_seconds_per_day > 0.0:
		return maxf(real_seconds_per_day * (game_hours / 24.0), 0.001)

	return maxf(lesson_duration_seconds, 0.1)


func _get_lesson_game_hours() -> float:
	return maxf(fallback_lesson_game_hours, 0.001)


func _get_real_seconds_per_day() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null:
		return 0.0

	var value = world_time.get("real_seconds_per_day")
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return maxf(float(value), 0.0)

	return 0.0


func _get_game_hours_for_real_seconds(real_seconds: float) -> float:
	if real_seconds <= 0.0:
		return 0.0

	var real_seconds_per_day := _get_real_seconds_per_day()
	if real_seconds_per_day > 0.0:
		return (real_seconds / real_seconds_per_day) * 24.0

	return (real_seconds / maxf(lesson_duration_seconds, 0.001)) * _get_lesson_game_hours()


func _lesson_schedule_is_active() -> bool:
	if not _schedule_controls_lesson():
		return true

	return world_definition.is_active_at(_get_current_time_of_day_hours())


func _schedule_controls_lesson() -> bool:
	return (
		world_definition != null
		and not world_definition.active_time_windows.is_empty()
		and get_node_or_null("/root/WorldTime") != null
	)


func _schedule_fallback_timer_is_done() -> bool:
	if _schedule_controls_lesson():
		return false

	return lesson_timer <= 0.0


func _participants_are_counting_progress() -> bool:
	if not _participants_valid():
		return false
	if not require_player_in_lesson_zone:
		return true

	return _participant_is_in_lesson_zone(active_mom) and _participant_is_in_lesson_zone(active_player)


func _participant_is_in_lesson_zone(participant: Node2D) -> bool:
	if participant == null or not is_instance_valid(participant):
		return false
	if not participant.is_inside_tree() or not is_inside_tree():
		return false
	if participant.get_tree() != get_tree():
		return false

	var local_position := to_local(participant.global_position)
	return (
		absf(local_position.x) <= lesson_zone_half_extents.x
		and absf(local_position.y) <= lesson_zone_half_extents.y
	)


func _get_current_time_of_day_hours() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		return float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))

	return 0.0


func _get_current_total_hours() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		return float(snapshot.get(
			"total_hours",
			float(snapshot.get("day", 0)) * 24.0 + float(snapshot.get(
				"time_of_day_hours",
				snapshot.get("hour", 0.0)
			))
		))

	return 0.0


func _ensure_visual_nodes() -> void:
	zone_visual = get_node_or_null("ZoneVisual") as Polygon2D
	if zone_visual == null:
		zone_visual = Polygon2D.new()
		zone_visual.name = "ZoneVisual"
		zone_visual.color = ready_color
		add_child(zone_visual)
		move_child(zone_visual, 0)
	_update_zone_polygon()

	label = get_node_or_null("Label") as Label
	if label == null:
		label = Label.new()
		label.name = "Label"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_shadow_color", Color.BLACK)
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		add_child(label)
	_update_label_layout()


func _update_zone_polygon() -> void:
	if zone_visual == null:
		return

	var half_width := maxf(lesson_zone_half_extents.x, 1.0)
	var half_height := maxf(lesson_zone_half_extents.y, 1.0)
	zone_visual.polygon = PackedVector2Array([
		Vector2(-half_width, -half_height),
		Vector2(half_width, -half_height),
		Vector2(half_width, half_height),
		Vector2(-half_width, half_height),
	])


func _update_label_layout() -> void:
	if label == null:
		return

	label.offset_left = -lesson_zone_half_extents.x
	label.offset_top = -lesson_zone_half_extents.y - 44.0
	label.offset_right = lesson_zone_half_extents.x
	label.offset_bottom = -lesson_zone_half_extents.y + 4.0


func _update_visual() -> void:
	if zone_visual != null:
		if state == STATE_RUNNING:
			zone_visual.color = ready_color.lerp(busy_color, _get_lesson_progress_ratio())
		elif _magic_lesson_disabled():
			zone_visual.color = unavailable_color
		elif _lesson_attempt_is_unavailable():
			zone_visual.color = unavailable_color
		else:
			zone_visual.color = ready_color

	if label == null:
		return

	var value_text := str(int(round(lesson_progress)))
	if state == STATE_INVITING:
		value_text = "%s | inviting" % value_text
	elif state == STATE_RUNNING:
		if _participants_are_counting_progress():
			value_text = "%s | class" % value_text
		else:
			value_text = "%s | waiting" % value_text
	elif _magic_lesson_disabled():
		value_text = "off"
	elif _lesson_attempt_is_unavailable():
		value_text = "done"

	var lines: Array[String] = []
	if show_owner_debug_label:
		lines.append("owners:mom,player")
	lines.append(label_prefix)
	lines.append(value_text)
	label.text = "\n".join(lines)


func _get_lesson_progress_ratio() -> float:
	var floor_value := _get_lesson_progress_floor()
	var ceiling_value := _get_lesson_progress_ceiling()
	if is_equal_approx(floor_value, ceiling_value):
		return 0.0

	return clampf(inverse_lerp(floor_value, ceiling_value, lesson_progress), 0.0, 1.0)


func _get_current_day() -> int:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		return int(snapshot.get("day", 0))

	return 0


func _get_current_scene_path() -> String:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return ""

	return current_scene.scene_file_path


func _get_mom_location_id() -> String:
	if active_mom == null or not is_instance_valid(active_mom):
		return ""
	if active_mom.has_method("get_npc_location_id"):
		return String(active_mom.call("get_npc_location_id"))
	if active_mom.has_meta("npc_location_id"):
		return String(active_mom.get_meta("npc_location_id"))

	return ""


func _magic_lesson_disabled() -> bool:
	if not lesson_enabled:
		return true
	return _magic_lesson_debug_disabled()


func _magic_lesson_debug_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_MAGIC_LESSON_ACTIVITY
	)


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
