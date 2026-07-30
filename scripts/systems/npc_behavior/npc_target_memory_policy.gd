class_name NpcTargetMemoryPolicy extends RefCounted

const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)

const RECENT_TARGET_FAILURE_REASON: StringName = &"recent_target_failure"
const DEFAULT_TARGET_UNAVAILABLE_RETRY_HOURS: float = 0.25
const DEFAULT_MOVEMENT_FAILED_RETRY_HOURS: float = 0.125
const DEFAULT_INTENTION_TARGET_LOST_RETRY_HOURS: float = 0.25

var target_unavailable_retry_hours: float = (
	DEFAULT_TARGET_UNAVAILABLE_RETRY_HOURS
)
var movement_failed_retry_hours: float = DEFAULT_MOVEMENT_FAILED_RETRY_HOURS
var intention_target_lost_retry_hours: float = (
	DEFAULT_INTENTION_TARGET_LOST_RETRY_HOURS
)


func evaluate_candidate(
	memory: NpcShortTermMemory,
	logical_action: StringName,
	candidate_target_id: StringName,
	candidate_place_id: StringName,
	now_game_hours: float,
	context: Dictionary = {}
) -> Dictionary:
	var action := String(logical_action).strip_edges()
	var target_id := String(candidate_target_id).strip_edges()
	var place_id := String(candidate_place_id).strip_edges()
	var decision := _allowed_decision(
		StringName(action),
		StringName(target_id)
	)
	if target_id.is_empty():
		decision["details"] = {"candidate_identity_valid": false}
		return decision
	if memory == null:
		return decision

	var remembering_npc_id := String(
		context.get("remembering_npc_id", "")
	).strip_edges()
	var matching_memory: NpcMemoryEvent
	var matching_retry_delay := 0.0
	for event_type in [
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST,
	]:
		for failure in memory.find_recent_at(event_type, now_game_hours):
			if (
				failure.resolved
				or failure.is_expired(now_game_hours)
				or String(failure.target_id) != target_id
				or not _memory_matches_candidate(
					failure,
					StringName(action),
					StringName(place_id),
					remembering_npc_id
				)
			):
				continue
			var retry_delay := _retry_delay_for(event_type, context)
			if retry_delay <= 0.0:
				continue
			var retry_game_hours := (
				failure.last_updated_game_hours + retry_delay
			)
			if retry_game_hours <= now_game_hours:
				continue
			if (
				matching_memory == null
				or failure.last_updated_game_hours
					> matching_memory.last_updated_game_hours
				or (
					is_equal_approx(
						failure.last_updated_game_hours,
						matching_memory.last_updated_game_hours
					)
					and failure.memory_id < matching_memory.memory_id
				)
			):
				matching_memory = failure
				matching_retry_delay = retry_delay

	if matching_memory == null:
		return decision

	var retry_game_hours := (
		matching_memory.last_updated_game_hours + matching_retry_delay
	)
	return {
		"allowed": false,
		"reason_code": RECENT_TARGET_FAILURE_REASON,
		"memory_id": matching_memory.memory_id,
		"memory_event_type": matching_memory.event_type,
		"remaining_retry_hours": maxf(
			retry_game_hours - now_game_hours,
			0.0
		),
		"retry_game_hours": retry_game_hours,
		"candidate_target_id": StringName(target_id),
		"logical_action": StringName(action),
		"details": {
			"occurrence_count": matching_memory.occurrence_count,
			"failure_reason_code": matching_memory.reason_code,
			"last_updated_game_hours": (
				matching_memory.last_updated_game_hours
			),
			"retry_delay_game_hours": matching_retry_delay,
			"candidate_place_id": StringName(place_id),
		},
	}


func _memory_matches_candidate(
	failure: NpcMemoryEvent,
	logical_action: StringName,
	candidate_place_id: StringName,
	remembering_npc_id: String
) -> bool:
	if (
		not remembering_npc_id.is_empty()
		and failure.subject_id != &""
		and String(failure.subject_id) != remembering_npc_id
	):
		return false
	match failure.event_type:
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE:
			if _is_target_general_unavailability(failure.metadata):
				return true
			return (
				failure.logical_action != &""
				and failure.logical_action == logical_action
			)
		MemoryPolicy.EVENT_MOVEMENT_FAILED:
			if (
				failure.logical_action == &""
				or failure.logical_action != logical_action
			):
				return false
			if failure.place_id == &"":
				return true
			return (
				candidate_place_id != &""
				and failure.place_id == candidate_place_id
			)
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST:
			return (
				failure.logical_action != &""
				and failure.logical_action == logical_action
			)
	return false


func _retry_delay_for(
	event_type: StringName,
	context: Dictionary
) -> float:
	match event_type:
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE:
			return maxf(float(context.get(
				"target_unavailable_retry_hours",
				target_unavailable_retry_hours
			)), 0.0)
		MemoryPolicy.EVENT_MOVEMENT_FAILED:
			return maxf(float(context.get(
				"movement_failed_retry_hours",
				movement_failed_retry_hours
			)), 0.0)
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST:
			return maxf(float(context.get(
				"intention_target_lost_retry_hours",
				intention_target_lost_retry_hours
			)), 0.0)
	return 0.0


static func _is_target_general_unavailability(metadata: Dictionary) -> bool:
	return (
		bool(metadata.get("target_generally_unavailable", false))
		or String(metadata.get("target_availability_scope", "")).to_lower()
			== "general"
	)


static func _allowed_decision(
	logical_action: StringName,
	candidate_target_id: StringName
) -> Dictionary:
	return {
		"allowed": true,
		"reason_code": &"",
		"memory_id": "",
		"memory_event_type": &"",
		"remaining_retry_hours": 0.0,
		"retry_game_hours": 0.0,
		"candidate_target_id": candidate_target_id,
		"logical_action": logical_action,
		"details": {},
	}
