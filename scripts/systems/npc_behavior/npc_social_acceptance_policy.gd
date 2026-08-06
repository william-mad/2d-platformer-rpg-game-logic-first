class_name NpcSocialAcceptancePolicy extends RefCounted

const DECISION_ACCEPTED: StringName = &"accepted"
const DECISION_TEMPORARILY_UNAVAILABLE: StringName = &"temporarily_unavailable"
const DECISION_SOCIAL_DECLINE: StringName = &"social_decline"
const DECISION_INVALID_REQUEST: StringName = &"invalid_request"

const REASON_RECENT_HARM: StringName = &"recently_harmed_by_requester"
const REASON_RECENT_CONVERSATION: StringName = &"recently_talked_with_requester"
const REASON_LOW_FAVOR: StringName = &"requester_favor_too_low"
const REASON_HIGH_ANGER: StringName = &"requester_anger_too_high"
const REASON_HIGH_FEAR: StringName = &"requester_fear_too_high"

const DEFAULT_MINIMUM_FAVOR: float = 20.0
const DEFAULT_MAXIMUM_ANGER: float = 70.0
const DEFAULT_MAXIMUM_FEAR: float = 80.0


func evaluate(
	requester_id: StringName,
	candidate_id: StringName,
	context: Dictionary = {}
) -> Dictionary:
	var result := _base_result(requester_id, candidate_id)
	if requester_id == &"" or candidate_id == &"" or requester_id == candidate_id:
		result["decision_kind"] = DECISION_INVALID_REQUEST
		result["reason_code"] = &"invalid_social_identity"
		return result

	var availability = context.get("availability", {})
	if availability is Dictionary and not bool(availability.get("available", true)):
		result["decision_kind"] = StringName(String(availability.get(
			"decision_kind",
			DECISION_TEMPORARILY_UNAVAILABLE
		)))
		result["reason_code"] = StringName(String(availability.get(
			"reason_code",
			"candidate_unavailable"
		)))
		result["details"] = {
			"availability": availability.duplicate(true),
		}
		return result

	var memory_decision = context.get("social_memory_decision", {})
	if memory_decision is Dictionary and not bool(memory_decision.get("allowed", true)):
		var memory_reason := StringName(String(memory_decision.get(
			"reason_code",
			""
		)))
		if memory_reason == &"recently_harmed_by_candidate":
			return _memory_result(
				result,
				DECISION_SOCIAL_DECLINE,
				REASON_RECENT_HARM,
				memory_decision
			)
		if memory_reason == &"recently_talked_with_candidate":
			return _memory_result(
				result,
				DECISION_TEMPORARILY_UNAVAILABLE,
				REASON_RECENT_CONVERSATION,
				memory_decision
			)
		# A prior refusal belongs to requester-side retry selection. It does not
		# recursively make the candidate decline the same requester again.

	var relationship = context.get("relationship", {})
	if not (relationship is Dictionary):
		relationship = {}
	var relationship_values := {
		"favor": _bounded(relationship.get("favor", 50.0), 50.0),
		"anger": _bounded(relationship.get("anger", 0.0), 0.0),
		"fear": _bounded(relationship.get("fear", 0.0), 0.0),
	}
	result["relationship"] = relationship_values.duplicate(true)
	var minimum_favor := clampf(float(context.get(
		"minimum_favor",
		DEFAULT_MINIMUM_FAVOR
	)), 0.0, 100.0)
	var maximum_anger := clampf(float(context.get(
		"maximum_anger",
		DEFAULT_MAXIMUM_ANGER
	)), 0.0, 100.0)
	var maximum_fear := clampf(float(context.get(
		"maximum_fear",
		DEFAULT_MAXIMUM_FEAR
	)), 0.0, 100.0)
	if float(relationship_values.favor) < minimum_favor:
		result["decision_kind"] = DECISION_SOCIAL_DECLINE
		result["reason_code"] = REASON_LOW_FAVOR
		return result
	if float(relationship_values.anger) >= maximum_anger:
		result["decision_kind"] = DECISION_SOCIAL_DECLINE
		result["reason_code"] = REASON_HIGH_ANGER
		return result
	if float(relationship_values.fear) >= maximum_fear:
		result["decision_kind"] = DECISION_SOCIAL_DECLINE
		result["reason_code"] = REASON_HIGH_FEAR
		return result

	result["accepted"] = true
	result["decision_kind"] = DECISION_ACCEPTED
	return result


static func _base_result(
	requester_id: StringName,
	candidate_id: StringName
) -> Dictionary:
	return {
		"accepted": false,
		"decision_kind": DECISION_INVALID_REQUEST,
		"reason_code": &"",
		"requester_id": requester_id,
		"candidate_id": candidate_id,
		"remaining_retry_hours": 0.0,
		"retry_game_hours": 0.0,
		"memory_id": "",
		"relationship": {},
		"details": {},
	}


static func _memory_result(
	result: Dictionary,
	decision_kind: StringName,
	reason_code: StringName,
	memory_decision: Dictionary
) -> Dictionary:
	result["decision_kind"] = decision_kind
	result["reason_code"] = reason_code
	result["remaining_retry_hours"] = float(memory_decision.get(
		"remaining_retry_hours",
		0.0
	))
	result["retry_game_hours"] = float(memory_decision.get(
		"retry_game_hours",
		0.0
	))
	result["memory_id"] = String(memory_decision.get("memory_id", ""))
	result["details"] = {
		"memory_event_type": memory_decision.get("memory_event_type", &""),
	}
	return result


static func _bounded(value: Variant, fallback: float) -> float:
	var numeric := float(value)
	if not is_finite(numeric):
		return fallback
	return clampf(numeric, 0.0, 100.0)
