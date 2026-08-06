extends "res://test/native_scene_tree_test.gd"

const Policy = preload("res://scripts/systems/npc_schedule_window_policy.gd")
const WorldSimulation = preload("res://scripts/systems/npc_world_simulation.gd")
const ActionSession = preload("res://scripts/systems/npc_action_session.gd")


class SelectorRuntime:
	extends RefCounted

	var spot_claim_counts: Dictionary = {}
	var spot_runtime_states: Dictionary = {}
	var meal_ids: Dictionary = {}

	func _definition_is_meal_cycle_managed(definition: NpcSpotDefinition) -> bool:
		return meal_ids.has(String(definition.spot_id))

	func _meal_cycle_definition_can_start(
		_definition: NpcSpotDefinition,
		_npc_id: StringName,
		_hour: float
	) -> bool:
		return true

	func _meal_cycle_definition_is_available(
		_definition: NpcSpotDefinition
	) -> bool:
		return true

	func _get_saved_stat(record: Dictionary, value_name: String) -> float:
		return float(record.get("node_state", {}).get(
			"social_stats",
			{}
		).get(value_name, 0.0))


class ScheduleMachine:
	extends Node

	var current_state: Node
	var socially_engaged: bool = false
	var scripted: bool = false
	var same_activity: bool = false
	var feedback_source: String = ""

	func set_state_name(state_name: String) -> void:
		if current_state != null:
			current_state.free()
		current_state = Node.new()
		current_state.name = state_name
		add_child(current_state)

	func is_socially_engaged() -> bool:
		return socially_engaged

	func has_scripted_control_claim() -> bool:
		return scripted

	func is_following_activity_descriptor(_descriptor: Dictionary) -> bool:
		return same_activity

	func get_feedback_descriptor() -> Dictionary:
		return {
			"intent": {"source": feedback_source} if not feedback_source.is_empty() else {},
		}


class ScheduleNpc:
	extends Node2D

	var persistent_id: String = "schedule_test_npc"

	func get_npc_location_id() -> StringName:
		return StringName(persistent_id)


class ScheduleLocations:
	extends Node

	var live_npc: Node
	var availability_allowed: bool = true
	var begin_allowed: bool = true
	var availability_calls: int = 0
	var begin_calls: int = 0
	var requested_priority: int = -1
	var requested_activity: Dictionary = {}
	var begun_activity: Dictionary = {}

	func get_live_npc(_npc_id: String) -> Node:
		return live_npc

	func is_npc_available_for_scheduled_activity(
		_npc_id: String,
		_requested_state_name: StringName,
		priority: int,
		activity: Dictionary
	) -> bool:
		availability_calls += 1
		requested_priority = priority
		requested_activity = activity.duplicate(true)
		return availability_allowed

	func begin_scheduled_activity(
		_npc_id: String,
		activity: Dictionary,
		_target_scene_path: String,
		_target_position: Vector2
	) -> bool:
		begin_calls += 1
		begun_activity = activity.duplicate(true)
		return begin_allowed


func test_policy_preserves_legacy_hard_windows_and_exact_boundaries() -> void:
	var legacy := _definition(&"legacy", 65, [{
		"start_hour": 16.0,
		"end_hour": 18.0,
	}])
	var at_start := Policy.evaluate_definition(legacy, 304.0)
	assert_true(bool(at_start.eligible), "legacy window opens at its exact start")
	assert_eq(at_start.start_policy, &"hard", "legacy defaults to hard")
	assert_eq(at_start.phase, &"on_time", "hard window is on time")
	assert_true(
		bool(at_start.may_interrupt_busy_live_npc),
		"hard window keeps immediate interruption semantics"
	)
	assert_eq(at_start.effective_priority, 65, "hard priority stays unchanged")
	var at_end := Policy.evaluate_definition(legacy, 306.0)
	assert_false(bool(at_end.eligible), "window closes at its exact end")
	assert_eq(at_end.phase, &"closed", "closed phase is explicit")


func test_flexible_grace_lateness_and_priority_interpolation() -> void:
	var flexible := _definition(&"mom_work", 65, [_flexible_window(16.0, 18.0)])
	var opened := Policy.evaluate_definition(flexible, 304.0)
	assert_eq(opened.phase, &"on_time", "flexible window opens on time")
	assert_eq(opened.grace_end_total_hours, 304.5, "thirty minutes is half an hour")
	assert_false(
		bool(opened.may_interrupt_busy_live_npc),
		"busy live NPC is protected during grace"
	)
	var grace_boundary := Policy.evaluate_definition(flexible, 304.5)
	assert_eq(grace_boundary.phase, &"on_time", "exact grace end remains on time")
	assert_eq(grace_boundary.effective_priority, 65, "bonus begins at zero")
	var midpoint := Policy.evaluate_definition(flexible, 305.25)
	assert_eq(midpoint.phase, &"late", "time after grace is late")
	assert_true(bool(midpoint.may_interrupt_busy_live_npc), "late work may ask existing states")
	assert_eq(midpoint.lateness_game_hours, 0.75, "lateness is measured from grace end")
	assert_eq(midpoint.effective_priority, 70, "late bonus interpolates linearly")
	var near_end := Policy.evaluate_definition(flexible, 305.999999)
	assert_eq(near_end.effective_priority, 75, "late bonus safely reaches its authored cap")
	var huge := _flexible_window(16.0, 18.0)
	huge["late_priority_bonus"] = 1.0e20
	var clamped := Policy.evaluate_definition(
		_definition(&"clamped", 65, [huge]),
		305.999999
	)
	assert_eq(
		clamped.effective_priority,
		Policy.MAXIMUM_SAFE_PRIORITY,
		"extreme authored bonus clamps before integer conversion"
	)


func test_occurrences_support_cross_midnight_multiple_windows_and_large_jumps() -> void:
	var overnight := _definition(&"overnight", 20, [{
		"start_hour": 22.0,
		"end_hour": 6.0,
	}])
	var after_midnight := Policy.evaluate_definition(overnight, 313.0)
	assert_true(bool(after_midnight.eligible), "cross-midnight occurrence stays open")
	assert_eq(after_midnight.window_start_total_hours, 310.0, "occurrence starts previous day")
	assert_eq(after_midnight.window_end_total_hours, 318.0, "occurrence ends current day")
	var multiple := _definition(&"two_windows", 20, [
		{"start_hour": 9.0, "end_hour": 10.0},
		{"start_hour": 16.0, "end_hour": 18.0},
	])
	var morning := Policy.evaluate_definition(multiple, 297.25)
	var afternoon := Policy.evaluate_definition(multiple, 304.25)
	assert_eq(morning.window_index, 0, "morning uses first window")
	assert_eq(afternoon.window_index, 1, "afternoon uses second window")
	assert_true(
		morning.occurrence_key != afternoon.occurrence_key,
		"daily windows have distinct stable occurrence keys"
	)
	var jumped := Policy.evaluate_definition(multiple, 2409.25)
	assert_true(bool(jumped.eligible), "large total-hour jump finds current occurrence")
	assert_eq(jumped.window_start_total_hours, 2409.0, "jump uses absolute day occurrence")
	var normalized := _definition(&"midnight", 20, [{
		"start_hour": 24.0,
		"end_hour": 1.0,
	}])
	assert_true(
		bool(Policy.evaluate_definition(normalized, 240.5).eligible),
		"hour 24 normalizes to the next midnight"
	)


func test_definition_validation_rejects_malformed_flexible_fields() -> void:
	var definition := _definition(&"invalid", 20, [{
		"start_hour": 16.0,
		"end_hour": 17.0,
		"start_policy": "elastic",
		"grace_game_minutes": 90.0,
		"late_priority_bonus": -1,
	}])
	var errors := definition.get_validation_errors()
	assert_true(_errors_contain(errors, "start_policy"), "unknown start policy is rejected")
	assert_true(_errors_contain(errors, "exceeds"), "grace cannot exceed window")
	assert_true(_errors_contain(errors, "late_priority_bonus"), "negative bonus is rejected")
	definition.active_time_windows = [{
		"start_hour": 16.0,
		"end_hour": 18.0,
		"start_policy": "flexible",
		"grace_game_minutes": NAN,
		"late_priority_bonus": INF,
	}]
	errors = definition.get_validation_errors()
	assert_true(_errors_contain(errors, "grace_game_minutes"), "non-finite grace is rejected")
	assert_true(_errors_contain(errors, "late_priority_bonus"), "non-finite bonus is rejected")
	var valid_legacy := _definition(&"valid_legacy", 20, [{
		"start_hour": 9.0,
		"end_hour": 10.0,
	}])
	assert_true(valid_legacy.get_validation_errors().is_empty(), "legacy window remains valid")


func test_selector_orders_by_effective_priority_urgency_and_spot_id() -> void:
	var runtime := SelectorRuntime.new()
	var record := _record()
	var legacy := _definition(&"legacy_high", 65, [{
		"start_hour": 16.0,
		"end_hour": 18.0,
	}])
	var flexible := _definition(&"flex_late", 64, [_flexible_window(16.0, 18.0)])
	var candidate := NpcActivitySelector.find_best_candidate(
		{legacy.spot_id: legacy, flexible.spot_id: flexible},
		&"mom",
		record,
		305.9,
		runtime
	)
	assert_eq(
		(candidate.definition as NpcSpotDefinition).spot_id,
		&"flex_late",
		"effective late priority wins candidate ordering"
	)
	assert_true(
		int(candidate.effective_priority) > flexible.priority,
		"selector exposes occurrence priority separately"
	)

	var a := _definition(&"a_spot", 30, [])
	var b := _definition(&"b_spot", 30, [])
	a.value_name = &"boredom"
	b.value_name = &"boredom"
	a.need_threshold = 20.0
	b.need_threshold = 40.0
	var urgency_candidate := NpcActivitySelector.find_best_candidate(
		{a.spot_id: a, b.spot_id: b},
		&"mom",
		record,
		300.0,
		runtime
	)
	assert_eq(
		(urgency_candidate.definition as NpcSpotDefinition).spot_id,
		&"a_spot",
		"existing need urgency remains second tie-break"
	)
	b.need_threshold = 20.0
	var stable_candidate := NpcActivitySelector.find_best_candidate(
		{b.spot_id: b, a.spot_id: a},
		&"mom",
		record,
		300.0,
		runtime
	)
	assert_eq(
		(stable_candidate.definition as NpcSpotDefinition).spot_id,
		&"a_spot",
		"spot ID deterministically breaks exact ties"
	)


func test_selector_bypasses_policy_for_meal_cycles_and_keeps_wrapper() -> void:
	var runtime := SelectorRuntime.new()
	var meal := _definition(&"meal", 40, [{
		"start_hour": 8.0,
		"end_hour": 9.0,
	}])
	runtime.meal_ids[String(meal.spot_id)] = true
	var candidate := NpcActivitySelector.find_best_candidate(
		{meal.spot_id: meal},
		&"mom",
		_record(),
		304.0,
		runtime
	)
	assert_eq(
		(candidate.definition as NpcSpotDefinition).spot_id,
		&"meal",
		"meal-cycle timing remains dedicated even outside active windows"
	)
	assert_true(
		bool(candidate.schedule_decision.meal_cycle_managed),
		"meal-cycle bypass is explicit"
	)
	assert_eq(
		NpcActivitySelector.find_best_definition(
			{meal.spot_id: meal},
			&"mom",
			_record(),
			16.0,
			runtime
		),
		meal,
		"compatibility wrapper returns the selected definition"
	)


func test_only_mom_work_is_authored_flexible_in_first_pass() -> void:
	var work := load("res://data/npc_spots/mom_work.tres") as NpcSpotDefinition
	assert_not_null(work, "Mom work definition loads")
	if work == null:
		return
	assert_eq(work.priority, 65, "Mom work base priority is unchanged")
	assert_eq(work.active_time_windows.size(), 2, "both existing work windows remain")
	for window in work.active_time_windows:
		assert_eq(window.get("start_policy", ""), "flexible", "work window opts in")
		assert_eq(float(window.get("grace_game_minutes", -1.0)), 30.0, "work grace is thirty minutes")
		assert_eq(int(window.get("late_priority_bonus", -1)), 10, "work late bonus is ten")
	for resource_path in [
		"res://data/npc_spots/mom_bed.tres",
		"res://data/npc_spots/mom_shower.tres",
		"res://data/npc_spots/mom_magic_lesson.tres",
	]:
		var definition := load(resource_path) as NpcSpotDefinition
		assert_not_null(definition, "%s loads" % resource_path.get_file())
		if definition == null:
			continue
		for window in definition.active_time_windows:
			assert_false(window.has("start_policy"), "other Mom schedules remain legacy hard")
func test_live_grace_defers_without_mutation_and_idle_starts_immediately() -> void:
	var fixture := _live_fixture("Rest")
	var simulator: Node = fixture.simulator
	var locations: ScheduleLocations = fixture.locations
	var record: Dictionary = fixture.record
	simulator.call(
		"_try_start_activity",
		&"mom",
		record,
		304.1,
		16.1,
		locations,
		{"mom": record}
	)
	assert_eq(locations.availability_calls, 0, "grace deferral skips availability mutation lane")
	assert_eq(locations.begin_calls, 0, "grace deferral creates no activity/session/reservation")
	var debug: Dictionary = simulator.call(
		"get_schedule_decision_debug_descriptor",
		&"mom"
	)
	assert_true(bool(debug.deferred_for_flexible_grace), "grace deferral is observable")
	assert_eq(debug.current_state, &"Rest", "descriptor includes current primary state")
	assert_true(float(debug.grace_remaining_game_hours) > 0.0, "remaining grace is structured")

	(fixture.machine as ScheduleMachine).set_state_name("Idle")
	simulator.call(
		"_try_start_activity",
		&"mom",
		record,
		304.2,
		16.2,
		locations,
		{"mom": record}
	)
	assert_eq(locations.availability_calls, 1, "Idle NPC is checked normally during grace")
	assert_eq(locations.begin_calls, 1, "Idle NPC starts during grace")
	assert_eq(locations.begun_activity.schedule_phase, "on_time", "on-time metadata is copied")
	assert_eq(locations.begun_activity.priority, 65, "base priority reaches activity")


func test_late_live_start_uses_existing_gate_and_copies_schedule_metadata() -> void:
	var fixture := _live_fixture("Rest")
	var simulator: Node = fixture.simulator
	var locations: ScheduleLocations = fixture.locations
	var record: Dictionary = fixture.record
	simulator.call(
		"_try_start_activity",
		&"mom",
		record,
		305.25,
		17.25,
		locations,
		{"mom": record}
	)
	assert_eq(locations.availability_calls, 1, "late busy NPC uses existing availability gate")
	assert_eq(locations.begin_calls, 1, "accepted late gate reaches existing transaction")
	assert_eq(locations.requested_priority, 70, "effective priority reaches availability")
	assert_eq(locations.begun_activity.priority, 70, "effective priority reaches action descriptor")
	assert_eq(locations.begun_activity.schedule_phase, "late", "late phase is retained")
	assert_eq(
		locations.begun_activity.schedule_occurrence_key,
		"mom_work:12:0",
		"activity retains absolute occurrence identity"
	)
	assert_eq(
		locations.begun_activity.metadata.schedule_occurrence_key,
		"mom_work:12:0",
		"action-session metadata receives copied occurrence context"
	)
	var session := ActionSession.create(
		"mom",
		&"Work",
		&"schedule",
		null,
		locations.begun_activity
	)
	assert_eq(session.priority, 70, "effective priority reaches typed action session")
	assert_eq(
		session.metadata.schedule_occurrence_key,
		"mom_work:12:0",
		"typed action session retains schedule context outside identity"
	)


func test_talk_scripted_emergency_and_same_activity_boundaries_are_protected() -> void:
	var talk_fixture := _live_fixture("Idle")
	(talk_fixture.machine as ScheduleMachine).socially_engaged = true
	_call_try_start(talk_fixture, 305.25)
	assert_eq(
		(talk_fixture.locations as ScheduleLocations).begin_calls,
		0,
		"active Talk remains protected while late"
	)
	var scripted_fixture := _live_fixture("Rest")
	(scripted_fixture.machine as ScheduleMachine).scripted = true
	_call_try_start(scripted_fixture, 305.25)
	assert_true(
		(scripted_fixture.simulator as Node).call(
			"get_schedule_decision_debug_descriptor",
			&"mom"
		).is_empty(),
		"scripted ownership clears stale schedule observability"
	)
	assert_eq((scripted_fixture.locations as ScheduleLocations).begin_calls, 0, "scripted state is untouched")
	var emergency_fixture := _live_fixture("Fight")
	_call_try_start(emergency_fixture, 305.25)
	assert_eq((emergency_fixture.locations as ScheduleLocations).begin_calls, 0, "emergency is untouched")
	var continuation_fixture := _live_fixture("Work")
	(continuation_fixture.machine as ScheduleMachine).same_activity = true
	_call_try_start(continuation_fixture, 304.1)
	assert_eq(
		(continuation_fixture.locations as ScheduleLocations).begin_calls,
		1,
		"exact same activity continuation is not treated as interruption"
	)


func test_offscreen_free_npc_starts_at_opening() -> void:
	var fixture := _live_fixture("Idle", false)
	_call_try_start(fixture, 304.0)
	var locations := fixture.locations as ScheduleLocations
	assert_eq(locations.begin_calls, 1, "free offscreen NPC starts at window opening")
	assert_eq(locations.begun_activity.schedule_phase, "on_time", "offscreen start is on time")


func _live_fixture(state_name: String, include_live_npc: bool = true) -> Dictionary:
	var simulator := WorldSimulation.new()
	add_child_autofree(simulator)
	simulator.set_process(false)
	simulator._social_planning_suppressed = true
	var definition := _definition(&"mom_work", 65, [_flexible_window(16.0, 18.0)])
	simulator.spot_definitions = {definition.spot_id: definition}
	simulator.spot_claim_counts = {}
	simulator.spot_runtime_states = {}
	var machine := ScheduleMachine.new()
	machine.name = "NpcStateMachine"
	machine.set_state_name(state_name)
	var npc := ScheduleNpc.new()
	npc.persistent_id = "mom"
	npc.add_child(machine)
	add_child_autofree(npc)
	var locations := ScheduleLocations.new()
	locations.live_npc = npc if include_live_npc else null
	add_child_autofree(locations)
	var record := _record()
	return {
		"simulator": simulator,
		"locations": locations,
		"machine": machine,
		"npc": npc,
		"record": record,
	}


func _call_try_start(fixture: Dictionary, total_hours: float) -> void:
	var record: Dictionary = fixture.record
	(fixture.simulator as Node).call(
		"_try_start_activity",
		&"mom",
		record,
		total_hours,
		fposmod(total_hours, 24.0),
		fixture.locations,
		{"mom": record}
	)


func _definition(
	spot_id: StringName,
	priority: int,
	windows: Array[Dictionary]
) -> NpcSpotDefinition:
	var definition := NpcSpotDefinition.new()
	definition.spot_id = spot_id
	definition.scene_path = "res://scenes/testscenes/realtest1.tscn"
	definition.position = Vector2.ZERO
	definition.state_name = &"Work"
	definition.priority = priority
	definition.capacity = 0
	definition.owner_ids = [&"mom"]
	definition.active_time_windows = windows.duplicate(true)
	return definition


func _flexible_window(start_hour: float, end_hour: float) -> Dictionary:
	return {
		"start_hour": start_hour,
		"end_hour": end_hour,
		"start_policy": "flexible",
		"grace_game_minutes": 30.0,
		"late_priority_bonus": 10,
	}


func _record() -> Dictionary:
	return {
		"scene_path": "res://scenes/testscenes/realtest1.tscn",
		"last_position": Vector2.ZERO,
		"activity": {},
		"pending_travel": {},
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"boredom": 80.0,
				"talk_need": 0.0,
			},
			"world_simulation_profile": {
				"social_seeking": {"enabled": false},
			},
		},
	}


func _errors_contain(errors: Array[String], fragment: String) -> bool:
	for error in errors:
		if error.contains(fragment):
			return true
	return false
