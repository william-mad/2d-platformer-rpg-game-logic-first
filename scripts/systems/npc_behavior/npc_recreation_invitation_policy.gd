class_name NpcRecreationInvitationPolicy extends RefCounted

const Identity = preload("res://scripts/systems/npc_identity.gd")
const AcceptancePolicy = preload(
	"res://scripts/systems/npc_behavior/npc_social_acceptance_policy.gd"
)
const CandidateScorer = preload(
	"res://scripts/systems/npc_behavior/npc_social_candidate_scorer.gd"
)

const ACTIVITY_KIND: StringName = &"Recreation"
const INVITATION_SOURCE: StringName = &"social_ai"
const INVITATION_PRIORITY: int = 45
const DECISION_ACCEPTED: StringName = AcceptancePolicy.DECISION_ACCEPTED
const DECISION_SOCIAL_DECLINE: StringName = AcceptancePolicy.DECISION_SOCIAL_DECLINE
const DECISION_INVALID_REQUEST: StringName = AcceptancePolicy.DECISION_INVALID_REQUEST

const HIGH_AUTHORITY_STATES := {
	"DisabledDead": true,
	"Downed": true,
	"Collapse": true,
	"Flee": true,
	"Fight": true,
	"Sleep": true,
	"ScriptedHold": true,
}

var _acceptance_policy := AcceptancePolicy.new()
var _candidate_scorer := CandidateScorer.new()


func rank_runtime_candidates(
	inviter_machine: Node,
	spot: Node2D,
	locations: Node,
	relationships: Node,
	request_priority: int = INVITATION_PRIORITY
) -> Dictionary:
	var inviter: Node2D = inviter_machine.get("npc") as Node2D
	var inviter_id := Identity.get_stable_actor_id(inviter)
	var inviter_relationship_id := _relationship_id(
		relationships,
		inviter,
		inviter_id
	)
	var inviter_record: Dictionary = locations.call(
		"get_record_snapshot",
		inviter_id
	)
	var inviter_scene_path := String(inviter_record.get(
		"scene_path",
		locations.call("get_current_scene_path")
	))
	var preferred_id := String(inviter_machine.call(
		"_get_authored_social_preference_target_id"
	)).strip_edges()
	var candidates: Array[Dictionary] = []
	var diagnostics: Array[Dictionary] = []
	for candidate_key in locations.call("get_record_ids_snapshot"):
		var candidate_id := String(candidate_key).strip_edges()
		if candidate_id.is_empty() or candidate_id == inviter_id:
			continue
		var record: Dictionary = locations.call("get_record_snapshot", candidate_id)
		var candidate := locations.call("get_live_npc", candidate_id) as Node2D
		var availability := evaluate_runtime_availability(
			inviter,
			candidate,
			spot,
			candidate_id,
			record,
			inviter_scene_path,
			locations,
			request_priority
		)
		var decision := {
			"candidate_id": StringName(candidate_id),
			"allowed": bool(availability.get("available", false)),
			"decision_kind": availability.get("decision_kind", &"temporarily_unavailable"),
			"reason_code": availability.get("reason_code", &"candidate_unavailable"),
		}
		if bool(decision.allowed):
			var memory: Dictionary = inviter_machine.call(
				"get_autonomous_social_memory_decision",
				candidate
			)
			if not bool(memory.get("allowed", true)):
				decision.merge(memory, true)
				decision["allowed"] = false
		if bool(decision.allowed):
			var candidate_relationship_id := _relationship_id(
				relationships,
				candidate,
				candidate_id
			)
			var relationship := _relationship_snapshot(
				relationships,
				inviter_relationship_id,
				candidate_relationship_id
			)
			var score := _candidate_scorer.score_candidate(
				StringName(inviter_id),
				StringName(candidate_id),
				{
					"relationship": relationship,
					"is_authored_preference": preferred_id == candidate_id,
					"has_live_distance": true,
					"live_distance": inviter.global_position.distance_to(
						candidate.global_position
					),
				}
			)
			decision.merge(score, true)
			if not _inviter_opinion_supports_invitation(relationship, score):
				decision["allowed"] = false
				decision["reason_code"] = &"inviter_does_not_like_candidate"
			else:
				candidates.append({
					"target_node": candidate,
					"candidate_id": candidate_id,
					"score": score,
				})
		diagnostics.append(decision)

	candidates.sort_custom(_scored_candidate_precedes)
	var selected: Node2D
	var selected_id := ""
	if not candidates.is_empty():
		selected = candidates[0].target_node as Node2D
		selected_id = String(candidates[0].candidate_id)
	return {
		"target_node": selected,
		"descriptor": {
			"requester_id": StringName(inviter_id),
			"candidate_count": candidates.size(),
			"candidates_considered": diagnostics.size(),
			"selected_candidate_id": StringName(selected_id),
			"candidates": diagnostics,
			"evaluated_at_usec": Time.get_ticks_usec(),
		},
	}


func evaluate_runtime_acceptance(
	inviter: Node2D,
	candidate: Node2D,
	spot: Node2D,
	locations: Node,
	relationships: Node,
	request_priority: int = INVITATION_PRIORITY
) -> Dictionary:
	var inviter_id := Identity.get_stable_actor_id(inviter)
	var candidate_id := Identity.get_stable_actor_id(candidate)
	var candidate_record: Dictionary = (
		locations.call("get_record_snapshot", candidate_id)
		if locations != null and not candidate_id.is_empty()
		else {}
	)
	var inviter_record: Dictionary = (
		locations.call("get_record_snapshot", inviter_id)
		if locations != null and not inviter_id.is_empty()
		else {}
	)
	var availability := evaluate_runtime_availability(
		inviter,
		candidate,
		spot,
		candidate_id,
		candidate_record,
		String(inviter_record.get("scene_path", "")),
		locations,
		request_priority
	)
	var candidate_machine := (
		candidate.get_node_or_null("NpcStateMachine")
		if candidate != null and is_instance_valid(candidate)
		else null
	)
	var candidate_relationship_id := _relationship_id(
		relationships,
		candidate,
		candidate_id
	)
	var inviter_relationship_id := _relationship_id(
		relationships,
		inviter,
		inviter_id
	)
	var candidate_memory := {}
	if candidate_machine != null and bool(availability.get("available", false)):
		candidate_memory = candidate_machine.call(
			"get_autonomous_social_memory_decision",
			inviter
		)
	var context := {
		"availability": availability,
		"social_memory_decision": candidate_memory,
		"relationship": _relationship_snapshot(
			relationships,
			candidate_relationship_id,
			inviter_relationship_id
		),
	}
	if candidate_machine != null:
		context["minimum_favor"] = float(candidate_machine.get(
			"npc_social_acceptance_minimum_favor"
		))
		context["maximum_anger"] = float(candidate_machine.get(
			"npc_social_acceptance_maximum_anger"
		))
		context["maximum_fear"] = float(candidate_machine.get(
			"npc_social_acceptance_maximum_fear"
		))
	var decision := _acceptance_policy.evaluate(
		StringName(inviter_id),
		StringName(candidate_id),
		context
	)
	decision["availability"] = availability.duplicate(true)
	decision["activity_kind"] = ACTIVITY_KIND
	decision["evaluated_at_usec"] = Time.get_ticks_usec()
	return decision


func evaluate_acceptance(
	inviter_id: StringName,
	candidate_id: StringName,
	candidate_to_inviter_relationship: Dictionary,
	availability: Dictionary = {},
	candidate_memory: Dictionary = {}
) -> Dictionary:
	return _acceptance_policy.evaluate(inviter_id, candidate_id, {
		"relationship": candidate_to_inviter_relationship,
		"availability": availability,
		"social_memory_decision": candidate_memory,
	})


static func evaluate_runtime_availability(
	inviter: Node2D,
	candidate: Node2D,
	spot: Node2D,
	candidate_id: String,
	candidate_record: Dictionary,
	inviter_scene_path: String,
	locations: Node,
	request_priority: int
) -> Dictionary:
	if (
		inviter == null
		or candidate == null
		or not is_instance_valid(inviter)
		or not is_instance_valid(candidate)
		or inviter == candidate
		or candidate_id.is_empty()
	):
		return _availability(false, &"invalid_request", &"invalid_candidate")
	if not candidate.is_in_group("npc"):
		return _availability(false, &"invalid_request", &"candidate_not_npc")
	if (
		not inviter.is_inside_tree()
		or not candidate.is_inside_tree()
		or inviter.get_tree() != candidate.get_tree()
	):
		return _availability(false, &"temporarily_unavailable", &"candidate_not_live_together")
	if locations == null or candidate_record.is_empty():
		return _availability(false, &"invalid_request", &"candidate_not_persistent")
	if locations.call("get_live_npc", candidate_id) != candidate:
		return _availability(false, &"temporarily_unavailable", &"candidate_not_live")
	var candidate_scene_path := String(candidate_record.get("scene_path", ""))
	if (
		inviter_scene_path.is_empty()
		or candidate_scene_path.is_empty()
		or candidate_scene_path != inviter_scene_path
	):
		return _availability(false, &"temporarily_unavailable", &"candidate_scene_mismatch")
	if not spot_is_valid_for_recreation(spot, candidate):
		return _availability(false, &"temporarily_unavailable", &"spot_incompatible_or_full")
	var machine := candidate.get_node_or_null("NpcStateMachine")
	if machine == null:
		return _availability(false, &"temporarily_unavailable", &"candidate_state_machine_missing")
	if bool(machine.call("has_scripted_control_claim")):
		return _availability(false, &"temporarily_unavailable", &"scripted_control")
	var current_state = machine.get("current_state")
	var current_state_name := String(current_state.name) if current_state != null else ""
	if HIGH_AUTHORITY_STATES.has(current_state_name):
		return _availability(false, &"temporarily_unavailable", &"high_authority_state")
	if machine.call("get_state", ACTIVITY_KIND) == null:
		return _availability(false, &"temporarily_unavailable", &"recreation_state_unavailable")
	if bool(machine.call("is_socially_engaged")):
		return _availability(false, &"temporarily_unavailable", &"existing_social_session")
	var requested_descriptor := {
		"action_kind": String(ACTIVITY_KIND),
		"state_name": String(ACTIVITY_KIND),
		"source": String(INVITATION_SOURCE),
		"priority": request_priority,
		"spot_id": Identity.get_spot_id(spot),
		"target_persistent_id": Identity.get_spot_id(spot),
	}
	if not bool(locations.call(
		"is_npc_available_for_scheduled_activity",
		candidate_id,
		ACTIVITY_KIND,
		request_priority,
		requested_descriptor
	)):
		return _availability(false, &"temporarily_unavailable", &"protected_primary_activity")
	return _availability(true, &"accepted", &"")


static func spot_is_valid_for_recreation(spot: Node2D, actor: Node2D) -> bool:
	return (
		spot != null
		and is_instance_valid(spot)
		and spot.is_inside_tree()
		and spot.has_method("can_serve_npc_casual_activity")
		and bool(spot.call(
			"can_serve_npc_casual_activity",
			actor,
			ACTIVITY_KIND
		))
	)


static func _relationship_id(
	relationships: Node,
	actor: Node,
	fallback: String
) -> String:
	if relationships != null and relationships.has_method("get_relationship_id"):
		var resolved := String(relationships.call("get_relationship_id", actor)).strip_edges()
		if not resolved.is_empty():
			return resolved
	var stable_id := Identity.get_stable_actor_id(actor)
	return stable_id if not stable_id.is_empty() else fallback.strip_edges()


static func _relationship_snapshot(
	relationships: Node,
	owner_id: String,
	other_id: String
) -> Dictionary:
	if (
		relationships == null
		or owner_id.is_empty()
		or other_id.is_empty()
		or not relationships.has_method("get_relationship_by_id")
	):
		return {}
	var snapshot = relationships.call(
		"get_relationship_by_id",
		owner_id,
		other_id
	)
	return snapshot.duplicate(true) if snapshot is Dictionary else {}


static func _inviter_opinion_supports_invitation(
	relationship: Dictionary,
	score: Dictionary
) -> bool:
	var favor := clampf(float(relationship.get("favor", 50.0)), 0.0, 100.0)
	var love := clampf(float(relationship.get("love", 0.0)), 0.0, 100.0)
	var anger := clampf(float(relationship.get("anger", 0.0)), 0.0, 100.0)
	var fear := clampf(float(relationship.get("fear", 0.0)), 0.0, 100.0)
	return (
		(favor > 50.0 or love > 0.0)
		and anger < AcceptancePolicy.DEFAULT_MAXIMUM_ANGER
		and fear < AcceptancePolicy.DEFAULT_MAXIMUM_FEAR
		and float(score.get("total_score", 0.0)) > 0.0
	)


static func _scored_candidate_precedes(a: Dictionary, b: Dictionary) -> bool:
	var a_score: Dictionary = a.get("score", {})
	var b_score: Dictionary = b.get("score", {})
	var a_total := float(a_score.get("total_score", 0.0))
	var b_total := float(b_score.get("total_score", 0.0))
	if not is_equal_approx(a_total, b_total):
		return a_total > b_total
	var a_distance := float(a_score.get("live_distance", 0.0))
	var b_distance := float(b_score.get("live_distance", 0.0))
	if not is_equal_approx(a_distance, b_distance):
		return a_distance < b_distance
	return String(a.get("candidate_id", "")) < String(b.get("candidate_id", ""))


static func _availability(
	available: bool,
	decision_kind: StringName,
	reason_code: StringName
) -> Dictionary:
	return {
		"available": available,
		"decision_kind": decision_kind,
		"reason_code": reason_code,
	}
