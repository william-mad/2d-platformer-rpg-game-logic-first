extends SceneTree

const TEST_NPC_ID := "transaction_npc"
const TEST_SPOT_ID := &"transaction_work_spot"
const TEST_NEED_SPOT_ID := &"transaction_need_spot"
const TEST_SCENE_PATH := "res://transaction_activity_test.tscn"

var _failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	func get_npc_location_id() -> StringName:
		return StringName(TEST_NPC_ID)


class RejectingState:
	extends NpcState

	func can_exit_to(_new_state: NpcState, _request_priority: int) -> bool:
		return false


class TestSpot:
	extends Node2D

	func get_world_spot_id() -> StringName:
		return TEST_SPOT_ID


class TestNeedSpot:
	extends Node2D

	func get_world_spot_id() -> StringName:
		return TEST_NEED_SPOT_ID


func _initialize() -> void:
	await process_frame
	var locations := root.get_node_or_null("NpcLocations")
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if locations == null or simulator == null:
		push_error("Transactional activity test requires NPC autoloads.")
		quit(1)
		return

	var original_records: Dictionary = locations.npc_records.duplicate(true)
	var original_live_npcs: Dictionary = locations.live_npcs.duplicate()
	var original_active_scene_path: String = locations.active_scene_path
	var original_definitions: Dictionary = simulator.spot_definitions.duplicate()
	var original_live_spots: Dictionary = simulator.live_spots.duplicate()
	var original_claims: Dictionary = simulator.spot_claim_counts.duplicate()
	var original_reservations: Dictionary = simulator.spot_reservations.duplicate(true)
	var original_current_scene := current_scene
	var simulator_was_processing := simulator.is_processing()
	simulator.set_process(false)

	var test_scene := Node2D.new()
	test_scene.name = "TransactionActivityTestScene"
	test_scene.scene_file_path = TEST_SCENE_PATH
	root.add_child(test_scene)
	current_scene = test_scene
	locations.active_scene_path = TEST_SCENE_PATH

	var npc := TestNpc.new()
	npc.name = "TransactionalNpc"
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var behavior_controller := NpcBehaviorController.new()
	behavior_controller.name = "NpcBehaviorController"
	var rejecting_state := RejectingState.new()
	rejecting_state.name = "Busy"
	rejecting_state.allows_scheduled_activity_interrupt = true
	var work_state := NpcState.new()
	work_state.name = "Work"
	var idle_state := NpcState.new()
	idle_state.name = "Idle"
	var move_state := NpcState.new()
	move_state.name = "MoveToTarget"
	var routine_state := NpcState.new()
	routine_state.name = "RoutineTask"
	machine.add_child(behavior_controller)
	machine.add_child(rejecting_state)
	machine.add_child(work_state)
	machine.add_child(idle_state)
	machine.add_child(move_state)
	machine.add_child(routine_state)
	npc.add_child(machine)
	test_scene.add_child(npc)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [rejecting_state]

	var spot := TestSpot.new()
	spot.name = "TransactionalWorkSpot"
	test_scene.add_child(spot)
	var need_spot := TestNeedSpot.new()
	need_spot.name = "TransactionalNeedSpot"
	test_scene.add_child(need_spot)
	var definition := NpcSpotDefinition.new()
	definition.spot_id = TEST_SPOT_ID
	definition.scene_path = TEST_SCENE_PATH
	definition.state_name = &"Work"
	definition.priority = 20
	definition.capacity = 1
	definition.target_assignment_method = &"assign_work_target"
	simulator.spot_definitions[TEST_SPOT_ID] = definition
	simulator.live_spots[TEST_SPOT_ID] = spot
	var need_definition := NpcSpotDefinition.new()
	need_definition.spot_id = TEST_NEED_SPOT_ID
	need_definition.scene_path = TEST_SCENE_PATH
	need_definition.state_name = &"RoutineTask"
	need_definition.priority = 10
	need_definition.capacity = 1
	simulator.spot_definitions[TEST_NEED_SPOT_ID] = need_definition
	simulator.live_spots[TEST_NEED_SPOT_ID] = need_spot
	simulator.spot_reservations.clear()
	simulator.call("_sync_spot_claim_count_cache")

	locations.npc_records[TEST_NPC_ID] = {
		"npc_id": TEST_NPC_ID,
		"scene_path": TEST_SCENE_PATH,
		"previous_scene_path": "",
		"last_position": Vector2.ZERO,
		"spawn_random": false,
		"activity": {},
		"pending_travel": {},
		"node_state": {},
		"inventory": {},
	}
	locations.live_npcs[TEST_NPC_ID] = npc
	var activity := {
		"spot_id": String(TEST_SPOT_ID),
		"state_name": "Work",
		"target_scene_path": TEST_SCENE_PATH,
		"target_position": Vector2.ZERO,
		"priority": 27,
		"schedule_phase": "late",
		"schedule_occurrence_key": "transaction_work_spot:12:0",
		"schedule_window_index": 0,
		"schedule_window_start_total_hours": 304.0,
		"schedule_grace_end_total_hours": 304.5,
		"schedule_window_end_total_hours": 306.0,
		"schedule_lateness_game_hours": 0.75,
		"schedule_base_priority": 20,
		"schedule_effective_priority": 27,
		"schedule_completion_policy": "finish_current",
		"schedule_maximum_overtime_game_hours": 0.5,
		"schedule_overtime_end_total_hours": 306.5,
		"metadata": {
			"schedule_phase": "late",
			"schedule_occurrence_key": "transaction_work_spot:12:0",
			"schedule_window_index": 0,
			"schedule_window_start_total_hours": 304.0,
			"schedule_grace_end_total_hours": 304.5,
			"schedule_window_end_total_hours": 306.0,
			"schedule_lateness_game_hours": 0.75,
			"schedule_base_priority": 20,
			"schedule_effective_priority": 27,
			"schedule_completion_policy": "finish_current",
			"schedule_maximum_overtime_game_hours": 0.5,
			"schedule_overtime_end_total_hours": 306.5,
		},
	}

	var rejected := bool(locations.call(
		"begin_scheduled_activity",
		TEST_NPC_ID,
		activity,
		TEST_SCENE_PATH,
		Vector2.ZERO
	))
	_expect(not rejected, "live assignment rejection is returned")
	var rejected_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		(rejected_record.get("activity", {}) as Dictionary).is_empty(),
		"rejected live assignment does not commit record activity"
	)
	_expect(
		(rejected_record.get("action", {}) as Dictionary).is_empty(),
		"rejected live assignment does not commit an action descriptor"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"rejected live assignment releases its temporary spot claim"
	)
	_expect(machine.current_state == rejecting_state, "rejected assignment leaves the live state unchanged")

	var legacy_activity := activity.duplicate(true)
	legacy_activity["session_id"] = "legacy-resume-session"
	legacy_activity["action_session_id"] = "legacy-resume-session"
	var legacy_claim: Dictionary = simulator.call(
		"try_claim_spot",
		StringName(TEST_NPC_ID),
		"legacy-resume-session",
		TEST_SPOT_ID,
		&"activity"
	)
	legacy_activity["reservation_ids"] = [String(legacy_claim.get("reservation_id", ""))]
	var legacy_committed_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	legacy_committed_record["activity"] = legacy_activity
	locations.npc_records[TEST_NPC_ID] = legacy_committed_record
	simulator.call("resume_live_activity", StringName(TEST_NPC_ID), npc)
	var rolled_back_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		(rolled_back_record.get("activity", {}) as Dictionary).is_empty(),
		"a previously committed offscreen activity is cleared when live acceptance fails"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"live-resume rejection releases the offscreen activity claim"
	)

	machine.state_history = [work_state]
	machine.work_target = spot
	var accepted := bool(locations.call(
		"begin_scheduled_activity",
		TEST_NPC_ID,
		activity,
		TEST_SCENE_PATH,
		Vector2.ZERO
	))
	_expect(accepted, "already-following live activity is committed")
	var accepted_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		String((accepted_record.get("activity", {}) as Dictionary).get("spot_id", "")) == String(TEST_SPOT_ID),
		"accepted live assignment commits record activity"
	)
	var accepted_activity: Dictionary = accepted_record.get("activity", {})
	var accepted_action: Dictionary = accepted_record.get("action", {})
	var accepted_session_id := String(accepted_activity.get("session_id", ""))
	_expect(not accepted_session_id.is_empty(), "accepted activity has a stable session ID")
	_expect(
		String(accepted_action.get("session_id", "")) == accepted_session_id,
		"persistent action and compatibility activity share one session ID"
	)
	_expect(
		machine.get_active_action_session_id() == accepted_session_id,
		"live state machine and persistent record share one session ID"
	)
	_expect(
		int(accepted_action.get("priority", -1)) == 27,
		"effective schedule priority reaches the persistent action"
	)
	_expect(
		String((accepted_action.get("metadata", {}) as Dictionary).get(
			"schedule_occurrence_key", ""
		)) == "transaction_work_spot:12:0",
		"persistent action retains copied schedule occurrence context"
	)
	_expect(
		String(accepted_action.get("schedule_occurrence_key", ""))
			== "transaction_work_spot:12:0",
		"typed action descriptor exposes copied schedule context"
	)
	_expect(
		String(accepted_action.get("schedule_completion_policy", ""))
			== "finish_current"
		and is_equal_approx(
			float(accepted_action.get("schedule_overtime_end_total_hours", 0.0)),
			306.5
		),
		"persistent action retains completion policy and absolute overtime deadline"
	)
	var accepted_intent: Dictionary = (
		machine.behavior_controller.get_current_intent_descriptor()
		if machine.behavior_controller != null
		else {}
	)
	_expect(
		String((accepted_intent.get("metadata", {}) as Dictionary).get(
			"schedule_occurrence_key", ""
		)) == "transaction_work_spot:12:0",
		"accepted behavior intention receives the same schedule context"
	)
	_expect(
		String((accepted_intent.get("metadata", {}) as Dictionary).get(
			"schedule_completion_policy", ""
		)) == "finish_current",
		"accepted behavior intention receives completion context"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
		"accepted live assignment retains exactly one spot claim"
	)
	_expect(bool(locations.call(
		"begin_scheduled_activity",
		TEST_NPC_ID,
		accepted_activity,
		TEST_SCENE_PATH,
		Vector2.ZERO
	)), "same-session proposal retry is accepted")
	var refreshed_action: Dictionary = machine.get_active_action_descriptor()
	_expect(
		String((refreshed_action.get("metadata", {}) as Dictionary).get(
			"schedule_occurrence_key", ""
		)) == "transaction_work_spot:12:0",
		"same-session refresh preserves the occurrence key"
	)
	_expect(
		is_equal_approx(float((refreshed_action.get("metadata", {}) as Dictionary).get(
			"schedule_overtime_end_total_hours", 0.0
		)), 306.5),
		"same-session refresh preserves the overtime deadline"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
		"same-session proposal retry does not double claim"
	)
	locations.call("set_scheduled_activity_field", TEST_NPC_ID, &"lesson_phase", "teaching")
	locations.call("set_scheduled_activity_field", TEST_NPC_ID, &"lesson_phase", "scoring")
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
		"multi-phase activity updates retain one reservation"
	)
	_expect(
		machine.request_state(
			&"Idle", null, "scheduled_execution_cycle_complete", definition.priority
		),
		"live scheduled execution can complete into Idle"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
		"live execution completion preserves the matching persistent activity reservation"
	)
	for repair_pass in range(3):
		simulator.call(
			"repair_orphan_spot_reservations", locations.get_records_snapshot()
		)
		_expect(
			int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
			"repair pass %d finds the persistent activity reservation intact" % repair_pass
		)
	var competing_need_action := {
		"session_id": "transaction-need-routine",
		"action_session_id": "transaction-need-routine",
		"activity_id": "transaction-need-routine",
		"action_kind": "RoutineTask",
		"state_name": "RoutineTask",
		"source": "need",
		"priority": 10,
		"status": "proposed",
	}
	_expect(
		not machine.request_action_from_descriptor(competing_need_action, need_spot),
		"an autonomous need cannot replace an authoritative scheduled activity between execution cycles"
	)
	var protected_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		String((protected_record.get("activity", {}) as Dictionary).get(
			"session_id", ""
		)) == accepted_session_id,
		"blocked autonomous need leaves the persistent activity authoritative"
	)
	simulator.call(
		"repair_orphan_spot_reservations", locations.get_records_snapshot()
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
		"blocked autonomous need creates no orphan reservation repair"
	)
	simulator.call("resume_live_activity", StringName(TEST_NPC_ID), npc)
	_expect(
		machine.get_active_action_session_id() == accepted_session_id,
		"persistent activity resumes the same live action session"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
		"same-session live resume retains exactly one reservation"
	)

	var stale_finished := bool(locations.call(
		"finish_scheduled_activity",
		TEST_NPC_ID,
		TEST_SCENE_PATH,
		Vector2.ZERO,
		"stale-session"
	))
	_expect(not stale_finished, "stale completion cannot finish the active action")
	_expect(
		String((locations.get_record_snapshot(TEST_NPC_ID).get("activity", {}) as Dictionary).get(
			"session_id", ""
		)) == accepted_session_id,
		"stale completion leaves the current persistent action unchanged"
	)

	var finished := bool(locations.call(
		"finish_scheduled_activity",
		TEST_NPC_ID,
		TEST_SCENE_PATH,
		Vector2.ZERO,
		accepted_session_id
	))
	_expect(finished, "committed activity can finish")
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"finishing the activity releases its committed claim"
	)

	machine.state_history = [rejecting_state]
	var pending_before: Dictionary = locations.get_record_snapshot(TEST_NPC_ID).get("pending_travel", {})
	var travel_rejected := bool(locations.call(
		"prepare_scheduled_travel",
		TEST_NPC_ID,
		{
			"mode": "start",
			"target_scene_path": "res://other_scene.tscn",
			"requested_state_name": "Work",
			"activity": activity,
		},
		spot
	))
	_expect(not travel_rejected, "rejected scheduled movement is returned")
	var pending_after: Dictionary = locations.get_record_snapshot(TEST_NPC_ID).get("pending_travel", {})
	_expect(pending_before == pending_after, "rejected movement does not commit pending travel")

	await _test_save_repair_is_session_safe(
		locations, machine, npc, spot, idle_state, work_state
	)
	_test_stale_resume_rejects_replaced_live_body(
		locations, simulator, machine, npc, spot, idle_state
	)
	_test_permitted_supersession_releases_activity_claim(
		locations, simulator, npc
	)

	locations.npc_records = original_records
	locations.live_npcs = original_live_npcs
	locations.active_scene_path = original_active_scene_path
	simulator.spot_definitions = original_definitions
	simulator.live_spots = original_live_spots
	simulator.spot_reservations = original_reservations
	simulator.call("_sync_spot_claim_count_cache")
	_expect(simulator.spot_claim_counts == original_claims, "reservation cache restores exactly")
	simulator.set_process(simulator_was_processing)
	current_scene = original_current_scene
	test_scene.queue_free()
	await process_frame

	if _failures.is_empty():
		print("Scheduled activity transaction runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_permitted_supersession_releases_activity_claim(
	locations: Node,
	simulator: Node,
	npc: Node
) -> void:
	var scheduled_session := "transaction-superseded-schedule"
	var claim: Dictionary = simulator.call(
		"try_claim_spot",
		StringName(TEST_NPC_ID),
		scheduled_session,
		TEST_SPOT_ID,
		&"activity"
	)
	_expect(bool(claim.get("accepted", false)), "supersession fixture owns its spot")
	var record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	record["activity"] = {
		"session_id": scheduled_session,
		"action_session_id": scheduled_session,
		"activity_id": scheduled_session,
		"spot_id": String(TEST_SPOT_ID),
		"state_name": "Work",
		"source": "schedule",
		"status": "active",
	}
	locations.npc_records[TEST_NPC_ID] = record
	var emergency_action := {
		"session_id": "transaction-emergency-replacement",
		"action_session_id": "transaction-emergency-replacement",
		"activity_id": "transaction-emergency-replacement",
		"action_kind": "DisabledDead",
		"state_name": "DisabledDead",
		"source": "emergency",
		"status": "active",
	}
	_expect(
		bool(locations.call(
			"sync_live_action_descriptor", TEST_NPC_ID, npc, emergency_action
		)),
		"permitted replacement synchronizes at the record boundary"
	)
	var replaced_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		(replaced_record.get("activity", {}) as Dictionary).is_empty(),
		"permitted replacement clears the superseded scheduled activity"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"permitted replacement releases the superseded claim immediately"
	)


func _test_save_repair_is_session_safe(
	locations: Node,
	machine: NpcStateMachine,
	npc: TestNpc,
	spot: TestSpot,
	idle_state: NpcState,
	work_state: NpcState
) -> void:
	_clear_active_action(machine, "save_repair_fixture_reset")
	machine.state_history = [idle_state]
	locations.live_npcs[TEST_NPC_ID] = npc

	var repaired_session := "save-repair-old-session"
	var repaired_action := _make_work_action(repaired_session)
	# This fixture exercises location repair, not reservation ownership.
	repaired_action["spot_id"] = ""
	repaired_action["target_persistent_id"] = ""
	_expect(
		machine.restore_action_descriptor(repaired_action),
		"save-repair fixture restores its old live action"
	)
	var repaired_activity := _make_work_activity(repaired_session)
	repaired_activity["target_scene_path"] = "res://save_repair_mismatched_scene.tscn"
	repaired_activity["return_scene_path"] = TEST_SCENE_PATH
	repaired_activity["return_position"] = Vector2(12.0, 34.0)
	var broken_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	broken_record["scene_path"] = TEST_SCENE_PATH
	broken_record["activity"] = repaired_activity
	broken_record["action"] = repaired_action
	broken_record["pending_travel"] = {}
	locations.npc_records[TEST_NPC_ID] = broken_record

	locations.synchronize_live_records()
	var repaired_snapshot: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		(repaired_snapshot.get("activity", {}) as Dictionary).is_empty(),
		"save repair clears the mismatched activity immediately"
	)
	_expect(
		(repaired_snapshot.get("action", {}) as Dictionary).is_empty(),
		"save repair does not recapture the old live action into the save snapshot"
	)
	_expect(
		(repaired_snapshot.get("pending_travel", {}) as Dictionary).is_empty(),
		"save repair leaves no stale pending travel"
	)

	var replacement_session := "save-repair-new-session"
	var observed_states: Array[String] = []
	var state_callback := func(state_name: StringName, _previous_state_name: StringName) -> void:
		observed_states.append(String(state_name))
	machine.state_changed.connect(state_callback)
	_expect(
		machine.request_action_from_descriptor(
			_make_work_action(replacement_session), spot
		),
		"a newer action can start before deferred save repair runs"
	)
	_expect(machine.current_state == work_state, "the newer action enters Work")
	observed_states.clear()
	await process_frame
	_expect(
		machine.get_active_action_session_id() == replacement_session,
		"deferred save repair preserves the newer action session"
	)
	_expect(
		machine.current_state == work_state and not observed_states.has("Idle"),
		"deferred save repair cannot force a newer action through Idle"
	)
	if machine.state_changed.is_connected(state_callback):
		machine.state_changed.disconnect(state_callback)
	_clear_active_action(machine, "save_repair_fixture_cleanup")
	machine.state_history = [idle_state]
	var cleaned_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	cleaned_record["activity"] = {}
	cleaned_record["action"] = {}
	cleaned_record["pending_travel"] = {}
	locations.npc_records[TEST_NPC_ID] = cleaned_record


func _test_stale_resume_rejects_replaced_live_body(
	locations: Node,
	simulator: Node,
	machine: NpcStateMachine,
	stale_npc: TestNpc,
	spot: TestSpot,
	idle_state: NpcState
) -> void:
	_clear_active_action(machine, "stale_resume_fixture_reset")
	machine.state_history = [idle_state]
	var session_id := "stale-resume-live-body"
	var claim: Dictionary = simulator.call(
		"try_claim_spot",
		StringName(TEST_NPC_ID),
		session_id,
		TEST_SPOT_ID,
		&"activity"
	)
	_expect(bool(claim.get("accepted", false)), "stale-resume fixture owns its spot")
	var reservation_id := String(claim.get("reservation_id", ""))
	var activity := _make_work_activity(session_id)
	activity["reservation_ids"] = [reservation_id]
	var action := _make_work_action(session_id)
	action["reservation_ids"] = [reservation_id]
	var routed_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	routed_record["scene_path"] = TEST_SCENE_PATH
	routed_record["activity"] = activity
	routed_record["action"] = action
	routed_record["pending_travel"] = {}
	locations.npc_records[TEST_NPC_ID] = routed_record

	var replacement_npc := TestNpc.new()
	replacement_npc.name = "ReplacementTransactionalNpc"
	current_scene.add_child(replacement_npc)
	locations.live_npcs[TEST_NPC_ID] = replacement_npc
	var pristine_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	simulator.call("resume_live_activity", StringName(TEST_NPC_ID), stale_npc)
	_expect(
		machine.current_state == idle_state
		and machine.get_active_action_session_id().is_empty(),
		"a stale deferred resume cannot assign activity to a replaced live body"
	)
	_expect(
		locations.get_record_snapshot(TEST_NPC_ID) == pristine_record,
		"a stale deferred resume leaves the canonical replacement record unchanged"
	)

	locations.live_npcs[TEST_NPC_ID] = stale_npc
	if not reservation_id.is_empty():
		simulator.call(
			"release_spot_reservation",
			reservation_id,
			StringName(TEST_NPC_ID),
			session_id
		)
	_clear_active_action(machine, "stale_resume_fixture_cleanup")
	var cleaned_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	cleaned_record["activity"] = {}
	cleaned_record["action"] = {}
	cleaned_record["pending_travel"] = {}
	locations.npc_records[TEST_NPC_ID] = cleaned_record
	replacement_npc.queue_free()


func _make_work_activity(session_id: String) -> Dictionary:
	return {
		"session_id": session_id,
		"action_session_id": session_id,
		"activity_id": session_id,
		"spot_id": String(TEST_SPOT_ID),
		"state_name": "Work",
		"value_name": "",
		"source": "schedule",
		"priority": 20,
		"status": "active",
		"target_scene_path": TEST_SCENE_PATH,
		"target_position": Vector2.ZERO,
		"return_scene_path": TEST_SCENE_PATH,
		"return_position": Vector2.ZERO,
		"reservation_ids": [],
	}


func _make_work_action(session_id: String) -> Dictionary:
	return {
		"session_id": session_id,
		"action_session_id": session_id,
		"activity_id": session_id,
		"action_kind": "Work",
		"state_name": "Work",
		"source": "schedule",
		"spot_id": String(TEST_SPOT_ID),
		"target_persistent_id": String(TEST_SPOT_ID),
		"scene_path": TEST_SCENE_PATH,
		"priority": 20,
		"phase": "executing",
		"status": "active",
		"reservation_ids": [],
	}


func _clear_active_action(machine: NpcStateMachine, reason: String) -> void:
	var session_id := machine.get_active_action_session_id()
	if session_id.is_empty():
		return
	if machine.cancel_active_action(session_id, reason):
		machine.clear_terminal_action(session_id)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
