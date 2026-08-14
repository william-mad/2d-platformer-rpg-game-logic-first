extends "res://test/native_scene_tree_test.gd"

const Coordinator = preload(
	"res://scripts/systems/npc_behavior/npc_recreation_invitation_coordinator.gd"
)
const InvitationPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_recreation_invitation_policy.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const MachineScene = preload(
	"res://scenes/creatures/npc/npc_state_machine.tscn"
)

const TEST_SCENE_PATH := "res://test/shared_recreation_fixture.tscn"


class TestActor:
	extends CharacterBody2D

	var persistent_id: StringName
	var relationship_id: StringName

	func _init(actor_id: StringName) -> void:
		persistent_id = actor_id
		relationship_id = actor_id

	func get_npc_location_id() -> StringName:
		return persistent_id

	func get_relationship_id() -> StringName:
		return relationship_id


var _location_records: Dictionary = {}
var _live_npcs: Dictionary = {}
var _active_scene_path := ""
var _reservations: Dictionary = {}
var _relationship_data: Dictionary = {}


func before_each() -> void:
	var locations := root.get_node_or_null("NpcLocations")
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var relationships := root.get_node_or_null("Relationships")
	_location_records = locations.npc_records.duplicate(true)
	_live_npcs = locations.live_npcs.duplicate()
	_active_scene_path = locations.active_scene_path
	_reservations = simulator.spot_reservations.duplicate(true)
	_relationship_data = relationships.get_save_data()
	locations.npc_records.clear()
	locations.live_npcs.clear()
	locations.active_scene_path = TEST_SCENE_PATH
	simulator.spot_reservations.clear()
	simulator.call("_sync_spot_claim_count_cache")
	relationships.apply_save_data({"relationships": {}})


func after_each() -> void:
	var locations := root.get_node_or_null("NpcLocations")
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var relationships := root.get_node_or_null("Relationships")
	locations.npc_records = _location_records.duplicate(true)
	locations.live_npcs = _live_npcs.duplicate()
	locations.active_scene_path = _active_scene_path
	simulator.spot_reservations = _reservations.duplicate(true)
	simulator.call("_sync_spot_claim_count_cache")
	relationships.apply_save_data(_relationship_data)


func test_high_favor_partner_is_preferred() -> void:
	var spot := _spot(&"invite_rank", 3)
	var leader := _npc(&"leader", Vector2.ZERO)
	var near_friend := _npc(&"near_friend", Vector2(8.0, 0.0))
	var liked_friend := _npc(&"liked_friend", Vector2(900.0, 0.0))
	_set_favor("leader", "near_friend", 60.0)
	_set_favor("leader", "liked_friend", 95.0)
	_start_recreation(leader.machine, spot, "leader-rank")
	var result := Coordinator.new().try_invite(leader.machine, "leader-rank")
	assert_true(bool(result.accepted))
	assert_eq(
		result.selected_candidate_id,
		&"liked_friend",
		"favor remains strong enough to beat the bounded distance tie-breaker"
	)
	assert_null(near_friend.machine.active_action)
	assert_eq(liked_friend.machine.active_action.action_kind, &"Recreation")


func test_acceptance_uses_candidate_to_inviter_direction() -> void:
	var coordinator := Coordinator.new()
	var reverse_low := coordinator.evaluate_acceptance(
		&"leader",
		&"candidate",
		{"favor": 10.0},
		{"available": true}
	)
	assert_eq(reverse_low.decision_kind, &"social_decline")
	var reverse_good := coordinator.evaluate_acceptance(
		&"leader",
		&"candidate",
		{"favor": 80.0},
		{"available": true}
	)
	assert_true(
		bool(reverse_good.accepted),
		"the candidate's opinion of the inviter owns acceptance"
	)


func test_social_decline_stops_assignment_and_records_one_refusal() -> void:
	var spot := _spot(&"invite_decline", 2)
	var leader := _npc(&"leader")
	var candidate := _npc(&"candidate")
	_set_favor("leader", "candidate", 100.0)
	_set_favor("candidate", "leader", 10.0)
	_start_recreation(leader.machine, spot, "leader-decline")
	var result := Coordinator.new().try_invite(leader.machine, "leader-decline")
	assert_eq(result.decision_kind, &"social_decline")
	assert_null(candidate.machine.active_action)
	assert_eq(
		_count_memory(leader.machine.short_term_memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED),
		1,
		"a genuine social decline reuses the existing refusal-memory semantics"
	)
	assert_false(bool(
		leader.machine.get_autonomous_social_memory_decision(candidate.npc).allowed
	))


func test_temporary_unavailability_creates_no_rejection_memory() -> void:
	var spot := _spot(&"invite_busy", 2)
	var leader := _npc(&"leader")
	var candidate := _npc(&"candidate")
	_set_favor("leader", "candidate", 100.0)
	candidate.machine.scripted_control_claim_token = 7
	_start_recreation(leader.machine, spot, "leader-busy")
	var result := Coordinator.new().try_invite(leader.machine, "leader-busy")
	assert_eq(result.decision_kind, &"temporarily_unavailable")
	assert_null(candidate.machine.active_action)
	assert_eq(
		_count_memory(leader.machine.short_term_memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED),
		0,
		"being busy is not remembered as a personal rejection"
	)
	candidate.machine.scripted_control_claim_token = 0
	assert_true(bool(
		leader.machine.get_autonomous_social_memory_decision(candidate.npc).allowed
	), "a later Recreation decision may reconsider the candidate")


func test_accepted_pair_shares_destination_and_shared_session() -> void:
	var accepted := _accepted_pair(&"invite_shared")
	var leader_action = accepted.leader.machine.active_action
	var candidate_action = accepted.candidate.machine.active_action
	var shared_id := String(leader_action.metadata[Coordinator.META_SESSION_ID])
	assert_same(leader_action.get_live_target(), accepted.spot)
	assert_same(candidate_action.get_live_target(), accepted.spot)
	assert_true(
		leader_action.session_id != candidate_action.session_id,
		"each NPC retains independent action ownership"
	)
	assert_eq(candidate_action.metadata[Coordinator.META_SESSION_ID], shared_id)
	assert_eq(candidate_action.metadata[Coordinator.META_LEADER_ID], "leader")
	assert_eq(
		Coordinator.get_active_participant_ids(shared_id, root.get_node("NpcLocations")),
		PackedStringArray(["candidate", "leader"])
	)
	assert_eq(
		accepted.candidate.machine.behavior_controller.current_intent.metadata[
			Coordinator.META_SESSION_ID
		],
		shared_id,
		"the invitee's committed behavior intent carries the same shared identity"
	)


func test_liked_npc_passively_joins_existing_recreation_session() -> void:
	var joined := _passively_joined_group(&"passive_join")
	var alice_action = joined.alice.machine.active_action
	var shared_id := String(joined.result.shared_activity_session_id)
	assert_eq(alice_action.action_kind, &"Recreation")
	assert_same(alice_action.get_live_target(), joined.spot)
	assert_eq(alice_action.metadata[Coordinator.META_SESSION_ID], shared_id)
	assert_eq(alice_action.metadata[Coordinator.META_ROLE], "joiner")
	assert_eq(alice_action.metadata[Coordinator.META_PARTNER_ID], "bob")
	assert_true(alice_action.get_live_target() != joined.bob.npc)
	assert_false(String(joined.alice.machine.current_state.name) == "TravelFollow")
	assert_true(
		alice_action.session_id != joined.leader.machine.active_action.session_id,
		"the passive joiner keeps an independent action session"
	)
	assert_eq(
		Coordinator.get_active_participant_ids(shared_id, root.get_node("NpcLocations")),
		PackedStringArray(["alice", "bob", "leader"])
	)
	var feedback: Dictionary = joined.alice.machine.get_feedback_descriptor()
	assert_eq(feedback.target_selection.social_attraction_target_id, &"bob")
	assert_eq(feedback.target_selection.joining_session_id, shared_id)
	assert_true(float(feedback.target_selection.social_affinity_bonus) > 0.0)


func test_leader_departure_does_not_break_or_redirect_remaining_group() -> void:
	var joined := _passively_joined_group(&"passive_leader_exit")
	var shared_id := String(joined.result.shared_activity_session_id)
	assert_true(joined.leader.machine.cancel_active_action(
		joined.result.leader_action_session_id,
		"leader_left"
	))
	assert_eq(
		Coordinator.get_active_participant_ids(shared_id, root.get_node("NpcLocations")),
		PackedStringArray(["alice", "bob"])
	)
	for participant in [joined.alice, joined.bob]:
		assert_eq(participant.machine.active_action.action_kind, &"Recreation")
		assert_same(participant.machine.get_active_action_target(), joined.spot)
		assert_true(participant.machine.get_active_action_target() != joined.leader.npc)
		assert_false(String(participant.machine.current_state.name) == "TravelFollow")


func test_passive_join_commitment_prevents_trivial_group_switching() -> void:
	var joined := _passively_joined_group(&"passive_commitment")
	var alice_machine := joined.alice.machine as NpcStateMachine
	var original_action_id := alice_machine.get_active_action_session_id()
	var alternate := _spot(&"passive_commitment_alternate", 4)
	assert_false(alice_machine.request_action_from_descriptor({
		"session_id": "passive-immediate-replacement",
		"action_kind": "Recreation",
		"source": "need",
		"priority": 20,
		"status": "proposed",
		"spot_id": String(alternate.spot_id),
	}, alternate), "equal-priority score changes cannot replace a committed group")
	assert_eq(alice_machine.get_active_action_session_id(), original_action_id)
	assert_same(alice_machine.get_active_action_target(), joined.spot)


func test_invitee_never_targets_or_follows_inviter() -> void:
	var accepted := _accepted_pair(&"invite_no_follow")
	var candidate_machine := accepted.candidate.machine as NpcStateMachine
	assert_same(candidate_machine.get_active_action_target(), accepted.spot)
	assert_true(candidate_machine.get_active_action_target() != accepted.leader.npc)
	assert_eq(candidate_machine.active_action.target_persistent_id, "invite_no_follow")
	assert_false(
		String(candidate_machine.current_state.name) == "TravelFollow",
		"shared Recreation never becomes Follow"
	)


func test_capacity_fill_between_selection_and_commit_is_clean() -> void:
	var spot := _spot(&"invite_capacity", 2)
	var leader := _npc(&"leader")
	var candidate := _npc(&"candidate")
	_set_favor("leader", "candidate", 100.0)
	_start_recreation(leader.machine, spot, "leader-capacity")
	var locations := root.get_node("NpcLocations")
	var relationships := root.get_node("Relationships")
	var policy := InvitationPolicy.new()
	var ranked := policy.rank_runtime_candidates(
		leader.machine,
		spot,
		locations,
		relationships
	)
	assert_same(ranked.target_node, candidate.npc, "candidate is eligible before the race")
	var simulator := root.get_node("NpcWorldSimulation")
	assert_true(bool(simulator.try_claim_spot(
		&"capacity_racer",
		"capacity-race",
		spot.spot_id,
		&"activity"
	).accepted))
	var decision := policy.evaluate_runtime_acceptance(
		leader.npc,
		candidate.npc,
		spot,
		locations,
		relationships
	)
	assert_eq(decision.decision_kind, &"temporarily_unavailable")
	assert_eq(decision.reason_code, &"spot_incompatible_or_full")
	assert_null(candidate.machine.active_action)
	var diagnostics: Dictionary = simulator.call(
		"get_spot_reservation_diagnostics",
		spot.spot_id
	)
	assert_eq(int(diagnostics.occupancy), 2)
	for reservation in diagnostics.reservations:
		assert_false(
			String(reservation.npc_id) == "candidate",
			"the losing candidate never acquires partial ownership"
		)


func test_high_authority_candidate_is_not_interrupted() -> void:
	var spot := _spot(&"invite_authority", 2)
	var leader := _npc(&"leader")
	var candidate := _npc(&"candidate")
	_set_favor("leader", "candidate", 100.0)
	candidate.machine.state_history.clear()
	candidate.machine.state_history.append(candidate.machine.get_state(&"Fight"))
	_start_recreation(leader.machine, spot, "leader-authority")
	var result := Coordinator.new().try_invite(leader.machine, "leader-authority")
	assert_eq(result.decision_kind, &"temporarily_unavailable")
	assert_eq(String(candidate.machine.current_state.name), "Fight")
	assert_null(candidate.machine.active_action)


func test_cancellation_releases_membership_and_reservations() -> void:
	var accepted := _accepted_pair(&"invite_cleanup")
	var shared_id := String(accepted.result.shared_activity_session_id)
	var simulator := root.get_node("NpcWorldSimulation")
	var locations := root.get_node("NpcLocations")
	assert_true(accepted.candidate.machine.cancel_active_action(
		accepted.result.invitee_action_session_id,
		"candidate_left"
	))
	assert_eq(
		Coordinator.get_active_participant_ids(shared_id, locations),
		PackedStringArray(["leader"]),
		"membership is derived from current action ownership"
	)
	assert_eq(int(simulator.get_spot_reservation_diagnostics(accepted.spot.spot_id).occupancy), 1)
	assert_true(accepted.leader.machine.cancel_active_action(
		accepted.result.leader_action_session_id,
		"leader_left"
	))
	assert_true(Coordinator.get_active_participant_ids(shared_id, locations).is_empty())
	assert_eq(int(simulator.get_spot_reservation_diagnostics(accepted.spot.spot_id).occupancy), 0)


func test_one_shot_invitation_and_commitment_prevent_trivial_thrashing() -> void:
	var accepted := _accepted_pair(&"invite_commitment")
	var candidate_machine := accepted.candidate.machine as NpcStateMachine
	var original_action_id := candidate_machine.get_active_action_session_id()
	var repeated := Coordinator.new().try_invite(
		accepted.leader.machine,
		accepted.result.leader_action_session_id
	)
	assert_eq(repeated.reason_code, &"invitation_already_attempted")
	assert_eq(candidate_machine.get_active_action_session_id(), original_action_id)
	assert_true(
		candidate_machine.behavior_controller.get_remaining_commitment_seconds() > 0.0
	)
	var alternate := _spot(&"invite_commitment_alternate", 2)
	assert_false(candidate_machine.request_action_from_descriptor({
		"session_id": "immediate-replacement",
		"action_kind": "Recreation",
		"source": "social_ai",
		"priority": Coordinator.INVITATION_PRIORITY,
		"status": "proposed",
		"spot_id": String(alternate.spot_id),
	}, alternate), "equal-priority autonomous replacement cannot thrash the invitee")
	assert_eq(candidate_machine.get_active_action_session_id(), original_action_id)


func test_rest_remains_passive_and_never_proactively_invites() -> void:
	var spot := _spot(&"passive_rest", 2, &"Rest")
	var leader := _npc(&"leader")
	var candidate := _npc(&"candidate")
	_set_favor("leader", "candidate", 100.0)
	assert_true(leader.machine.request_action_from_descriptor({
		"session_id": "leader-rest",
		"action_kind": "Rest",
		"source": "need",
		"priority": 20,
		"status": "proposed",
		"spot_id": String(spot.spot_id),
	}, spot))
	assert_eq(leader.machine.active_action.action_kind, &"Rest")
	assert_false(leader.machine.active_action.metadata.has(Coordinator.META_ATTEMPTED))
	assert_null(candidate.machine.active_action)


func _accepted_pair(spot_id: StringName) -> Dictionary:
	var spot := _spot(spot_id, 2)
	var leader := _npc(&"leader", Vector2.ZERO)
	var candidate := _npc(&"candidate", Vector2(80.0, 0.0))
	_set_favor("leader", "candidate", 100.0)
	_set_favor("candidate", "leader", 80.0)
	var leader_action_id := "%s-leader" % String(spot_id)
	_start_recreation(leader.machine, spot, leader_action_id)
	var result := Coordinator.new().try_invite(leader.machine, leader_action_id)
	assert_true(bool(result.accepted), "shared Recreation fixture is accepted")
	return {
		"spot": spot,
		"leader": leader,
		"candidate": candidate,
		"result": result,
	}


func _passively_joined_group(spot_id: StringName) -> Dictionary:
	var spot := _spot(spot_id, 4)
	var leader := _npc(&"leader", Vector2.ZERO)
	var bob := _npc(&"bob", Vector2(20.0, 0.0))
	_set_favor("leader", "bob", 100.0)
	_set_favor("bob", "leader", 80.0)
	var leader_action_id := "%s-leader" % String(spot_id)
	_start_recreation(leader.machine, spot, leader_action_id)
	var result := Coordinator.new().try_invite(leader.machine, leader_action_id)
	assert_true(bool(result.accepted), "the existing shared group starts")

	var alice := _npc(&"alice", Vector2(40.0, 0.0))
	_set_favor("alice", "bob", 90.0)
	alice.machine.value_reactions_enabled = true
	alice.machine.replace_values({
		"hp": 100.0,
		"disabled": 0.0,
		"knockout": 0.0,
		"sleep_need": 0.0,
		"hunger": 0.0,
		"tired": 0.0,
		"boredom": 80.0,
		"talk_need": 0.0,
	}, null, {}, false)
	assert_true(alice.machine.evaluate_value_reactions(null, {}), "Alice chooses Recreation")
	return {
		"spot": spot,
		"leader": leader,
		"bob": bob,
		"alice": alice,
		"result": result,
	}


func _npc(npc_id: StringName, position: Vector2 = Vector2.ZERO) -> Dictionary:
	var actor := TestActor.new(npc_id)
	actor.name = String(npc_id)
	actor.position = position
	actor.add_to_group("npc")
	var machine := MachineScene.instantiate() as NpcStateMachine
	machine.active = false
	machine.value_reactions_enabled = false
	machine.passive_needs_enabled = false
	actor.add_child(machine)
	add_child_autofree(actor)
	machine.bind_npc(actor)
	machine.initialize_states()
	machine.state_history = [machine.get_state(&"Idle")]
	machine.short_term_memory.clear_all(&"test_reset")
	machine.active = true
	var locations := root.get_node("NpcLocations")
	locations.npc_records[String(npc_id)] = {
		"npc_id": String(npc_id),
		"scene_path": TEST_SCENE_PATH,
		"pending_travel": {},
		"activity": {},
		"action": {},
		"node_state": {"social_stats": {"hp": 100.0}},
	}
	locations.live_npcs[String(npc_id)] = actor
	return {"npc": actor, "machine": machine}


func _spot(
	spot_id: StringName,
	capacity: int,
	activity_kind: StringName = &"Recreation"
) -> NpcCasualSpot:
	var spot := NpcCasualSpot.new()
	spot.name = String(spot_id)
	spot.spot_id = spot_id
	spot.activity_state_name = activity_kind
	spot.reservation_capacity = capacity
	return add_child_autofree(spot) as NpcCasualSpot


func _start_recreation(
	machine: NpcStateMachine,
	spot: NpcCasualSpot,
	session_id: String
) -> void:
	assert_true(machine.request_action_from_descriptor({
		"session_id": session_id,
		"action_kind": "Recreation",
		"source": "need",
		"priority": 20,
		"status": "proposed",
		"spot_id": String(spot.spot_id),
	}, spot), "leader Recreation starts")


func _set_favor(owner_id: String, other_id: String, favor: float) -> void:
	root.get_node("Relationships").set_opinion_metric_by_id(
		owner_id,
		other_id,
		&"favor",
		favor,
		"test"
	)


func _count_memory(memory: NpcShortTermMemory, event_type: StringName) -> int:
	var count := 0
	for event in memory.get_recent_memories():
		if event.event_type == event_type:
			count += 1
	return count
