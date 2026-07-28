extends SceneTree

const TEST_NPC_ID := "magic_lesson_test_mom"
const TEST_SESSION_ID := "magic-lesson-session"
const COMPLETION_SESSION_ID := "magic-lesson-completion-session"
const TEST_SPOT_ID := &"magic_lesson_test_spot"
const TEST_SCENE_PATH := "res://magic_lesson_lifecycle_test.tscn"
const LESSON_SCENE_PATH := "res://scenes/testscenes/realhometest.tscn"
const CLASS_POSITION := Vector2(320.0, 144.0)
const SAVED_ORIGIN_POSITION := Vector2(-640.0, -360.0)
const MANA_BALANCE_DEFINITION := preload(
	"res://data/interactive_activities/mana_balance.tres"
)

var _failures: Array[String] = []
var _cancellation_count: int = 0
var _interactive_claim_release_count: int = 0


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
	var external_prepare_count: int = 0
	var external_prepare_accepted: bool = true
	var mutate_phase_during_prepare: String = ""
	var phase_seen_during_prepare: String = ""
	var last_prompt_id: StringName = &""

	func begin_spot_action(_owner: Node, _action: StringName) -> void:
		begin_count += 1

	func end_spot_action(_owner: Node, _action: StringName, _completed: bool) -> void:
		end_count += 1

	func can_accept_player_control_claim(control_mode: StringName) -> Dictionary:
		if control_mode != &"ui_only":
			return {"accepted": false, "reason": "unknown_control_mode"}
		return {"accepted": true, "reason": ""}

	func prepare_for_external_activity(_reason: StringName) -> Dictionary:
		external_prepare_count += 1
		var locations := get_node_or_null("/root/NpcLocations")
		if locations != null:
			var record: Dictionary = locations.call("get_record_snapshot", TEST_NPC_ID)
			var activity = record.get("activity", {})
			if activity is Dictionary:
				phase_seen_during_prepare = String(activity.get("lesson_phase", ""))
				if not mutate_phase_during_prepare.is_empty():
					var changed_record := record.duplicate(true)
					var changed_activity: Dictionary = activity.duplicate(true)
					changed_activity["lesson_phase"] = mutate_phase_during_prepare
					changed_record["activity"] = changed_activity
					locations.npc_records[TEST_NPC_ID] = changed_record
		return {
			"accepted": external_prepare_accepted,
			"reason": "" if external_prepare_accepted else "test_player_prepare_rejected",
		}

	func show_npc_prompt(
		_mom: Node2D,
		prompt_id: StringName,
		_title: String,
		_options: PackedStringArray,
		_callback_owner: Object,
		_accept_method: StringName,
		_decline_method: StringName,
		_timeout_seconds: float
	) -> bool:
		last_prompt_id = prompt_id
		return true


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
	var gameplay_flow := root.get_node_or_null("GameplayFlow")
	if locations == null or simulator == null or gameplay_flow == null:
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
	var player_claim_callback := Callable(
		self, "_on_interactive_player_claim_changed"
	).bind(player)
	gameplay_flow.player_control_claim_changed.connect(player_claim_callback)
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
	simulator.call("set_spot_value", TEST_SPOT_ID, 1.0, false)
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

	var mana_definition := MANA_BALANCE_DEFINITION as InteractiveActivityDefinition
	_expect(
		mana_definition != null
		and mana_definition.is_valid_definition()
		and mana_definition.module_config is ManaBalanceConfig,
		"Mana Balance definition is valid and carries typed module configuration"
	)
	_expect(
		_real_home_has_mana_balance_assignment(),
		"real Mom magic lesson scene assigns the Mana Balance definition"
	)
	lesson_spot.interactive_activity_definitions = [mana_definition]
	lesson_spot.interactive_activity_launch_options = _make_magic_training_launch_options()

	var prepare_failure_session := "interactive-prepare-failure"
	_install_lesson_session(
		locations,
		simulator,
		local_machine,
		lesson_spot,
		activity,
		prepare_failure_session,
		"handoff"
	)
	player.external_prepare_accepted = false
	var prepare_failure := lesson_spot.start_lesson(
		local_mom, player, prepare_failure_session
	)
	_expect(
		not bool(prepare_failure.get("accepted", false)),
		"failed interactive runner preparation rejects lesson startup"
	)
	var prepare_failure_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		String((prepare_failure_record.get("activity", {}) as Dictionary).get(
			"lesson_phase", ""
		)) == "handoff",
		"failed runner preparation does not persist running"
	)
	_expect(
		not gameplay_flow.is_player_control_claimed(player)
		and lesson_spot.get_interactive_activity_runner().get_player_claim_token() == 0,
		"failed runner preparation releases its partial player claim"
	)
	player.external_prepare_accepted = true

	var transition_failure_session := "interactive-transition-failure"
	_install_lesson_session(
		locations,
		simulator,
		local_machine,
		lesson_spot,
		activity,
		transition_failure_session,
		"handoff"
	)
	player.mutate_phase_during_prepare = "invalid_after_prepare"
	var transition_failure := lesson_spot.start_lesson(
		local_mom, player, transition_failure_session
	)
	_expect(
		not bool(transition_failure.get("accepted", false)),
		"persistent transition rejection aborts interactive startup"
	)
	var transition_failure_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		String((transition_failure_record.get("activity", {}) as Dictionary).get(
			"lesson_phase", ""
		)) == "invalid_after_prepare",
		"runner preparation occurs before the attempted persistent running transition"
	)
	_expect(
		not gameplay_flow.is_player_control_claimed(player)
		and lesson_spot.get_interactive_activity_runner().get_presentation_host() == null,
		"failed persistent transition cleans the prepared runner and visible host"
	)
	player.mutate_phase_during_prepare = ""

	var interactive_completion_session := "interactive-lesson-completion"
	_install_lesson_session(
		locations,
		simulator,
		local_machine,
		lesson_spot,
		activity,
		interactive_completion_session,
		"handoff"
	)
	player.phase_seen_during_prepare = ""
	var begin_count_before_interactive := player.begin_count
	var interactive_start := lesson_spot.start_lesson(
		local_mom, player, interactive_completion_session
	)
	_expect(bool(interactive_start.get("accepted", false)), "interactive lesson starts")
	_expect(
		player.phase_seen_during_prepare == "handoff",
		"interactive runner prepares before persistent phase becomes running"
	)
	_expect(
		player.begin_count == begin_count_before_interactive,
		"interactive startup does not begin the legacy player spot action"
	)
	var interactive_runner := lesson_spot.get_interactive_activity_runner()
	var interactive_host := interactive_runner.get_presentation_host()
	_expect(
		interactive_runner.is_active()
		and interactive_runner.get_player_claim_token() != 0,
		"interactive lesson owns a live ui-only runner claim"
	)
	_expect(
		not gameplay_flow.is_world_progression_locked(),
		"interactive lesson does not lock WorldTime progression"
	)
	_expect(
		interactive_host != null
		and interactive_host.get_parent() == test_scene
		and not lesson_spot.is_ancestor_of(interactive_host),
		"interactive lesson host uses the visible scene root rather than the lesson spot"
	)
	_expect(
		interactive_host.is_selecting()
		and interactive_host.get_active_module() == null
		and interactive_host.get_launch_options().selection_policy
			== InteractiveActivityLaunchOptions.SelectionPolicy.ALWAYS_SHOW,
		"Mom's accepted lesson opens ALWAYS_SHOW selection before Mana Balance"
	)
	_expect(
		String(interactive_host.title_label.text) == "Magic Training"
		and String(interactive_host.options_label.text).contains("Choose what to train")
		and String(interactive_host.options_label.text).contains("> Mana Balance")
		and String(interactive_host.help_label.text) == "Z: Begin",
		"training menu clearly distinguishes selection from invitation consent"
	)
	var selection_progress_before := lesson_spot.get_lesson_progress()
	lesson_spot._process(0.05)
	_expect(
		lesson_spot.get_lesson_state() == &"running"
		and lesson_spot.get_lesson_progress() > selection_progress_before,
		"selection time counts as authoritative class progress"
	)
	var lesson_activity_input := interactive_runner.get_input_source()
	lesson_activity_input._input(_action_event(&"attack", true))
	interactive_host._process(0.0)
	_expect(
		interactive_host.get_active_module() is ManaBalanceModule
		and interactive_host.get_active_module().is_running()
		and not interactive_host.is_selecting(),
		"Z confirmation starts Mana Balance exactly once"
	)
	var selected_mana_module := interactive_host.get_active_module()
	lesson_activity_input.clear_one_frame_states()
	lesson_activity_input._input(_action_event(&"attack", true))
	interactive_host._process(0.0)
	_expect(
		interactive_host.get_active_module() == selected_mana_module,
		"repeated lesson confirmation cannot duplicate Mana Balance"
	)
	lesson_activity_input._input(_action_event(&"attack", false))
	interactive_host.get_active_module().publish_result({
		"score": 9.0,
		"details": {"lesson_mana_balance_update": true},
	})
	_expect(
		lesson_spot.complete_lesson(interactive_completion_session),
		"interactive lesson completion succeeds"
	)
	var merged_result := lesson_spot.get_last_lesson_result()
	var merged_activity: Dictionary = merged_result.get("interactive_activity", {})
	_expect(
		String(merged_activity.get("activity_id", "")) == "mana_balance"
		and String(merged_activity.get("session_id", "")) == interactive_completion_session
		and String(merged_activity.get("status", "")) == "completed",
		"lesson completion collects the standardized Mana Balance result"
	)
	_expect(
		not gameplay_flow.is_player_control_claimed(player),
		"interactive lesson completion releases its local player claim"
	)
	_expect(
		is_instance_valid(local_mom)
		and local_mom.get_parent() == test_scene
		and local_mom.position.is_equal_approx(CLASS_POSITION),
		"Mom remains valid in the lesson scene after interactive completion"
	)

	var interactive_cancel_session := "interactive-lesson-cancel"
	_install_lesson_session(
		locations,
		simulator,
		local_machine,
		lesson_spot,
		activity,
		interactive_cancel_session,
		"handoff"
	)
	var cancellation_releases_before := _interactive_claim_release_count
	var interactive_cancel_start := lesson_spot.start_lesson(
		local_mom, player, interactive_cancel_session
	)
	_expect(bool(interactive_cancel_start.get("accepted", false)), "interactive cancellation fixture starts")
	_expect(
		lesson_spot.cancel_lesson(&"interactive_test_cancel", interactive_cancel_session),
		"interactive lesson cancellation succeeds"
	)
	_expect(
		_interactive_claim_release_count == cancellation_releases_before + 1,
		"interactive cancellation releases its runner claim exactly once"
	)
	lesson_spot.cancel_lesson(&"interactive_repeat_cancel", interactive_cancel_session)
	_expect(
		_interactive_claim_release_count == cancellation_releases_before + 1,
		"repeated interactive cancellation is harmless"
	)

	var same_scene_spot_id := &"magic_lesson_same_scene_test_spot"
	var same_scene_spot := _make_interactive_lesson_spot(
		"SameSceneLessonSpot",
		same_scene_spot_id,
		test_scene,
		mana_definition
	)
	var same_scene_session := "same-scene-invitation-session"
	_install_lesson_session(
		locations,
		simulator,
		local_machine,
		same_scene_spot,
		activity,
		same_scene_session,
		"inviting",
		same_scene_spot_id
	)
	_expect(
		same_scene_spot.begin_invitation(local_mom, player),
		"same-scene invitation displays"
	)
	_expect(
		same_scene_spot.accept_lesson(local_mom, player),
		"same-scene acceptance starts the accepted lesson"
	)
	var same_scene_runner := same_scene_spot.get_interactive_activity_runner()
	var same_scene_host := same_scene_runner.get_presentation_host()
	_expect(
		same_scene_host != null
		and same_scene_host.is_selecting()
		and same_scene_host.get_active_module() == null,
		"same-scene acceptance opens activity selection"
	)
	var same_scene_releases_before := _interactive_claim_release_count
	_expect(
		same_scene_spot.cancel_lesson(&"selection_menu_cancel", same_scene_session),
		"selection-menu cancellation ends the accepted local lesson"
	)
	_expect(
		_interactive_claim_release_count == same_scene_releases_before + 1
		and not gameplay_flow.is_player_control_claimed(player),
		"selection-menu cancellation removes the host and releases one claim"
	)
	same_scene_spot.queue_free()
	await process_frame

	var resumable_session := "interactive-lesson-resumable"
	var resumable_reservation_id := _install_lesson_session(
		locations,
		simulator,
		local_machine,
		lesson_spot,
		activity,
		resumable_session,
		"running"
	)
	var resumable_start := lesson_spot.start_lesson(
		local_mom, player, resumable_session
	)
	_expect(
		bool(resumable_start.get("accepted", false)),
		"persistent running lesson reconstructs its local interactive presentation"
	)
	var resumable_runner := lesson_spot.get_interactive_activity_runner()
	var resumable_host := resumable_runner.get_presentation_host()
	_expect(
		resumable_host != null
		and resumable_host.is_selecting()
		and resumable_host.get_active_module() == null,
		"running-session reload reconstructs the activity selection presentation"
	)
	_expect(
		gameplay_flow.is_player_control_claimed(player)
		and resumable_runner.get_player_claim_token() != 0,
		"reloaded presentation owns one exact player-control claim"
	)
	var unload_releases_before := _interactive_claim_release_count
	lesson_spot.queue_free()
	await process_frame
	await process_frame
	var resumable_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		String((resumable_record.get("activity", {}) as Dictionary).get(
			"lesson_phase", ""
		)) == "running",
		"scene-local shutdown preserves the persistent running lesson"
	)
	_expect(
		simulator.spot_reservations.has(resumable_reservation_id),
		"scene-local shutdown preserves the scheduled lesson reservation"
	)
	_expect(
		not gameplay_flow.is_player_control_claimed(player)
		and _interactive_claim_release_count == unload_releases_before + 1,
		"scene-local shutdown releases only the local runner claim once"
	)

	var decline_spot_id := &"magic_lesson_decline_test_spot"
	var decline_spot := _make_interactive_lesson_spot(
		"DeclineLessonSpot",
		decline_spot_id,
		test_scene,
		mana_definition
	)
	var decline_session := "declined-invitation-session"
	var decline_base_activity := activity.duplicate(true)
	decline_base_activity["return_scene_path"] = LESSON_SCENE_PATH
	decline_base_activity["return_position"] = local_mom.global_position
	_install_lesson_session(
		locations,
		simulator,
		local_machine,
		decline_spot,
		decline_base_activity,
		decline_session,
		"inviting",
		decline_spot_id
	)
	var player_position_before_decline := player.global_position
	_expect(
		decline_spot.begin_invitation(local_mom, player),
		"decline fixture displays its first invitation"
	)
	decline_spot.decline_lesson(local_mom, player)
	var declined_record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	_expect(
		player.global_position == player_position_before_decline,
		"decline does not transport the player"
	)
	_expect(
		(declined_record.get("activity", {}) as Dictionary).is_empty()
		and not decline_spot.is_interactive_lesson_active()
		and decline_spot.get_interactive_activity_runner() == null,
		"decline creates neither a handoff nor a destination activity menu"
	)
	locations.npc_records = original_records
	locations.live_npcs = original_live_npcs
	locations.active_scene_path = original_active_scene_path
	simulator.spot_reservations = original_reservations
	simulator.live_spots = original_live_spots
	simulator.call("_sync_spot_claim_count_cache")
	simulator.set_process(simulator_was_processing)
	gameplay_flow.player_control_claim_changed.disconnect(player_claim_callback)
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


func _real_home_has_mana_balance_assignment() -> bool:
	var packed_scene := load(LESSON_SCENE_PATH) as PackedScene
	if packed_scene == null:
		return false
	var scene_state := packed_scene.get_state()
	for node_index in scene_state.get_node_count():
		if String(scene_state.get_node_name(node_index)) != "MomMagicLessonSpot":
			continue
		var has_mana_balance := false
		var has_always_show := false
		for property_index in scene_state.get_node_property_count(node_index):
			var property_name := String(
				scene_state.get_node_property_name(node_index, property_index)
			)
			var assigned = scene_state.get_node_property_value(node_index, property_index)
			if property_name == "interactive_activity_definitions":
				if assigned is Array and assigned.size() == 1:
					var definition := assigned[0] as InteractiveActivityDefinition
					has_mana_balance = (
						definition != null and definition.id == &"mana_balance"
					)
			elif property_name == "interactive_activity_launch_options":
				var options := assigned as InteractiveActivityLaunchOptions
				has_always_show = (
					options != null
					and options.selection_policy
						== InteractiveActivityLaunchOptions.SelectionPolicy.ALWAYS_SHOW
					and options.get_menu_title() == "Magic Training"
					and options.menu_prompt == "Choose what to train"
				)
		return has_mana_balance and has_always_show
	return false


func _make_magic_training_launch_options() -> InteractiveActivityLaunchOptions:
	var options := InteractiveActivityLaunchOptions.new()
	options.selection_policy = (
		InteractiveActivityLaunchOptions.SelectionPolicy.ALWAYS_SHOW
	)
	options.menu_title = "Magic Training"
	options.menu_prompt = "Choose what to train"
	options.confirm_text = "Z: Begin"
	return options


func _make_interactive_lesson_spot(
	node_name: String,
	target_spot_id: StringName,
	parent: Node2D,
	definition: InteractiveActivityDefinition
) -> MagicLessonSpot:
	var spot := MagicLessonSpot.new()
	spot.name = node_name
	spot.spot_id = target_spot_id
	spot.require_player_in_lesson_zone = false
	spot.interactive_activity_definitions = [definition]
	spot.interactive_activity_launch_options = _make_magic_training_launch_options()
	var marker := Marker2D.new()
	marker.name = "MomLessonPosition"
	marker.position = CLASS_POSITION
	spot.add_child(marker)
	parent.add_child(spot)
	return spot


func _action_event(action: StringName, pressed: bool) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	return event


func _install_lesson_session(
	locations: Node,
	simulator: Node,
	machine: NpcStateMachine,
	lesson_spot: MagicLessonSpot,
	base_activity: Dictionary,
	session_id: String,
	lesson_phase: String,
	target_spot_id: StringName = TEST_SPOT_ID
) -> String:
	simulator.call(
		"release_scheduled_activity_claim",
		target_spot_id,
		"interactive_test_fixture_reset"
	)
	var claim: Dictionary = simulator.call(
		"try_claim_spot",
		StringName(TEST_NPC_ID),
		session_id,
		target_spot_id,
		&"activity"
	)
	var reservation_id := String(claim.get("reservation_id", ""))
	var installed_activity := base_activity.duplicate(true)
	installed_activity["session_id"] = session_id
	installed_activity["action_session_id"] = session_id
	installed_activity["activity_id"] = session_id
	installed_activity["spot_id"] = String(target_spot_id)
	installed_activity["lesson_phase"] = lesson_phase
	installed_activity["target_scene_path"] = LESSON_SCENE_PATH
	installed_activity["target_position"] = CLASS_POSITION
	installed_activity["return_scene_path"] = TEST_SCENE_PATH
	installed_activity["return_position"] = SAVED_ORIGIN_POSITION
	installed_activity["reservation_ids"] = [reservation_id]
	var action := NpcActionSession.create(
		TEST_NPC_ID,
		&"InvitePlayer",
		&"schedule",
		lesson_spot,
		installed_activity
	)
	action.status = NpcActionSession.Status.ACTIVE
	action.phase = &"executing"
	machine.active_action = action
	var record: Dictionary = locations.get_record_snapshot(TEST_NPC_ID)
	record["scene_path"] = LESSON_SCENE_PATH
	record["last_position"] = CLASS_POSITION
	record["activity"] = installed_activity
	record["action"] = action.to_descriptor()
	record["pending_travel"] = {}
	locations.npc_records[TEST_NPC_ID] = record
	return reservation_id


func _on_interactive_player_claim_changed(
	claimed_player: Node,
	claimed: bool,
	_token_id: int,
	expected_player: Node
) -> void:
	if claimed_player == expected_player and not claimed:
		_interactive_claim_release_count += 1
