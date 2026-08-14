class_name NpcActivitySocialAffinityPolicy extends RefCounted

const SocialMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_social_memory_policy.gd"
)

const NEUTRAL_FAVOR: float = 50.0
const RELATIONSHIP_MAXIMUM: float = 100.0
const STRONG_ANGER_THRESHOLD: float = 70.0
const STRONG_FEAR_THRESHOLD: float = 70.0
const GROUP_COMPATIBILITY_VETO_THRESHOLD: float = 85.0
const REST_MAX_FAVOR_BONUS: float = 20.0
const RECREATION_MAX_FAVOR_BONUS: float = 35.0


static func score_reserved_participants(
	requester_id: StringName,
	activity_kind: StringName,
	reservations: Array[Dictionary],
	locations: Node,
	relationships: Node,
	memory: NpcShortTermMemory = null,
	now_game_hours: float = 0.0
) -> Dictionary:
	var maximum_bonus := get_maximum_bonus(activity_kind)
	var requester_text := String(requester_id).strip_edges()
	var result := {
		"requester_id": requester_id,
		"activity_kind": activity_kind,
		"social_bonus": 0.0,
		"strongest_positive_bonus": 0.0,
		"best_participant_id": &"",
		"participant_count": 0,
		"participant_ids": PackedStringArray(),
		"group_compatible": true,
		"compatibility_veto": false,
		"veto_participant_id": &"",
		"veto_reason_code": &"",
		"joining_session_id": "",
		"joining_leader_id": &"",
		"joining_partner_action_session_id": "",
		"joining_capacity": 0,
		"participants": [],
	}
	if requester_text.is_empty() or maximum_bonus <= 0.0:
		return result

	var requester_relationship_id := _resolve_relationship_id(
		requester_text,
		locations,
		relationships
	)
	var memory_policy := SocialMemoryPolicy.new()
	var seen_participants: Dictionary = {}
	for reservation in reservations:
		if String(reservation.get("purpose", "activity")) != "activity":
			continue
		var participant_descriptor := _get_present_participant_descriptor(
			reservation,
			locations
		)
		if participant_descriptor.is_empty():
			continue
		var participant_id := String(reservation.get("npc_id", "")).strip_edges()
		if (
			participant_id.is_empty()
			or participant_id == requester_text
			or seen_participants.has(participant_id)
		):
			continue
		seen_participants[participant_id] = true

		var memory_decision := memory_policy.evaluate_candidate(
			memory,
			StringName(participant_id),
			now_game_hours,
			{"remembering_npc_id": requester_text}
		)
		var relationship_id := _resolve_relationship_id(
			participant_id,
			locations,
			relationships
		)
		var relationship := _get_relationship_snapshot(
			relationships,
			requester_relationship_id,
			relationship_id
		)
		var participant_score := score_relationship(activity_kind, relationship)
		participant_score["participant_id"] = StringName(participant_id)
		participant_score["relationship_id"] = relationship_id
		participant_score["memory_allowed"] = bool(memory_decision.get("allowed", true))
		participant_score["memory_reason_code"] = memory_decision.get("reason_code", &"")
		if not bool(participant_score["memory_allowed"]):
			participant_score["social_bonus"] = 0.0
		var shared_activity := _get_shared_activity_metadata(
			participant_descriptor,
			reservation,
			activity_kind
		)
		if not shared_activity.is_empty():
			participant_score["shared_activity"] = shared_activity
		(result["participants"] as Array).append(participant_score)

		var bonus := float(participant_score.get("social_bonus", 0.0))
		var current_best_id := String(result["best_participant_id"])
		if (
			bonus > float(result["strongest_positive_bonus"])
			or (
				bonus > 0.0
				and is_equal_approx(bonus, float(result["strongest_positive_bonus"]))
				and (current_best_id.is_empty() or participant_id < current_best_id)
			)
		):
			result["strongest_positive_bonus"] = bonus
			result["social_bonus"] = bonus
			result["best_participant_id"] = StringName(participant_id)
			result["joining_session_id"] = String(shared_activity.get(
				"session_id",
				""
			))
			result["joining_leader_id"] = StringName(String(shared_activity.get(
				"leader_id",
				""
			)))
			result["joining_partner_action_session_id"] = String(
				reservation.get("session_id", "")
			)
			result["joining_capacity"] = int(shared_activity.get("capacity", 0))

		var danger_value := maxf(
			float(participant_score.get("anger", 0.0)),
			float(participant_score.get("fear", 0.0))
		)
		var current_veto_id := String(result["veto_participant_id"])
		var current_veto_value := float(result.get("veto_value", 0.0))
		if (
			danger_value >= GROUP_COMPATIBILITY_VETO_THRESHOLD
			and (
				danger_value > current_veto_value
				or (
					is_equal_approx(danger_value, current_veto_value)
					and (current_veto_id.is_empty() or participant_id < current_veto_id)
				)
			)
		):
			result["compatibility_veto"] = true
			result["group_compatible"] = false
			result["veto_participant_id"] = StringName(participant_id)
			result["veto_value"] = danger_value
			result["veto_reason_code"] = (
				&"strong_group_fear"
				if float(participant_score.get("fear", 0.0))
					>= float(participant_score.get("anger", 0.0))
				else &"strong_group_anger"
			)

	result["participant_count"] = seen_participants.size()
	var participant_ids := PackedStringArray(seen_participants.keys())
	participant_ids.sort()
	result["participant_ids"] = participant_ids
	if bool(result["compatibility_veto"]):
		result["social_bonus"] = 0.0
		result["joining_session_id"] = ""
		result["joining_leader_id"] = &""
		result["joining_partner_action_session_id"] = ""
		result["joining_capacity"] = 0
	return result


static func score_relationship(
	activity_kind: StringName,
	relationship: Dictionary
) -> Dictionary:
	var maximum_bonus := get_maximum_bonus(activity_kind)
	var favor := _bounded_relationship_value(
		relationship.get("favor", NEUTRAL_FAVOR),
		NEUTRAL_FAVOR
	)
	var anger := _bounded_relationship_value(relationship.get("anger", 0.0), 0.0)
	var fear := _bounded_relationship_value(relationship.get("fear", 0.0), 0.0)
	var favor_ratio := clampf(
		(favor - NEUTRAL_FAVOR) / (RELATIONSHIP_MAXIMUM - NEUTRAL_FAVOR),
		0.0,
		1.0
	)
	var raw_favor_bonus := favor_ratio * maximum_bonus
	var anger_ratio := clampf(anger / STRONG_ANGER_THRESHOLD, 0.0, 1.0)
	var fear_ratio := clampf(fear / STRONG_FEAR_THRESHOLD, 0.0, 1.0)
	var danger_ratio := maxf(anger_ratio, fear_ratio)
	return {
		"social_bonus": raw_favor_bonus * (1.0 - danger_ratio),
		"raw_favor_bonus": raw_favor_bonus,
		"favor": favor,
		"anger": anger,
		"fear": fear,
		"danger_ratio": danger_ratio,
		"strong_anger": anger >= STRONG_ANGER_THRESHOLD,
		"strong_fear": fear >= STRONG_FEAR_THRESHOLD,
	}


static func get_maximum_bonus(activity_kind: StringName) -> float:
	match activity_kind:
		&"Rest":
			return REST_MAX_FAVOR_BONUS
		&"Recreation":
			return RECREATION_MAX_FAVOR_BONUS
	return 0.0


static func build_selected_activity_metadata(
	score: Dictionary,
	requester_id: StringName,
	spot_id: StringName,
	activity_kind: StringName
) -> Dictionary:
	var social_bonus := maxf(float(score.get("social_bonus", 0.0)), 0.0)
	var attraction_target := String(score.get(
		"best_participant_id",
		""
	)).strip_edges()
	if (
		social_bonus <= 0.0
		or attraction_target.is_empty()
		or not bool(score.get("group_compatible", true))
	):
		return {}
	var metadata := {
		"activity_social_attraction_target_id": attraction_target,
		"activity_social_bonus": social_bonus,
		"activity_social_group_compatible": true,
	}
	var shared_session_id := String(score.get(
		"joining_session_id",
		""
	)).strip_edges()
	if shared_session_id.is_empty():
		return metadata
	var participant_ids: Array = []
	for participant_id in score.get("participant_ids", PackedStringArray()):
		var participant_text := String(participant_id).strip_edges()
		if not participant_text.is_empty() and not participant_ids.has(participant_text):
			participant_ids.append(participant_text)
	var requester_text := String(requester_id).strip_edges()
	if not requester_text.is_empty() and not participant_ids.has(requester_text):
		participant_ids.append(requester_text)
	participant_ids.sort()
	metadata.merge({
		"activity_social_joining_session_id": shared_session_id,
		"shared_activity_session_id": shared_session_id,
		"shared_activity_type": String(activity_kind),
		"shared_activity_leader_id": String(score.get(
			"joining_leader_id",
			attraction_target
		)),
		"shared_activity_spot_id": String(spot_id),
		"shared_activity_participant_ids": participant_ids,
		"shared_activity_capacity": int(score.get("joining_capacity", 0)),
		"shared_activity_role": "joiner",
		"shared_activity_partner_id": attraction_target,
		"shared_activity_partner_action_session_id": String(score.get(
			"joining_partner_action_session_id",
			""
		)),
		"shared_activity_invitation_attempted": true,
		"shared_activity_invitation_result": "joined_existing",
	}, true)
	return metadata


static func build_selected_activity_context(
	score: Dictionary,
	requester_id: StringName,
	spot_id: StringName,
	activity_kind: StringName
) -> Dictionary:
	return {
		"debug": {
			"social_attraction_target_id": score.get("best_participant_id", &""),
			"social_affinity_bonus": float(score.get("social_bonus", 0.0)),
			"group_compatible": bool(score.get("group_compatible", true)),
			"joining_session_id": String(score.get("joining_session_id", "")),
		},
		"metadata": build_selected_activity_metadata(
			score,
			requester_id,
			spot_id,
			activity_kind
		),
	}


static func _resolve_relationship_id(
	actor_id: String,
	locations: Node,
	relationships: Node
) -> String:
	var live_actor: Node
	if locations != null and locations.has_method("get_live_npc"):
		live_actor = locations.call("get_live_npc", actor_id) as Node
	if (
		live_actor != null
		and relationships != null
		and relationships.has_method("get_relationship_id")
	):
		var live_relationship_id := String(relationships.call(
			"get_relationship_id",
			live_actor
		)).strip_edges()
		if not live_relationship_id.is_empty():
			return live_relationship_id

	if locations != null and locations.has_method("get_record_snapshot"):
		var record = locations.call("get_record_snapshot", actor_id)
		if record is Dictionary:
			var node_state = record.get("node_state", {})
			if node_state is Dictionary:
				var stored_relationship_id := String(
					node_state.get("relationship_id", "")
				).strip_edges()
				if not stored_relationship_id.is_empty():
					return stored_relationship_id

	return actor_id.strip_edges()


static func _get_present_participant_descriptor(
	reservation: Dictionary,
	locations: Node
) -> Dictionary:
	if locations == null or not locations.has_method("get_record_snapshot"):
		return {"status": "active", "phase": "executing"}
	var npc_id := String(reservation.get("npc_id", "")).strip_edges()
	var session_id := String(reservation.get("session_id", "")).strip_edges()
	if npc_id.is_empty() or session_id.is_empty():
		return {}
	var record = locations.call("get_record_snapshot", npc_id)
	if record is Dictionary and not record.is_empty():
		var pending_travel = record.get("pending_travel", {})
		if pending_travel is Dictionary and not pending_travel.is_empty():
			return {}
	var live_actor = locations.call("get_live_npc", npc_id) as Node
	if live_actor != null:
		var machine := live_actor.get_node_or_null("NpcStateMachine")
		if machine != null and machine.has_method("get_active_action_descriptor"):
			var live_descriptor: Dictionary = machine.call(
				"get_active_action_descriptor"
			)
			if _descriptor_session_id(live_descriptor) == session_id:
				return (
					live_descriptor.duplicate(true)
					if _descriptor_is_socially_present(live_descriptor)
					else {}
				)
	if not (record is Dictionary) or record.is_empty():
		# Legacy reservations without a record remain compatible with older callers.
		return {"status": "active", "phase": "executing"}

	for descriptor_key in ["action", "activity"]:
		var descriptor = record.get(descriptor_key, {})
		if not (descriptor is Dictionary) or descriptor.is_empty():
			continue
		if _descriptor_session_id(descriptor) != session_id:
			continue
		return descriptor.duplicate(true) if _descriptor_is_socially_present(descriptor) else {}
	return {}


static func _descriptor_is_socially_present(descriptor: Dictionary) -> bool:
	var status := String(descriptor.get("status", "active")).to_lower()
	if status in ["completed", "failed", "cancelled", "cancelling", "proposed"]:
		return false
	return String(descriptor.get("phase", "executing")).to_lower() not in [
		"approaching",
		"moving_to_target",
		"route_retry_wait",
		"proposed",
	]


static func _get_shared_activity_metadata(
	descriptor: Dictionary,
	reservation: Dictionary,
	activity_kind: StringName
) -> Dictionary:
	var metadata = descriptor.get("metadata", {})
	if not (metadata is Dictionary):
		return {}
	var shared_session_id := String(metadata.get(
		"shared_activity_session_id",
		""
	)).strip_edges()
	if shared_session_id.is_empty():
		return {}
	if String(metadata.get("shared_activity_type", "")) != String(activity_kind):
		return {}
	var reservation_spot_id := String(reservation.get("spot_id", "")).strip_edges()
	var shared_spot_id := String(metadata.get("shared_activity_spot_id", "")).strip_edges()
	if not shared_spot_id.is_empty() and shared_spot_id != reservation_spot_id:
		return {}
	return {
		"session_id": shared_session_id,
		"leader_id": StringName(String(metadata.get("shared_activity_leader_id", ""))),
		"capacity": int(metadata.get("shared_activity_capacity", 0)),
	}


static func _descriptor_session_id(descriptor: Dictionary) -> String:
	for key in ["session_id", "action_session_id", "activity_id", "request_id"]:
		var value := String(descriptor.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	return ""


static func _get_relationship_snapshot(
	relationships: Node,
	requester_relationship_id: String,
	participant_relationship_id: String
) -> Dictionary:
	if (
		relationships == null
		or not relationships.has_method("get_relationship_by_id")
		or requester_relationship_id.is_empty()
		or participant_relationship_id.is_empty()
	):
		return {}
	var snapshot = relationships.call(
		"get_relationship_by_id",
		requester_relationship_id,
		participant_relationship_id
	)
	return snapshot.duplicate(true) if snapshot is Dictionary else {}


static func _bounded_relationship_value(value: Variant, fallback: float) -> float:
	var numeric := float(value)
	if not is_finite(numeric):
		return fallback
	return clampf(numeric, 0.0, RELATIONSHIP_MAXIMUM)
