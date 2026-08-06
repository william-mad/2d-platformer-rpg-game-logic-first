extends "res://test/native_scene_tree_test.gd"

const AcceptancePolicy = preload(
	"res://scripts/systems/npc_behavior/npc_social_acceptance_policy.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const MemoryScene = preload(
	"res://scenes/creatures/npc/npc_state_machine.tscn"
)
const Scorer = preload(
	"res://scripts/systems/npc_behavior/npc_social_candidate_scorer.gd"
)

var _previous_total_hours: float = 0.0
var _previous_auto_advance: bool = false
var _previous_relationships: Dictionary = {}


class TestActor:
	extends CharacterBody2D

	var persistent_id: StringName
	var relationship_id: StringName

	func _init(new_id: StringName, new_relationship_id: StringName = &"") -> void:
		persistent_id = new_id
		relationship_id = new_relationship_id if new_relationship_id != &"" else new_id

	func get_npc_location_id() -> StringName:
		return persistent_id

	func get_relationship_id() -> StringName:
		return relationship_id


func before_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		_previous_total_hours = world_time.get_total_hours()
		_previous_auto_advance = world_time.auto_advance
		world_time.auto_advance = false
		world_time.set_total_hours(10.0)
	var relationships := root.get_node_or_null("Relationships")
	if relationships != null:
		_previous_relationships = relationships.get_save_data()
		relationships.apply_save_data({"relationships": {}})


func after_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		world_time.auto_advance = _previous_auto_advance
		world_time.set_total_hours(_previous_total_hours)
	var relationships := root.get_node_or_null("Relationships")
	if relationships != null:
		relationships.apply_save_data(_previous_relationships)


func test_available_socially_acceptable_candidate_accepts() -> void:
	var requester := _npc_fixture(&"requester", &"requester_rel")
	var candidate := _npc_fixture(&"candidate", &"candidate_rel")
	var decision: Dictionary = candidate.machine.evaluate_npc_talk_request(
		requester.npc,
		{"request_priority": 60}
	)
	assert_true(bool(decision.accepted), "available neutral candidate accepts")
	assert_eq(decision.decision_kind, &"accepted")
	assert_eq(decision.requester_id, &"requester")
	assert_eq(decision.candidate_id, &"candidate")
	assert_true(
		candidate.machine.can_accept_talk_request(requester.npc, 60),
		"Boolean compatibility wrapper delegates to the structured decision"
	)
	assert_eq(
		candidate.machine.get_social_acceptance_debug_descriptor(),
		decision,
		"diagnostics expose a defensive copy of the latest decision"
	)


func test_hard_ownership_gates_are_temporary_not_personal() -> void:
	var requester := _npc_fixture(&"requester")
	var candidate := _npc_fixture(&"candidate")
	var candidate_machine := candidate.machine as NpcStateMachine
	var stale: Dictionary = candidate_machine.evaluate_npc_talk_request(
		requester.npc,
		{
			"require_current_session": true,
			"session_id": "stale-session",
			"source": &"social_ai",
		}
	)
	assert_eq(stale.decision_kind, &"invalid_request")
	assert_eq(stale.reason_code, &"stale_social_session")
	assert_eq(
		candidate_machine.evaluate_npc_talk_request(candidate.npc).decision_kind,
		&"invalid_request",
		"self-directed requests are invalid before social policy"
	)
	candidate_machine.set("scripted_control_claim_token", 9)
	var scripted: Dictionary = candidate_machine.evaluate_npc_talk_request(requester.npc)
	assert_eq(scripted.decision_kind, &"temporarily_unavailable")
	assert_eq(scripted.reason_code, &"scripted_control")
	candidate_machine.set("scripted_control_claim_token", 0)
	candidate_machine.state_history = [candidate_machine.get_state(&"Fight")]
	var emergency: Dictionary = candidate_machine.evaluate_npc_talk_request(requester.npc)
	assert_eq(emergency.decision_kind, &"temporarily_unavailable")
	assert_eq(emergency.reason_code, &"emergency_state")
	candidate_machine.state_history = [candidate_machine.get_state(&"Work")]
	candidate_machine.current_state_priority = 100
	var protected: Dictionary = candidate_machine.evaluate_npc_talk_request(
		requester.npc,
		{"request_priority": 60}
	)
	assert_eq(protected.decision_kind, &"temporarily_unavailable")
	assert_eq(protected.reason_code, &"protected_primary_activity")
	assert_true(
		requester.memory.get_recent_memories().is_empty(),
		"candidate inspection creates no requester refusal memory"
	)


func test_candidate_recent_harm_memory_socially_declines() -> void:
	var requester := _npc_fixture(&"requester")
	var candidate := _npc_fixture(&"candidate")
	_remember(candidate.memory, MemoryPolicy.EVENT_HARMED_BY_ACTOR, &"requester", &"candidate", &"Harm")
	var decision: Dictionary = candidate.machine.evaluate_npc_talk_request(requester.npc)
	assert_false(bool(decision.accepted))
	assert_eq(decision.decision_kind, &"social_decline")
	assert_eq(decision.reason_code, &"recently_harmed_by_requester")
	assert_true(float(decision.remaining_retry_hours) > 0.0)
	assert_false(String(decision.memory_id).is_empty(), "decline identifies the candidate-owned memory")


func test_candidate_directed_relationship_thresholds_use_opposite_row() -> void:
	var requester := _npc_fixture(&"requester", &"requester_rel")
	var candidate := _npc_fixture(&"candidate", &"candidate_rel")
	var relationships := root.get_node_or_null("Relationships")
	assert_not_null(relationships)
	if relationships == null:
		return
	relationships.set_favor(candidate.npc, requester.npc, 10.0, "test")
	var low_favor: Dictionary = candidate.machine.evaluate_npc_talk_request(requester.npc)
	assert_eq(low_favor.decision_kind, &"social_decline")
	assert_eq(low_favor.reason_code, &"requester_favor_too_low")
	relationships.set_favor(candidate.npc, requester.npc, 50.0, "test")
	relationships.set_favor(requester.npc, candidate.npc, 0.0, "opposite_direction")
	assert_true(
		bool(candidate.machine.evaluate_npc_talk_request(requester.npc).accepted),
		"requester-to-candidate row does not replace candidate-owned acceptance"
	)
	relationships.set_anger(candidate.npc, requester.npc, 70.0, "test")
	var angry: Dictionary = candidate.machine.evaluate_npc_talk_request(requester.npc)
	assert_eq(angry.reason_code, &"requester_anger_too_high")
	relationships.set_anger(candidate.npc, requester.npc, 0.0, "test")
	relationships.set_fear(candidate.npc, requester.npc, 80.0, "test")
	var afraid: Dictionary = candidate.machine.evaluate_npc_talk_request(requester.npc)
	assert_eq(afraid.reason_code, &"requester_fear_too_high")


func test_recent_completed_conversation_is_temporary_unavailability() -> void:
	var requester := _npc_fixture(&"requester")
	var candidate := _npc_fixture(&"candidate")
	_remember(
		candidate.memory,
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED,
		&"requester",
		&"candidate",
		&"Talk"
	)
	var decision: Dictionary = candidate.machine.evaluate_npc_talk_request(requester.npc)
	assert_eq(decision.decision_kind, &"temporarily_unavailable")
	assert_eq(decision.reason_code, &"recently_talked_with_requester")
	assert_true(float(decision.remaining_retry_hours) > 0.0)
	assert_true(requester.memory.get_recent_memories().is_empty())


func test_social_decline_creates_one_structured_requester_memory() -> void:
	var requester := _npc_fixture(&"requester")
	var candidate := _npc_fixture(&"candidate")
	_remember(candidate.memory, MemoryPolicy.EVENT_HARMED_BY_ACTOR, &"requester", &"candidate", &"Harm")
	assert_false(
		requester.machine.request_talk(candidate.npc, 60, true, &"social_ai"),
		"candidate decline stops mutual Talk before either overlay commits"
	)
	var refusals := _memory_descriptors(
		requester.memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED
	)
	assert_eq(refusals.size(), 1, "one handshake decline creates one refusal memory")
	if refusals.size() == 1:
		var descriptor: Dictionary = refusals[0]
		assert_eq(descriptor.subject_id, &"candidate")
		assert_eq(descriptor.target_id, &"requester")
		assert_eq(descriptor.metadata.decision_kind, &"social_decline")
		assert_eq(
			descriptor.metadata.refusal_reason_code,
			&"recently_harmed_by_requester"
		)
	assert_null(requester.machine.interaction_overlay)
	assert_null(candidate.machine.interaction_overlay)


func test_temporary_unavailability_has_no_suppression_and_can_retry_later() -> void:
	var requester := _npc_fixture(&"requester")
	var candidate := _npc_fixture(&"candidate")
	requester.machine.set_value(&"talk_need", 80.0, null, false)
	candidate.machine.set("scripted_control_claim_token", 1)
	assert_false(requester.machine.request_talk(candidate.npc, 60, true, &"social_ai"))
	assert_null(requester.machine.interaction_overlay)
	assert_null(candidate.machine.interaction_overlay)
	assert_eq(requester.machine.get_value(&"talk_need", 0.0), 80.0)
	assert_true(
		_memory_descriptors(requester.memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED).is_empty(),
		"being busy does not install refusal-memory suppression"
	)
	assert_true(
		bool(requester.machine.get_autonomous_social_memory_decision(candidate.npc).allowed),
		"existing planner cadence may reconsider the candidate"
	)
	candidate.machine.set("scripted_control_claim_token", 0)
	assert_true(
		requester.machine.request_talk(candidate.npc, 60, true, &"social_ai"),
		"the same candidate can accept after temporary ownership clears"
	)


func test_accepted_talk_is_not_reevaluated_and_player_path_stays_separate() -> void:
	var requester := _npc_fixture(&"requester")
	var candidate := _npc_fixture(&"candidate")
	assert_true(requester.machine.request_talk(candidate.npc, 60, true, &"social_ai"))
	assert_true(requester.machine.is_talking_with(candidate.npc))
	assert_true(candidate.machine.is_talking_with(requester.npc))
	_remember(candidate.memory, MemoryPolicy.EVENT_HARMED_BY_ACTOR, &"requester", &"candidate", &"Harm")
	assert_true(
		candidate.machine.is_talking_with(requester.npc),
		"new private memory does not retroactively cancel an accepted Talk"
	)
	var player_fixture := _npc_fixture(&"player_talker")
	var player := TestActor.new(&"player")
	player.name = "Player"
	player.add_to_group("player")
	add_child_autofree(player)
	assert_true(
		player_fixture.machine.request_talk(player, 60, false, &"player"),
		"player Talk continues through the existing non-NPC path"
	)
	assert_true(
		player_fixture.machine.get_social_acceptance_debug_descriptor().is_empty(),
		"player Talk never invokes candidate social acceptance"
	)
	var score := Scorer.new().score_candidate(&"requester", &"candidate", {
		"relationship": {"favor": 80.0},
	})
	assert_true(float(score.total_score) > 0.0, "candidate scoring remains a separate policy")


func _npc_fixture(npc_id: StringName, relationship_id: StringName = &"") -> Dictionary:
	var npc := TestActor.new(npc_id, relationship_id)
	npc.name = String(npc_id)
	npc.add_to_group("npc")
	var machine := MemoryScene.instantiate() as NpcStateMachine
	machine.active = false
	machine.value_reactions_enabled = false
	machine.passive_needs_enabled = false
	npc.add_child(machine)
	add_child_autofree(npc)
	machine.bind_npc(npc)
	machine.state_history = [machine.get_state(&"Idle")]
	machine.current_state.enter()
	machine.short_term_memory.clear_all(&"test_fixture_reset")
	machine.active = true
	return {
		"npc": npc,
		"machine": machine,
		"memory": machine.short_term_memory,
	}


func _remember(
	memory: NpcShortTermMemory,
	event_type: StringName,
	subject_id: StringName,
	target_id: StringName,
	logical_action: StringName
) -> Dictionary:
	return memory.remember_event(event_type, {
		"source": "test",
		"reason_code": "test",
		"subject_id": subject_id,
		"target_id": target_id,
		"logical_action": logical_action,
		"now_game_hours": 10.0,
	})


func _memory_descriptors(
	memory: NpcShortTermMemory,
	event_type: StringName
) -> Array[Dictionary]:
	var matches: Array[Dictionary] = []
	for event in memory.get_recent_memories():
		if event.event_type == event_type:
			matches.append(event.to_dict())
	return matches
