class_name NpcSocialPlanner
extends RefCounted


const PLAYER_SOCIAL_TARGET_ID := "__player__"
const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")
const SocialMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_social_memory_policy.gd"
)
const SocialCandidateScorer = preload(
	"res://scripts/systems/npc_behavior/npc_social_candidate_scorer.gd"
)
const SOCIAL_SEEK_REASON_CODE := &"social_need_high"
const SOCIAL_SEEK_FEEDBACK_TEXT := "Looking for someone to talk to"
const SOCIAL_SEEK_ORIGIN_VALUE := &"talk_need"
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
var _social_memory_policy := SocialMemoryPolicy.new()
var _social_candidate_scorer := SocialCandidateScorer.new()
var _last_selection_descriptor: Dictionary = {}


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


func was_participant_used_this_pass(participant_id: String) -> bool:
	return _used_participants.has(participant_id.strip_edges())


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
	if machine.has_method("is_socially_engaged") and bool(machine.call("is_socially_engaged")):
		return _rejected("already_socially_engaged")
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
	candidate_evaluated: Callable = Callable(),
	short_term_memory: NpcShortTermMemory = null,
	now_game_hours: float = 0.0,
	selection_context: Dictionary = {}
) -> Dictionary:
	_last_selection_descriptor = _new_selection_descriptor(
		npc_id,
		now_game_hours
	)
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
		_last_selection_descriptor["reason_code"] = &"seeker_unavailable"
		return {}
	var seeker_scene_path := String(record.get("scene_path", ""))
	var candidates: Array[Dictionary] = []
	var owner_id := _get_record_relationship_id(
		npc_id,
		record,
		relationships
	)
	var preferred_target_id := String(record.get(
		"social_visit_target_id",
		""
	)).strip_edges()
	var live_requester: Node2D
	if locations != null and locations.has_method("get_live_npc"):
		live_requester = locations.call(
			"get_live_npc",
			String(npc_id)
		) as Node2D
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
		var player_relationship_id := _get_node_relationship_id(
			relationships,
			player,
			PLAYER_SOCIAL_TARGET_ID
		)
		var player_has_live_distance := live_requester != null
		_consider_candidate({
			"target_id": PLAYER_SOCIAL_TARGET_ID,
			"scene_path": player_scene_path,
			"position": player.global_position,
			"is_player": true,
		}, seeker_scene_path, candidates, short_term_memory, now_game_hours, selection_context, {
			"relationship": _get_relationship_snapshot(
				relationships,
				owner_id,
				player_relationship_id
			),
			"is_authored_preference": (
				preferred_target_id == PLAYER_SOCIAL_TARGET_ID
			),
			"has_live_distance": player_has_live_distance,
			"live_distance": (
				live_requester.global_position.distance_to(player.global_position)
				if player_has_live_distance
				else 0.0
			),
		})

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
			target_record,
			relationships
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
		var target_live: Node2D
		if locations.has_method("get_live_npc"):
			target_live = locations.call("get_live_npc", target_id) as Node2D
			if target_live != null:
				target_position = target_live.global_position
		_consider_candidate({
			"target_id": target_id,
			"scene_path": String(target_record.get("scene_path", "")),
			"position": target_position,
			"is_player": false,
		}, seeker_scene_path, candidates, short_term_memory, now_game_hours, selection_context, {
			"relationship": _get_relationship_snapshot(
				relationships,
				owner_id,
				target_relationship_id
			),
			"is_authored_preference": preferred_target_id == target_id,
			"has_live_distance": (
				live_requester != null and target_live != null
			),
			"live_distance": (
				live_requester.global_position.distance_to(
					target_live.global_position
				)
				if live_requester != null and target_live != null
				else 0.0
			),
		})

	if candidates.is_empty():
		if (
			int(_last_selection_descriptor.get("candidates_considered", 0)) > 0
			and int(_last_selection_descriptor.get("suppressed_count", 0))
				== int(_last_selection_descriptor.get("candidates_considered", 0))
		):
			_last_selection_descriptor["all_candidates_suppressed"] = true
			_last_selection_descriptor["reason_code"] = (
				&"no_social_target_due_to_recent_memory"
			)
			_last_selection_descriptor["remaining_retry_hours"] = maxf(
				float(_last_selection_descriptor.get(
					"earliest_retry_game_hours",
					now_game_hours
				)) - now_game_hours,
				0.0
			)
		else:
			_last_selection_descriptor["reason_code"] = &"no_social_target"
		return {}
	candidates.sort_custom(_scored_candidate_precedes)
	return _record_selected_candidate(candidates[0])


func get_last_selection_descriptor() -> Dictionary:
	# Candidate diagnostics are accumulated in one internal array. Add the legacy
	# alias only after making the public defensive copy so candidate evaluation
	# does not repeatedly clone every decision collected so far.
	var descriptor := _last_selection_descriptor.duplicate(true)
	var candidate_decisions: Array = descriptor.get("candidate_decisions", [])
	descriptor["candidates"] = candidate_decisions
	return descriptor


func _get_relationship_snapshot(
	relationships: Node,
	owner_id: String,
	other_id: String
) -> Dictionary:
	if (
		relationships == null
		or owner_id.strip_edges().is_empty()
		or other_id.strip_edges().is_empty()
		or not relationships.has_method("get_relationship_by_id")
	):
		return {}
	var snapshot = relationships.call(
		"get_relationship_by_id",
		owner_id,
		other_id
	)
	return snapshot.duplicate(true) if snapshot is Dictionary else {}


func _get_node_relationship_id(
	relationships: Node,
	actor: Node,
	fallback: String
) -> String:
	if (
		relationships != null
		and actor != null
		and relationships.has_method("get_relationship_id")
	):
		var relationship_id := String(relationships.call(
			"get_relationship_id",
			actor
		)).strip_edges()
		if not relationship_id.is_empty():
			return relationship_id
	var stable_actor_id := NpcIdentity.get_stable_actor_id(actor)
	if not stable_actor_id.is_empty():
		return stable_actor_id
	return fallback.strip_edges()


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


func _consider_candidate(
	candidate: Dictionary,
	seeker_scene_path: String,
	candidates: Array[Dictionary],
	short_term_memory: NpcShortTermMemory,
	now_game_hours: float,
	selection_context: Dictionary,
	score_context: Dictionary
) -> void:
	var candidate_scene_path := String(candidate.get("scene_path", ""))
	if candidate_scene_path.is_empty() or candidate_scene_path != seeker_scene_path:
		return
	_last_selection_descriptor["candidates_considered"] = (
		int(_last_selection_descriptor.get("candidates_considered", 0)) + 1
	)
	_last_selection_descriptor["candidate_count"] = int(
		_last_selection_descriptor.get("candidates_considered", 0)
	)
	var candidate_id := String(candidate.get("target_id", ""))
	var decision := {
		"candidate_id": candidate_id,
		"allowed": true,
		"reason_code": &"",
		"memory_event_type": &"",
		"memory_id": "",
		"remaining_retry_hours": 0.0,
		"retry_game_hours": 0.0,
	}
	if short_term_memory != null:
		decision.merge(
			_social_memory_policy.evaluate_candidate(
				short_term_memory,
				StringName(candidate_id),
				now_game_hours,
				selection_context
			),
			true
		)
	decision["candidate_id"] = candidate_id
	var candidate_decisions: Array = _last_selection_descriptor.get(
		"candidate_decisions",
		[]
	)
	candidate_decisions.append(decision)
	_last_selection_descriptor["candidate_decisions"] = candidate_decisions
	if not bool(decision.get("allowed", true)):
		_last_selection_descriptor["suppressed_count"] = (
			int(_last_selection_descriptor.get("suppressed_count", 0)) + 1
		)
		var reason_code := StringName(String(decision.get("reason_code", "")))
		var suppressed_by_reason: Dictionary = _last_selection_descriptor.get(
			"suppressed_by_reason",
			{}
		)
		suppressed_by_reason[reason_code] = (
			int(suppressed_by_reason.get(reason_code, 0)) + 1
		)
		_last_selection_descriptor["suppressed_by_reason"] = suppressed_by_reason
		if reason_code == SocialMemoryPolicy.RECENT_REFUSAL_REASON:
			_last_selection_descriptor["suppressed_by_refusal_count"] = (
				int(_last_selection_descriptor.get(
					"suppressed_by_refusal_count",
					0
				)) + 1
			)
		var retry_game_hours := float(decision.get("retry_game_hours", 0.0))
		var earliest_retry := float(_last_selection_descriptor.get(
			"earliest_retry_game_hours",
			0.0
		))
		if earliest_retry <= 0.0 or retry_game_hours < earliest_retry:
			_last_selection_descriptor["earliest_retry_game_hours"] = retry_game_hours
		return
	var score_result := _social_candidate_scorer.score_candidate(
		StringName(String(_last_selection_descriptor.get("requester_id", ""))),
		StringName(candidate_id),
		score_context
	)
	decision.merge(score_result, true)
	candidate["social_score"] = score_result.duplicate(true)
	candidates.append(candidate)


func _new_selection_descriptor(
	npc_id: StringName,
	now_game_hours: float
) -> Dictionary:
	return {
		"requester_id": String(npc_id),
		"seeker_id": String(npc_id),
		"evaluated_game_hours": now_game_hours,
		"evaluated_at_usec": Time.get_ticks_usec(),
		"candidate_count": 0,
		"candidates_considered": 0,
		"suppressed_count": 0,
		"suppressed_by_refusal_count": 0,
		"suppressed_by_reason": {
			SocialMemoryPolicy.RECENT_REFUSAL_REASON: 0,
			SocialMemoryPolicy.RECENT_HARM_REASON: 0,
			SocialMemoryPolicy.RECENT_CONVERSATION_REASON: 0,
		},
		"selected_candidate_id": "",
		"alternative_selected": false,
		"all_candidates_suppressed": false,
		"earliest_retry_game_hours": 0.0,
		"remaining_retry_hours": 0.0,
		"reason_code": &"",
		"candidate_decisions": [],
	}


func _record_selected_candidate(candidate: Dictionary) -> Dictionary:
	_last_selection_descriptor["selected_candidate_id"] = String(
		candidate.get("target_id", "")
	)
	_last_selection_descriptor["alternative_selected"] = (
		int(_last_selection_descriptor.get("suppressed_count", 0)) > 0
	)
	_last_selection_descriptor["reason_code"] = &""
	return candidate


static func _scored_candidate_precedes(a: Dictionary, b: Dictionary) -> bool:
	var a_score: Dictionary = a.get("social_score", {})
	var b_score: Dictionary = b.get("social_score", {})
	var a_total := float(a_score.get("total_score", 0.0))
	var b_total := float(b_score.get("total_score", 0.0))
	if not is_equal_approx(a_total, b_total):
		return a_total > b_total
	var a_has_distance := bool(a_score.get("has_live_distance", false))
	var b_has_distance := bool(b_score.get("has_live_distance", false))
	if a_has_distance != b_has_distance:
		return a_has_distance
	if a_has_distance:
		var a_distance := float(a_score.get("live_distance", 0.0))
		var b_distance := float(b_score.get("live_distance", 0.0))
		if not is_equal_approx(a_distance, b_distance):
			return a_distance < b_distance
	return String(a.get("target_id", "")) < String(b.get("target_id", ""))


func _get_record_relationship_id(
	npc_id: StringName,
	record: Dictionary,
	relationships: Node = null
) -> String:
	var canonical_id := String(npc_id).strip_edges()
	var node_state = record.get("node_state", {})
	if node_state is Dictionary:
		var legacy_id := String(
			node_state.get("relationship_id", "")
		).strip_edges()
		if not legacy_id.is_empty() and legacy_id != canonical_id:
			if (
				relationships != null
				and relationships.has_method("migrate_relationship_alias")
			):
				var migration = relationships.call(
					"migrate_relationship_alias",
					legacy_id,
					canonical_id
				)
				if (
					migration is Dictionary
					and bool(migration.get("accepted", false))
				):
					return canonical_id
			# Compatibility for injected/legacy relationship services that do not
			# expose migration, or for records whose key is itself transient.
			return legacy_id
	if not canonical_id.is_empty():
		return canonical_id
	return ""


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
