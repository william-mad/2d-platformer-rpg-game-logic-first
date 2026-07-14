extends SceneTree

const TEST_NPC_ID := "magic_lesson_test_mom"
const TEST_SESSION_ID := "magic-lesson-session"
const TEST_SPOT_ID := &"magic_lesson_test_spot"
const TEST_SCENE_PATH := "res://magic_lesson_lifecycle_test.tscn"
const LESSON_SCENE_PATH := "res://scenes/testscenes/realhometest.tscn"

var _failures: Array[String] = []
var _cancellation_count: int = 0


class TestMom:
	extends CharacterBody2D

	func get_npc_location_id() -> StringName:
		return StringName(TEST_NPC_ID)


class TestPlayer:
	extends CharacterBody2D

	var begin_count: int = 0
	var end_count: int = 0

	func begin_spot_action(_owner: Node, _action: StringName) -> void:
		begin_count += 1

	func end_spot_action(_owner: Node, _action: StringName, _completed: bool) -> void:
		end_count += 1


class TestRemoteInvitation:
	extends MagicLessonRemoteInvitation

	var travel_called: bool = false
	var transfer_was_committed_before_travel: bool = false

	func _move_player_to_lesson_scene(_player: Node2D) -> bool:
		travel_called = true
		var locations := get_node_or_null("/root/NpcLocations")
		if locations != null:
			var record: Dictionary = locations.call("get_record_snapshot", active_mom_id)
			var activity = record.get("activity", {})
			transfer_was_committed_before_travel = (
				activity is Dictionary
				and String(activity.get("lesson_phase", "")) == "handoff"
				and String(record.get("scene_path", "")) == lesson_scene_path
			)
		return true


func _initialize() -> void:
	await process_frame
	var locations := root.get_node_or_null("NpcLocations")
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if locations == null or simulator == null:
		push_error("Magic lesson lifecycle test requires NPC autoloads.")
		quit(1)
		return

	var original_records: Dictionary = locations.npc_records.duplicate(true)
	var original_live_npcs: Dictionary = locations.live_npcs.duplicate()
	var original_active_scene_path: String = locations.active_scene_path
	var original_reservations: Dictionary = simulator.spot_reservations.duplicate(true)
	var original_live_spots: Dictionary = simulator.live_spots.duplicate()
	var original_scene := current_scene
	var simulator_was_processing := simulator.is_processing()
	simulator.set_process(false)

	var test_scene := Node2D.new()
	test_scene.name = "MagicLessonLifecycleTest"
	test_scene.scene_file_path = TEST_SCENE_PATH
	root.add_child(test_scene)
	current_scene = test_scene
	locations.active_scene_path = TEST_SCENE_PATH

	var mom := TestMom.new()
	mom.name = "LessonMom"
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	mom.add_child(machine)
	test_scene.add_child(mom)
	var player := TestPlayer.new()
	player.name = "LessonPlayer"
	player.add_to_group("player")
	test_scene.add_child(player)
	var lesson_spot := MagicLessonSpot.new()
	lesson_spot.name = "LessonSpot"
	lesson_spot.spot_id = TEST_SPOT_ID
	lesson_spot.require_player_in_lesson_zone = false
	test_scene.add_child(lesson_spot)

	simulator.spot_reservations.clear()
	simulator.call("_sync_spot_claim_count_cache")
	var claim: Dictionary = simulator.call(
		"try_claim_spot",
		StringName(TEST_NPC_ID),
		TEST_SESSION_ID,
		TEST_SPOT_ID,
		&"activity"
	)
	var reservation_id := String(claim.get("reservation_id", ""))
	var activity := {
		"session_id": TEST_SESSION_ID,
		"action_session_id": TEST_SESSION_ID,
		"activity_id": TEST_SESSION_ID,
		"state_name": "InvitePlayer",
		"source": "schedule",
		"priority": 40,
		"status": "active",
		"spot_id": String(TEST_SPOT_ID),
		"lesson_phase": "inviting",
		"target_scene_path": TEST_SCENE_PATH,
		"target_position": Vector2.ZERO,
		"return_scene_path": TEST_SCENE_PATH,
		"return_position": Vector2.ZERO,
		"reservation_ids": [reservation_id],
	}
	var session := NpcActionSession.create(
		TEST_NPC_ID, &"InvitePlayer", &"schedule", lesson_spot, activity
	)
	session.status = NpcActionSession.Status.ACTIVE
	session.phase = &"executing"
	machine.active_action = session
	locations.npc_records[TEST_NPC_ID] = {
		"npc_id": TEST_NPC_ID,
		"scene_path": TEST_SCENE_PATH,
		"home_scene_path": TEST_SCENE_PATH,
		"home_position": Vector2.ZERO,
		"last_position": Vector2.ZERO,
		"activity": activity.duplicate(true),
		"action": session.to_descriptor(),
		"pending_travel": {},
		"node_state": {},
		"inventory": {},
	}
	locations.live_npcs[TEST_NPC_ID] = mom

	var definition := NpcSpotDefinition.new()
	definition.spot_id = TEST_SPOT_ID
	definition.scene_path = LESSON_SCENE_PATH
	definition.position = Vector2(32.0, 48.0)
	definition.state_name = &"InvitePlayer"
	var remote := TestRemoteInvitation.new()
	remote.name = "RemoteLessonInvitation"
	test_scene.add_child(remote)
	remote.configure(definition, activity)
	remote.active_mom = mom
	remote.active_player = player
	remote.active_mom_id = TEST_NPC_ID
	remote.invitation_scene_path = TEST_SCENE_PATH
	remote.invitation_position = mom.global_position
	remote.state = &"inviting"
	_expect(remote.accept_lesson(mom, player), "remote acceptance transaction succeeds")
	_expect(remote.travel_called, "player travel begins after accepted handoff")
	_expect(
		remote.transfer_was_committed_before_travel,
		"Mom's persistent transfer commits before player travel"
	)
	var handoff_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		String((handoff_record.get("activity", {}) as Dictionary).get("session_id", "")) == TEST_SESSION_ID,
		"handoff preserves the action session"
	)
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 1,
		"handoff preserves exactly one reservation"
	)
	_expect(
		String(((handoff_record.get("action", {}) as Dictionary).get("metadata", {}) as Dictionary).get(
			"lesson_phase", ""
		)) == "handoff",
		"handoff updates action metadata atomically"
	)
	_expect(
		String(handoff_record.get("scene_path", "")) == LESSON_SCENE_PATH,
		"remote handoff relocates Mom's record to the lesson scene"
	)
	var legacy_handoff_record := handoff_record.duplicate(true)
	var legacy_action: Dictionary = legacy_handoff_record.get("action", {})
	legacy_action.erase("metadata")
	legacy_handoff_record["action"] = legacy_action
	var normalized_handoff: Dictionary = locations.call(
		"_normalize_loaded_record", TEST_NPC_ID, legacy_handoff_record
	)
	_expect(
		String(((normalized_handoff.get("action", {}) as Dictionary).get("metadata", {}) as Dictionary).get(
			"lesson_phase", ""
		)) == "handoff",
		"save normalization restores lesson phase into action metadata"
	)

	var local_mom := TestMom.new()
	local_mom.name = "LocalLessonMom"
	var local_machine := NpcStateMachine.new()
	local_machine.name = "NpcStateMachine"
	local_machine.active = false
	local_mom.add_child(local_machine)
	test_scene.add_child(local_mom)
	var local_action := NpcActionSession.create(
		TEST_NPC_ID,
		&"InvitePlayer",
		&"schedule",
		lesson_spot,
		handoff_record.get("action", {})
	)
	local_action.status = NpcActionSession.Status.ACTIVE
	local_machine.active_action = local_action
	locations.live_npcs[TEST_NPC_ID] = local_mom

	var start_result: Dictionary = lesson_spot.start_lesson(local_mom, player, TEST_SESSION_ID)
	_expect(bool(start_result.get("accepted", false)), "local lesson starts under the handoff session")
	_expect(lesson_spot.get_lesson_state() == &"running", "local controller enters running")
	_expect(
		String((locations.get_record_snapshot(TEST_NPC_ID).get("activity", {}) as Dictionary).get(
			"lesson_phase", ""
		)) == "running",
		"running is persisted only after local startup"
	)

	_expect(
		not lesson_spot.complete_lesson("stale-lesson-session"),
		"stale completion cannot finish the current lesson"
	)
	_expect(
		NpcActionSession._descriptor_session_id(
			locations.get_record_snapshot(TEST_NPC_ID).get("activity", {})
		) == TEST_SESSION_ID,
		"stale completion leaves the newer activity intact"
	)

	lesson_spot.lesson_cancelled.connect(func(_reason: StringName) -> void:
		_cancellation_count += 1
	)
	_expect(lesson_spot.cancel_lesson(&"test_cancel", TEST_SESSION_ID), "current lesson cancels")
	_expect(not lesson_spot.cancel_lesson(&"repeat_cancel", TEST_SESSION_ID), "repeat cancellation is harmless")
	_expect(_cancellation_count == 1, "cancellation signal emits exactly once")
	_expect(player.end_count == 1, "participant controls unlock exactly once")
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"terminal cancellation releases the lesson reservation"
	)

	var failed_transfer_activity := activity.duplicate(true)
	failed_transfer_activity["session_id"] = "newer-session"
	failed_transfer_activity["action_session_id"] = "newer-session"
	failed_transfer_activity["activity_id"] = "newer-session"
	failed_transfer_activity["reservation_ids"] = []
	locations.npc_records[TEST_NPC_ID]["activity"] = failed_transfer_activity
	locations.npc_records[TEST_NPC_ID]["action"] = {}
	var player_position_before := player.global_position
	var failed_remote := TestRemoteInvitation.new()
	failed_remote.name = "FailedRemoteLessonInvitation"
	test_scene.add_child(failed_remote)
	failed_remote.configure(definition, activity)
	failed_remote.active_mom = local_mom
	failed_remote.active_player = player
	failed_remote.active_mom_id = TEST_NPC_ID
	failed_remote.invitation_scene_path = TEST_SCENE_PATH
	failed_remote.invitation_position = local_mom.global_position
	failed_remote.state = &"inviting"
	_expect(
		not failed_remote.accept_lesson(local_mom, player),
		"stale remote activity transfer is rejected"
	)
	_expect(not failed_remote.travel_called, "rejected transfer never starts player travel")
	_expect(failed_remote.state == &"failed", "rejected handoff becomes terminally failed")
	_expect(player.global_position == player_position_before, "rejected transfer does not move the player")
	_expect(
		int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"rejected stale handoff does not leak or manufacture a reservation"
	)
	_expect(
		String((locations.get_record_snapshot(TEST_NPC_ID).get("activity", {}) as Dictionary).get(
			"lesson_phase", ""
		)) == "inviting",
		"rejected transfer has no activity side effects"
	)

	locations.npc_records = original_records
	locations.live_npcs = original_live_npcs
	locations.active_scene_path = original_active_scene_path
	simulator.spot_reservations = original_reservations
	simulator.live_spots = original_live_spots
	simulator.call("_sync_spot_claim_count_cache")
	simulator.set_process(simulator_was_processing)
	current_scene = original_scene
	test_scene.queue_free()
	await process_frame

	if _failures.is_empty():
		print("Magic lesson lifecycle runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
