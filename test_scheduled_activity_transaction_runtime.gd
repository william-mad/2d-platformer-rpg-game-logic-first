extends SceneTree

const TEST_NPC_ID := "transaction_npc"
const TEST_SPOT_ID := &"transaction_work_spot"
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
	var rejecting_state := RejectingState.new()
	rejecting_state.name = "Busy"
	rejecting_state.allows_scheduled_activity_interrupt = true
	var work_state := NpcState.new()
	work_state.name = "Work"
	var move_state := NpcState.new()
	move_state.name = "MoveToTarget"
	machine.add_child(rejecting_state)
	machine.add_child(work_state)
	machine.add_child(move_state)
	npc.add_child(machine)
	test_scene.add_child(npc)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [rejecting_state]

	var spot := TestSpot.new()
	spot.name = "TransactionalWorkSpot"
	test_scene.add_child(spot)
	var definition := NpcSpotDefinition.new()
	definition.spot_id = TEST_SPOT_ID
	definition.scene_path = TEST_SCENE_PATH
	definition.state_name = &"Work"
	definition.priority = 20
	definition.capacity = 1
	definition.target_assignment_method = &"assign_work_target"
	simulator.spot_definitions[TEST_SPOT_ID] = definition
	simulator.live_spots[TEST_SPOT_ID] = spot
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
