extends "res://test/native_scene_tree_test.gd"

const Policy = preload("res://scripts/systems/npc_schedule_window_policy.gd")
const Selector = preload("res://scripts/systems/npc_activity_selector.gd")
const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const WorldSimulation = preload("res://scripts/systems/npc_world_simulation.gd")


class CompletionLocations:
	extends Node

	var updated_record: Dictionary = {}
	var finish_calls: int = 0
	var finished_session_id: String = ""

	func is_npc_live(_npc_id: String) -> bool:
		return false

	func get_live_npc(_npc_id: String) -> Node:
		return null

	func update_simulated_record(_npc_id: String, record: Dictionary) -> void:
		updated_record = record.duplicate(true)

	func finish_scheduled_activity(
		_npc_id: String,
		_return_scene_path: String,
		_return_position: Vector2,
		expected_session_id: String = ""
	) -> bool:
		finish_calls += 1
		finished_session_id = expected_session_id
		return true


class LiveActivityLocations:
	extends Node

	var live_npc: Node2D

	func is_npc_live(_npc_id: String) -> bool:
		return live_npc != null

	func get_live_npc(_npc_id: String) -> Node:
		return live_npc


class LiveActivityFlowProbe:
	extends WorldSimulation

	var resume_calls: int = 0
	var finish_calls: int = 0

	func resume_live_activity(_npc_id: StringName, _npc: Node) -> void:
		resume_calls += 1

	func _finish_activity(
		_npc_id: StringName,
		_record: Dictionary,
		_activity: Dictionary,
		_spot_id: StringName,
		_locations: Node
	) -> void:
		finish_calls += 1


class OwnershipMachine:
	extends Node

	var current_state: Node
	var feedback_calls: int = 0
	var protected: bool = false

	func get_scheduled_activity_ownership_gate() -> Dictionary:
		return {"protected": protected, "reason_code": &"test"}

	func get_feedback_descriptor() -> Dictionary:
		feedback_calls += 1
		return {"intent": {"source": "emergency"}}


func test_legacy_completion_defaults_stop_at_window_end_and_validate() -> void:
	var definition := _definition(&"legacy", [_window(false)])
	var decision := Policy.evaluate_definition(definition, 305.5)
	assert_eq(
		decision.completion_policy,
		Policy.COMPLETION_POLICY_STOP_AT_WINDOW_END,
		"legacy completion defaults to stop-at-window-end"
	)
	var activity := _activity_from_decision(decision, "legacy-session")
	var continuation := Policy.evaluate_active_activity(definition, activity, 306.0)
	assert_false(bool(continuation.may_continue), "legacy activity stops at exact end")
	assert_eq(continuation.reason_code, &"window_closed", "legacy close reason is explicit")

	definition.active_time_windows[0]["completion_policy"] = "forever"
	definition.active_time_windows[0]["maximum_overtime_game_minutes"] = -1.0
	var errors := definition.get_validation_errors()
	assert_true(_errors_contain(errors, "completion_policy"), "unknown completion policy is invalid")
	assert_true(_errors_contain(errors, "maximum_overtime"), "negative overtime is invalid")
	definition.active_time_windows[0]["maximum_overtime_game_minutes"] = 241.0
	assert_true(
		_errors_contain(definition.get_validation_errors(), "safe maximum"),
		"overtime is conservatively bounded"
	)


func test_finish_current_continues_only_until_bounded_overtime_deadline() -> void:
	var definition := _definition(&"mom_work", [_window(true)])
	var decision := Policy.evaluate_definition(definition, 305.8)
	var activity := _activity_from_decision(decision, "overtime-session")
	var inside := Policy.evaluate_active_activity(definition, activity, 305.9)
	assert_true(bool(inside.may_continue), "committed activity continues inside window")
	assert_eq(inside.reason_code, &"inside_window", "inside-window reason is explicit")
	var overtime := Policy.evaluate_active_activity(definition, activity, 306.2)
	assert_true(bool(overtime.may_continue), "finish-current continues in overtime")
	assert_eq(overtime.reason_code, &"finishing_current_activity", "overtime reason is explicit")
	assert_true(bool(overtime.in_overtime), "overtime phase is structured")
	assert_float_close(float(overtime.overtime_remaining_game_hours), 0.3, 0.0001)
	var expired := Policy.evaluate_active_activity(definition, activity, 306.5)
	assert_false(bool(expired.may_continue), "activity stops at exact overtime deadline")
	assert_eq(expired.reason_code, &"overtime_expired", "deadline reason is explicit")


func test_normal_spot_completion_remains_authoritative_during_overtime() -> void:
	var fixture := _simulator_fixture()
	var simulator: Node = fixture.simulator
	var definition: NpcSpotDefinition = fixture.definition
	var activity := _activity_from_decision(
		Policy.evaluate_definition(definition, 305.8),
		"completed-session"
	)
	simulator.spot_runtime_states[String(definition.spot_id)]["value"] = 0.0
	assert_false(
		bool(simulator.call(
			"_activity_can_continue",
			&"mom",
			_record(activity),
			definition,
			activity,
			306.2,
			18.2
		)),
		"normal spot completion ends work even during allowed overtime"
	)


func test_closed_occurrence_cannot_create_a_new_candidate() -> void:
	var fixture := _simulator_fixture()
	var simulator: Node = fixture.simulator
	var definition: NpcSpotDefinition = fixture.definition
	var candidate := Selector.find_best_candidate(
		{definition.spot_id: definition},
		&"mom",
		_record({}),
		306.05,
		simulator
	)
	assert_true(candidate.is_empty(), "finish-current never reopens candidate selection")


func test_cross_midnight_occurrence_keeps_absolute_overtime_context() -> void:
	var definition := _definition(&"overnight_work", [{
		"start_hour": 22.0,
		"end_hour": 1.0,
		"completion_policy": "finish_current",
		"maximum_overtime_game_minutes": 30.0,
	}])
	var decision := Policy.evaluate_definition(definition, 312.5)
	assert_eq(decision.window_start_total_hours, 310.0, "occurrence starts on prior day")
	assert_eq(decision.window_end_total_hours, 313.0, "absolute end crosses midnight")
	assert_eq(decision.overtime_end_total_hours, 313.5, "overtime extends absolute end")
	var activity := _activity_from_decision(decision, "overnight-session")
	var overtime := Policy.evaluate_active_activity(definition, activity, 313.25)
	assert_true(bool(overtime.may_continue), "original cross-midnight occurrence continues")
	assert_eq(overtime.occurrence_key, decision.occurrence_key, "identity is not recalculated")


func test_large_offscreen_jump_clamps_progress_before_overtime_expiry() -> void:
	var fixture := _simulator_fixture()
	var simulator: Node = fixture.simulator
	var definition: NpcSpotDefinition = fixture.definition
	var locations := CompletionLocations.new()
	add_child_autofree(locations)
	var activity := _activity_from_decision(
		Policy.evaluate_definition(definition, 305.9),
		"jump-session"
	)
	activity["last_total_hours"] = 305.9
	activity["reservation_ids"] = ["jump-session:mom_work:activity"]
	var record := _record(activity)
	simulator.call(
		"_update_activity",
		&"mom",
		record,
		activity,
		307.0,
		19.0,
		locations
	)
	assert_float_close(
		float(simulator.spot_runtime_states.mom_work.value),
		40.0,
		0.001,
		"only 0.6 permitted game-hours of work are applied"
	)
	assert_eq(locations.finish_calls, 1, "unfinished activity terminates after clamped progress")
	assert_eq(locations.finished_session_id, "jump-session", "normal finish uses original session")
	assert_float_close(
		float(locations.updated_record.activity.last_total_hours),
		306.5,
		0.0001,
		"offscreen progress endpoint is the overtime deadline"
	)
	assert_eq(
		locations.updated_record.activity.reservation_ids,
		["jump-session:mom_work:activity"],
		"reservation identity is unchanged before terminal cleanup"
	)


func test_valid_live_shower_and_lesson_activities_are_resumed_not_finished() -> void:
	var simulator := LiveActivityFlowProbe.new()
	add_child_autofree(simulator)
	simulator.set_process(false)
	simulator._social_planning_suppressed = true
	var shower := load("res://data/npc_spots/mom_shower.tres") as NpcSpotDefinition
	var lesson := load("res://data/npc_spots/mom_magic_lesson.tres") as NpcSpotDefinition
	assert_not_null(shower, "Mom shower definition loads")
	assert_not_null(lesson, "Mom lesson definition loads")
	if shower == null or lesson == null:
		return
	simulator.spot_definitions = {
		shower.spot_id: shower,
		lesson.spot_id: lesson,
	}
	simulator.spot_runtime_states = {
		"mom_magic_lesson": {
			"value": 1.0,
			"minimum": 0.0,
			"maximum": 1.0,
			"done_threshold": 0.0,
		},
	}
	var locations := LiveActivityLocations.new()
	locations.live_npc = Node2D.new()
	add_child_autofree(locations.live_npc)
	add_child_autofree(locations)

	for case in [
		{"definition": shower, "total_hours": 80.25, "hour": 8.25},
		{"definition": lesson, "total_hours": 87.25, "hour": 15.25},
	]:
		var definition: NpcSpotDefinition = case.definition
		var session_id := "live-%s-session" % String(definition.spot_id)
		var activity := {
			"session_id": session_id,
			"action_session_id": session_id,
			"activity_id": session_id,
			"source": "schedule",
			"status": "active",
			"priority": definition.priority,
			"spot_id": String(definition.spot_id),
			"state_name": String(definition.state_name),
			"target_scene_path": definition.scene_path,
			"target_position": definition.position,
			"return_scene_path": "res://scenes/testscenes/realtest1.tscn",
			"return_position": Vector2.ZERO,
		}
		var record := _record(activity)
		record["scene_path"] = definition.scene_path
		simulator.call(
			"_update_activity",
			&"mom",
			record,
			activity,
			float(case.total_hours),
			float(case.hour),
			locations
		)

	assert_eq(simulator.finish_calls, 0, "valid live activities are not ended by reconciliation")
	assert_eq(simulator.resume_calls, 2, "live shower and lesson sessions both resume")


func test_overtime_context_survives_action_session_without_changing_identity() -> void:
	var definition := _definition(&"mom_work", [_window(true)])
	var activity := _activity_from_decision(
		Policy.evaluate_definition(definition, 305.75),
		"identity-session"
	)
	activity["reservation_ids"] = ["identity-reservation"]
	var session := ActionSession.create(&"mom", &"Work", &"schedule", null, activity)
	var descriptor := session.to_descriptor()
	assert_eq(session.session_id, "identity-session", "session identity remains authoritative")
	assert_eq(descriptor.reservation_ids, ["identity-reservation"], "reservation identity is retained")
	assert_eq(
		descriptor.schedule_completion_policy,
		"finish_current",
		"completion policy propagates through the typed session"
	)
	assert_float_close(
		float(descriptor.schedule_overtime_end_total_hours),
		306.5,
		0.0001,
		"absolute overtime deadline propagates through the session"
	)


func test_live_overtime_transition_is_once_and_restored_overtime_is_silent() -> void:
	var simulator := WorldSimulation.new()
	add_child_autofree(simulator)
	var definition := _definition(&"mom_work", [_window(true)])
	var activity := _activity_from_decision(
		Policy.evaluate_definition(definition, 305.9),
		"transition-session"
	)
	var events := {"count": 0}
	simulator.scheduled_activity_entered_overtime.connect(
		func(_npc_id: StringName, _activity: Dictionary, _decision: Dictionary) -> void:
			events.count += 1
	)
	simulator._schedule_overtime_last_observed_by_session["transition-session"] = 305.9
	simulator._schedule_overtime_last_observed_live_by_session["transition-session"] = true
	var overtime := Policy.evaluate_active_activity(definition, activity, 306.1)
	simulator.call("_observe_schedule_overtime_transition", &"mom", activity, overtime, 306.1, true)
	simulator.call("_observe_schedule_overtime_transition", &"mom", activity, overtime, 306.2, true)
	assert_eq(events.count, 1, "live matching session emits one boundary transition")

	var restored := activity.duplicate(true)
	restored["session_id"] = "restored-session"
	restored["action_session_id"] = "restored-session"
	simulator.call("_observe_schedule_overtime_transition", &"mom", restored, overtime, 306.2, true)
	assert_eq(events.count, 1, "first observation already in overtime is treated as restored history")


func test_schedule_ownership_gate_never_reads_feedback_descriptor() -> void:
	var simulator := WorldSimulation.new()
	add_child_autofree(simulator)
	var machine := OwnershipMachine.new()
	add_child_autofree(machine)
	machine.protected = false
	assert_false(
		bool(simulator.call("_machine_schedule_start_is_emergency_or_scripted", machine)),
		"narrow gameplay gate reports available ownership"
	)
	machine.protected = true
	assert_true(
		bool(simulator.call("_machine_schedule_start_is_emergency_or_scripted", machine)),
		"narrow gameplay gate reports protected ownership"
	)
	assert_eq(machine.feedback_calls, 0, "scheduling never reads presentation descriptors")


func test_only_mom_work_opts_into_bounded_finish_current() -> void:
	var work := load("res://data/npc_spots/mom_work.tres") as NpcSpotDefinition
	assert_not_null(work, "Mom work definition loads")
	if work == null:
		return
	for window in work.active_time_windows:
		assert_eq(window.get("completion_policy", ""), "finish_current", "work may finish current")
		assert_eq(
			float(window.get("maximum_overtime_game_minutes", -1.0)),
			30.0,
			"work overtime remains bounded to thirty game minutes"
		)
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
			assert_false(window.has("completion_policy"), "other Mom schedules remain legacy")


func _simulator_fixture() -> Dictionary:
	var simulator := WorldSimulation.new()
	add_child_autofree(simulator)
	simulator.set_process(false)
	simulator._social_planning_suppressed = true
	var definition := _definition(&"mom_work", [_window(true)])
	definition.spot_value_name = &"work_needed"
	definition.spot_value_initial = 100.0
	definition.spot_value_minimum = 0.0
	definition.spot_value_maximum = 100.0
	definition.spot_value_done_threshold = 0.0
	definition.spot_value_delta_per_game_hour = -100.0
	simulator.spot_definitions = {definition.spot_id: definition}
	simulator.spot_claim_counts = {}
	simulator.spot_runtime_states = {
		"mom_work": {
			"value": 100.0,
			"minimum": 0.0,
			"maximum": 100.0,
			"done_threshold": 0.0,
		}
	}
	return {"simulator": simulator, "definition": definition}


func _definition(spot_id: StringName, windows: Array[Dictionary]) -> NpcSpotDefinition:
	var definition := NpcSpotDefinition.new()
	definition.spot_id = spot_id
	definition.scene_path = "res://scenes/testscenes/realtest1.tscn"
	definition.position = Vector2.ZERO
	definition.state_name = &"Work"
	definition.priority = 65
	definition.capacity = 0
	definition.owner_ids = [&"mom"]
	definition.require_npc_value_threshold = false
	definition.finish_when_npc_value_sated = false
	definition.active_time_windows = windows.duplicate(true)
	return definition


func _window(finish_current: bool) -> Dictionary:
	var window := {
		"start_hour": 16.0,
		"end_hour": 18.0,
		"start_policy": "flexible",
		"grace_game_minutes": 30.0,
		"late_priority_bonus": 10,
	}
	if finish_current:
		window["completion_policy"] = "finish_current"
		window["maximum_overtime_game_minutes"] = 30.0
	return window


func _activity_from_decision(decision: Dictionary, session_id: String) -> Dictionary:
	var metadata := {
		"schedule_phase": String(decision.get("phase", "on_time")),
		"schedule_occurrence_key": String(decision.get("occurrence_key", "")),
		"schedule_window_index": int(decision.get("window_index", -1)),
		"schedule_window_start_total_hours": float(decision.get("window_start_total_hours", 0.0)),
		"schedule_grace_end_total_hours": float(decision.get("grace_end_total_hours", 0.0)),
		"schedule_window_end_total_hours": float(decision.get("window_end_total_hours", 0.0)),
		"schedule_completion_policy": String(decision.get("completion_policy", "stop_at_window_end")),
		"schedule_maximum_overtime_game_hours": float(decision.get("maximum_overtime_game_hours", 0.0)),
		"schedule_overtime_end_total_hours": float(decision.get("overtime_end_total_hours", 0.0)),
	}
	var activity := {
		"session_id": session_id,
		"action_session_id": session_id,
		"activity_id": session_id,
		"source": "schedule",
		"status": "active",
		"priority": int(decision.get("effective_priority", 65)),
		"spot_id": "mom_work" if String(decision.get("occurrence_key", "")).begins_with("mom_work:") else String(decision.get("occurrence_key", "")).get_slice(":", 0),
		"state_name": "Work",
		"target_scene_path": "res://scenes/testscenes/realtest1.tscn",
		"target_position": Vector2.ZERO,
		"return_scene_path": "res://scenes/testscenes/realtest1.tscn",
		"return_position": Vector2.ZERO,
		"metadata": metadata.duplicate(true),
	}
	for key in metadata:
		activity[key] = metadata[key]
	return activity


func _record(activity: Dictionary) -> Dictionary:
	return {
		"scene_path": "res://scenes/testscenes/realtest1.tscn",
		"last_position": Vector2.ZERO,
		"activity": activity,
		"pending_travel": {},
		"action": {},
		"node_state": {"social_stats": {"boredom": 80.0, "hp": 100.0}},
	}


func _errors_contain(errors: Array[String], fragment: String) -> bool:
	for error in errors:
		if error.contains(fragment):
			return true
	return false


func assert_float_close(
	actual: float,
	expected: float,
	tolerance: float,
	message: String = ""
) -> void:
	assert_true(
		absf(actual - expected) <= tolerance,
		("floats differ" if message.is_empty() else message)
			+ " (expected %.6f, got %.6f)" % [expected, actual]
	)
