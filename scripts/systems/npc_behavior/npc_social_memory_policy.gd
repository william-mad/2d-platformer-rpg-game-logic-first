class_name NpcSocialMemoryPolicy extends RefCounted

const MemoryPolicy = preload("res://scripts/systems/npc_behavior/npc_memory_policy.gd")

const RECENT_REFUSAL_REASON: StringName = &"recent_conversation_refusal"
const DEFAULT_REFUSAL_RETRY_DELAY_GAME_HOURS: float = 0.25

var recent_refusal_retry_delay_game_hours: float = (
	DEFAULT_REFUSAL_RETRY_DELAY_GAME_HOURS
)


func evaluate_candidate(
	memory: NpcShortTermMemory,
	candidate_persistent_id: StringName,
	now_game_hours: float,
	context: Dictionary = {}
) -> Dictionary:
	var decision := _allowed_decision()
	var candidate_id := String(candidate_persistent_id).strip_edges()
	if candidate_id.is_empty():
		decision["reason_code"] = &"invalid_candidate_id"
		decision["details"] = {"candidate_identity_valid": false}
		return decision
	if memory == null:
		return decision

	var remembering_npc_id := String(
		context.get("remembering_npc_id", "")
	).strip_edges()
	var retry_delay := maxf(float(context.get(
		"retry_delay_game_hours",
		recent_refusal_retry_delay_game_hours
	)), 0.0)
	if retry_delay <= 0.0:
		return decision

	var matching_memory: NpcMemoryEvent
	for refusal in memory.find_recent(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		StringName(candidate_id)
	):
		if refusal.resolved:
			continue
		if (
			not remembering_npc_id.is_empty()
			and String(refusal.target_id) != remembering_npc_id
		):
			continue
		if (
			matching_memory == null
			or refusal.last_updated_game_hours
				> matching_memory.last_updated_game_hours
			or (
				is_equal_approx(
					refusal.last_updated_game_hours,
					matching_memory.last_updated_game_hours
				)
				and refusal.memory_id < matching_memory.memory_id
			)
		):
			matching_memory = refusal
	if matching_memory == null:
		return decision

	var retry_game_hours := (
		matching_memory.last_updated_game_hours
		+ retry_delay
	)
	var remaining_retry_hours := maxf(retry_game_hours - now_game_hours, 0.0)
	if remaining_retry_hours <= 0.0:
		return decision

	return {
		"allowed": false,
		"reason_code": RECENT_REFUSAL_REASON,
		"memory_id": matching_memory.memory_id,
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
			"retry_delay_game_hours": retry_delay,
		},
	}


static func _allowed_decision() -> Dictionary:
	return {
		"allowed": true,
		"reason_code": &"",
		"memory_id": "",
		"remaining_retry_hours": 0.0,
		"retry_game_hours": 0.0,
		"subject_id": &"",
		"details": {},
	}
