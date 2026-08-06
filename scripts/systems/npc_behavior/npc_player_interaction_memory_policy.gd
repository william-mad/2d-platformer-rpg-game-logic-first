class_name NpcPlayerInteractionMemoryPolicy extends RefCounted

const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const Identity = preload("res://scripts/systems/npc_identity.gd")

const DEFAULT_RECENT_HARM_DELAY_GAME_HOURS: float = 0.5
const DEFAULT_PLAYER_ACTOR_ID: StringName = Identity.PLAYER_ACTOR_ID


func evaluate_actor(
	memory: NpcShortTermMemory,
	actor_id: StringName,
	now_game_hours: float,
	context: Dictionary = {}
) -> Dictionary:
	var clean_actor_id := String(actor_id).strip_edges()
	var result := {
		"allowed": true,
		"reason_code": &"",
		"memory_id": "",
		"actor_id": StringName(clean_actor_id),
		"remaining_retry_hours": 0.0,
		"occurrence_count": 0,
		"details": {},
	}
	if memory == null or clean_actor_id.is_empty():
		return result

	var remembering_npc_id := String(context.get(
		"remembering_npc_id",
		""
	)).strip_edges()
	var delay := maxf(float(context.get(
		"recent_harm_interaction_delay_game_hours",
		DEFAULT_RECENT_HARM_DELAY_GAME_HOURS
	)), 0.0)
	var candidates := memory.find_recent_at(
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		maxf(now_game_hours, 0.0),
		StringName(clean_actor_id),
		StringName(remembering_npc_id),
		&"Harm"
	)
	var newest: NpcMemoryEvent
	for candidate in candidates:
		if candidate == null or candidate.resolved:
			continue
		if (
			newest == null
			or candidate.last_updated_game_hours
				> newest.last_updated_game_hours
		):
			newest = candidate
	if newest == null:
		return result

	var retry_game_hours := newest.last_updated_game_hours + delay
	var remaining := maxf(retry_game_hours - maxf(now_game_hours, 0.0), 0.0)
	result["memory_id"] = newest.memory_id
	result["occurrence_count"] = newest.occurrence_count
	result["remaining_retry_hours"] = remaining
	result["details"] = {
		"memory_event_type": MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		"retry_game_hours": retry_game_hours,
	}
	if remaining <= 0.0:
		return result
	result["allowed"] = false
	result["reason_code"] = &"recently_harmed_by_actor"
	return result


static func get_stable_actor_id(actor: Node) -> StringName:
	return StringName(Identity.get_stable_actor_id(actor))
