extends SceneTree

const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const BehaviorIntent = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_intent.gd"
)
const FeedbackFormatter = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_feedback_formatter.gd"
)

var _failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	func get_npc_location_id() -> StringName:
		return &"behavior_runtime_npc"


class TestSpot:
	extends Node2D

	var spot_id: StringName

	func _init(new_spot_id: StringName) -> void:
		spot_id = new_spot_id

	func get_world_spot_id() -> StringName:
		return spot_id

	func can_serve_npc_need(
		_npc: Node2D,
		_action_kind: StringName,
		_value_name: StringName
	) -> bool:
		return true

	func can_serve_npc_casual_activity(
		_npc: Node2D,
		_action_kind: StringName
	) -> bool:
		return true


class TestLocations:
	extends Node

	func is_npc_available_for_scheduled_activity(
		_npc_id: String,
		_state: StringName,
		_priority: int,
		_descriptor: Dictionary = {}
	) -> bool:
		return true


func _initialize() -> void:
	await process_frame
	_test_controller_policy()
	_test_explicit_provenance_and_lifecycle()
	_test_feedback_formatting()
	_test_request_boundary_and_same_session_arrival()
	await process_frame
	if _failures.is_empty():
		print("NPC behavior commitment runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
		quit(1)


func _test_controller_policy() -> void:
	var controller := NpcBehaviorController.new()
	root.add_child(controller)
	var start_usec := 10000000
	var hunger := _intent(&"Eat", &"Eat", &"need", 50, "table:a", "meal:1")
	var first_decision := controller.evaluate_candidate(hunger, start_usec)
	_expect(bool(first_decision.accepted), "the first autonomous candidate is accepted")
	_expect(
		controller.current_intent == null,
		"candidate evaluation does not mutate intention state"
	)
	controller.commit_candidate(hunger, start_usec)

	var arrival := _intent(
		&"MoveToTarget", &"Eat", &"need", 50, "table:a", "meal:1"
	)
	_expect(
		bool(controller.evaluate_candidate(arrival, start_usec + 100000).accepted),
		"a same-session continuation is accepted"
	)
	controller.commit_candidate(arrival, start_usec + 100000)
	_expect(
		controller.accepted_at_usec == start_usec,
		"a same-session continuation does not restart commitment"
	)

	var refresh := _intent(&"Eat", &"Eat", &"need", 50, "table:a")
	var refresh_controller := NpcBehaviorController.new()
	root.add_child(refresh_controller)
	refresh_controller.commit_candidate(
		_intent(&"Eat", &"Eat", &"need", 50, "table:a"),
		start_usec
	)
	_expect(
		bool(refresh_controller.evaluate_candidate(
			refresh, start_usec + 100000
		).accepted),
		"the same logical action and target refresh is accepted"
	)
	var different_target := _intent(&"Eat", &"Eat", &"need", 50, "table:b")
	_expect(
		not bool(refresh_controller.evaluate_candidate(
			different_target, start_usec + 100000
		).accepted),
		"identical states with different targets are distinct intentions"
	)

	var social_60 := _intent(
		&"LookForTalkTarget",
		&"LookForTalkTarget",
		&"social_ai",
		60,
		"npc:b"
	)
	var below_margin := controller.evaluate_candidate(
		social_60, start_usec + 100000
	)
	_expect(
		not bool(below_margin.accepted)
		and int(below_margin.required_interrupt_priority) == 65,
		"a competing autonomous candidate below current plus margin is rejected"
	)
	var social_65 := _intent(
		&"LookForTalkTarget",
		&"LookForTalkTarget",
		&"social_ai",
		65,
		"npc:b"
	)
	_expect(
		bool(controller.evaluate_candidate(
			social_65, start_usec + 100000
		).accepted),
		"a candidate meeting the interruption margin is accepted"
	)
	_expect(
		bool(controller.evaluate_candidate(
			social_60, start_usec + 2100000
		).accepted),
		"a competing candidate is accepted after commitment expires"
	)
	for source in [&"emergency", &"schedule", &"scripted", &"player", &"manual", &"internal"]:
		_expect(
			bool(controller.evaluate_candidate(
				_intent(&"Fight", &"Fight", source, 1, String(source)),
				start_usec + 100000
			).accepted),
			"%s bypasses the generic gate" % String(source)
		)
	_expect(
		not controller.clear_intent_for_session("stale:meal", &"completed")
		and controller.current_intent != null,
		"a stale terminal session cannot clear the current intention"
	)
	_expect(
		controller.clear_intent_for_session("meal:1", &"completed")
		and controller.current_intent == null,
		"the matching terminal session clears the intention"
	)
	controller.queue_free()
	refresh_controller.queue_free()


func _test_explicit_provenance_and_lifecycle() -> void:
	var hunger_fixture := _make_fixture()
	var hunger_machine: NpcStateMachine = hunger_fixture["machine"]
	var hunger_controller: NpcBehaviorController = hunger_fixture["controller"]
	hunger_machine.values["hunger"] = 80.0
	_expect(
		hunger_machine.evaluate_value_reactions(null, {"hunger": 55.0}),
		"the default hunger rule starts an explicit intention"
	)
	_expect(
		hunger_controller.current_intent != null
		and hunger_controller.current_intent.source == &"need"
		and hunger_controller.current_intent.reason_code == &"hunger_high"
		and hunger_controller.current_intent.origin_value == &"hunger"
		and not bool(hunger_controller.current_intent.metadata.get(
			"legacy_derived", true
		)),
		"hunger provenance is explicit and does not use reason parsing"
	)
	for rule_key in hunger_machine.value_state_rules.keys():
		var rule: Dictionary = hunger_machine.value_state_rules[rule_key]
		_expect(
			rule.has("behavior_source")
			and not String(rule.get("behavior_source", "")).is_empty()
			and rule.has("behavior_reason_code")
			and not String(rule.get("behavior_reason_code", "")).is_empty(),
			"default value rule %s has explicit source and reason code" % String(rule_key)
		)
	_free_fixture(hunger_fixture)

	var legacy_fixture := _make_fixture()
	var legacy_machine: NpcStateMachine = legacy_fixture["machine"]
	var legacy_controller: NpcBehaviorController = legacy_fixture["controller"]
	legacy_machine.value_state_rules = {
		"old_custom_rule": {
			"value": "boredom",
			"state": "Recreation",
			"at_least": 1.0,
			"priority": 10,
		},
	}
	legacy_machine.values["boredom"] = 5.0
	_expect(
		legacy_machine.evaluate_value_reactions(null, {"boredom": 5.0}),
		"a custom legacy value rule remains operational"
	)
	_expect(
		legacy_controller.current_intent != null
		and bool(legacy_controller.current_intent.metadata.get(
			"legacy_derived", false
		)),
		"a legacy rule is identified as legacy-derived"
	)
	_free_fixture(legacy_fixture)

	var explicit_fixture := _make_fixture()
	var explicit_machine: NpcStateMachine = explicit_fixture["machine"]
	var explicit_controller: NpcBehaviorController = explicit_fixture["controller"]
	var producer_intent := BehaviorIntent.create(
		&"Eat",
		&"Eat",
		&"need",
		"social manual target reason",
		50,
		"",
		"explicit-provenance",
		0.0,
		0,
		{},
		&"hunger_high",
		"Hungry",
		&"hunger"
	)
	var producer_id := producer_intent.intent_id
	_expect(
		explicit_machine.request_behavior_intent(producer_intent),
		"the public explicit-intention API enters the normal request pipeline"
	)
	_expect(
		explicit_controller.current_intent.source == &"need"
		and explicit_controller.current_intent.reason == "social manual target reason",
		"explicit source overrides conflicting legacy-looking reason text"
	)
	_expect(
		producer_intent.intent_id == producer_id
		and producer_intent.target_persistent_id.is_empty(),
		"the producer-owned intention is not mutated at the request boundary"
	)
	_free_fixture(explicit_fixture)

	var social_fixture := _make_fixture()
	var social_machine: NpcStateMachine = social_fixture["machine"]
	var social_controller: NpcBehaviorController = social_fixture["controller"]
	var social_npc: Node2D = social_fixture["npc"]
	var social_target := TestNpc.new()
	social_target.name = "SocialTarget"
	root.add_child(social_target)
	var locations := TestLocations.new()
	root.add_child(locations)
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	_expect(
		simulator != null and bool(simulator.call(
			"_request_live_social_seek",
			&"behavior_runtime_npc",
			social_npc,
			social_target,
			60,
			locations,
			"social-explicit-session",
			"social-target"
		)),
		"the live world-simulation social path submits an explicit intention"
	)
	_expect(
		social_controller.current_intent != null
		and social_controller.current_intent.source == &"social_ai"
		and social_controller.current_intent.reason_code == &"social_need_high"
		and social_controller.current_intent.origin_value == &"talk_need",
		"live social-search provenance is explicit"
	)
	locations.queue_free()
	social_target.queue_free()
	_free_fixture(social_fixture)

	var idle_fixture := _make_fixture()
	var idle_machine: NpcStateMachine = idle_fixture["machine"]
	var idle_controller: NpcBehaviorController = idle_fixture["controller"]
	idle_machine.state_history = []
	_expect(
		idle_machine.request_state(&"Idle", null, "initial"),
		"initial Idle still enters successfully"
	)
	_expect(
		idle_controller.current_intent == null,
		"initial Idle does not create a goal intention"
	)
	_free_fixture(idle_fixture)


func _test_feedback_formatting() -> void:
	var controller := NpcBehaviorController.new()
	root.add_child(controller)
	var start_usec := 20000000
	var explicit := BehaviorIntent.create(
		&"MoveToTarget",
		&"Eat",
		&"need",
		"raw_reason",
		50,
		"table:a",
		"feedback-meal",
		2.0,
		15,
		{},
		&"hunger_high",
		"Hungry",
		&"hunger"
	)
	controller.commit_candidate(explicit, start_usec)
	var early_text := FeedbackFormatter.format_label(
		&"MoveToTarget",
		&"",
		controller.get_feedback_descriptor(start_usec + 500000)
	)
	var later_text := FeedbackFormatter.format_label(
		&"MoveToTarget",
		&"",
		controller.get_feedback_descriptor(start_usec + 1500000)
	)
	_expect(
		early_text.contains("MoveToTarget \u2192 Eat")
		and early_text.contains("Hungry \u00b7 need \u00b7 p50")
		and early_text.contains("hold 1.5s"),
		"explicit feedback text and supplied countdown time are formatted"
	)
	_expect(
		later_text.contains("hold 0.5s") and later_text != early_text,
		"countdown formatting changes without state-machine frame formatting"
	)
	var rejected := BehaviorIntent.create(
		&"LookForTalkTarget",
		&"LookForTalkTarget",
		&"social_ai",
		"raw_social",
		60,
		"npc:b",
		"social:b",
		2.0,
		15,
		{},
		&"social_need_high",
		"Looking for someone to talk to",
		&"talk_need"
	)
	controller.reject_candidate(rejected, &"behavior_commitment_active")
	var blocked_text := FeedbackFormatter.format_label(
		&"Eat", &"Talk", controller.get_feedback_descriptor(start_usec + 500000)
	)
	_expect(
		blocked_text.begins_with("Eat + Talk")
		and blocked_text.contains(
			"blocked: Looking for someone to talk to \u00b7 p60"
		),
		"Talk overlay and explicit rejection feedback are preserved"
	)
	controller.clear_rejection_feedback()
	_expect(
		not FeedbackFormatter.format_label(
			&"Eat", &"", controller.get_feedback_descriptor(start_usec + 500000)
		).contains("blocked:"),
		"rejection feedback can expire"
	)
	var legacy := BehaviorIntent.create(
		&"Eat", &"Eat", &"need", "hungry_legacy", 50
	)
	var legacy_controller := NpcBehaviorController.new()
	root.add_child(legacy_controller)
	legacy_controller.commit_candidate(legacy, start_usec)
	_expect(
		FeedbackFormatter.format_label(
			&"Eat", &"", legacy_controller.get_feedback_descriptor(start_usec)
		).contains("Hungry legacy"),
		"legacy feedback remains readable"
	)
	_expect(
		FeedbackFormatter.format_label(&"Idle", &"", {}) == "Idle",
		"internal Idle is state-only feedback"
	)
	controller.queue_free()
	legacy_controller.queue_free()


func _intent(
	state: StringName,
	action: StringName,
	source: StringName,
	priority: int,
	target_id: String = "",
	session_id: String = ""
) -> NpcBehaviorIntent:
	return BehaviorIntent.create(
		state,
		action,
		source,
		String(action).to_lower(),
		priority,
		target_id,
		session_id,
		2.0,
		15
	)


func _test_request_boundary_and_same_session_arrival() -> void:
	var fixture := _make_fixture()
	var machine: NpcStateMachine = fixture["machine"]
	var controller: NpcBehaviorController = fixture["controller"]
	var table_a: TestSpot = fixture["table_a"]
	var yard_b: TestSpot = fixture["yard_b"]
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if simulator == null:
		_expect(false, "spot reservation service is available")
		_free_fixture(fixture)
		return

	var meal := {
		"session_id": "behavior-meal-a",
		"action_kind": "Eat",
		"source": "need",
		"spot_id": "behavior_table_a",
		"priority": 50,
		"status": "proposed",
		"reason": "hungry",
		"arrival_state": "Eat",
	}
	_expect(
		machine.request_action_movement_from_descriptor(meal, table_a, &"Eat"),
		"the first autonomous movement intention is accepted"
	)
	_expect(
		machine.get_active_action_session_id() == "behavior-meal-a",
		"the accepted intent keeps the action-session identity"
	)
	_expect(
		controller.current_intent != null
		and controller.current_intent.requested_primary_state == &"MoveToTarget"
		and controller.current_intent.logical_action_kind == &"Eat",
		"movement is described as MoveToTarget toward the Eat intention"
	)
	var original_intent_id := controller.current_intent.intent_id
	var original_created_at := controller.current_intent.created_at_usec
	var original_accepted_at := controller.accepted_at_usec
	var replaced_count := 0
	controller.intention_replaced.connect(
		func(_previous: NpcBehaviorIntent, _current: NpcBehaviorIntent) -> void:
			replaced_count += 1
	)
	_expect(
		int(simulator.spot_claim_counts.get(&"behavior_table_a", 0)) == 1,
		"the accepted meal owns its reservation"
	)

	var competing := ActionSession.create(
		"behavior_runtime_npc",
		&"Recreation",
		&"social_ai",
		yard_b,
		{
			"session_id": "behavior-social-b",
			"spot_id": "behavior_yard_b",
			"priority": 60,
			"reason": "social break",
		}
	)
	machine._proposed_action = competing
	_expect(
		not machine._request_state_direct(
			&"Recreation", yard_b, "social break", 60, {}
		),
		"a competing autonomous request below the margin is rejected"
	)
	_expect(
		machine.last_state_request_failure_reason == "behavior_commitment_active",
		"the rejection uses the behavior commitment reason"
	)
	_expect(
		machine._proposed_action == competing,
		"the decision gate does not consume the proposed action"
	)
	_expect(
		machine.get_active_action_session_id() == "behavior-meal-a",
		"the rejected request does not replace the active action"
	)
	_expect(
		int(simulator.spot_claim_counts.get(&"behavior_table_a", 0)) == 1
		and int(simulator.spot_claim_counts.get(&"behavior_yard_b", 0)) == 0,
		"the rejected request neither changes nor claims a reservation"
	)
	machine._proposed_action = null

	var arrival_state := machine.finish_active_action_approach(
		"behavior-meal-a", &"Idle"
	)
	_expect(arrival_state == &"Eat", "the movement session resolves to Eat")
	_expect(
		machine.change_state(machine.get_state(arrival_state), "state_tick", 50),
		"same-session MoveToTarget to destination remains accepted"
	)
	_expect(
		machine.get_active_action_session_id() == "behavior-meal-a"
		and controller.current_intent.action_session_id == "behavior-meal-a"
		and controller.current_intent.requested_primary_state == &"Eat",
		"the arrival preserves both action and intent session identity"
	)
	_expect(
		controller.current_intent.intent_id == original_intent_id
		and controller.current_intent.created_at_usec == original_created_at
		and controller.accepted_at_usec == original_accepted_at
		and replaced_count == 0,
		"same-session arrival preserves identity and commitment without replacement"
	)
	var stale_refresh := controller.current_intent.refreshed_copy({
		"action_session_id": "older-session",
		"requested_primary_state": &"Recreation",
	})
	_expect(
		not controller.refresh_current_intent(stale_refresh, "older-session")
		and controller.current_intent.intent_id == original_intent_id
		and controller.current_intent.requested_primary_state == &"Eat",
		"a stale session cannot refresh the newer intention"
	)

	_expect(
		machine.complete_active_action("behavior-meal-a", "meal_complete"),
		"the current action completes"
	)
	_expect(
		controller.current_intent == null,
		"terminal completion clears the matching intention"
	)
	_free_fixture(fixture)


func _make_fixture() -> Dictionary:
	var npc := TestNpc.new()
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var controller := NpcBehaviorController.new()
	controller.name = "NpcBehaviorController"
	machine.add_child(controller)
	for state_name in [
		&"Idle",
		&"MoveToTarget",
		&"Eat",
		&"Recreation",
		&"LookForTalkTarget",
	]:
		var state := NpcState.new()
		state.name = String(state_name)
		machine.add_child(state)
	npc.add_child(machine)
	var table_a := TestSpot.new(&"behavior_table_a")
	var yard_b := TestSpot.new(&"behavior_yard_b")
	npc.add_child(table_a)
	npc.add_child(yard_b)
	table_a.add_to_group("npc_need_spot")
	root.add_child(npc)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [machine.get_state(&"Idle")]
	machine.current_state.enter()

	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if simulator != null:
		simulator.call("register_live_spot", &"behavior_table_a", table_a)
		simulator.call("register_live_spot", &"behavior_yard_b", yard_b)
	return {
		"npc": npc,
		"machine": machine,
		"controller": controller,
		"table_a": table_a,
		"yard_b": yard_b,
	}


func _free_fixture(fixture: Dictionary) -> void:
	var machine: NpcStateMachine = fixture.get("machine")
	if machine != null and machine.active_action != null:
		machine._cancel_and_clear_active_action("test_cleanup")
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if simulator != null:
		simulator.call(
			"unregister_live_spot",
			&"behavior_table_a",
			fixture.get("table_a")
		)
		simulator.call(
			"unregister_live_spot",
			&"behavior_yard_b",
			fixture.get("yard_b")
		)
	var npc: Node = fixture.get("npc")
	if npc != null:
		npc.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
