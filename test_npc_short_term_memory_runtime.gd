extends "res://test/native_scene_tree_test.gd"

const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const BehaviorIntent = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_intent.gd"
)
const FeedbackFormatter = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_feedback_formatter.gd"
)
const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const MemoryScene = preload(
	"res://scenes/creatures/npc/npc_state_machine.tscn"
)

var _previous_total_hours: float = 0.0
var _previous_auto_advance: bool = false


class TestNpc:
	extends CharacterBody2D

	var persistent_id: StringName

	func _init(new_id: StringName = &"memory_npc") -> void:
		persistent_id = new_id

	func get_npc_location_id() -> StringName:
		return persistent_id


class TargetLosingState:
	extends NpcState

	func target_lost(_lost_target: Node2D) -> NpcState:
		return get_state(&"Idle")


func before_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		_previous_total_hours = world_time.get_total_hours()
		_previous_auto_advance = world_time.auto_advance
		world_time.auto_advance = false
		world_time.set_total_hours(10.0)


func after_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		world_time.auto_advance = _previous_auto_advance
		world_time.set_total_hours(_previous_total_hours)


func test_memory_record_round_trip_and_safe_defaults() -> void:
	var source_metadata := {"nested": {"value": 3}}
	var event := MemoryEvent.create(
		MemoryPolicy.EVENT_ACTION_FAILED,
		{
			"source": "need",
			"reason_code": "no_food",
			"subject_id": "npc:one",
			"target_id": "table:one",
			"place_id": "kitchen",
			"logical_action": "Eat",
			"intent_id": "intent:1",
			"action_session_id": "session:1",
			"importance": 0.7,
			"emotional_valence": -0.4,
			"occurrence_count": 2,
			"resolved": true,
			"metadata": source_metadata,
		},
		10.0
	)
	var original_id := event.memory_id
	event.ensure_memory_id()
	assert_true(not original_id.is_empty(), "a memory receives an ID")
	assert_eq(event.memory_id, original_id, "memory identity remains stable")
	source_metadata.nested.value = 99
	assert_eq(event.metadata.nested.value, 3, "create copies metadata")

	var serialized := event.to_dict()
	var restored := MemoryEvent.from_dict(serialized)
	assert_eq(restored.to_dict(), serialized, "all supported record fields round-trip")
	serialized.metadata.nested.value = 12
	assert_eq(restored.metadata.nested.value, 3, "from_dict does not alias metadata")

	var minimal := MemoryEvent.from_dict({
		"event_type": "conversation_completed",
		"metadata": "malformed",
	})
	assert_eq(minimal.source, &"", "missing source has a safe default")
	assert_eq(minimal.occurrence_count, 1, "missing count has a safe default")
	assert_true(minimal.metadata.is_empty(), "malformed optional metadata is ignored")


func test_memory_record_expiration_and_dedupe_are_structured() -> void:
	var event := _event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.0,
		{"subject_id": "mom", "target_id": "child"}
	)
	assert_false(event.is_expired(11.49), "memory remains before game-hour expiry")
	assert_true(event.is_expired(11.5), "memory expires using game hours")
	assert_eq(event.get_remaining_hours(11.0), 0.5, "remaining age is game time")
	var key := event.get_dedupe_key()
	event.metadata["feedback_text"] = "localized words"
	assert_eq(
		event.get_dedupe_key(),
		key,
		"dedupe identity does not use human-readable feedback"
	)


func test_policy_table_has_all_initial_types_and_documented_ranges() -> void:
	for event_type in [
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED,
		MemoryPolicy.EVENT_ACTION_FAILED,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST,
	]:
		var policy := MemoryPolicy.get_policy(event_type)
		assert_false(policy.is_empty(), "%s has a policy" % String(event_type))
		assert_true(
			float(policy.get("default_duration_game_hours", 0.0)) > 0.0,
			"%s has a game-hour duration" % String(event_type)
		)
		assert_true(
			float(policy.get("maximum_lifetime_game_hours", 0.0))
				>= float(policy.get("default_duration_game_hours", 0.0)),
			"%s has a bounded lifetime" % String(event_type)
		)
		assert_false(
			String(policy.get("debug_feedback_text", "")).is_empty(),
			"%s has developer feedback text" % String(event_type)
		)


func test_storage_inserts_merges_and_preserves_first_observation() -> void:
	var memory := _memory()
	var first := _event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.0,
		{"subject_id": "mom", "target_id": "child"}
	)
	var first_id := first.memory_id
	var first_result := memory.remember(first)
	assert_eq(first_result.result, "added", "the first valid memory is inserted")
	var second_result := memory.remember(_event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.2,
		{"subject_id": "mom", "target_id": "child"}
	))
	assert_eq(second_result.result, "merged", "equivalent recent memory merges")
	var merged := memory.get_memory_by_id(first_id)
	assert_not_null(merged, "merge preserves the first memory ID")
	assert_eq(merged.created_game_hours, 10.0, "merge preserves creation time")
	assert_eq(merged.last_updated_game_hours, 10.2, "merge records latest time")
	assert_eq(merged.occurrence_count, 2, "merge increments occurrence count")


func test_dedupe_distinguishes_subject_target_and_action() -> void:
	var memory := _memory()
	memory.remember(_event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.0,
		{"subject_id": "mom", "target_id": "child"}
	))
	memory.remember(_event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.1,
		{"subject_id": "dad", "target_id": "child"}
	))
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_REFUSED).size(),
		2,
		"different subjects do not merge"
	)
	memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"subject_id": "child", "target_id": "table:a", "logical_action": "Eat"}
	))
	memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.1,
		{"subject_id": "child", "target_id": "table:b", "logical_action": "Eat"}
	))
	memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.1,
		{"subject_id": "child", "target_id": "table:a", "logical_action": "Work"}
	))
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_ACTION_FAILED).size(),
		3,
		"action failures distinguish target and logical action"
	)


func test_repeated_merge_has_absolute_lifetime_cap() -> void:
	var memory := _memory()
	var first := _event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.0,
		{"subject_id": "mom", "target_id": "child"}
	)
	memory.remember(first)
	for index in 14:
		var now := 10.2 + (float(index) * 0.2)
		memory.remember(_event(
			MemoryPolicy.EVENT_CONVERSATION_REFUSED,
			now,
			{"subject_id": "mom", "target_id": "child"}
		))
	var merged := memory.get_memory_by_id(first.memory_id)
	assert_true(
		merged.expires_game_hours <= 13.0,
		"repeated merges cannot extend beyond the policy lifetime cap"
	)
	assert_eq(merged.occurrence_count, 4, "occurrence count is policy-capped")


func test_expiry_and_deterministic_capacity_eviction() -> void:
	var memory := _memory()
	memory.maximum_memories = 2
	var a := _event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"memory_id": "memory:a", "subject_id": "a", "logical_action": "Eat"}
	)
	var b := _event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"memory_id": "memory:b", "subject_id": "b", "logical_action": "Eat"}
	)
	var c := _event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"memory_id": "memory:c", "subject_id": "c", "logical_action": "Eat"}
	)
	memory.remember(a)
	memory.remember(b)
	memory.remember(c)
	assert_null(memory.get_memory_by_id("memory:a"), "memory ID breaks eviction ties")
	assert_not_null(memory.get_memory_by_id("memory:b"), "later tie member remains")
	assert_not_null(memory.get_memory_by_id("memory:c"), "new event remains")
	assert_eq(memory.prune_expired(11.1), 2, "expired memories are removed")
	assert_true(
		memory.get_debug_descriptor(11.1).recent.is_empty(),
		"expired memories disappear from debug feedback"
	)


func test_resolved_then_low_importance_eviction_order() -> void:
	var memory := _memory()
	memory.maximum_memories = 2
	var resolved := _event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{
			"memory_id": "resolved",
			"subject_id": "resolved",
			"logical_action": "Eat",
			"importance": 1.0,
		}
	)
	var low := _event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{
			"memory_id": "low",
			"subject_id": "low",
			"logical_action": "Eat",
			"importance": 0.1,
		}
	)
	memory.remember(resolved)
	memory.remember(low)
	memory.resolve_memory("resolved", &"handled")
	memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.1,
		{
			"memory_id": "new",
			"subject_id": "new",
			"logical_action": "Eat",
			"importance": 0.05,
		}
	))
	assert_null(memory.get_memory_by_id("resolved"), "resolved memory is evicted first")

	var importance_memory := _memory()
	importance_memory.maximum_memories = 2
	importance_memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"memory_id": "low", "subject_id": "low", "importance": 0.1}
	))
	importance_memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"memory_id": "high", "subject_id": "high", "importance": 0.9}
	))
	importance_memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.1,
		{"memory_id": "middle", "subject_id": "middle", "importance": 0.5}
	))
	assert_null(
		importance_memory.get_memory_by_id("low"),
		"lower importance is evicted before higher importance"
	)


func test_queries_return_safe_copies() -> void:
	var memory := _memory()
	var event := _event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"subject_id": "child", "target_id": "table", "logical_action": "Eat"}
	)
	memory.remember(event)
	assert_true(
		memory.has_recent(
			MemoryPolicy.EVENT_ACTION_FAILED, &"child", &"table", &"Eat"
		),
		"has_recent matches structured fields"
	)
	var queried := memory.find_recent(MemoryPolicy.EVENT_ACTION_FAILED)
	queried[0].importance = 0.0
	queried[0].metadata["mutated"] = true
	var stored := memory.get_memory_by_id(event.memory_id)
	assert_true(stored.importance > 0.0, "query object mutation cannot change storage")
	assert_false(stored.metadata.has("mutated"), "query metadata is also copied")


func test_action_lifecycle_only_records_authoritative_failures() -> void:
	var fixture := _machine_fixture()
	var machine: NpcStateMachine = fixture.machine
	var memory: NpcShortTermMemory = fixture.memory
	var controller: NpcBehaviorController = fixture.controller
	var target: TestNpc = fixture.target

	var lifecycle := BehaviorIntent.create(
		&"Idle", &"Eat", &"internal", "arrival", 0, "", "", 0.0, 0, {}, &"", "", &"", true
	)
	controller.commit_candidate(lifecycle)
	assert_eq(memory.get_recent_memories().size(), 0, "lifecycle-only intent creates no memory")

	_start_action(machine, controller, target, "complete", &"Eat")
	var refresh := controller.current_intent.refreshed_copy({
		"requested_primary_state": &"Eat",
	})
	controller.refresh_current_intent(refresh, "complete")
	assert_eq(memory.get_recent_memories().size(), 0, "same-session refresh creates no memory")
	machine.complete_active_action("complete", "normal_completion")
	assert_eq(memory.get_recent_memories().size(), 0, "normal completion creates no failure memory")

	_start_action(machine, controller, target, "failed", &"Eat")
	assert_true(machine.fail_active_action("failed", "food_action_failed"), "matching failure is terminal")
	machine.fail_active_action("failed", "food_action_failed")
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_ACTION_FAILED).size(),
		1,
		"matching duplicated terminal routing creates exactly one memory"
	)
	var failure := memory.find_recent(MemoryPolicy.EVENT_ACTION_FAILED)[0]
	assert_eq(failure.intent_id.is_empty(), false, "failure preserves accepted intent ID")
	assert_eq(failure.action_session_id, "failed", "failure preserves session ID")
	assert_eq(failure.reason_code, &"test_action", "accepted intention reason is preserved")
	assert_eq(
		failure.metadata.get("terminal_reason", ""),
		"food_action_failed",
		"structured terminal reason is preserved separately"
	)


func test_stale_supersession_recovery_and_teardown_are_not_failures() -> void:
	var fixture := _machine_fixture()
	var machine: NpcStateMachine = fixture.machine
	var memory: NpcShortTermMemory = fixture.memory
	var controller: NpcBehaviorController = fixture.controller
	var target: TestNpc = fixture.target

	_start_action(machine, controller, target, "old", &"Eat")
	_start_action(machine, controller, target, "new", &"Work")
	assert_eq(memory.get_recent_memories().size(), 0, "supersession is not failure")
	assert_false(machine.fail_active_action("old", "late_failure"), "stale failure is rejected")
	assert_eq(memory.get_recent_memories().size(), 0, "stale failure creates no memory")

	machine.active_action.phase = &"moving_to_target"
	assert_true(
		machine.pause_active_action_movement_for_retry("new"),
		"temporary movement retry remains nonterminal"
	)
	assert_eq(memory.get_recent_memories().size(), 0, "temporary retry creates no memory")
	machine.active_action.phase = &"moving_to_target"
	assert_true(machine.fail_active_action("new", "movement_stuck"), "final movement fails")
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_MOVEMENT_FAILED).size(),
		1,
		"final matching movement failure creates one memory"
	)

	_start_action(machine, controller, target, "teardown", &"Eat")
	machine._cancel_and_clear_active_action("scene_exit")
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_ACTION_FAILED).size(),
		0,
		"lifecycle teardown cancellation creates no action failure"
	)


func test_target_failure_and_goal_target_loss_are_canonical() -> void:
	var fixture := _machine_fixture(true)
	var machine: NpcStateMachine = fixture.machine
	var memory: NpcShortTermMemory = fixture.memory
	var controller: NpcBehaviorController = fixture.controller
	var target: TestNpc = fixture.target

	_start_action(machine, controller, target, "unavailable", &"Eat")
	machine.fail_active_action("unavailable", "missing_action_target")
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_TARGET_UNAVAILABLE).size(),
		1,
		"matching missing target creates target-unavailable memory"
	)
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_ACTION_FAILED).size(),
		0,
		"target unavailability is not duplicated as generic action failure"
	)

	_start_action(machine, controller, target, "lost", &"ReactToEvent")
	var losing_state: NpcState = machine.get_state(&"TargetLosing")
	machine.state_history = [losing_state]
	losing_state.enter()
	machine.active = true
	machine.notify_target_lost(target)
	machine.active = false
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_INTENTION_TARGET_LOST).size(),
		1,
		"accepted matching goal loss creates one target-lost memory"
	)
	assert_eq(
		memory.find_recent(MemoryPolicy.EVENT_TARGET_UNAVAILABLE).size(),
		1,
		"target loss does not duplicate target-unavailable outcome"
	)


func test_explicit_npc_refusal_only_records_for_requester() -> void:
	var requester := _full_npc_fixture(&"requester")
	var refuser := _full_npc_fixture(&"refuser")
	var requester_machine: NpcStateMachine = requester.machine
	var refuser_machine: NpcStateMachine = refuser.machine
	refuser_machine.state_history = [refuser_machine.get_state(&"MoveToTarget")]
	refuser_machine.current_state_priority = 50

	assert_false(
		requester_machine.request_state(&"Talk", refuser.npc, "social_seek", 0),
		"busy intended partner explicitly refuses Talk"
	)
	var refusals: Array[NpcMemoryEvent] = requester.memory.find_recent(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED
	)
	assert_eq(refusals.size(), 1, "requester receives one refusal memory")
	assert_eq(refusals[0].subject_id, &"refuser", "refusing NPC is the subject")
	assert_eq(refusals[0].target_id, &"requester", "remembering NPC is the target role")
	assert_eq(
		refuser.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_REFUSED).size(),
		0,
		"refuser does not receive the requester's memory"
	)
	assert_null(
		requester_machine.get_state(&"NpcShortTermMemory"),
		"memory component remains outside the state registry"
	)
	assert_true(
		requester.label.text.contains("remembers: Refuser refused to talk"),
		"memory_changed refreshes the existing StateLabel"
	)

	requester_machine.talk_refusal_cooldowns.clear()
	requester_machine.request_state(&"Talk", refuser.npc, "social_seek", 0)
	assert_eq(
		requester.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_REFUSED)[0].occurrence_count,
		2,
		"repeated refusal by the same NPC merges"
	)
	var other_refuser := _full_npc_fixture(&"other_refuser")
	var other_refuser_machine: NpcStateMachine = other_refuser.machine
	var other_refuser_states: Array[NpcState] = [
		other_refuser_machine.get_state(&"MoveToTarget")
	]
	other_refuser_machine.state_history = other_refuser_states
	other_refuser_machine.current_state_priority = 50
	requester_machine.talk_refusal_cooldowns.clear()
	requester_machine.request_state(&"Talk", other_refuser.npc, "social_seek", 0)
	assert_eq(
		requester.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_REFUSED).size(),
		2,
		"refusal from another NPC stays separate"
	)


func test_conversation_start_completion_and_non_npc_cancellation() -> void:
	var first := _full_npc_fixture(&"first")
	var second := _full_npc_fixture(&"second")
	assert_true(
		first.machine.request_state(&"Talk", second.npc, "social_seek", 0),
		"NPC conversation starts"
	)
	assert_eq(
		first.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_COMPLETED).size(),
		0,
		"starting Talk is not completion"
	)
	first.machine._complete_interaction_overlay("completed", true)
	assert_eq(
		first.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_COMPLETED).size(),
		1,
		"normal successful conversation creates completion memory"
	)
	assert_eq(
		second.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_COMPLETED).size(),
		1,
		"both NPC participants remember normal completion"
	)

	var player := Node2D.new()
	player.add_to_group("player")
	add_child_autofree(player)
	var npc := _full_npc_fixture(&"player_talker")
	assert_true(npc.machine.request_state(&"Talk", player, "player", 0), "player Talk starts")
	npc.machine._cancel_interaction_overlay("player_cancelled")
	assert_eq(
		npc.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_REFUSED).size(),
		0,
		"player Talk cancellation is not NPC refusal"
	)


func test_commitment_rejection_does_not_become_social_refusal() -> void:
	var npc := _full_npc_fixture(&"committed")
	var partner := _full_npc_fixture(&"partner")
	var current := BehaviorIntent.create(
		&"Eat", &"Eat", &"need", "hungry", 50, "table", "meal", 20.0, 15
	)
	npc.controller.commit_candidate(current)
	var social := BehaviorIntent.create(
		&"Talk",
		&"Talk",
		&"social_ai",
		"social_seek",
		60,
		"partner",
		"social",
		2.0,
		15
	)
	var decision: Dictionary = npc.controller.evaluate_candidate(social)
	assert_false(bool(decision.accepted), "generic commitment rejects social candidate")
	npc.controller.reject_candidate(social, &"behavior_commitment_active")
	assert_eq(
		npc.memory.find_recent(MemoryPolicy.EVENT_CONVERSATION_REFUSED).size(),
		0,
		"commitment rejection does not become partner refusal"
	)


func test_debug_feedback_relevance_and_coexistence() -> void:
	var memory := _memory()
	var low := _event(
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED,
		10.0,
		{"subject_id": "friend", "target_id": "self", "importance": 0.2}
	)
	var high := _event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.1,
		{"subject_id": "mom", "target_id": "self", "importance": 0.8}
	)
	memory.remember(low)
	memory.remember(high)
	var debug := memory.get_debug_descriptor(10.1)
	assert_eq(debug.recent.size(), 1, "debug descriptor shows at most one memory")
	assert_eq(
		debug.recent[0].memory_id,
		high.memory_id,
		"unresolved higher-importance recent memory is selected"
	)

	var controller := NpcBehaviorController.new()
	add_child_autofree(controller)
	var intent := BehaviorIntent.create(
		&"MoveToTarget", &"Eat", &"need", "hungry", 50, "table", "meal", 2.0, 15
	)
	var start_usec := 10000000
	controller.commit_candidate(intent, start_usec)
	var feedback := controller.get_feedback_descriptor(start_usec + 500000)
	feedback["memory"] = debug
	var text := FeedbackFormatter.format_label(&"MoveToTarget", &"Talk", feedback)
	assert_true(text.begins_with("MoveToTarget \u2192 Eat + Talk"), "state and Talk overlay remain")
	assert_true(text.contains("hold 1.5s"), "commitment countdown remains")
	assert_true(text.contains("remembers: Mom refused to talk"), "memory feedback coexists")

	var rejected := BehaviorIntent.create(
		&"LookForTalkTarget", &"LookForTalkTarget", &"social_ai", "social", 60
	)
	controller.reject_candidate(rejected, &"behavior_commitment_active")
	feedback = controller.get_feedback_descriptor(start_usec + 500000)
	feedback["memory"] = debug
	text = FeedbackFormatter.format_label(&"Eat", &"", feedback)
	assert_true(text.contains("blocked:"), "rejection feedback remains")
	assert_true(text.contains("remembers:"), "memory coexists with rejection")
	assert_eq(
		FeedbackFormatter.format_label(&"Idle", &"", {}),
		"Idle",
		"Idle without memory remains state-only"
	)


func test_memory_changed_is_event_driven_not_per_frame() -> void:
	var memory := _memory()
	var changes := {"count": 0}
	memory.memory_changed.connect(func() -> void: changes.count += 1)
	memory.remember(_event(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.0,
		{"subject_id": "self", "logical_action": "Eat"}
	))
	assert_eq(changes.count, 1, "insertion emits one feedback refresh event")
	memory._process(0.1)
	memory._process(0.1)
	assert_eq(changes.count, 1, "ordinary frames do not rebuild feedback")
	memory.prune_expired(11.0)
	assert_eq(changes.count, 2, "displayed memory expiry emits a refresh")


func test_snapshot_round_trip_and_import_validation() -> void:
	var source := _memory()
	source.remember(_event(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.0,
		{"memory_id": "kept", "subject_id": "mom", "target_id": "child"}
	))
	var snapshot := source.export_snapshot(10.0)
	var destination := _memory()
	var changes := {"count": 0}
	destination.memory_changed.connect(func() -> void: changes.count += 1)
	var result := destination.import_snapshot(snapshot, 10.0)
	assert_eq(result.imported_count, 1, "snapshot imports")
	assert_eq(
		destination.export_snapshot(10.0),
		snapshot,
		"export and import round-trip"
	)
	assert_eq(changes.count, 1, "import emits one summarized change notification")

	var mixed: Array = []
	for entry in snapshot:
		mixed.append(entry.duplicate(true))
	var expired := snapshot[0].duplicate(true)
	expired.memory_id = "expired"
	expired.created_game_hours = 8.0
	expired.last_updated_game_hours = 8.0
	expired.expires_game_hours = 9.0
	mixed.append(expired)
	mixed.append("malformed")
	mixed.append({"event_type": "unknown", "memory_id": "unknown"})
	mixed.append(snapshot[0].duplicate(true))
	result = destination.import_snapshot(mixed, 10.0)
	assert_eq(result.expired_count, 1, "import removes expired entries")
	assert_eq(result.malformed_count, 2, "import ignores malformed and unknown entries")
	assert_eq(result.duplicate_id_count, 1, "first duplicate imported memory ID wins")
	assert_eq(destination.get_memory_by_id("kept").memory_id, "kept", "valid ID is preserved")


func test_snapshot_import_enforces_capacity_deterministically() -> void:
	var memory := _memory()
	memory.maximum_memories = 1
	var snapshot: Array = [
		_event(
			MemoryPolicy.EVENT_ACTION_FAILED,
			10.0,
			{"memory_id": "low", "subject_id": "low", "importance": 0.1}
		).to_dict(),
		_event(
			MemoryPolicy.EVENT_ACTION_FAILED,
			10.0,
			{"memory_id": "high", "subject_id": "high", "importance": 0.9}
		).to_dict(),
	]
	var result := memory.import_snapshot(snapshot, 10.0)
	assert_eq(result.evicted_count, 1, "import enforces capacity")
	assert_null(memory.get_memory_by_id("low"), "import uses deterministic eviction")
	assert_not_null(memory.get_memory_by_id("high"), "higher importance survives import")


func _memory() -> NpcShortTermMemory:
	var memory := NpcShortTermMemory.new()
	add_child_autofree(memory)
	return memory


func _event(
	event_type: StringName,
	now_game_hours: float,
	overrides: Dictionary = {}
) -> NpcMemoryEvent:
	var context := {
		"source": "test",
		"reason_code": "test_event",
		"subject_id": "subject",
		"target_id": "target",
		"place_id": "place",
		"logical_action": "Action",
		"created_game_hours": now_game_hours,
		"last_updated_game_hours": now_game_hours,
	}
	context.merge(overrides, true)
	var event := MemoryEvent.create(event_type, context, now_game_hours)
	if overrides.has("memory_id"):
		event.memory_id = String(overrides.memory_id)
	return event


func _machine_fixture(include_target_losing_state: bool = false) -> Dictionary:
	var npc := TestNpc.new(&"memory_npc")
	npc.add_to_group("npc")
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var controller := NpcBehaviorController.new()
	controller.name = "NpcBehaviorController"
	var memory := NpcShortTermMemory.new()
	memory.name = "NpcShortTermMemory"
	var observer := NpcMemoryObserver.new()
	observer.name = "NpcMemoryObserver"
	machine.add_child(controller)
	machine.add_child(memory)
	machine.add_child(observer)
	for state_name in [&"Idle", &"MoveToTarget", &"Eat", &"Work"]:
		var state := NpcState.new()
		state.name = String(state_name)
		machine.add_child(state)
	if include_target_losing_state:
		var target_losing := TargetLosingState.new()
		target_losing.name = "TargetLosing"
		machine.add_child(target_losing)
	npc.add_child(machine)
	var target := TestNpc.new(&"memory_target")
	target.name = "Target"
	target.add_to_group("npc")
	npc.add_child(target)
	add_child_autofree(npc)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [machine.get_state(&"Idle")]
	machine.current_state.enter()
	return {
		"npc": npc,
		"machine": machine,
		"controller": controller,
		"memory": memory,
		"observer": observer,
		"target": target,
	}


func _start_action(
	machine: NpcStateMachine,
	controller: NpcBehaviorController,
	target: Node2D,
	session_id: String,
	action_kind: StringName
) -> void:
	var session := ActionSession.create(
		"memory_npc",
		action_kind,
		&"need",
		target,
		{
			"session_id": session_id,
			"status": "active",
			"phase": "executing",
		}
	)
	machine.replace_active_action(session, "test_replace")
	var intent := BehaviorIntent.create(
		action_kind,
		action_kind,
		&"need",
		"test_action",
		50,
		ActionSession.get_persistent_id(target),
		session_id,
		2.0,
		15,
		{},
		&"test_action",
		"Testing action"
	)
	controller.commit_candidate(intent)


func _full_npc_fixture(npc_id: StringName) -> Dictionary:
	var npc := TestNpc.new(npc_id)
	npc.name = String(npc_id)
	npc.add_to_group("npc")
	var label := Label.new()
	label.name = "StateLabel"
	npc.add_child(label)
	var machine := MemoryScene.instantiate() as NpcStateMachine
	machine.active = false
	machine.debug_label_path = NodePath("StateLabel")
	npc.add_child(machine)
	add_child_autofree(npc)
	machine.bind_npc(npc)
	machine.state_history = [machine.get_state(&"Idle")]
	machine.current_state.enter()
	return {
		"npc": npc,
		"machine": machine,
		"controller": machine.behavior_controller,
		"memory": machine.short_term_memory,
		"observer": machine.memory_observer,
		"label": label,
	}
