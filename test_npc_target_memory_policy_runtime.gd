extends "res://test/native_scene_tree_test.gd"

const FeedbackFormatter = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_feedback_formatter.gd"
)
const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const TargetMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_target_memory_policy.gd"
)

var _previous_total_hours: float = 0.0
var _previous_auto_advance: bool = false


class TestNpc:
	extends CharacterBody2D

	var persistent_id: StringName

	func _init(new_id: StringName) -> void:
		persistent_id = new_id

	func get_npc_location_id() -> StringName:
		return persistent_id


class TestSpot:
	extends Node2D

	var spot_id: StringName
	var reservation_capacity: int = 1

	func _init(new_id: StringName, x_position: float) -> void:
		spot_id = new_id
		position.x = x_position

	func get_world_spot_id() -> StringName:
		return spot_id

	func can_serve_npc_need(
		_npc: Node,
		action: StringName,
		value_name: StringName
	) -> bool:
		return action == &"Eat" and value_name == &"hunger"


func before_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		_previous_total_hours = world_time.get_total_hours()
		_previous_auto_advance = world_time.auto_advance
		world_time.auto_advance = false
		world_time.set_total_hours(10.1)


func after_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		world_time.auto_advance = _previous_auto_advance
		world_time.set_total_hours(_previous_total_hours)


func test_policy_allows_without_relevant_memory_and_fails_open() -> void:
	var policy := TargetMemoryPolicy.new()
	var memory := _memory()
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"Eat", &"table:a", &"kitchen", 10.1
		).allowed),
		"no memory allows a stable candidate"
	)
	_remember(
		memory,
		MemoryPolicy.EVENT_ACTION_FAILED,
		&"Eat",
		&"table:a",
		&"kitchen"
	)
	_remember(
		memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"Talk",
		&"table:a",
		&""
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"Eat", &"table:a", &"kitchen", 10.1
		).allowed),
		"generic action and conversation memories do not suppress activity targets"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"Eat", &"", &"kitchen", 10.1
		).allowed),
		"a missing stable candidate ID fails open"
	)


func test_initial_target_failure_types_match_structured_identity() -> void:
	var policy := TargetMemoryPolicy.new()
	for event_type in [
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST,
	]:
		var memory := _memory()
		_remember(memory, event_type, &"Eat", &"table:a", &"kitchen")
		var matching := policy.evaluate_candidate(
			memory, &"Eat", &"table:a", &"kitchen", 10.1
		)
		assert_false(
			bool(matching.allowed),
			"%s suppresses its matching candidate" % String(event_type)
		)
		assert_eq(
			matching.reason_code,
			&"recent_target_failure",
			"suppression has one stable policy reason"
		)
		assert_eq(
			matching.memory_event_type,
			event_type,
			"the structured event classification remains observable"
		)
		assert_true(
			bool(policy.evaluate_candidate(
				memory, &"Rest", &"table:a", &"kitchen", 10.1
			).allowed),
			"action-specific failure does not cross logical actions"
		)
		assert_true(
			bool(policy.evaluate_candidate(
				memory, &"Eat", &"table:b", &"kitchen", 10.1
			).allowed),
			"a different persistent target remains eligible"
		)
		if event_type == MemoryPolicy.EVENT_MOVEMENT_FAILED:
			assert_true(
				bool(policy.evaluate_candidate(
					memory, &"Eat", &"table:a", &"garden", 10.1
				).allowed),
				"movement failure remains place-specific"
			)


func test_target_general_unavailability_must_be_explicit() -> void:
	var policy := TargetMemoryPolicy.new()
	var action_specific := _memory()
	_remember(
		action_specific,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		&"Eat",
		&"bench:a",
		&"yard"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			action_specific, &"Rest", &"bench:a", &"yard", 10.1
		).allowed),
		"ordinary target unavailability remains action-specific"
	)
	var general := _memory()
	_remember(
		general,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		&"Eat",
		&"bench:a",
		&"yard",
		{"target_generally_unavailable": true}
	)
	assert_false(
		bool(policy.evaluate_candidate(
			general, &"Rest", &"bench:a", &"yard", 10.1
		).allowed),
		"explicit target-general metadata permits cross-action suppression"
	)


func test_resolution_expiry_and_retry_lifetime_are_independent() -> void:
	var policy := TargetMemoryPolicy.new()
	var memory := _memory()
	var memory_id := _remember(
		memory,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		&"Eat",
		&"table:a",
		&"kitchen"
	)
	assert_false(
		bool(policy.evaluate_candidate(
			memory, &"Eat", &"table:a", &"kitchen", 10.124
		).allowed),
		"candidate is suppressed before the movement retry boundary"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"Eat", &"table:a", &"kitchen", 10.126
		).allowed),
		"candidate becomes eligible after the short retry delay"
	)
	assert_not_null(
		memory.get_memory_by_id(memory_id),
		"memory remains stored after behavioral suppression ends"
	)
	assert_true(memory.resolve_memory(memory_id, &"test"), "memory resolves")
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"Eat", &"table:a", &"kitchen", 10.11
		).allowed),
		"resolved memory does not suppress"
	)

	var expired := _memory()
	var expired_event := _event(
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		&"Eat",
		&"table:a",
		&"kitchen",
		8.0
	)
	expired_event.expires_game_hours = 9.0
	expired.remember(expired_event)
	assert_true(
		bool(policy.evaluate_candidate(
			expired, &"Eat", &"table:a", &"kitchen", 10.1
		).allowed),
		"expired memory does not suppress"
	)


func test_last_updated_restarts_retry_without_policy_mutation() -> void:
	var policy := TargetMemoryPolicy.new()
	var memory := _memory()
	var event := _event(
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		&"Eat",
		&"table:a",
		&"kitchen",
		9.9
	)
	event.last_updated_game_hours = 10.05
	event.expires_game_hours = 10.5
	memory.remember(event)
	var before := memory.export_snapshot(10.1)
	var decision := policy.evaluate_candidate(
		memory, &"Eat", &"table:a", &"kitchen", 10.1
	)
	assert_false(bool(decision.allowed), "last update, not creation, starts retry")
	assert_true(
		float(decision.remaining_retry_hours) > 0.074
		and float(decision.remaining_retry_hours) < 0.076,
		"remaining delay is based on last_updated_game_hours"
	)
	assert_eq(
		memory.export_snapshot(10.1),
		before,
		"policy evaluation cannot mutate storage"
	)


func test_feedback_text_and_node_replacement_do_not_define_identity() -> void:
	var policy := TargetMemoryPolicy.new()
	var memory := _memory()
	var event := _event(
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST,
		&"Eat",
		&"table:persistent",
		&"kitchen",
		10.0
	)
	event.metadata["feedback_text"] = "old wording"
	memory.remember(event)
	event.metadata["feedback_text"] = "new wording"
	assert_false(
		bool(policy.evaluate_candidate(
			memory,
			&"Eat",
			&"table:persistent",
			&"kitchen",
			10.1
		).allowed),
		"replacement node with the same persistent ID remains suppressed"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory,
			&"Eat",
			&"table:persistant",
			&"kitchen",
			10.1
		).allowed),
		"similar labels do not merge distinct persistent IDs"
	)


func test_candidate_adapter_selects_alternative_and_reports_all_suppressed() -> void:
	var machine := NpcStateMachine.new()
	var memory := _memory()
	machine.short_term_memory = memory
	_remember(
		memory,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		&"Eat",
		&"table:a",
		&"kitchen"
	)
	var selected := machine.select_memory_informed_activity_target(
		&"Eat",
		[
			{"target_id": "table:a", "place_id": "kitchen"},
			{"target_id": "table:b", "place_id": "kitchen"},
			{"target_id": "table:c", "place_id": "kitchen"},
		],
		10.1,
		{"remembering_npc_id": "remembering:npc"}
	)
	assert_true(bool(selected.selected), "an allowed alternative is selected")
	assert_eq(selected.target_id, &"table:b", "existing candidate order is preserved")
	assert_eq(
		selected.descriptor.suppressed_count,
		1,
		"alternative selection reports inspected suppression"
	)
	assert_false(
		bool(selected.descriptor.all_suppressed),
		"alternative selection does not install all-suppressed feedback"
	)

	_remember(
		memory,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		&"Eat",
		&"table:b",
		&"kitchen"
	)
	var blocked := machine.select_memory_informed_activity_target(
		&"Eat",
		[
			{"target_id": "table:a", "place_id": "kitchen"},
			{"target_id": "table:b", "place_id": "kitchen"},
		],
		10.1,
		{"remembering_npc_id": "remembering:npc"}
	)
	assert_false(bool(blocked.selected), "all suppressed selects no target")
	assert_true(bool(blocked.descriptor.all_suppressed), "all-suppressed is explicit")
	assert_eq(
		blocked.descriptor.reason_code,
		&"all_targets_recently_failed",
		"all-suppressed has a stable reason code"
	)
	assert_eq(
		blocked.descriptor.earliest_retry_game_hours,
		10.125,
		"earliest candidate retry is reported"
	)
	machine.free()


func test_candidate_set_changes_are_discovered_without_retry_cache() -> void:
	var machine := NpcStateMachine.new()
	var memory := _memory()
	machine.short_term_memory = memory
	_remember(
		memory,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		&"Recreation",
		&"yard:a",
		&"yard"
	)
	var blocked := machine.select_memory_informed_activity_target(
		&"Recreation",
		[{"target_id": "yard:a", "place_id": "yard"}],
		10.1,
		{"remembering_npc_id": "remembering:npc"}
	)
	assert_false(bool(blocked.selected), "old candidate is suppressed")
	var changed := machine.select_memory_informed_activity_target(
		&"Recreation",
		[
			{"target_id": "yard:a", "place_id": "yard"},
			{"target_id": "yard:new", "place_id": "yard"},
		],
		10.11,
		{"remembering_npc_id": "remembering:npc"}
	)
	assert_eq(
		changed.target_id,
		&"yard:new",
		"a newly added candidate is selectable before the old retry"
	)
	machine.free()


func test_live_need_producer_filters_before_reservation_and_intention() -> void:
	var allowed_fixture := _live_eat_fixture(
		&"memory_filter_allowed",
		&"memory_table_a",
		&"memory_table_b"
	)
	_remember(
		allowed_fixture.memory,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		&"Eat",
		&"memory_table_a",
		&"memory_table_a",
		{},
		&"memory_filter_allowed"
	)
	var committed_outcomes: Array[Dictionary] = []
	allowed_fixture.machine.activity_target_selection_committed.connect(
		func(descriptor: Dictionary) -> void:
			committed_outcomes.append(descriptor)
	)
	var allowed_hunger := float(allowed_fixture.machine.get_value(&"hunger"))
	assert_true(
		allowed_fixture.machine.evaluate_value_reactions(
			null,
			{"hunger": 1.0}
		),
		"live need rule selects an allowed alternative"
	)
	assert_eq(
		allowed_fixture.machine.get_active_action_target_id(),
		&"memory_table_b",
		"the second ordered target owns the action"
	)
	assert_eq(
		allowed_fixture.controller.current_intent.target_persistent_id,
		"memory_table_b",
		"only the allowed target reaches intention commitment"
	)
	assert_eq(committed_outcomes.size(), 1, "one committed alternative is emitted")
	assert_eq(
		committed_outcomes[0].reason_code,
		&"alternative_target_selected",
		"committed alternative has a stable outcome reason"
	)
	assert_eq(
		committed_outcomes[0].selected_target_id,
		&"memory_table_b",
		"outcome identifies the accepted alternative"
	)
	assert_eq(
		committed_outcomes[0].action_session_id,
		allowed_fixture.machine.active_action.session_id,
		"outcome session matches the authoritative active action"
	)
	assert_eq(
		committed_outcomes[0].intent_id,
		allowed_fixture.controller.current_intent.intent_id,
		"outcome intent matches the accepted intention"
	)
	allowed_fixture.machine._emit_committed_activity_target_selection(
		committed_outcomes[0],
		allowed_fixture.second
	)
	assert_eq(
		committed_outcomes.size(),
		1,
		"same-session phase observation emits no duplicate outcome"
	)
	var simulator := root.get_node("NpcWorldSimulation")
	assert_eq(
		simulator.get_spot_reservations(&"memory_table_a").size(),
		0,
		"inspected suppressed target receives no reservation"
	)
	assert_eq(
		simulator.get_spot_reservations(&"memory_table_b").size(),
		1,
		"exactly one reservation is claimed for the selected target"
	)
	assert_eq(
		float(allowed_fixture.machine.get_value(&"hunger")),
		allowed_hunger,
		"selection itself does not change the need"
	)
	var active_session: NpcActionSession = allowed_fixture.machine.active_action
	var active_intent_id: String = (
		allowed_fixture.controller.current_intent.intent_id
	)
	_remember(
		allowed_fixture.memory,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		&"Eat",
		&"memory_table_b",
		&"memory_table_b",
		{},
		&"memory_filter_allowed"
	)
	var future_retry: Dictionary = (
		allowed_fixture.machine.select_memory_informed_activity_target(
			&"Eat",
			[{
				"target_node": allowed_fixture.second,
				"target_id": "memory_table_b",
				"place_id": "memory_table_b",
			}],
			10.1
		)
	)
	assert_false(
		bool(future_retry.selected),
		"a future selection sees the newly recorded failure"
	)
	assert_same(
		allowed_fixture.machine.active_action,
		active_session,
		"policy query does not cancel an accepted action"
	)
	assert_eq(
		allowed_fixture.controller.current_intent.intent_id,
		active_intent_id,
		"policy query does not replace active commitment"
	)
	assert_eq(
		simulator.get_spot_reservations(&"memory_table_b").size(),
		1,
		"accepted session reservation remains authoritative"
	)
	_free_live_eat_fixture(allowed_fixture)

	var blocked_fixture := _live_eat_fixture(
		&"memory_filter_blocked",
		&"memory_table_c",
		&"memory_table_d"
	)
	for target_id in [&"memory_table_c", &"memory_table_d"]:
		_remember(
			blocked_fixture.memory,
			MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
			&"Eat",
			target_id,
			target_id,
			{},
			&"memory_filter_blocked"
		)
	var blocked_hunger := float(blocked_fixture.machine.get_value(&"hunger"))
	var blocked_outcomes := {"count": 0}
	blocked_fixture.machine.activity_target_selection_committed.connect(
		func(_descriptor: Dictionary) -> void:
			blocked_outcomes.count += 1
	)
	assert_false(
		blocked_fixture.machine.evaluate_value_reactions(
			null,
			{"hunger": 1.0}
		),
		"all-suppressed live rule submits no action"
	)
	assert_null(
		blocked_fixture.machine.active_action,
		"all-suppressed creates no action session"
	)
	assert_null(
		blocked_fixture.controller.current_intent,
		"all-suppressed submits no behavior intention"
	)
	assert_eq(
		String(blocked_fixture.machine.current_state.name),
		"Idle",
		"the current valid primary state remains unchanged"
	)
	assert_eq(
		float(blocked_fixture.machine.get_value(&"hunger")),
		blocked_hunger,
		"all-suppressed preserves the need"
	)
	assert_eq(
		simulator.get_spot_reservations(&"memory_table_c").size(),
		0,
		"first suppressed target is not reserved"
	)
	assert_eq(
		simulator.get_spot_reservations(&"memory_table_d").size(),
		0,
		"second suppressed target is not reserved"
	)
	assert_eq(
		blocked_fixture.machine.get_target_selection_debug_descriptor().reason_code,
		&"all_targets_recently_failed",
		"live all-suppressed result is observable"
	)
	assert_eq(
		blocked_outcomes.count,
		0,
		"all-suppressed inspection emits no committed alternative"
	)
	_free_live_eat_fixture(blocked_fixture)


func test_committed_alternative_requires_memory_suppression_and_request_success() -> void:
	var ordinary_fixture := _live_eat_fixture(
		&"memory_no_suppression",
		&"ordinary_table_a",
		&"ordinary_table_b"
	)
	var ordinary_outcomes := {"count": 0}
	ordinary_fixture.machine.activity_target_selection_committed.connect(
		func(_descriptor: Dictionary) -> void:
			ordinary_outcomes.count += 1
	)
	assert_true(
		ordinary_fixture.machine.evaluate_value_reactions(
			null,
			{"hunger": 1.0}
		),
		"ordinary need action succeeds"
	)
	assert_eq(
		ordinary_outcomes.count,
		0,
		"selection without memory suppression emits no alternative outcome"
	)
	_free_live_eat_fixture(ordinary_fixture)

	var rejected_fixture := _live_eat_fixture(
		&"memory_commitment_rejected",
		&"rejected_table_a",
		&"rejected_table_b"
	)
	_remember(
		rejected_fixture.memory,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		&"Eat",
		&"rejected_table_a",
		&"rejected_table_a",
		{},
		&"memory_commitment_rejected"
	)
	rejected_fixture.controller.commit_candidate(NpcBehaviorIntent.create(
		&"Work",
		&"Work",
		NpcBehaviorIntent.SOURCE_NEED,
		"existing_commitment",
		100,
		"existing_target",
		"existing_session",
		10.0,
		15
	))
	var rejected_outcomes := {"count": 0}
	rejected_fixture.machine.activity_target_selection_committed.connect(
		func(_descriptor: Dictionary) -> void:
			rejected_outcomes.count += 1
	)
	assert_false(
		rejected_fixture.machine.evaluate_value_reactions(
			null,
			{"hunger": 1.0}
		),
		"commitment rejects the selected alternative request"
	)
	assert_eq(
		rejected_outcomes.count,
		0,
		"rejected final request emits no committed alternative"
	)
	assert_null(
		rejected_fixture.machine.active_action,
		"rejected request creates no action session"
	)
	_free_live_eat_fixture(rejected_fixture)


func test_reservation_failure_emits_no_committed_alternative() -> void:
	var fixture := _live_eat_fixture(
		&"memory_reservation_rejected",
		&"reserved_table_a",
		&"reserved_table_b"
	)
	_remember(
		fixture.memory,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		&"Eat",
		&"reserved_table_a",
		&"reserved_table_a",
		{},
		&"memory_reservation_rejected"
	)
	var simulator := root.get_node("NpcWorldSimulation")
	var occupied: Dictionary = simulator.try_claim_spot(
		&"other_npc",
		"other_session",
		&"reserved_table_b"
	)
	assert_true(bool(occupied.accepted), "test occupies the alternative target")
	var outcomes := {"count": 0}
	fixture.machine.activity_target_selection_committed.connect(
		func(_descriptor: Dictionary) -> void:
			outcomes.count += 1
	)
	assert_false(
		fixture.machine.evaluate_value_reactions(
			null,
			{"hunger": 1.0}
		),
		"reservation failure rejects the selected alternative"
	)
	assert_eq(outcomes.count, 0, "reservation failure emits no outcome")
	assert_null(fixture.machine.active_action, "failed reservation is not adopted")
	simulator.release_spot_reservation(
		String(occupied.reservation_id),
		&"other_npc",
		"other_session"
	)
	_free_live_eat_fixture(fixture)


func test_scheduled_target_request_cannot_emit_need_alternative() -> void:
	var fixture := _live_eat_fixture(
		&"memory_scheduled_request",
		&"scheduled_table_a",
		&"scheduled_table_b"
	)
	var outcomes := {"count": 0}
	fixture.machine.activity_target_selection_committed.connect(
		func(_descriptor: Dictionary) -> void:
			outcomes.count += 1
	)
	assert_true(
		fixture.machine.request_action_from_descriptor(
			{
				"action_kind": &"Eat",
				"source": &"schedule",
				"priority": 50,
				"reason": "scheduled_meal",
			},
			fixture.second
		),
		"scheduled target request succeeds through its normal path"
	)
	fixture.machine._emit_committed_activity_target_selection(
		{
			"logical_action": &"Eat",
			"selected_target_id": &"scheduled_table_b",
			"suppressed_count": 1,
			"all_suppressed": false,
			"suppressed_candidates": [],
		},
		fixture.second
	)
	assert_eq(
		outcomes.count,
		0,
		"non-need accepted session cannot produce alternative outcome"
	)
	_free_live_eat_fixture(fixture)


func test_target_feedback_coexists_and_clears_for_alternative() -> void:
	var blocked_text := FeedbackFormatter.format_label(
		&"Idle",
		&"Talk",
		{
			"intent": {
				"logical_action_kind": "Eat",
				"feedback_text": "Hungry",
				"source": "need",
				"priority": 50,
			},
			"rejected_intent": {
				"feedback_text": "Wants to talk",
				"priority": 40,
			},
			"target_selection": {
				"all_suppressed": true,
				"reason_code": "all_targets_recently_failed",
				"logical_action": "Eat",
			},
			"social_selection": {
				"all_candidates_suppressed": true,
				"reason_code": "no_social_target_due_to_recent_refusal",
			},
			"memory": {
				"recent": [{"debug_feedback_text": "Could not reach Table"}],
			},
		}
	)
	assert_true(blocked_text.contains("+ Talk"), "Talk overlay remains visible")
	assert_true(blocked_text.contains("blocked:"), "rejection remains visible")
	assert_true(blocked_text.contains("social:"), "social suppression remains visible")
	assert_true(
		blocked_text.contains("Eat targets recently failed"),
		"target all-suppressed line is concise"
	)
	assert_true(blocked_text.contains("remembers:"), "memory line remains visible")
	var clear_text := FeedbackFormatter.format_label(
		&"Idle",
		&"",
		{
			"target_selection": {
				"all_suppressed": false,
				"selected_target_id": "table:b",
			},
		}
	)
	assert_false(
		clear_text.contains("targets recently failed"),
		"alternative selection clears target suppression feedback"
	)


func _memory() -> NpcShortTermMemory:
	return add_child_autofree(NpcShortTermMemory.new()) as NpcShortTermMemory


func _remember(
	memory: NpcShortTermMemory,
	event_type: StringName,
	action: StringName,
	target_id: StringName,
	place_id: StringName,
	metadata: Dictionary = {},
	subject_id: StringName = &"remembering:npc"
) -> String:
	var event := _event(
		event_type,
		action,
		target_id,
		place_id,
		10.0
	)
	event.subject_id = subject_id
	event.metadata = metadata.duplicate(true)
	var result := memory.remember(event)
	return String(result.get("memory", {}).get("memory_id", ""))


func _event(
	event_type: StringName,
	action: StringName,
	target_id: StringName,
	place_id: StringName,
	now_game_hours: float
) -> NpcMemoryEvent:
	return MemoryEvent.create(event_type, {
		"subject_id": "remembering:npc",
		"target_id": String(target_id),
		"place_id": String(place_id),
		"logical_action": String(action),
		"reason_code": "movement_stuck",
		"now_game_hours": now_game_hours,
	}, now_game_hours)


func _live_eat_fixture(
	npc_id: StringName,
	first_spot_id: StringName,
	second_spot_id: StringName
) -> Dictionary:
	var npc := TestNpc.new(npc_id)
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var controller := NpcBehaviorController.new()
	controller.name = "NpcBehaviorController"
	var memory := NpcShortTermMemory.new()
	memory.name = "NpcShortTermMemory"
	machine.add_child(controller)
	machine.add_child(memory)
	for state_name in [&"Idle", &"MoveToTarget", &"Eat"]:
		var state := NpcState.new()
		state.name = String(state_name)
		machine.add_child(state)
	npc.add_child(machine)
	var first := TestSpot.new(first_spot_id, 10.0)
	var second := TestSpot.new(second_spot_id, 20.0)
	first.add_to_group("npc_need_spot")
	second.add_to_group("npc_need_spot")
	npc.add_child(first)
	npc.add_child(second)
	add_child_autofree(npc)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [machine.get_state(&"Idle")]
	machine.current_state.enter()
	machine.values["hunger"] = 80.0
	var simulator := root.get_node("NpcWorldSimulation")
	simulator.register_live_spot(first_spot_id, first)
	simulator.register_live_spot(second_spot_id, second)
	return {
		"npc": npc,
		"machine": machine,
		"controller": controller,
		"memory": memory,
		"first": first,
		"second": second,
	}


func _free_live_eat_fixture(fixture: Dictionary) -> void:
	var machine: NpcStateMachine = fixture.machine
	if machine.active_action != null:
		machine._cancel_and_clear_active_action("test_cleanup")
	var simulator := root.get_node("NpcWorldSimulation")
	simulator.unregister_live_spot(fixture.first.spot_id, fixture.first)
	simulator.unregister_live_spot(fixture.second.spot_id, fixture.second)
	var npc: Node = fixture.npc
	if npc != null and is_instance_valid(npc):
		npc.free()
