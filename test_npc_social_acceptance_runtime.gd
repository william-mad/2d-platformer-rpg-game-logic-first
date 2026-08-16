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


func test_player_gate_reuses_directed_opinion_and_conversation_memory() -> void:
	var candidate := _npc_fixture(&"player_gate_candidate")
	var player := TestActor.new(&"player")
	player.name = "Player"
	player.add_to_group("player")
	add_child_autofree(player)
	var relationships := root.get_node_or_null("Relationships")
	assert_not_null(relationships)
	if relationships == null:
		return

	assert_true(
		bool(candidate.machine.can_begin_player_interaction(player).accepted),
		"neutral Player interaction remains accepted"
	)
	relationships.set_favor(player, candidate.npc, 0.0, "opposite_direction")
	assert_true(
		bool(candidate.machine.can_begin_player_interaction(player).accepted),
		"the Player's opinion of the NPC does not control the NPC's response"
	)
	relationships.set_favor(candidate.npc, player, 10.0, "player_gate_test")
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"requester_favor_too_low",
		"low NPC-to-Player favor reuses the social-acceptance reason"
	)
	relationships.set_favor(candidate.npc, player, 50.0, "player_gate_test")
	relationships.set_anger(candidate.npc, player, 70.0, "player_gate_test")
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"requester_anger_too_high",
		"high directed anger refuses the Player"
	)
	relationships.set_anger(candidate.npc, player, 0.0, "player_gate_test")
	relationships.set_fear(candidate.npc, player, 80.0, "player_gate_test")
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"requester_fear_too_high",
		"high directed fear refuses the Player"
	)
	relationships.set_fear(candidate.npc, player, 0.0, "player_gate_test")
	_remember(
		candidate.memory,
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED,
		&"__player__",
		&"player_gate_candidate",
		&"Talk"
	)
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"recently_talked_with_requester",
		"existing completed-conversation memory provides the repeat reason"
	)


func test_high_favor_bypasses_only_player_repeat_limits_from_70() -> void:
	var candidate := _npc_fixture(&"high_favor_repeat_candidate")
	var player := TestActor.new(&"player")
	player.name = "Player"
	player.add_to_group("player")
	add_child_autofree(player)
	var relationships := root.get_node_or_null("Relationships")
	assert_not_null(relationships)
	if relationships == null:
		return
	relationships.set_favor(candidate.npc, player, 69.9, "repeat_bypass_test")
	candidate.machine.start_player_interaction_cooldown(player, 7.0)
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"npc_ignoring_player",
		"favor below 70 still respects the real-time repeat cooldown"
	)
	candidate.machine.player_interaction_cooldown_timer = 0.0
	_remember(
		candidate.memory,
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED,
		&"__player__",
		&"high_favor_repeat_candidate",
		&"Talk"
	)
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"recently_talked_with_requester",
		"favor below 70 still respects completed-conversation memory"
	)
	relationships.set_favor(candidate.npc, player, 70.0, "repeat_bypass_test")
	candidate.machine.start_player_interaction_cooldown(player, 7.0)
	assert_true(
		candidate.machine.is_ignoring_player_interaction(player),
		"the underlying cooldown remains intact for non-Player-initiated consumers"
	)
	var accepted_gate: Dictionary = candidate.machine.can_begin_player_interaction(player)
	assert_true(
		bool(accepted_gate.accepted),
		"favor 70 bypasses recent-conversation memory"
	)
	assert_eq(
		accepted_gate.get("favor_bypass"),
		&"repeat",
		"the repeat-only favor bypass is diagnosable"
	)
	var interactor := PlayerNpcTalkInteractor.new()
	player.add_child(interactor)
	assert_eq(
		interactor._get_block_reason(candidate.npc),
		"",
		"the Player interactor honors the authoritative repeat bypass"
	)
	relationships.set_anger(candidate.npc, player, 70.0, "repeat_bypass_test")
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"requester_anger_too_high",
		"the 70 tier does not bypass non-repeat refusal reasons"
	)
	relationships.set_favor(candidate.npc, player, 39.9, "soft_refusal_boundary")
	candidate.machine.present_player_interaction_refusal(
		&"requester_anger_too_high",
		player
	)
	var refusal_cue: Dictionary = (
		candidate.machine.feedback_presenter.get_current_cue_descriptor()
	)
	assert_eq(
		refusal_cue.get("metadata", {}).get("refusal_tone"),
		&"standard",
		"favor below 40 retains standard refusal wording"
	)
	candidate.machine.feedback_presenter.clear_all(&"soft_refusal_boundary")
	relationships.set_favor(candidate.npc, player, 40.0, "soft_refusal_boundary")
	candidate.machine.present_player_interaction_refusal(
		&"requester_anger_too_high",
		player
	)
	refusal_cue = candidate.machine.feedback_presenter.get_current_cue_descriptor()
	assert_eq(
		refusal_cue.get("metadata", {}).get("refusal_tone"),
		&"soft",
		"favor 40 begins softer refusal presentation"
	)


func test_exceptional_favor_above_95_bypasses_all_npc_player_refusals() -> void:
	var candidate := _npc_fixture(&"exceptional_favor_candidate")
	var machine := candidate.machine as NpcStateMachine
	var player := TestActor.new(&"player")
	player.name = "Player"
	player.add_to_group("player")
	add_child_autofree(player)
	var relationships := root.get_node_or_null("Relationships")
	assert_not_null(relationships)
	if relationships == null:
		return
	relationships.set_favor(player, candidate.npc, 100.0, "opposite_direction")
	relationships.set_favor(candidate.npc, player, 95.0, "full_bypass_boundary")
	relationships.set_anger(candidate.npc, player, 100.0, "full_bypass_boundary")
	assert_eq(
		candidate.machine.can_begin_player_interaction(player).reason,
		"requester_anger_too_high",
		"exactly 95 and the opposite relationship row do not activate the bypass"
	)
	relationships.set_favor(candidate.npc, player, 95.1, "full_bypass_test")
	machine.scripted_control_claim_token = 9
	machine.state_history = [machine.get_state(&"Fight")]
	machine.values["hp"] = 0.0
	var gate: Dictionary = machine.can_begin_player_interaction(player)
	assert_true(bool(gate.accepted), "favor above 95 bypasses all NPC refusal gates")
	assert_eq(gate.get("favor_bypass"), &"all", "the exceptional bypass is diagnosable")
	var interactor := PlayerNpcTalkInteractor.new()
	interactor.allowed_npc_ids = [&"some_other_npc"]
	interactor.required_npc_tags = [&"missing_test_tag"]
	player.add_child(interactor)
	assert_eq(
		interactor._get_block_reason(candidate.npc),
		"",
		"the exceptional bypass clears secondary Player-interactor refusal gates"
	)
	assert_false(
		machine.request_talk(player, 60, false, &"social_ai"),
		"the exceptional bypass does not leak into autonomous social requests"
	)
	assert_true(
		machine.request_talk(player, 60, false, &"player"),
		"the exceptional bypass reaches the downstream Player Talk overlay"
	)
	assert_true(
		machine.is_talking_with(player),
		"the Player Talk reservation is active despite the bypassed state gates"
	)


func test_one_blocked_player_attempt_submits_one_npc_anchored_cue() -> void:
	var candidate := _npc_fixture(&"player_refusal_feedback")
	var player := TestActor.new(&"player")
	player.name = "Player"
	player.add_to_group("player")
	var interactor := PlayerNpcTalkInteractor.new()
	interactor.name = "NpcTalkInteractor"
	player.add_child(interactor)
	add_child_autofree(player)
	interactor.nearby_npcs.append(candidate.npc)
	var relationships := root.get_node_or_null("Relationships")
	assert_not_null(relationships)
	if relationships == null:
		return
	relationships.set_favor(candidate.npc, player, 10.0, "feedback_test")
	var blocked_count := {"value": 0}
	interactor.interaction_blocked.connect(
		func(_player: Node2D, _npc: Node2D, _id: StringName, _reason: String) -> void:
			blocked_count.value += 1
	)

	assert_true(
		interactor.can_interact(player),
		"a presentable refusal remains an attemptable Talk target"
	)
	assert_false(interactor.interact(player), "the underlying interaction remains rejected")
	assert_eq(blocked_count.value, 1, "one attempt emits one existing rejection event")
	var cue: Dictionary = candidate.machine.feedback_presenter.get_current_cue_descriptor()
	assert_eq(cue.get("cue_code"), &"player_interaction_refused_opinion")
	assert_eq(
		cue.get("metadata", {}).get("reason_code"),
		&"requester_favor_too_low",
		"the feedback cue preserves the authoritative gate reason"
	)
	assert_eq(
		candidate.memory.get_recent_memories().size(),
		0,
		"showing the refusal creates no memory"
	)
	assert_eq(
		relationships.get_opinion_metric(candidate.npc, player, &"favor", 50.0),
		10.0,
		"showing the refusal does not alter the relationship"
	)


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
