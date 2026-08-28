class_name NpcStateTalk extends NpcState

signal talk_started(talker: Node2D, partner: Node2D)
signal talk_finished(talker: Node2D, partner: Node2D, changed_values: Dictionary)
signal talk_cancelled(talker: Node2D, partner: Node2D, reason: String)

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")


class TalkProgressRing:
	extends Control

	var progress_ratio: float = 1.0
	var ring_color: Color = Color(0.2, 0.95, 0.35, 1.0)
	var track_color: Color = Color(0.02, 0.08, 0.03, 0.72)
	var ring_width: float = 2.0

	func set_progress_ratio(next_ratio: float) -> void:
		progress_ratio = clampf(next_ratio, 0.0, 1.0)
		queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		var radius := maxf((minf(size.x, size.y) - ring_width) * 0.5, 0.0)
		if radius <= 0.0:
			return
		draw_arc(center, radius, 0.0, TAU, 24, track_color, ring_width, true)
		if progress_ratio <= 0.0:
			return
		var start_angle := -PI * 0.5
		draw_arc(
			center,
			radius,
			start_angle,
			start_angle + (TAU * progress_ratio),
			24,
			ring_color,
			ring_width,
			true
		)

const ROUTINE_INTERRUPT_STATES: Array[StringName] = [
	&"Work",
	&"Eat",
	&"Sleep",
	&"Rest",
	&"Recreation",
	&"RoutineTask",
	&"MoveToTarget",
	&"LookForTalkTarget",
]

@export_group("Timing and Range")
# Negative duration uses the owning state machine's game-time-scaled Talk duration.
@export_range(-1.0, 60.0, 0.1, "suffix:s") var talk_duration: float = 5.0
@export_range(0.0, 512.0, 1.0, "suffix:px") var talk_range: float = 32.0
@export_range(0.0, 1024.0, 1.0, "suffix:px") var maximum_talk_distance: float = 180.0
@export_range(0.1, 1.0, 0.01) var preferred_talk_distance_ratio: float = 0.65
@export_range(0.0, 64.0, 1.0, "suffix:px") var talk_follow_resume_margin: float = 6.0
@export var use_horizontal_talk_distance: bool = true
@export var follow_partner_while_talking: bool = true
@export_range(0.0, 200.0, 1.0, "suffix:px/s") var talk_follow_speed: float = 28.0
@export_range(0.0, 200.0, 1.0, "suffix:px/s") var talk_approach_speed: float = 91.0
@export_range(0.0, 30.0, 0.1, "suffix:s") var talk_approach_timeout: float = 8.0
@export_range(0.0, 30.0, 0.1, "suffix:s") var maximum_talk_distance_cancel_seconds: float = 2.0
@export var follow_animation_name: StringName = &"walk"

@export_group("Visible Limits")
@export var show_talk_limits: bool = true
@export var talk_limits_offset: Vector2 = Vector2(-90.0, -172.0)
@export var talk_limits_size: Vector2 = Vector2(180.0, 20.0)
@export_range(6, 24, 1) var talk_limits_font_size: int = 10
@export_range(0.0, 1.0, 0.01) var near_break_distance_ratio: float = 0.8
@export_range(8.0, 24.0, 1.0, "suffix:px") var talk_ring_size: float = 14.0
@export_range(1.0, 5.0, 0.5, "suffix:px") var talk_ring_width: float = 2.0
@export var talk_ring_color: Color = Color(0.2, 0.95, 0.35, 1.0)

@export_group("Need")
@export var talk_value_name: StringName = &"talk_need"
@export var talk_complete_delta: float = -40.0
@export var boredom_value_name: StringName = &"boredom"
@export var boredom_complete_delta: float = -10.0
@export var reduce_partner_talk_need: bool = true
@export var partner_talk_complete_delta: float = -25.0

@export_group("Conversation Spillover")
@export var spread_values_to_npc_talk_partner: bool = true
@export_range(0.0, 1.0, 0.01) var spread_player_topic_chance: float = 0.5
@export_range(0.0, 100.0, 0.1) var spread_emotion_threshold: float = 70.0
@export var spread_emotion_delta: float = 8.0
@export var spread_emotion_value_names: Array[StringName] = [&"anger"]
@export_range(0.0, 1.0, 0.01) var spread_high_emotion_priority_chance: float = 0.7
@export_range(0.0, 100.0, 0.1) var spread_favor_low_threshold: float = 20.0
@export_range(0.0, 100.0, 0.1) var spread_favor_high_threshold: float = 70.0
@export var spread_favor_delta: float = 5.0
@export_range(0.0, 1.0, 0.01) var spread_gossip_extreme_priority_chance: float = 0.5
@export var spread_gossip_target_groups: Array[StringName] = [&"npc"]

@export_group("Hooks")
@export var require_talk_partner: bool = true
@export var talk_action_name: StringName = &"talk"
@export var end_state_name: StringName = &"Idle"

@export_group("Interrupts")
@export_range(0, 1000, 1) var minimum_emergency_interrupt_priority: int = 90
@export var emergency_interrupt_states: Array[StringName] = [
	&"DisabledDead",
	&"Downed",
	&"Collapse",
	&"Flee",
	&"Fight",
]

var talk_timer: float = 0.0
var talk_total_duration: float = 0.0
var talk_partner: Node2D
var talk_started_handled: bool = false
var talk_finished_handled: bool = false
var talk_completed_successfully: bool = false
var following_partner: bool = false
var approaching_partner: bool = false
var approach_timer: float = 0.0
var maximum_distance_cancel_timer: float = 0.0
var static_task_talk: bool = false
var talk_progress_ring: TalkProgressRing
var spread_rng := RandomNumberGenerator.new()
var talk_elapsed_seconds: float = 0.0
var terminal_session_id: String = ""
var terminal_partner_identity: String = "none"
var terminal_source: String = "social_ai"
var external_completion_pending: bool = false


func init() -> void:
	super.init()
	spread_rng.randomize()


func enter() -> void:
	# Starts a timed talk with the assigned partner or the machine's active target.
	# The state machine selects overlay-versus-primary presentation after Talk has
	# established whether a compatible activity remains active underneath it.
	begin_enter_without_animation()
	talk_partner = machine.get_talk_target()
	# The state machine owns the primary/overlay relationship. Talk never reads state
	# history and never exits or re-enters the activity underneath it.
	static_task_talk = machine != null and machine.primary_state_continues_under_talk() and not machine.is_primary_state(&"Idle")
	talk_started_handled = false
	talk_finished_handled = false
	talk_completed_successfully = false
	external_completion_pending = false
	talk_elapsed_seconds = 0.0
	terminal_session_id = machine.get_active_interaction_session_id() if machine != null else ""
	terminal_partner_identity = _target_label(talk_partner)
	terminal_source = (
		String(machine.active_interaction_session.source)
		if machine != null and machine.active_interaction_session != null
		else ("player" if _is_valid_talk_partner(talk_partner) and talk_partner.is_in_group("player") else "social_ai")
	)
	following_partner = false
	approaching_partner = false
	approach_timer = talk_approach_timeout
	maximum_distance_cancel_timer = maximum_talk_distance_cancel_seconds
	talk_timer = talk_duration

	if talk_timer < 0.0:
		talk_timer = machine.get_real_seconds_for_game_minutes(
			machine.default_talk_game_minutes,
			machine.default_talk_time
		)
	talk_total_duration = maxf(talk_timer, 0.0)

	stop_horizontal()
	_face_talk_partner()

	if require_talk_partner and not _is_valid_talk_partner(talk_partner):
		talk_timer = 0.0
		_hide_talk_progress()
		return

	_show_talk_progress()
	_update_talk_progress()
	if _needs_talk_approach():
		approaching_partner = true
		if not static_task_talk and follow_animation_name != &"":
			play_animation(follow_animation_name)
		return

	_start_talk_action()


func exit() -> void:
	# Treat leaving early as a cancelled talk, so no talk_need reduction happens.
	stop_horizontal()
	following_partner = false
	approaching_partner = false
	_hide_talk_progress()
	if not talk_finished_handled:
		_cancel_talk_action("state_exit")


func physics_process(delta: float) -> NpcState:
	# The timed window continues while the NPC slowly follows a drifting partner.
	talk_elapsed_seconds += maxf(delta, 0.0)
	# Dialogue can finish or cancel Talk between state-machine ticks. Surface that
	# terminal result immediately so the overlay/session lifecycle can close normally.
	if talk_finished_handled:
		return _get_after_talk_state()
	if require_talk_partner and not _is_valid_talk_partner(talk_partner):
		_cancel_talk_action("missing_partner")
		return _get_after_talk_state()

	if talk_started_handled and _update_maximum_talk_distance_cancel(delta):
		return _get_after_talk_state()

	if approaching_partner:
		if _update_talk_approach(delta):
			_start_talk_action()
		if talk_finished_handled:
			return _get_after_talk_state()
		_update_talk_progress()
		return next_state

	if static_task_talk:
		stop_horizontal()
	else:
		_update_talk_movement()
	_face_talk_partner()
	_update_talk_progress()
	if _talk_is_outside_active_range():
		if static_task_talk:
			_start_static_partner_wait()
		return next_state
	if external_completion_pending:
		# A modal conversation is now the completion condition. Keep Talk alive as
		# the social-action authority, but never let its fallback timer pay out below it.
		stop_horizontal()
		_hide_talk_progress()
		return next_state

	if talk_timer <= 0.0:
		_finish_talk_action()
		return _get_after_talk_state()

	talk_timer -= delta
	_update_talk_progress()
	if talk_timer > 0.0:
		return next_state

	_finish_talk_action()
	return _get_after_talk_state()


func target_lost(lost_target: Node2D) -> NpcState:
	# Sight loss alone does not end a conversation; distance and validity do.
	if lost_target == talk_partner:
		return next_state

	return next_state


func is_talking_with(candidate: Node2D) -> bool:
	return _is_valid_talk_partner(candidate) and talk_partner == candidate


func cancel_talk_with(candidate: Node2D, reason: String = "cancelled") -> void:
	if not is_talking_with(candidate):
		return

	_cancel_talk_action(reason)


func cancel_talk_session(reason: String = "cancelled") -> void:
	_cancel_talk_action(reason)


func complete_talk_with(candidate: Node2D, reason: String = "completed") -> void:
	if not is_talking_with(candidate):
		return
	_finish_talk_action(reason)


func wait_for_external_completion() -> bool:
	if not talk_started_handled or talk_finished_handled:
		return false
	external_completion_pending = true
	stop_horizontal()
	_hide_talk_progress()
	return true


func is_waiting_for_external_completion() -> bool:
	return external_completion_pending and not talk_finished_handled


func refresh_overlay_presentation() -> void:
	if static_task_talk:
		return
	if (following_partner or approaching_partner) and not static_task_talk and follow_animation_name != &"":
		play_animation(follow_animation_name)
	elif animation_name != &"":
		play_animation(animation_name)
	_face_talk_partner()


func can_be_interrupted_by_scheduled_activity(_request_priority: int) -> bool:
	if talk_finished_handled:
		return true

	return false


func can_exit_to(new_state: NpcState, request_priority: int) -> bool:
	if talk_finished_handled:
		return true
	if new_state == null:
		return false

	var new_state_name := StringName(String(new_state.name))
	if _is_emergency_interrupt_state(new_state_name):
		return true
	if _is_routine_interrupt_state(new_state_name):
		return false

	return request_priority >= minimum_emergency_interrupt_priority


func get_talk_approach_distance() -> float:
	# Search states use this smaller distance so NPCs do not stop at the range edge.
	return maxf(talk_range * preferred_talk_distance_ratio, 0.0)


func is_talk_start_distance_viable(candidate: Node2D) -> bool:
	# Autonomous search checks this before creating a conversation. Keep direct
	# far-distance Talk requests free to use this state's existing approach phase.
	if npc == null or not _is_valid_talk_partner(candidate):
		return false
	if maximum_talk_distance <= 0.0:
		return true
	return npc.global_position.distance_to(candidate.global_position) <= maximum_talk_distance


func _get_after_talk_state() -> NpcState:
	# A non-null result tells the state machine to close this overlay. It is not a
	# request to exit, re-enter, or otherwise replace the primary state.
	var after_state := get_state(end_state_name)
	if after_state != null:
		return after_state
	return self


func _start_static_partner_wait() -> void:
	if approaching_partner:
		return

	approaching_partner = true
	approach_timer = talk_approach_timeout


func _start_talk_action() -> void:
	# Emits start hooks for future dialogue UI, barks, or animation wiring.
	if talk_started_handled:
		return

	talk_started_handled = true
	talk_started.emit(npc, talk_partner)

	# Hook dialogue UI, bark text, voice, or custom talk animation here.
	_call_talk_hook(npc, &"on_npc_talk_started", [talk_partner, self, talk_action_name])
	_call_talk_hook(talk_partner, &"on_npc_talk_received", [npc, self, talk_action_name])


func _finish_talk_action(reason: String = "completed") -> void:
	# Applies talk relief and emits finish hooks once, at successful completion.
	if talk_finished_handled:
		return

	stop_horizontal()
	_hide_talk_progress()
	external_completion_pending = false
	talk_finished_handled = true
	talk_completed_successfully = true
	var changed_values := {}
	var talk_need_before := _get_talk_need_value()

	var skip_own_need_payout := machine.consume_next_talk_need_payout_already_applied(
		terminal_session_id
	)
	if not skip_own_need_payout:
		var own_delta := _apply_talk_delta_to_machine(machine, talk_value_name, talk_complete_delta, talk_partner)
		if not is_equal_approx(own_delta, 0.0):
			changed_values[String(talk_value_name)] = own_delta

		var boredom_delta := _apply_talk_delta_to_machine(
			machine,
			boredom_value_name,
			boredom_complete_delta,
			talk_partner
		)
		if not is_equal_approx(boredom_delta, 0.0):
			changed_values[String(boredom_value_name)] = boredom_delta

	if reduce_partner_talk_need:
		_apply_partner_talk_delta()

	if spread_values_to_npc_talk_partner:
		_apply_talk_spillover(changed_values)

	talk_finished.emit(npc, talk_partner, changed_values)

	# Hook follow-up dialogue, rewards, relationship changes, or animation cleanup here.
	_call_talk_hook(npc, &"on_npc_talk_finished", [talk_partner, self, changed_values])
	_call_talk_hook(talk_partner, &"on_npc_talk_finished_with", [npc, self, changed_values])
	_log_talk_terminal(
		"completed", reason, talk_need_before, _get_talk_need_value(), skip_own_need_payout
	)
	_clear_talk_target()


func _cancel_talk_action(reason: String) -> void:
	# Clears the talk target without changing needs when talk is interrupted.
	if talk_finished_handled:
		return

	stop_horizontal()
	approaching_partner = false
	following_partner = false
	_hide_talk_progress()
	external_completion_pending = false
	talk_finished_handled = true
	talk_completed_successfully = false
	var talk_need_before := _get_talk_need_value()
	if talk_started_handled:
		var valid_partner := talk_partner if is_instance_valid(talk_partner) else null
		talk_cancelled.emit(npc, valid_partner, reason)
		_call_talk_hook(npc, &"on_npc_talk_cancelled", [valid_partner, self, reason])
		_call_talk_hook(valid_partner, &"on_npc_talk_cancelled_with", [npc, self, reason])

	if not reason.begins_with("partner_"):
		_cancel_partner_talk_if_linked(reason)

	_log_talk_terminal("cancelled", reason, talk_need_before, _get_talk_need_value(), true)
	_clear_talk_target()


func _log_talk_terminal(
	result: String,
	reason: String,
	talk_need_before: float,
	talk_need_after: float,
	payout_skipped: bool
) -> void:
	if not OS.is_debug_build():
		return
	var distance_text := "n/a"
	if npc != null and is_instance_valid(npc) and _is_valid_talk_partner(talk_partner):
		distance_text = "%.2f" % npc.global_position.distance_to(talk_partner.global_position)
	print("NPC Talk terminal: npc=%s session=%s partner=%s source=%s result=%s reason=%s started=%s elapsed=%.2f distance=%s talk_need_before=%.2f talk_need_after=%.2f payout_skipped=%s" % [
		_npc_label(), terminal_session_id, terminal_partner_identity, terminal_source,
		result, reason, str(talk_started_handled), talk_elapsed_seconds, distance_text,
		talk_need_before, talk_need_after, str(payout_skipped),
	])


func _get_talk_need_value() -> float:
	if machine == null or talk_value_name == &"":
		return 0.0
	return machine.get_value(talk_value_name)


func _npc_label() -> String:
	if npc != null and is_instance_valid(npc):
		if npc.has_method("get_npc_location_id"):
			var npc_id := String(npc.call("get_npc_location_id")).strip_edges()
			if not npc_id.is_empty():
				return "%s(%s)" % [npc.name, npc_id]
		return String(npc.name)
	return "unknown"


func _target_label(candidate) -> String:
	if candidate == null or not is_instance_valid(candidate):
		return "none"
	if candidate.has_method("get_npc_location_id"):
		var npc_id := String(candidate.call("get_npc_location_id")).strip_edges()
		if not npc_id.is_empty():
			return "%s(%s)" % [candidate.name, npc_id]
	return String(candidate.name)


func _apply_partner_talk_delta() -> void:
	# If the partner is also an NPC, optionally lowers that NPC's talk need too.
	if talk_partner == null or not is_instance_valid(talk_partner):
		return

	var partner_machine := _get_partner_machine()
	if partner_machine != null:
		if _partner_machine_is_talking_back(partner_machine):
			return

		_apply_talk_delta_to_machine(partner_machine, talk_value_name, partner_talk_complete_delta, npc)
		return

	if talk_partner.has_method("apply_social_event"):
		talk_partner.call(
			"apply_social_event",
			{String(talk_value_name): partner_talk_complete_delta},
			npc,
			false
		)


func _partner_machine_is_talking_back(partner_machine: NpcStateMachine) -> bool:
	if partner_machine == null:
		return false
	if partner_machine.has_method("is_talking_with"):
		return bool(partner_machine.call("is_talking_with", npc))

	return (
		partner_machine.is_in_state(&"Talk")
		and partner_machine.get_talk_target() == npc
	)


func _cancel_partner_talk_if_linked(reason: String) -> void:
	var partner_machine := _get_partner_machine()
	if partner_machine == null:
		return
	if not partner_machine.has_method("cancel_talk_with"):
		return

	partner_machine.call("cancel_talk_with", npc, "partner_%s" % reason)


func _apply_talk_spillover(changed_values: Dictionary) -> void:
	# Shares one conversation topic from this NPC into the NPC they finished talking to.
	if npc == null or talk_partner == null or not is_instance_valid(talk_partner):
		return

	var partner_machine := _get_partner_machine()
	if partner_machine == null:
		return

	var player_topic_candidates := _build_player_topic_spillover_candidates()
	var gossip_candidates := _build_gossip_spillover_candidates()
	var selected_candidate := _select_spillover_candidate(player_topic_candidates, gossip_candidates)
	if selected_candidate.is_empty():
		return

	_apply_spillover_candidate(selected_candidate, partner_machine, changed_values)


func _build_player_topic_spillover_candidates() -> Array[Dictionary]:
	# Only undirected emotion values belong here. Fear is relationship-specific
	# and must not be copied without its actual relationship target.
	var candidates: Array[Dictionary] = []
	if machine == null:
		return candidates

	for value_name in spread_emotion_value_names:
		if value_name == &"":
			continue

		var source_value := machine.get_value(value_name)
		if source_value < spread_emotion_threshold:
			continue

		candidates.append({
			"kind": "player_trait",
			"value_name": value_name,
			"source_value": source_value,
			"delta": absf(spread_emotion_delta),
		})

	return candidates


func _build_gossip_spillover_candidates() -> Array[Dictionary]:
	# Gossip spreads the speaker's strong like/dislike for NPCs outside this conversation.
	var candidates: Array[Dictionary] = []
	if npc == null or talk_partner == null:
		return candidates

	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("get_relationships_for"):
		return candidates

	var npc_relationships = relationships.call("get_relationships_for", npc)
	if not (npc_relationships is Dictionary):
		return candidates

	var speaker_id := _get_relationship_id_for_node(npc)
	var listener_id := _get_relationship_id_for_node(talk_partner)
	for relationship_key in npc_relationships.keys():
		var relationship_value = npc_relationships[relationship_key]
		if not (relationship_value is Dictionary):
			continue

		var relationship: Dictionary = relationship_value.duplicate(true)
		var target_id := String(relationship.get("other_id", relationship_key)).strip_edges()
		if target_id.is_empty() or target_id == speaker_id or target_id == listener_id:
			continue

		var gossip_target := _resolve_gossip_target(relationship, target_id)
		if gossip_target == npc or gossip_target == talk_partner:
			continue
		if not _is_gossip_target(gossip_target):
			continue

		var favor_value := float(relationship.get("favor", 50.0))
		var favor_delta := 0.0
		if favor_value >= spread_favor_high_threshold:
			favor_delta = absf(spread_favor_delta)
		elif favor_value <= spread_favor_low_threshold:
			favor_delta = -absf(spread_favor_delta)
		else:
			continue

		candidates.append({
			"kind": "gossip_favor",
			"target": gossip_target,
			"target_id": target_id,
			"target_name": _get_gossip_target_label(relationship, gossip_target),
			"target_path": String(relationship.get("other_path", "")),
			"source_value": favor_value,
			"delta": favor_delta,
			"extreme": absf(favor_value - 50.0),
		})

	return candidates


func _select_spillover_candidate(
	player_topic_candidates: Array[Dictionary],
	gossip_candidates: Array[Dictionary]
) -> Dictionary:
	# Picks one topic total: player/emotion talk or gossip about another NPC.
	var has_player_topic := not player_topic_candidates.is_empty()
	var has_gossip := not gossip_candidates.is_empty()
	if not has_player_topic and not has_gossip:
		return {}
	if has_player_topic and not has_gossip:
		return _select_player_topic_spillover_candidate(player_topic_candidates)
	if has_gossip and not has_player_topic:
		return _select_gossip_spillover_candidate(gossip_candidates)

	if spread_rng.randf() < spread_player_topic_chance:
		return _select_player_topic_spillover_candidate(player_topic_candidates)

	return _select_gossip_spillover_candidate(gossip_candidates)


func _select_player_topic_spillover_candidate(player_topic_candidates: Array[Dictionary]) -> Dictionary:
	# Fear/anger normally choose the highest current value, with a small chance of another high emotion.
	if player_topic_candidates.is_empty():
		return {}
	if player_topic_candidates.size() == 1:
		return player_topic_candidates[0]

	if spread_rng.randf() >= spread_high_emotion_priority_chance:
		return player_topic_candidates[spread_rng.randi_range(0, player_topic_candidates.size() - 1)]

	var strongest_candidate: Dictionary = player_topic_candidates[0]
	var strongest_value := float(strongest_candidate.get("source_value", 0.0))
	for candidate in player_topic_candidates:
		var source_value := float(candidate.get("source_value", 0.0))
		if source_value > strongest_value:
			strongest_candidate = candidate
			strongest_value = source_value

	return strongest_candidate


func _select_gossip_spillover_candidate(gossip_candidates: Array[Dictionary]) -> Dictionary:
	# Gossip often chooses the strongest like/dislike, but can wander to another known NPC.
	if gossip_candidates.is_empty():
		return {}
	if gossip_candidates.size() == 1:
		return gossip_candidates[0]

	if spread_rng.randf() >= spread_gossip_extreme_priority_chance:
		return gossip_candidates[spread_rng.randi_range(0, gossip_candidates.size() - 1)]

	var strongest_candidate: Dictionary = gossip_candidates[0]
	var strongest_extreme := float(strongest_candidate.get("extreme", 0.0))
	for candidate in gossip_candidates:
		var candidate_extreme := float(candidate.get("extreme", 0.0))
		if candidate_extreme > strongest_extreme:
			strongest_candidate = candidate
			strongest_extreme = candidate_extreme

	return strongest_candidate


func _apply_spillover_candidate(
	candidate: Dictionary,
	partner_machine: NpcStateMachine,
	changed_values: Dictionary
) -> void:
	# Applies the chosen effect without forcing the listener to abandon their current action.
	var kind := String(candidate.get("kind", ""))
	var value_delta := float(candidate.get("delta", 0.0))
	if is_equal_approx(value_delta, 0.0):
		return

	if kind == "gossip_favor":
		var actual_favor_delta := _apply_gossip_favor_spillover(candidate, value_delta)
		if not is_equal_approx(actual_favor_delta, 0.0):
			var target_name := String(candidate.get("target_name", "npc"))
			changed_values["partner_relationship_favor:%s" % target_name] = actual_favor_delta
		return

	if kind == "player_trait":
		var value_name := StringName(String(candidate.get("value_name", "")))
		var actual_emotion_delta := _apply_talk_delta_to_machine(
			partner_machine,
			value_name,
			value_delta,
			npc
		)
		if not is_equal_approx(actual_emotion_delta, 0.0):
			changed_values["partner_%s" % String(value_name)] = actual_emotion_delta


func _apply_gossip_favor_spillover(candidate: Dictionary, value_delta: float) -> float:
	# The listener's relationship toward the third NPC moves after gossip.
	if talk_partner == null or not is_instance_valid(talk_partner):
		return 0.0

	var target_id := String(candidate.get("target_id", "")).strip_edges()
	if target_id.is_empty():
		return 0.0

	var relationships := _get_relationship_system()
	if relationships != null and relationships.has_method("change_favor_by_id"):
		var listener_id := _get_relationship_id_for_node(talk_partner)
		var previous_value := 50.0
		if relationships.has_method("get_favor_by_id"):
			previous_value = float(relationships.call("get_favor_by_id", listener_id, target_id, 50.0))

		var gossip_target := candidate.get("target", null) as Node
		var context := {
			"other_name": String(candidate.get("target_name", "")),
			"other_path": String(candidate.get("target_path", "")),
			"source": "talk_gossip",
		}
		if gossip_target != null and is_instance_valid(gossip_target):
			context["other"] = gossip_target

		var next_value := float(relationships.call(
			"change_favor_by_id",
			talk_partner,
			target_id,
			value_delta,
			"talk_gossip",
			context
		))
		return next_value - previous_value

	var live_target := candidate.get("target", null) as Node
	if live_target == null or not is_instance_valid(live_target):
		return 0.0
	if not talk_partner.has_method("change_relationship_favor_for"):
		return 0.0

	var fallback_previous_value := 50.0
	if talk_partner.has_method("get_relationship_favor_for"):
		fallback_previous_value = float(talk_partner.call("get_relationship_favor_for", live_target, 50.0))

	var fallback_next_value := float(talk_partner.call(
		"change_relationship_favor_for",
		live_target,
		value_delta,
		"talk_gossip"
	))
	return fallback_next_value - fallback_previous_value


func _apply_talk_delta_to_machine(
	target_machine: NpcStateMachine,
	value_name: StringName,
	value_delta: float,
	actor: Node2D
) -> float:
	# Applies a delta and returns the actual changed amount after clamping.
	if target_machine == null or value_name == &"":
		return 0.0

	var previous_value := target_machine.get_value(value_name)
	target_machine.apply_value_delta({String(value_name): value_delta}, actor, false)
	return target_machine.get_value(value_name) - previous_value


func _resolve_gossip_target(relationship: Dictionary, target_id: String) -> Node:
	# Finds the live NPC node for a stored relationship row.
	var other_path := String(relationship.get("other_path", ""))
	if not other_path.is_empty():
		var path_target := get_node_or_null(NodePath(other_path))
		if path_target != null and is_instance_valid(path_target):
			return path_target

	if not is_inside_tree():
		return null

	for group_name in spread_gossip_target_groups:
		for candidate in get_tree().get_nodes_in_group(String(group_name)):
			var candidate_node := candidate as Node
			if candidate_node == null or not is_instance_valid(candidate_node):
				continue
			if _get_relationship_id_for_node(candidate_node) == target_id:
				return candidate_node

	return null


func _is_gossip_target(target: Node) -> bool:
	# Loaded targets must match the allowed groups; off-scene targets are trusted saved NPC rows.
	if target == null:
		return true
	if not is_instance_valid(target):
		return false
	if spread_gossip_target_groups.is_empty():
		return true

	for group_name in spread_gossip_target_groups:
		if target.is_in_group(String(group_name)):
			return true

	return false


func _get_gossip_target_label(relationship: Dictionary, target: Node) -> String:
	var relationship_name := String(relationship.get("other_name", ""))
	if not relationship_name.is_empty():
		return relationship_name
	if target != null:
		return target.name

	return "npc"


func _get_relationship_id_for_node(target: Node) -> String:
	if target == null or not is_instance_valid(target):
		return ""

	var relationships := _get_relationship_system()
	if relationships != null and relationships.has_method("get_relationship_id"):
		return String(relationships.call("get_relationship_id", target))
	return NpcIdentity.get_actor_id(target, true)


func _get_relationship_system() -> Node:
	return get_node_or_null("/root/Relationships")


func _get_partner_machine() -> NpcStateMachine:
	# Player targets can safely return null; NPC partners expose a child machine.
	if talk_partner == null or not is_instance_valid(talk_partner):
		return null

	# Talk partners are world bodies like SocialNpc or Player. NPCs keep the machine as a child;
	# player targets can simply return null here and still satisfy this NPC's talk need.
	return talk_partner.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _clear_talk_target() -> void:
	# The interaction controller owns and clears the Talk session after exit.
	pass


func _call_talk_hook(target, method_name: StringName, args: Array) -> void:
	# Calls optional methods only when the target script actually implements them.
	if target == null or not is_instance_valid(target):
		return
	if target.has_method(method_name):
		target.callv(method_name, args)


func _face_talk_partner() -> void:
	# Keeps the NPC visually oriented toward whoever they are talking to.
	if npc == null or not _is_valid_talk_partner(talk_partner):
		return

	face_x_direction(talk_partner.global_position.x - npc.global_position.x)


func _partner_is_beyond_maximum_distance() -> bool:
	if maximum_talk_distance <= 0.0 or npc == null or not _is_valid_talk_partner(talk_partner):
		return false

	return _get_maximum_talk_distance_to_partner() > maximum_talk_distance


func _update_maximum_talk_distance_cancel(delta: float) -> bool:
	if not _partner_is_beyond_maximum_distance():
		maximum_distance_cancel_timer = maximum_talk_distance_cancel_seconds
		return false

	if maximum_talk_distance_cancel_seconds <= 0.0:
		_cancel_talk_action("maximum_distance")
		return true

	maximum_distance_cancel_timer -= delta
	if maximum_distance_cancel_timer > 0.0:
		return false

	_cancel_talk_action("maximum_distance")
	return true


func _update_talk_movement() -> void:
	if npc == null or not _is_valid_talk_partner(talk_partner):
		stop_horizontal()
		return

	if _talk_is_outside_active_range():
		_reconnect_to_talk_partner()
		return

	var desired_range := get_talk_approach_distance()
	var follow_resume_distance := minf(
		maxf(desired_range + talk_follow_resume_margin, desired_range),
		maxf(talk_range, desired_range)
	)
	var x_distance := absf(talk_partner.global_position.x - npc.global_position.x)
	var distance_for_follow := desired_range if following_partner else follow_resume_distance
	var should_follow := (
		follow_partner_while_talking
		and talk_follow_speed > 0.0
		and x_distance > distance_for_follow
	)
	if not should_follow:
		stop_horizontal()
		if following_partner and animation_name != &"":
			play_animation(animation_name)
		following_partner = false
		return

	if not following_partner and follow_animation_name != &"":
		play_animation(follow_animation_name)
	following_partner = true
	move_toward_position(talk_partner.global_position, _get_talk_follow_speed(), desired_range)


func _talk_is_outside_active_range() -> bool:
	if npc == null or not _is_valid_talk_partner(talk_partner):
		return false

	return _get_talk_distance_to_partner() > talk_range


func _reconnect_to_talk_partner() -> void:
	var approach_speed := _get_talk_approach_speed()
	if approach_speed <= 0.0:
		stop_horizontal()
		return

	if not following_partner and follow_animation_name != &"":
		play_animation(follow_animation_name)
	following_partner = true
	move_toward_position(talk_partner.global_position, approach_speed, get_talk_approach_distance())


func _needs_talk_approach() -> bool:
	if npc == null or not _is_valid_talk_partner(talk_partner):
		return false

	return _get_talk_distance_to_partner() > get_talk_approach_distance()


func _get_talk_distance_to_partner() -> float:
	if npc == null or not _is_valid_talk_partner(talk_partner):
		return 0.0
	if use_horizontal_talk_distance:
		return absf(talk_partner.global_position.x - npc.global_position.x)

	return npc.global_position.distance_to(talk_partner.global_position)


func _get_maximum_talk_distance_to_partner() -> float:
	if npc == null or not _is_valid_talk_partner(talk_partner):
		return 0.0

	var full_distance := npc.global_position.distance_to(talk_partner.global_position)
	if use_horizontal_talk_distance:
		return maxf(full_distance, absf(talk_partner.global_position.x - npc.global_position.x))

	return full_distance


func _update_talk_approach(delta: float) -> bool:
	# Direct Talk requests can come from sight reactions while the partner is still far away.
	# Approach first, then start the actual timed conversation once the spacing is comfortable.
	if npc == null or not _is_valid_talk_partner(talk_partner):
		stop_horizontal()
		return false

	if not _needs_talk_approach():
		stop_horizontal()
		approaching_partner = false
		maximum_distance_cancel_timer = maximum_talk_distance_cancel_seconds
		refresh_overlay_presentation()
		return true

	if static_task_talk:
		stop_horizontal()
		_face_talk_partner()
		if talk_approach_timeout > 0.0:
			approach_timer -= delta
			if approach_timer <= 0.0:
				_cancel_talk_action("approach_timeout")
		return false

	if talk_approach_timeout > 0.0:
		approach_timer -= delta
		if approach_timer <= 0.0:
			_cancel_talk_action("approach_timeout")
			return false

	move_toward_position(
		talk_partner.global_position,
		_get_talk_approach_speed(),
		get_talk_approach_distance()
	)
	_face_talk_partner()
	return false


func _get_talk_approach_speed() -> float:
	var approach_speed := talk_approach_speed
	if approach_speed <= 0.0 and machine != null:
		approach_speed = machine.get_effective_walk_speed()
		return maxf(approach_speed, _get_talk_follow_speed())

	var base_speed := maxf(approach_speed, talk_follow_speed)
	if machine != null:
		return base_speed * machine.get_fatigue_speed_multiplier()

	return base_speed


func _get_talk_follow_speed() -> float:
	if machine != null:
		return maxf(talk_follow_speed * machine.get_fatigue_speed_multiplier(), 0.0)

	return maxf(talk_follow_speed, 0.0)


func _is_emergency_interrupt_state(state_name: StringName) -> bool:
	for emergency_state_name in emergency_interrupt_states:
		if String(emergency_state_name) == String(state_name):
			return true

	return false


func _is_routine_interrupt_state(state_name: StringName) -> bool:
	for routine_state_name in ROUTINE_INTERRUPT_STATES:
		if String(routine_state_name) == String(state_name):
			return true

	return false


func _is_valid_talk_partner(candidate) -> bool:
	# A freed Node2D must be rejected before any typed cast or method call occurs.
	if candidate == null or not is_instance_valid(candidate):
		return false
	var candidate_node := candidate as Node2D
	return candidate_node != null and is_valid_target(candidate_node) and candidate_node != npc


func _show_talk_progress() -> void:
	if not show_talk_limits or npc == null:
		return

	_ensure_talk_progress_ring()
	if talk_progress_ring != null:
		talk_progress_ring.visible = true


func _hide_talk_progress() -> void:
	if talk_progress_ring != null and is_instance_valid(talk_progress_ring):
		talk_progress_ring.visible = false


func _ensure_talk_progress_ring() -> void:
	if talk_progress_ring != null and is_instance_valid(talk_progress_ring):
		return
	if npc == null:
		return

	talk_progress_ring = TalkProgressRing.new()
	talk_progress_ring.name = "TalkProgressRing"
	var diameter := maxf(talk_ring_size, 1.0)
	var ring_dimensions := Vector2(diameter, diameter)
	talk_progress_ring.position = (
		talk_limits_offset + ((talk_limits_size - ring_dimensions) * 0.5)
	)
	talk_progress_ring.size = ring_dimensions
	talk_progress_ring.custom_minimum_size = ring_dimensions
	talk_progress_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	talk_progress_ring.z_index = 120
	talk_progress_ring.ring_color = talk_ring_color
	talk_progress_ring.ring_width = talk_ring_width
	npc.add_child(talk_progress_ring)


func _update_talk_progress() -> void:
	if (
		external_completion_pending
		or not show_talk_limits
		or not _is_valid_talk_partner(talk_partner)
	):
		_hide_talk_progress()
		return

	_ensure_talk_progress_ring()
	if talk_progress_ring == null:
		return

	var remaining_ratio := 0.0
	if talk_total_duration > 0.0:
		remaining_ratio = clampf(talk_timer / talk_total_duration, 0.0, 1.0)
	talk_progress_ring.set_progress_ratio(remaining_ratio)
