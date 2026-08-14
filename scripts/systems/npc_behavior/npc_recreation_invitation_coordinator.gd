class_name NpcRecreationInvitationCoordinator extends RefCounted

const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const Identity = preload("res://scripts/systems/npc_identity.gd")
const InvitationPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_recreation_invitation_policy.gd"
)

const ACTIVITY_KIND: StringName = InvitationPolicy.ACTIVITY_KIND
const INVITATION_SOURCE: StringName = InvitationPolicy.INVITATION_SOURCE
const INVITATION_PRIORITY: int = InvitationPolicy.INVITATION_PRIORITY

const META_ATTEMPTED := "shared_activity_invitation_attempted"
const META_RESULT := "shared_activity_invitation_result"
const META_SESSION_ID := "shared_activity_session_id"
const META_TYPE := "shared_activity_type"
const META_LEADER_ID := "shared_activity_leader_id"
const META_SPOT_ID := "shared_activity_spot_id"
const META_PARTICIPANTS := "shared_activity_participant_ids"
const META_CAPACITY := "shared_activity_capacity"
const META_ROLE := "shared_activity_role"
const META_PARTNER_ID := "shared_activity_partner_id"
const META_PARTNER_ACTION_ID := "shared_activity_partner_action_session_id"

var _policy := InvitationPolicy.new()
var _last_descriptor: Dictionary = {}


func try_invite(inviter_machine: Node, expected_action_session_id: String) -> Dictionary:
	_last_descriptor = _base_result()
	if not _inviter_action_is_current(inviter_machine, expected_action_session_id):
		return _finish_result(&"invalid_request", &"stale_inviter_action")

	var inviter_action = inviter_machine.get("active_action")
	var inviter_metadata: Dictionary = inviter_action.metadata
	if String(inviter_metadata.get(META_ROLE, "")) == "invitee":
		return _finish_result(&"invalid_request", &"invitee_cannot_chain_invite")
	if bool(inviter_metadata.get(META_ATTEMPTED, false)):
		return _finish_result(&"invalid_request", &"invitation_already_attempted")

	_update_action_metadata(inviter_machine, {
		META_ATTEMPTED: true,
		META_RESULT: "evaluating",
	})
	var inviter: Node2D = inviter_machine.get("npc") as Node2D
	var spot: Node2D = inviter_action.get_live_target()
	if not InvitationPolicy.spot_is_valid_for_recreation(spot, inviter):
		return _record_inviter_result(
			inviter_machine,
			&"temporarily_unavailable",
			&"recreation_spot_unavailable"
		)

	var locations := inviter_machine.get_node_or_null("/root/NpcLocations")
	var relationships := inviter_machine.get_node_or_null("/root/Relationships")
	if locations == null or relationships == null:
		return _record_inviter_result(
			inviter_machine,
			&"invalid_request",
			&"social_services_missing"
		)

	var ranked := _policy.rank_runtime_candidates(
		inviter_machine,
		spot,
		locations,
		relationships,
		INVITATION_PRIORITY
	)
	_last_descriptor["selection"] = ranked.get("descriptor", {}).duplicate(true)
	var candidate: Node2D = ranked.get("target_node", null) as Node2D
	if candidate == null:
		return _record_inviter_result(
			inviter_machine,
			&"temporarily_unavailable",
			&"no_eligible_recreation_partner"
		)

	var candidate_id := Identity.get_stable_actor_id(candidate)
	var inviter_id := Identity.get_stable_actor_id(inviter)
	var shared_session_id := ActionSession.make_session_id(
		inviter_id,
		INVITATION_SOURCE,
		&"SharedRecreation"
	)
	var acceptance := _policy.evaluate_runtime_acceptance(
		inviter,
		candidate,
		spot,
		locations,
		relationships,
		INVITATION_PRIORITY
	)
	_last_descriptor["acceptance"] = acceptance.duplicate(true)
	_last_descriptor["selected_candidate_id"] = StringName(candidate_id)
	_last_descriptor["shared_activity_session_id"] = shared_session_id
	if not bool(acceptance.get("accepted", false)):
		return _handle_rejection(
			inviter_machine,
			candidate,
			shared_session_id,
			acceptance
		)

	var candidate_machine := candidate.get_node_or_null("NpcStateMachine")
	if candidate_machine == null:
		return _record_inviter_result(
			inviter_machine,
			&"temporarily_unavailable",
			&"candidate_state_machine_missing"
		)
	var candidate_action_session_id := ActionSession.make_session_id(
		candidate_id,
		INVITATION_SOURCE,
		ACTIVITY_KIND
	)
	var spot_id := Identity.get_spot_id(spot)
	var participant_ids := [inviter_id, candidate_id]
	var shared_capacity := _get_shared_capacity(spot_id, inviter_machine)
	var accepted := bool(candidate_machine.call(
		"request_action_from_descriptor",
		{
			"session_id": candidate_action_session_id,
			"action_kind": String(ACTIVITY_KIND),
			"source": String(INVITATION_SOURCE),
			"reason": "shared_recreation_invitation",
			"priority": INVITATION_PRIORITY,
			"status": "proposed",
			"phase": "executing",
			"spot_id": spot_id,
			"scene_path": String(locations.call("get_current_scene_path")),
			"target_persistent_id": spot_id,
			"metadata": _shared_metadata(
				shared_session_id,
				inviter_id,
				spot_id,
				participant_ids,
				shared_capacity,
				"invitee",
				inviter_id,
				expected_action_session_id
			),
		},
		spot
	))
	if not accepted:
		return _record_inviter_result(
			inviter_machine,
			&"temporarily_unavailable",
			&"candidate_activity_assignment_rejected"
		)

	if not _inviter_action_is_current(inviter_machine, expected_action_session_id):
		candidate_machine.call(
			"cancel_active_action",
			candidate_action_session_id,
			"inviter_action_changed_during_handshake"
		)
		return _finish_result(&"temporarily_unavailable", &"inviter_action_changed")

	var leader_metadata := _shared_metadata(
		shared_session_id,
		inviter_id,
		spot_id,
		participant_ids,
		shared_capacity,
		"leader",
		candidate_id,
		candidate_action_session_id
	)
	leader_metadata[META_ATTEMPTED] = true
	leader_metadata[META_RESULT] = "accepted"
	_update_action_metadata(inviter_machine, leader_metadata)
	_last_descriptor.merge({
		"accepted": true,
		"decision_kind": InvitationPolicy.DECISION_ACCEPTED,
		"reason_code": &"",
		"leader_action_session_id": expected_action_session_id,
		"invitee_action_session_id": candidate_action_session_id,
	}, true)
	return _last_descriptor.duplicate(true)


func evaluate_acceptance(
	inviter_id: StringName,
	candidate_id: StringName,
	candidate_to_inviter_relationship: Dictionary,
	availability: Dictionary = {},
	candidate_memory: Dictionary = {}
) -> Dictionary:
	return _policy.evaluate_acceptance(
		inviter_id,
		candidate_id,
		candidate_to_inviter_relationship,
		availability,
		candidate_memory
	)


func get_last_descriptor() -> Dictionary:
	return _last_descriptor.duplicate(true)


static func get_active_participant_ids(
	shared_activity_session_id: String,
	locations: Node
) -> PackedStringArray:
	var participants := PackedStringArray()
	var clean_shared_id := shared_activity_session_id.strip_edges()
	if clean_shared_id.is_empty() or locations == null:
		return participants
	for npc_id_value in locations.call("get_record_ids_snapshot"):
		var npc_id := String(npc_id_value)
		var descriptor: Dictionary = {}
		var live_npc := locations.call("get_live_npc", npc_id) as Node
		if live_npc != null:
			var machine := live_npc.get_node_or_null("NpcStateMachine")
			if machine != null:
				descriptor = machine.call("get_active_action_descriptor")
		if descriptor.is_empty():
			var record: Dictionary = locations.call("get_record_snapshot", npc_id)
			var record_action = record.get("action", {})
			if record_action is Dictionary:
				descriptor = record_action
		if _descriptor_is_active_shared_recreation(descriptor, clean_shared_id):
			participants.append(npc_id)
	participants.sort()
	return participants


func _handle_rejection(
	inviter_machine: Node,
	candidate: Node2D,
	shared_session_id: String,
	acceptance: Dictionary
) -> Dictionary:
	var decision_kind := StringName(String(acceptance.get(
		"decision_kind",
		InvitationPolicy.DECISION_INVALID_REQUEST
	)))
	var reason_code := StringName(String(acceptance.get(
		"reason_code",
		"candidate_rejected"
	)))
	if decision_kind == InvitationPolicy.DECISION_SOCIAL_DECLINE:
		_remember_social_decline(
			inviter_machine,
			candidate,
			shared_session_id,
			reason_code
		)
	return _record_inviter_result(inviter_machine, decision_kind, reason_code)


func _record_inviter_result(
	inviter_machine: Node,
	decision_kind: StringName,
	reason_code: StringName
) -> Dictionary:
	_update_action_metadata(inviter_machine, {
		META_ATTEMPTED: true,
		META_RESULT: String(decision_kind),
	})
	return _finish_result(decision_kind, reason_code)


func _finish_result(decision_kind: StringName, reason_code: StringName) -> Dictionary:
	_last_descriptor["accepted"] = decision_kind == InvitationPolicy.DECISION_ACCEPTED
	_last_descriptor["decision_kind"] = decision_kind
	_last_descriptor["reason_code"] = reason_code
	return _last_descriptor.duplicate(true)


static func _inviter_action_is_current(machine: Node, session_id: String) -> bool:
	if machine == null or session_id.strip_edges().is_empty():
		return false
	var action = machine.get("active_action")
	return (
		action != null
		and action.session_id == session_id
		and action.action_kind == ACTIVITY_KIND
		and action.status == ActionSession.Status.ACTIVE
	)


static func _update_action_metadata(machine: Node, updates: Dictionary) -> void:
	if machine == null:
		return
	var action = machine.get("active_action")
	if action == null:
		return
	for key in updates:
		action.metadata[String(key)] = updates[key]
	var behavior_controller = machine.get("behavior_controller")
	if (
		behavior_controller != null
		and behavior_controller.current_intent != null
		and behavior_controller.current_intent.action_session_id == action.session_id
	):
		var intent_metadata: Dictionary = behavior_controller.current_intent.metadata.duplicate(true)
		for key in updates:
			intent_metadata[String(key)] = updates[key]
		behavior_controller.refresh_current_intent(
			behavior_controller.current_intent.refreshed_copy({
				"metadata": intent_metadata,
			}),
			action.session_id
		)
	machine.call("_publish_active_action")


static func _remember_social_decline(
	inviter_machine: Node,
	candidate: Node2D,
	shared_session_id: String,
	reason_code: StringName
) -> void:
	var observer = inviter_machine.get("memory_observer")
	if observer == null:
		return
	observer.call(
		"observe_conversation_refused",
		candidate,
		shared_session_id,
		reason_code,
		INVITATION_SOURCE,
		{
			"decision_kind": InvitationPolicy.DECISION_SOCIAL_DECLINE,
			"invitation_activity": ACTIVITY_KIND,
		}
	)


static func _shared_metadata(
	shared_session_id: String,
	leader_id: String,
	spot_id: String,
	participant_ids: Array,
	capacity: int,
	role: String,
	partner_id: String,
	partner_action_session_id: String
) -> Dictionary:
	return {
		META_SESSION_ID: shared_session_id,
		META_TYPE: String(ACTIVITY_KIND),
		META_LEADER_ID: leader_id,
		META_SPOT_ID: spot_id,
		META_PARTICIPANTS: participant_ids.duplicate(),
		META_CAPACITY: capacity,
		META_ROLE: role,
		META_PARTNER_ID: partner_id,
		META_PARTNER_ACTION_ID: partner_action_session_id,
	}


static func _get_shared_capacity(spot_id: String, machine: Node) -> int:
	var simulator := machine.get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or spot_id.is_empty():
		return 0
	var diagnostics: Dictionary = simulator.call(
		"get_spot_reservation_diagnostics",
		StringName(spot_id)
	)
	return int(diagnostics.get("capacity", 0))


static func _descriptor_is_active_shared_recreation(
	descriptor: Dictionary,
	shared_session_id: String
) -> bool:
	if (
		descriptor.is_empty()
		or String(descriptor.get("action_kind", "")) != String(ACTIVITY_KIND)
		or String(descriptor.get("status", "")) not in ["proposed", "active"]
	):
		return false
	var metadata = descriptor.get("metadata", {})
	return (
		metadata is Dictionary
		and String(metadata.get(META_SESSION_ID, "")) == shared_session_id
	)


static func _base_result() -> Dictionary:
	return {
		"accepted": false,
		"decision_kind": InvitationPolicy.DECISION_INVALID_REQUEST,
		"reason_code": &"",
		"selected_candidate_id": &"",
		"shared_activity_session_id": "",
		"leader_action_session_id": "",
		"invitee_action_session_id": "",
		"selection": {},
		"acceptance": {},
	}
