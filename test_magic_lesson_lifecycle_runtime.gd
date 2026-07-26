extends SceneTree

const TEST_NPC_ID := "magic_lesson_test_mom"
const TEST_SESSION_ID := "magic-lesson-session"
const COMPLETION_SESSION_ID := "magic-lesson-completion-session"
const TEST_SPOT_ID := &"magic_lesson_test_spot"
const TEST_SCENE_PATH := "res://magic_lesson_lifecycle_test.tscn"
const LESSON_SCENE_PATH := "res://scenes/testscenes/realhometest.tscn"
const CLASS_POSITION := Vector2(320.0, 144.0)
const SAVED_ORIGIN_POSITION := Vector2(-640.0, -360.0)

var _failures: Array[String] = []
var _cancellation_count: int = 0


class TestMom:
	extends CharacterBody2D

	var home_position := Vector2.ZERO
	var location_position_call_count: int = 0

	func get_npc_location_id() -> StringName:
		return StringName(TEST_NPC_ID)

	func set_npc_location_position(spawn_position: Vector2) -> void:
		location_position_call_count += 1
		global_position = spawn_position
		home_position = spawn_position


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
	var mom_marker := Marker2D.new()
	mom_marker.name = "MomLessonPosition"
	mom_marker.position = CLASS_POSITION
	lesson_spot.add_child(mom_marker)
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
	_expect(
		String((handoff_record.get("activity", {}) as Dictionary).get(
			"return_scene_path", ""
		)) == TEST_SCENE_PATH,
		"handoff retains the pre-invitation origin for failure recovery"
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

	# Simulate the accepted player handoff having loaded the lesson scene.
	test_scene.scene_file_path = LESSON_SCENE_PATH
	locations.active_scene_path = LESSON_SCENE_PATH
	var local_mom := TestMom.new()
	local_mom.name = "LocalLessonMom"
	local_mom.home_position = Vector2(72.0, 96.0)
	local_mom.velocity = Vector2(14.0, -11.0)
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
	_expect(local_mom.global_position == CLASS_POSITION, "local lesson stages Mom at the class marker")
	_expect(
		local_mom.home_position == Vector2(72.0, 96.0),
		"temporary lesson staging preserves Mom's home position"
	)
	_expect(
		local_mom.location_position_call_count == 0,
		"temporary lesson staging does not use the location restoration setter"
	)
	_expect(local_mom.velocity == Vector2.ZERO, "temporary lesson staging stops Mom's velocity")
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
	var cancelled_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(is_instance_valid(local_mom), "local cancellation keeps the live Mom instance")
	_expect(
		String(cancelled_record.get("scene_path", "")) == LESSON_SCENE_PATH,
		"local cancellation keeps Mom in the loaded lesson scene"
	)
	_expect(
		cancelled_record.get("last_position", Vector2.ZERO) == local_mom.global_position,
		"local cancellation records Mom's actual class position"
	)
	_expect(
		(cancelled_record.get("activity", {}) as Dictionary).is_empty()
		and (cancelled_record.get("action", {}) as Dictionary).is_empty(),
		"local cancellation clears the exact activity and action descriptors"
	)
	_expect(
		local_machine.get_active_action_session_id().is_empty(),
		"local cancellation detaches the finished InvitePlayer action"
	)

	var completion_claim: Dictionary = simulator.call(
		"try_claim_spot",
		StringName(TEST_NPC_ID),
		COMPLETION_SESSION_ID,
		TEST_SPOT_ID,
		&"activity"
	)
	var completion_reservation_id := String(completion_claim.get("reservation_id", ""))
	var completion_activity := activity.duplicate(true)
	completion_activity["session_id"] = COMPLETION_SESSION_ID
	completion_activity["action_session_id"] = COMPLETION_SESSION_ID
	completion_activity["activity_id"] = COMPLETION_SESSION_ID
	completion_activity["lesson_phase"] = "handoff"
	completion_activity["target_scene_path"] = LESSON_SCENE_PATH
	completion_activity["target_position"] = CLASS_POSITION
	completion_activity["return_scene_path"] = TEST_SCENE_PATH
	completion_activity["return_position"] = SAVED_ORIGIN_POSITION
	completion_activity["reservation_ids"] = [completion_reservation_id]
	var completion_action := NpcActionSession.create(
		TEST_NPC_ID,
		&"InvitePlayer",
		&"schedule",
		lesson_spot,
		completion_activity
	)
	completion_action.status = NpcActionSession.Status.ACTIVE
	completion_action.phase = &"executing"
	local_machine.active_action = completion_action
	var completion_record := cancelled_record.duplicate(true)
	completion_record["scene_path"] = LESSON_SCENE_PATH
	completion_record["last_position"] = local_mom.global_position
	completion_record["activity"] = completion_activity.duplicate(true)
	completion_record["action"] = completion_action.to_descriptor()
	completion_record["pending_travel"] = {}
	locations.npc_records[TEST_NPC_ID] = completion_record
	locations.live_npcs[TEST_NPC_ID] = local_mom

	var completion_start: Dictionary = lesson_spot.start_lesson(
		local_mom, player, COMPLETION_SESSION_ID
	)
	_expect(
		bool(completion_start.get("accepted", false)),
		"cross-scene-origin completion lesson starts"
	)
	var running_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	var running_activity: Dictionary = running_record.get("activity", {})
	_expect(
		String(running_activity.get("return_scene_path", "")) == TEST_SCENE_PATH
		and running_activity.get("return_position", Vector2.ZERO) == SAVED_ORIGIN_POSITION,
		"saved cross-scene origin remains available before local completion"
	)
	var completed_class_position := local_mom.global_position
	_expect(
		completed_class_position == CLASS_POSITION,
		"completion fixture keeps Mom at the visible class position"
	)
	_expect(
		lesson_spot.complete_lesson(COMPLETION_SESSION_ID),
		"current cross-scene-origin lesson completes"
	)
	var completed_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		is_instance_valid(local_mom) and not local_mom.is_queued_for_deletion(),
		"completion does not queue-free the live Mom instance"
	)
	_expect(
		locations.live_npcs.get(TEST_NPC_ID, null) == local_mom,
		"completion keeps the same live Mom registered"
	)
	_expect(
		String(completed_record.get("scene_path", "")) == LESSON_SCENE_PATH,
		"completion keeps Mom's record in the loaded lesson scene"
	)
	_expect(
		completed_record.get("last_position", Vector2.ZERO) == completed_class_position
		and local_mom.global_position == completed_class_position,
		"completion records Mom's actual class position"
	)
	_expect(
		(completed_record.get("activity", {}) as Dictionary).is_empty()
		and (completed_record.get("action", {}) as Dictionary).is_empty(),
		"completion clears the exact activity and action descriptors"
	)
	_expect(
		local_machine.get_active_action_session_id().is_empty(),
		"completion detaches the finished InvitePlayer action for normal reconciliation"
	)
	_expect(
		not simulator.spot_reservations.has(completion_reservation_id)
		and int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"completion releases the exact lesson reservation once"
	)
	_expect(
		not lesson_spot.complete_lesson(COMPLETION_SESSION_ID),
		"repeated completion is harmless"
	)
	_expect(
		not simulator.spot_reservations.has(completion_reservation_id)
		and int(simulator.spot_claim_counts.get(TEST_SPOT_ID, 0)) == 0,
		"repeated completion cannot release or recreate the reservation"
	)
	await process_frame
	_expect(
		is_instance_valid(local_mom) and not local_mom.is_queued_for_deletion(),
		"Mom remains live after deferred completion work"
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
