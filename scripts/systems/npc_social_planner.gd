class_name NpcSocialPlanner
extends RefCounted


const PLAYER_SOCIAL_TARGET_ID := "__player__"
const ACTIVE_CONVERSATION_STATES := ["Talk", "LookForTalkTarget"]
const INTERRUPTIBLE_SIMULATED_ACTIVITY_STATES := [
	"Idle",
	"Work",
	"Eat",
	"Rest",
	"Recreation",
	"RoutineTask",
]

var _favor_cache: Dictionary = {}
var _participant_reservations: Dictionary = {}
var _sessions: Dictionary = {}
var _used_participants: Dictionary = {}
var _session_serial: int = 0


func begin_simulation_pass() -> void:
	_favor_cache.clear()
	_participant_reservations.clear()
	_sessions.clear()
	_used_participants.clear()


func end_simulation_pass() -> void:
	_favor_cache.clear()
	_participant_reservations.clear()
	_sessions.clear()
	_used_participants.clear()


func get_participant_availability(
	participant_id: String,
	record: Dictionary,
	locations: Node,
	requested_priority: int,
	as_seeker: bool = false,
	live_player: Node2D = null,
	records: Dictionary = {}
) -> Dictionary:
	var clean_id := participant_id.strip_edges()
	if clean_id.is_empty():
		return _rejected("missing_participant_id")
	if _participant_reservations.has(clean_id):
		return _rejected("reserved_by_social_session")
	if _used_participants.has(clean_id):
		return _rejected("already_used_this_pass")

	if clean_id == PLAYER_SOCIAL_TARGET_ID:
		if live_player == null or not is_instance_valid(live_player):
			return _rejected("player_unavailable")
		if _player_is_in_live_conversation(records, locations, live_player):
			return _rejected("player_already_in_live_conversation")
		return _accepted()

	if record.is_empty():
		return _rejected("missing_record")
	var record_reason := _get_record_unavailability_reason(record, as_seeker)
	if not record_reason.is_empty():
		return _rejected(record_reason)

	var live_npc: Node
	if locations != null and locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", clean_id) as Node
	if live_npc == null:
		return _accepted()

	var machine := live_npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return _rejected("live_state_machine_missing")
	var current_state = machine.get("current_state")
	var current_state_name := String(current_state.name) if current_state != null else ""
	if current_state_name == "Sleep":
		return _rejected("sleeping")
	for conversation_state_name in ACTIVE_CONVERSATION_STATES:
		if machine.has_method("is_in_state") and bool(machine.call("is_in_state", conversation_state_name)):
			return _rejected("already_in_live_conversation")
		if current_state_name == String(conversation_state_name):
			return _rejected("already_in_live_conversation")
	if machine.has_method("can_begin_player_interaction"):
		var interaction_gate = machine.call("can_begin_player_interaction", null)
		if interaction_gate is Dictionary and not bool(interaction_gate.get("accepted", false)):
			return _rejected(String(interaction_gate.get("reason", "live_npc_unavailable")))
	if locations != null and locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			clean_id,
			&"LookForTalkTarget",
			requested_priority,
			{}
		)):
			return _rejected("non_interruptible_live_activity")
	return _accepted()


func reserve_pair(
	seeker_id: String,
	seeker_record: Dictionary,
	target_id: String,
	target_record: Dictionary,
	locations: Node,
	requested_priority: int,
	live_player: Node2D = null,
	records: Dictionary = {}
) -> Dictionary:
	var clean_seeker_id := seeker_id.strip_edges()
	var clean_target_id := target_id.strip_edges()
	if clean_seeker_id.is_empty() or clean_target_id.is_empty():
		return _rejected("missing_participant_id")
	if clean_seeker_id == clean_target_id:
		return _rejected("same_participant")

	var seeker_gate := get_participant_availability(
		clean_seeker_id,
		seeker_record,
		locations,
		requested_priority,
		true,
		live_player,
		records
	)
	if not bool(seeker_gate.get("accepted", false)):
		return _rejected("seeker_%s" % String(seeker_gate.get("reason", "unavailable")))
	var target_gate := get_participant_availability(
		clean_target_id,
		target_record,
		locations,
		requested_priority,
		false,
		live_player,
		records
	)
	if not bool(target_gate.get("accepted", false)):
		return _rejected("target_%s" % String(target_gate.get("reason", "unavailable")))

	_session_serial += 1
	var session_id := "social:%d:%d" % [Time.get_ticks_usec(), _session_serial]
	# Commit both participant reservations only after both availability checks pass.
	_participant_reservations[clean_seeker_id] = session_id
	_participant_reservations[clean_target_id] = session_id
	_used_participants[clean_seeker_id] = session_id
	_used_participants[clean_target_id] = session_id
	_sessions[session_id] = {
		"seeker_id": clean_seeker_id,
		"target_id": clean_target_id,
	}
	return {
		"accepted": true,
		"reason": "",
		"session_id": session_id,
	}


func finish_session(session_id: String, completed: bool) -> bool:
	if session_id.is_empty() or not _sessions.has(session_id):
		return false
	var session: Dictionary = _sessions[session_id]
	for participant_key in ["seeker_id", "target_id"]:
		var participant_id := String(session.get(participant_key, ""))
		if String(_participant_reservations.get(participant_id, "")) == session_id:
			_participant_reservations.erase(participant_id)
		if not completed and String(_used_participants.get(participant_id, "")) == session_id:
			_used_participants.erase(participant_id)
	_sessions.erase(session_id)
	return true


func choose_candidate(
	npc_id: StringName,
	record: Dictionary,
	records: Dictionary,
	locations: Node,
	settings: Dictionary,
	relationships: Node,
	player: Node2D,
	rng: RandomNumberGenerator,
	candidate_evaluated: Callable = Callable()
) -> Dictionary:
	var seek_priority := int(settings.get("priority", 60))
	var seeker_gate := get_participant_availability(
		String(npc_id),
		record,
		locations,
		seek_priority,
		true,
		player,
		records
	)
	if not bool(seeker_gate.get("accepted", false)):
		return {}
	var seeker_scene_path := String(record.get("scene_path", ""))
	var local_candidates: Array[Dictionary] = []
	var remote_candidates: Array[Dictionary] = []
	var player_gate := get_participant_availability(
		PLAYER_SOCIAL_TARGET_ID,
		{},
		locations,
		seek_priority,
		false,
		player,
		records
	)
	if bool(player_gate.get("accepted", false)):
		var player_scene_path := String(locations.call("get_current_scene_path"))
		_add_candidate({
			"target_id": PLAYER_SOCIAL_TARGET_ID,
			"scene_path": player_scene_path,
			"position": player.global_position,
			"is_player": true,
		}, seeker_scene_path, local_candidates, remote_candidates)

	var owner_id := _get_record_relationship_id(npc_id, record)
	var minimum_favor := float(settings.get("minimum_npc_favor", 10.0))
	for target_id_key in records.keys():
		var target_id := String(target_id_key)
		if target_id == String(npc_id):
			continue
		var target_record = records[target_id_key]
		if not (target_record is Dictionary):
			continue
		var target_gate := get_participant_availability(
			target_id,
			target_record,
			locations,
			seek_priority,
			false,
			player
		)
		if not bool(target_gate.get("accepted", false)):
			continue
		if candidate_evaluated.is_valid():
			candidate_evaluated.call()
		var target_relationship_id := _get_record_relationship_id(
			StringName(target_id),
			target_record
		)
		if relationships != null and relationships.has_method("get_favor_by_id"):
			var seeker_favor := _get_cached_favor(
				relationships,
				owner_id,
				target_relationship_id,
				50.0
			)
			var target_favor := _get_cached_favor(
				relationships,
				target_relationship_id,
				owner_id,
				50.0
			)
			if seeker_favor <= minimum_favor or target_favor <= minimum_favor:
				continue
		var target_position = target_record.get("last_position", Vector2.ZERO)
		if locations.has_method("get_live_npc"):
			var target_live := locations.call("get_live_npc", target_id) as Node2D
			if target_live != null:
				target_position = target_live.global_position
		_add_candidate({
			"target_id": target_id,
			"scene_path": String(target_record.get("scene_path", "")),
			"position": target_position,
			"is_player": false,
		}, seeker_scene_path, local_candidates, remote_candidates)

	var allow_remote := bool(settings.get("allow_remote_visits", false)) and _supports_remote_visit(locations)
	var candidates: Array[Dictionary] = []
	if not local_candidates.is_empty():
		candidates = local_candidates
	elif allow_remote:
		candidates = remote_candidates
	if candidates.is_empty():
		return {}
	var preferred_target_id := String(record.get("social_visit_target_id", ""))
	for candidate in candidates:
		if not preferred_target_id.is_empty() and String(candidate.get("target_id", "")) == preferred_target_id:
			return candidate

	var player_chance := clampf(float(settings.get("player_target_chance", 0.35)), 0.0, 1.0)
	if rng.randf() < player_chance:
		for candidate in candidates:
			if bool(candidate.get("is_player", false)):
				return candidate
	return candidates[rng.randi_range(0, candidates.size() - 1)]


func _get_cached_favor(
	relationships: Node,
	owner_id: String,
	other_id: String,
	fallback: float
) -> float:
	var favors_for_owner = _favor_cache.get(owner_id, null)
	if favors_for_owner is Dictionary and favors_for_owner.has(other_id):
		return float(favors_for_owner[other_id])

	var favor := float(relationships.call("get_favor_by_id", owner_id, other_id, fallback))
	if not (favors_for_owner is Dictionary):
		favors_for_owner = {}
		_favor_cache[owner_id] = favors_for_owner
	favors_for_owner[other_id] = favor
	return favor


func _add_candidate(
	candidate: Dictionary,
	seeker_scene_path: String,
	local_candidates: Array[Dictionary],
	remote_candidates: Array[Dictionary]
) -> void:
	if String(candidate.get("scene_path", "")).is_empty():
		return
	if String(candidate.get("scene_path", "")) == seeker_scene_path:
		local_candidates.append(candidate)
	else:
		remote_candidates.append(candidate)


func _get_record_relationship_id(npc_id: StringName, record: Dictionary) -> String:
	var node_state = record.get("node_state", {})
	if node_state is Dictionary:
		var relationship_id := String(node_state.get("relationship_id", ""))
		if not relationship_id.is_empty():
			return relationship_id
	return String(npc_id)


func _record_is_disabled(record: Dictionary) -> bool:
	return _get_saved_stat(record, "disabled", 0.0) >= 1.0 or _get_saved_stat(record, "hp", 1.0) <= 0.0


func _get_saved_stat(record: Dictionary, value_name: String, fallback: float = 0.0) -> float:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return fallback
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return fallback
	return float(social_stats.get(value_name, fallback))


func _get_record_unavailability_reason(record: Dictionary, as_seeker: bool) -> String:
	if _record_is_disabled(record):
		return "disabled_or_dead"
	var node_state = record.get("node_state", {})
	if node_state is Dictionary:
		if bool(node_state.get("is_downed", false)) or bool(node_state.get("dead", false)):
			return "downed_or_dead"
	if _get_saved_stat(record, "knockout", 0.0) >= 100.0:
		return "knocked_out"
	if not String(record.get("previous_scene_path", "")).is_empty():
		return "travelling"
	var pending = record.get("pending_travel", {})
	if pending is Dictionary and not pending.is_empty():
		return "pending_travel"
	if not String(record.get("social_session_id", "")).is_empty():
		return "already_in_simulated_conversation"
	if not as_seeker and not String(record.get("social_visit_target_id", "")).is_empty():
		return "reserved_by_existing_social_request"

	var activity = record.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		var activity_state := String(activity.get("state_name", ""))
		if activity_state == "Sleep":
			return "sleeping"
		if ACTIVE_CONVERSATION_STATES.has(activity_state):
			return "already_in_simulated_conversation"
		if activity.has("allows_social_interrupt"):
			if not bool(activity.get("allows_social_interrupt", false)):
				return "non_interruptible_activity"
		elif not INTERRUPTIBLE_SIMULATED_ACTIVITY_STATES.has(activity_state):
			return "non_interruptible_activity"
	return ""


func _supports_remote_visit(locations: Node) -> bool:
	return locations != null and (
		locations.has_method("move_simulated_npc_for_social_visit")
		or locations.has_method("prepare_scheduled_travel")
	)


func _player_is_in_live_conversation(
	records: Dictionary,
	locations: Node,
	player: Node2D
) -> bool:
	if records.is_empty() or locations == null or not locations.has_method("get_live_npc"):
		return false
	for npc_id_key in records.keys():
		var live_npc := locations.call("get_live_npc", String(npc_id_key)) as Node
		if live_npc == null:
			continue
		var machine := live_npc.get_node_or_null("NpcStateMachine")
		if machine == null or not machine.has_method("get_current_activity_descriptor"):
			continue
		var descriptor = machine.call("get_current_activity_descriptor")
		if not (descriptor is Dictionary):
			continue
		if not ACTIVE_CONVERSATION_STATES.has(String(descriptor.get("action_kind", ""))):
			continue
		if String(descriptor.get("target_npc_id", "")) == PLAYER_SOCIAL_TARGET_ID:
			return true
		var target_node = descriptor.get("target_node", null)
		if target_node is Node and is_instance_valid(target_node) and target_node == player:
			return true
	return false


func _accepted() -> Dictionary:
	return {"accepted": true, "reason": ""}


func _rejected(reason: String) -> Dictionary:
	return {"accepted": false, "reason": reason}
