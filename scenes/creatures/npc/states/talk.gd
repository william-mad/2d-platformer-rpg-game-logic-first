class_name NpcStateTalk extends NpcState

signal talk_started(talker: Node2D, partner: Node2D)
signal talk_finished(talker: Node2D, partner: Node2D, changed_values: Dictionary)
signal talk_cancelled(talker: Node2D, partner: Node2D, reason: String)

@export_group("Timing and Range")
# Negative duration uses the owning state machine's game-time-scaled Talk duration.
@export_range(-1.0, 60.0, 0.1, "suffix:s") var talk_duration: float = -1.0
@export_range(0.0, 512.0, 1.0, "suffix:px") var talk_range: float = 32.0
@export_range(0.0, 1024.0, 1.0, "suffix:px") var maximum_talk_distance: float = 180.0
@export_range(0.1, 1.0, 0.01) var preferred_talk_distance_ratio: float = 0.65
@export_range(0.0, 64.0, 1.0, "suffix:px") var talk_follow_resume_margin: float = 6.0
@export var use_horizontal_talk_distance: bool = true
@export var follow_partner_while_talking: bool = true
@export_range(0.0, 200.0, 1.0, "suffix:px/s") var talk_follow_speed: float = 20.0
@export_range(0.0, 200.0, 1.0, "suffix:px/s") var talk_approach_speed: float = 65.0
@export_range(0.0, 30.0, 0.1, "suffix:s") var talk_approach_timeout: float = 8.0
@export var follow_animation_name: StringName = &"walk"

@export_group("Visible Limits")
@export var show_talk_limits: bool = true
@export var talk_limits_offset: Vector2 = Vector2(-90.0, -172.0)
@export var talk_limits_size: Vector2 = Vector2(180.0, 20.0)
@export_range(6, 24, 1) var talk_limits_font_size: int = 10
@export_range(0.0, 1.0, 0.01) var near_break_distance_ratio: float = 0.8

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
@export var spread_emotion_value_names: Array[StringName] = [&"fear", &"anger"]
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

var talk_timer: float = 0.0
var talk_total_duration: float = 0.0
var talk_partner: Node2D
var talk_started_handled: bool = false
var talk_finished_handled: bool = false
var following_partner: bool = false
var approaching_partner: bool = false
var approach_timer: float = 0.0
var talk_limits_label: Label
var spread_rng := RandomNumberGenerator.new()


func init() -> void:
	super.init()
	spread_rng.randomize()


func enter() -> void:
	# Starts a timed talk with the assigned partner or the machine's active target.
	super.enter()
	talk_partner = machine.talk_target if machine.talk_target != null else machine.get_active_target()
	talk_started_handled = false
	talk_finished_handled = false
	following_partner = false
	approaching_partner = false
	approach_timer = talk_approach_timeout
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
		_hide_talk_limits()
		return

	_show_talk_limits()
	_update_talk_limits()
	if _needs_talk_approach():
		approaching_partner = true
		if follow_animation_name != &"":
			play_animation(follow_animation_name)
		return

	_start_talk_action()


func exit() -> void:
	# Treat leaving early as a cancelled talk, so no talk_need reduction happens.
	stop_horizontal()
	following_partner = false
	approaching_partner = false
	_hide_talk_limits()
	if talk_started_handled and not talk_finished_handled:
		_cancel_talk_action("state_exit")


func physics_process(delta: float) -> NpcState:
	# The timed window continues while the NPC slowly follows a drifting partner.
	if require_talk_partner and not _is_valid_talk_partner(talk_partner):
		_cancel_talk_action("missing_partner")
		return get_state(end_state_name)

	if _partner_is_beyond_maximum_distance():
		_cancel_talk_action("partner_out_of_range")
		return get_state(end_state_name)

	if approaching_partner:
		if _update_talk_approach(delta):
			_start_talk_action()
		if talk_finished_handled:
			return get_state(end_state_name)
		_update_talk_limits()
		return next_state

	_update_talk_movement()
	_face_talk_partner()
	_update_talk_limits()
	if _talk_is_outside_active_range():
		return next_state

	if talk_timer <= 0.0:
		_finish_talk_action()
		return get_state(end_state_name)

	talk_timer -= delta
	_update_talk_limits()
	if talk_timer > 0.0:
		return next_state

	_finish_talk_action()
	return get_state(end_state_name)


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


func get_talk_approach_distance() -> float:
	# Search states use this smaller distance so NPCs do not stop at the range edge.
	return maxf(talk_range * preferred_talk_distance_ratio, 0.0)


func _start_talk_action() -> void:
	# Emits start hooks for future dialogue UI, barks, or animation wiring.
	if talk_started_handled:
		return

	talk_started_handled = true
	talk_started.emit(npc, talk_partner)

	# Hook dialogue UI, bark text, voice, or custom talk animation here.
	_call_talk_hook(npc, &"on_npc_talk_started", [talk_partner, self, talk_action_name])
	_call_talk_hook(talk_partner, &"on_npc_talk_received", [npc, self, talk_action_name])


func _finish_talk_action() -> void:
	# Applies talk relief and emits finish hooks once, at successful completion.
	if talk_finished_handled:
		return

	stop_horizontal()
	_hide_talk_limits()
	talk_finished_handled = true
	var changed_values := {}

	var skip_own_need_payout := machine.consume_next_talk_need_payout_already_applied()
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
	_clear_talk_target()


func _cancel_talk_action(reason: String) -> void:
	# Clears the talk target without changing needs when talk is interrupted.
	if talk_finished_handled:
		return

	stop_horizontal()
	approaching_partner = false
	following_partner = false
	_hide_talk_limits()
	talk_finished_handled = true
	if talk_started_handled:
		var valid_partner := talk_partner if is_instance_valid(talk_partner) else null
		talk_cancelled.emit(npc, valid_partner, reason)
		_call_talk_hook(npc, &"on_npc_talk_cancelled", [valid_partner, self, reason])
		_call_talk_hook(valid_partner, &"on_npc_talk_cancelled_with", [npc, self, reason])

	if not reason.begins_with("partner_"):
		_cancel_partner_talk_if_linked(reason)

	_clear_talk_target()


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
		partner_machine.current_state != null
		and String(partner_machine.current_state.name) == "Talk"
		and partner_machine.talk_target == npc
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
	# Player-related emotional talk spreads strong traits such as fear or anger.
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
	if target == null:
		return ""

	var relationships := _get_relationship_system()
	if relationships != null and relationships.has_method("get_relationship_id"):
		return String(relationships.call("get_relationship_id", target))

	if target.has_method("get_relationship_id"):
		return String(target.call("get_relationship_id"))
	if target.has_meta("relationship_id"):
		return String(target.get_meta("relationship_id"))
	if target.is_inside_tree():
		return String(target.get_path())

	return "instance:%s" % target.get_instance_id()


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
	# Prevents the next Talk state from reusing a stale partner.
	if machine != null and machine.talk_target == talk_partner:
		machine.talk_target = null


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

	return _get_talk_distance_to_partner() > maximum_talk_distance


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
	move_toward_position(talk_partner.global_position, talk_follow_speed, desired_range)


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


func _update_talk_approach(delta: float) -> bool:
	# Direct Talk requests can come from sight reactions while the partner is still far away.
	# Approach first, then start the actual timed conversation once the spacing is comfortable.
	if npc == null or not _is_valid_talk_partner(talk_partner):
		stop_horizontal()
		return false

	if not _needs_talk_approach():
		stop_horizontal()
		approaching_partner = false
		if animation_name != &"":
			play_animation(animation_name)
		return true

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
		approach_speed = machine.walk_speed

	return maxf(approach_speed, talk_follow_speed)


func _is_valid_talk_partner(candidate) -> bool:
	# A freed Node2D must be rejected before any typed cast or method call occurs.
	if candidate == null or not is_instance_valid(candidate):
		return false
	var candidate_node := candidate as Node2D
	return candidate_node != null and is_valid_target(candidate_node) and candidate_node != npc


func _show_talk_limits() -> void:
	if not show_talk_limits or npc == null:
		return

	_ensure_talk_limits_label()
	if talk_limits_label != null:
		talk_limits_label.visible = true


func _hide_talk_limits() -> void:
	if talk_limits_label != null and is_instance_valid(talk_limits_label):
		talk_limits_label.visible = false


func _ensure_talk_limits_label() -> void:
	if talk_limits_label != null and is_instance_valid(talk_limits_label):
		return
	if npc == null:
		return

	talk_limits_label = Label.new()
	talk_limits_label.name = "TalkLimitsLabel"
	talk_limits_label.position = talk_limits_offset
	talk_limits_label.size = talk_limits_size
	talk_limits_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	talk_limits_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	talk_limits_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	talk_limits_label.z_index = 120
	talk_limits_label.add_theme_font_size_override("font_size", talk_limits_font_size)
	talk_limits_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	talk_limits_label.add_theme_constant_override("outline_size", 3)
	npc.add_child(talk_limits_label)


func _update_talk_limits() -> void:
	if not show_talk_limits or not _is_valid_talk_partner(talk_partner):
		_hide_talk_limits()
		return

	_ensure_talk_limits_label()
	if talk_limits_label == null:
		return

	var distance := _get_talk_distance_to_partner()
	var break_distance := maxf(maximum_talk_distance, 0.0)
	var mode_text := "Talk"
	if approaching_partner:
		mode_text = "Approach"
	elif _talk_is_outside_active_range():
		mode_text = "Reconnect"
	talk_limits_label.text = "%s %.1f/%.1fs | %.0f/%.0fpx" % [
		mode_text,
		maxf(talk_timer, 0.0),
		talk_total_duration,
		distance,
		break_distance,
	]

	var next_color := Color(0.45, 1.0, 0.55, 1.0)
	if distance > talk_range:
		next_color = Color(1.0, 0.88, 0.3, 1.0)
	if break_distance > 0.0 and distance >= break_distance * near_break_distance_ratio:
		next_color = Color(1.0, 0.35, 0.25, 1.0)
	talk_limits_label.add_theme_color_override("font_color", next_color)
