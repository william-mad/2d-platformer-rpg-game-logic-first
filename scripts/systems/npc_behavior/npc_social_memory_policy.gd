class_name NpcSocialMemoryPolicy extends RefCounted

const MemoryPolicy = preload("res://scripts/systems/npc_behavior/npc_memory_policy.gd")

const RECENT_REFUSAL_REASON: StringName = &"recent_conversation_refusal"
const RECENT_HARM_REASON: StringName = &"recently_harmed_by_candidate"
const RECENT_CONVERSATION_REASON: StringName = &"recently_talked_with_candidate"

const DEFAULT_REFUSAL_RETRY_DELAY_GAME_HOURS: float = 0.25
const DEFAULT_HARM_RETRY_DELAY_GAME_HOURS: float = 0.5
const DEFAULT_CONVERSATION_REPEAT_DELAY_GAME_HOURS: float = 0.125

const _SEVERITY_BY_REASON := {
	RECENT_HARM_REASON: 3,
	RECENT_REFUSAL_REASON: 2,
	RECENT_CONVERSATION_REASON: 1,
}

var recent_refusal_retry_delay_game_hours: float = (
	DEFAULT_REFUSAL_RETRY_DELAY_GAME_HOURS
)
var recent_harm_social_delay_game_hours: float = (
	DEFAULT_HARM_RETRY_DELAY_GAME_HOURS
)
var recent_conversation_repeat_delay_game_hours: float = (
	DEFAULT_CONVERSATION_REPEAT_DELAY_GAME_HOURS
)


func evaluate_candidate(
	memory: NpcShortTermMemory,
	candidate_persistent_id: StringName,
	now_game_hours: float,
	context: Dictionary = {}
) -> Dictionary:
	var candidate_id := String(candidate_persistent_id).strip_edges()
	var decision := _allowed_decision(StringName(candidate_id))
	if candidate_id.is_empty():
		decision["reason_code"] = &"invalid_candidate_id"
		decision["details"] = {"candidate_identity_valid": false}
		return decision
	if memory == null:
		return decision

	var remembering_npc_id := String(
		context.get("remembering_npc_id", "")
	).strip_edges()
	var refusal_delay := maxf(float(context.get(
		"recent_refusal_retry_delay_game_hours",
		context.get(
			"retry_delay_game_hours",
			recent_refusal_retry_delay_game_hours
		)
	)), 0.0)
	var harm_delay := maxf(float(context.get(
		"recent_harm_social_delay_game_hours",
		recent_harm_social_delay_game_hours
	)), 0.0)
	var repeat_delay := maxf(float(context.get(
		"recent_conversation_repeat_delay_game_hours",
		recent_conversation_repeat_delay_game_hours
	)), 0.0)

	var blockers: Array[Dictionary] = []
	_append_memory_blockers(
		blockers,
		memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		RECENT_REFUSAL_REASON,
		StringName(candidate_id),
		StringName(remembering_npc_id),
		&"Talk",
		refusal_delay,
		now_game_hours
	)
	_append_memory_blockers(
		blockers,
		memory,
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		RECENT_HARM_REASON,
		StringName(candidate_id),
		StringName(remembering_npc_id),
		&"Harm",
		harm_delay,
		now_game_hours
	)
	_append_memory_blockers(
		blockers,
		memory,
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED,
		RECENT_CONVERSATION_REASON,
		StringName(candidate_id),
		StringName(remembering_npc_id),
		&"Talk",
		repeat_delay,
		now_game_hours
	)
	if blockers.is_empty():
		return decision
	blockers.sort_custom(_blocker_precedes)
	return blockers[0].duplicate(true)


func _append_memory_blockers(
	blockers: Array[Dictionary],
	memory: NpcShortTermMemory,
	event_type: StringName,
	reason_code: StringName,
	candidate_id: StringName,
	remembering_npc_id: StringName,
	logical_action: StringName,
	retry_delay_game_hours: float,
	now_game_hours: float
) -> void:
	if retry_delay_game_hours <= 0.0:
		return
	var matches := memory.find_recent_at(
		event_type,
		now_game_hours,
		candidate_id,
		remembering_npc_id,
		logical_action
	)
	for matching_memory in matches:
		if matching_memory == null or matching_memory.resolved:
			continue
		var retry_game_hours := (
			matching_memory.last_updated_game_hours
			+ retry_delay_game_hours
		)
		var remaining_retry_hours := maxf(
			retry_game_hours - now_game_hours,
			0.0
		)
		if remaining_retry_hours <= 0.0:
			continue
		blockers.append({
			"allowed": false,
			"reason_code": reason_code,
			"memory_event_type": event_type,
			"memory_id": matching_memory.memory_id,
			"candidate_id": candidate_id,
			"remaining_retry_hours": remaining_retry_hours,
			"retry_game_hours": retry_game_hours,
			"subject_id": matching_memory.subject_id,
			"details": {
				"occurrence_count": matching_memory.occurrence_count,
				"memory_age_hours": maxf(
					now_game_hours - matching_memory.last_updated_game_hours,
					0.0
				),
				"last_updated_game_hours": matching_memory.last_updated_game_hours,
				"retry_delay_game_hours": retry_delay_game_hours,
			},
		})


static func _blocker_precedes(a: Dictionary, b: Dictionary) -> bool:
	var a_retry := float(a.get("retry_game_hours", 0.0))
	var b_retry := float(b.get("retry_game_hours", 0.0))
	if not is_equal_approx(a_retry, b_retry):
		return a_retry > b_retry
	var a_severity := int(_SEVERITY_BY_REASON.get(
		StringName(String(a.get("reason_code", ""))),
		0
	))
	var b_severity := int(_SEVERITY_BY_REASON.get(
		StringName(String(b.get("reason_code", ""))),
		0
	))
	if a_severity != b_severity:
		return a_severity > b_severity
	return String(a.get("memory_id", "")) < String(b.get("memory_id", ""))


static func _allowed_decision(candidate_id: StringName = &"") -> Dictionary:
	return {
		"allowed": true,
		"reason_code": &"",
		"memory_event_type": &"",
		"memory_id": "",
		"candidate_id": candidate_id,
		"remaining_retry_hours": 0.0,
		"retry_game_hours": 0.0,
		"subject_id": &"",
		"details": {},
	}
