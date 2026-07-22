extends SceneTree

const NpcActionSessionModel = preload("res://scripts/systems/npc_action_session.gd")
const NpcRouteLocationCoordinator = preload(
	"res://scripts/systems/npc_route_location_coordinator.gd"
)

const MOM_ID := "mom"
const MOM_BED_ID := &"mom_bed"
const YARD_SCENE := "res://scenes/testscenes/realtest1.tscn"
const HOME_SCENE := "res://scenes/testscenes/realhometest.tscn"
const BEDROOM_SCENE := "res://scenes/testscenes/mom_bedroom.tscn"
const BED_POSITION := Vector2(220.0, 420.0)
const YARD_RETURN_POSITION := Vector2(520.0, 368.0)
const YARD_TO_HOME_ARRIVAL := Vector2(610.0, 368.0)
const BEDROOM_TO_HOME_ARRIVAL := Vector2(-680.0, 368.0)

var _failures: Array[String] = []


class RouteTestNpc:
	extends Node2D

	var persistent_id: String

	func _init(new_persistent_id: String) -> void:
		persistent_id = new_persistent_id

	func get_npc_location_id() -> StringName:
		return StringName(persistent_id)


class RouteTestMachine:
	extends Node

	var active_session_id: String
	var cancelled_sessions: Array[String] = []
	var cleared_sessions: Array[String] = []
	var paused_retry_sessions: Array[String] = []
	var movement_descriptors: Array[Dictionary] = []
	var session_executable: bool = true
	var current_state: Node
	var move_target: Node2D

	func _init(session_id: String) -> void:
		active_session_id = session_id

	func get_active_action_session_id() -> String:
		return active_session_id

	func is_action_session_current_for_execution(
		session_id: String,
		_state_name: StringName = &""
	) -> bool:
		return session_executable and session_id == active_session_id

	func cancel_active_action(session_id: String, _reason: String = "cancelled") -> bool:
		if session_id != active_session_id:
			return false
		cancelled_sessions.append(session_id)
		session_executable = false
		active_session_id = ""
		return true

	func clear_terminal_action(session_id: String) -> bool:
		cleared_sessions.append(session_id)
		return true

	func pause_active_action_movement_for_retry(
		session_id: String,
		_reason: String = "movement_retry",
		_require_movement_phase: bool = true
	) -> bool:
		if not is_action_session_current_for_execution(session_id):
			return false
		if paused_retry_sessions.has(session_id):
			return true
		paused_retry_sessions.append(session_id)
		return true

	func assign_move_target(_target: Node2D, _state_after_move: StringName = &"Idle") -> bool:
		return true

	func request_action_movement_from_descriptor(
		descriptor: Dictionary,
		_target: Node2D,
		_destination_action_kind: StringName = &"Idle"
	) -> bool:
		movement_descriptors.append(descriptor.duplicate(true))
		active_session_id = NpcActionSessionModel._descriptor_session_id(descriptor)
		session_executable = not active_session_id.is_empty()
		return session_executable


func _initialize() -> void:
	await process_frame
	var routes := root.get_node_or_null("NpcSceneRoutes")
	var locations := root.get_node_or_null("NpcLocations")
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if routes == null or locations == null or simulator == null:
		_fail("multiscene transaction test requires route, location, and simulation autoloads")
		_finish()
		return

	var original_records: Dictionary = locations.npc_records.duplicate(true)
	var original_live_npcs: Dictionary = locations.live_npcs.duplicate()
	var original_active_scene_path: String = locations.active_scene_path
	var original_reservations: Dictionary = simulator.spot_reservations.duplicate(true)
	var original_claim_counts: Dictionary = simulator.spot_claim_counts.duplicate()
	var simulator_was_processing := simulator.is_processing()
	var routes_were_enabled := bool(routes.call("is_enabled"))

	simulator.set_process(false)
	locations.npc_records = {}
	locations.live_npcs = {}
	locations.active_scene_path = ""
	simulator.spot_reservations = {}
	simulator.call("_sync_spot_claim_count_cache")
	routes.call("set_enabled", true, "multiscene_transaction_test")

	_test_start_and_finish_route_transactions(routes, locations, simulator)
	_test_finish_replan_marker_recovery(routes, locations, simulator)
	_test_offscreen_scheduler_routes(routes, locations, simulator)
	_test_live_scheduler_direct_door_kill_switch(routes, locations, simulator)
	_test_wired_direct_door_kill_switch(routes, locations)
	_test_actual_door_handoff_chain(routes, locations, simulator)
	_test_pending_session_guards(routes, locations, simulator)
	_test_pending_cancellation_boundaries(routes, locations, simulator)
	_test_offscreen_route_cas_preserves_newer_pending(routes, locations, simulator)
	_test_offscreen_active_destination_arrival(routes, locations, simulator)

	locations.npc_records = original_records
	locations.live_npcs = original_live_npcs
	locations.active_scene_path = original_active_scene_path
	simulator.spot_reservations = original_reservations
	simulator.call("_sync_spot_claim_count_cache")
	_expect(
		simulator.spot_claim_counts == original_claim_counts,
		"spot-claim cache restores exactly after the isolated transaction test"
	)
	simulator.set_process(simulator_was_processing)
	routes.call("set_enabled", routes_were_enabled, "multiscene_transaction_test_restore")
	await process_frame
	_finish()


func _test_start_and_finish_route_transactions(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var start_session := "mom-multiscene-sleep-start"
	var sleep_activity := _sleep_activity(start_session)
	var outbound_plan := routes.call(
		"plan_route", YARD_SCENE, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	_expect(bool(outbound_plan.get("accepted", false)), "Mom's real outbound route plans")
	if not bool(outbound_plan.get("accepted", false)):
		return

	var outbound_pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"requested_state_name": "Sleep",
		"requested_priority": 70,
		"activity": sleep_activity,
	}, outbound_plan) as Dictionary
	locations.npc_records[MOM_ID] = _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	var start_record: Dictionary = locations.npc_records[MOM_ID]
	start_record["action"] = _action_descriptor(start_session, "Sleep")
	start_record["pending_travel"] = outbound_pending
	locations.npc_records[MOM_ID] = start_record

	var first_hop := routes.call(
		"get_current_hop", outbound_pending, YARD_SCENE, StringName(MOM_ID)
	) as Dictionary
	_expect(bool(first_hop.get("accepted", false)), "outbound first hop validates")
	var pristine_record: Dictionary = locations.get_record_snapshot(MOM_ID)
	var callback_npc := _make_npc_with_machine(MOM_ID, start_session)
	locations.live_npcs[MOM_ID] = callback_npc
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			callback_npc,
			&"household.realhometest_to_mom_bedroom",
			HOME_SCENE
		)),
		"a callback from the wrong route edge is rejected"
	)
	_expect(
		locations.get_record_snapshot(MOM_ID) == pristine_record,
		"wrong-edge rejection leaves the canonical record untouched"
	)
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			callback_npc,
			StringName(String(first_hop.get("edge_id", ""))),
			BEDROOM_SCENE
		)),
		"a door callback cannot skip the shared-home scene"
	)
	_expect(
		locations.get_record_snapshot(MOM_ID) == pristine_record,
		"wrong-target rejection leaves the canonical record untouched"
	)

	callback_npc.position = YARD_RETURN_POSITION
	locations.live_npcs[MOM_ID] = callback_npc
	_expect(bool(locations.call(
		"complete_pending_route_hop",
		callback_npc,
		StringName(String(first_hop.get("edge_id", ""))),
		HOME_SCENE
	)), "yard-to-home callback commits the first routed leg")
	var home_record: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(home_record.get("scene_path", "")) == HOME_SCENE, "first leg records Mom in the home")
	_expect(String(home_record.get("previous_scene_path", "")) == YARD_SCENE, "first leg records its source scene")
	_expect(home_record.get("last_position", Vector2.ZERO) == YARD_TO_HOME_ARRIVAL, "first leg uses its explicit home arrival")
	_expect(_pending_hop_index(home_record) == 1, "first leg preserves pending travel at hop one")
	_expect(
		String((home_record.get("pending_travel", {}) as Dictionary).get("target_scene_path", "")) == BEDROOM_SCENE,
		"intermediate travel retains the final bedroom destination"
	)
	_expect((home_record.get("activity", {}) as Dictionary).is_empty(), "sleep does not commit in the intermediate scene")

	var pending_at_home: Dictionary = home_record.get("pending_travel", {})
	var second_hop := routes.call(
		"get_current_hop", pending_at_home, HOME_SCENE, StringName(MOM_ID)
	) as Dictionary
	var stale_final_npc := _make_npc(MOM_ID)
	var before_stale_final: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			stale_final_npc,
			StringName(String(second_hop.get("edge_id", ""))),
			BEDROOM_SCENE
		)),
		"an unregistered duplicate body cannot commit a final routed leg"
	)
	_expect(
		locations.get_record_snapshot(MOM_ID) == before_stale_final,
		"stale final callback leaves the canonical record untouched"
	)
	stale_final_npc.queue_free()
	var second_npc := _make_npc_with_machine(MOM_ID, start_session)
	second_npc.position = YARD_TO_HOME_ARRIVAL
	locations.live_npcs[MOM_ID] = second_npc
	var wrong_source_record := home_record.duplicate(true)
	wrong_source_record["scene_path"] = YARD_SCENE
	locations.npc_records[MOM_ID] = wrong_source_record
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			second_npc,
			StringName(String(second_hop.get("edge_id", ""))),
			BEDROOM_SCENE
		)),
		"route metadata cannot override a mismatched canonical source scene"
	)
	locations.npc_records[MOM_ID] = home_record
	_expect(bool(locations.call(
		"complete_pending_route_hop",
		second_npc,
		StringName(String(second_hop.get("edge_id", ""))),
		BEDROOM_SCENE
	)), "home-to-bedroom callback commits the final routed leg")
	var sleeping_record: Dictionary = locations.get_record_snapshot(MOM_ID)
	var committed_activity: Dictionary = sleeping_record.get("activity", {})
	var committed_session := String(committed_activity.get("session_id", ""))
	_expect(String(sleeping_record.get("scene_path", "")) == BEDROOM_SCENE, "final start commit records Mom in her bedroom")
	_expect(sleeping_record.get("last_position", Vector2.ZERO) == BED_POSITION, "final start commit places Mom at her bed")
	_expect((sleeping_record.get("pending_travel", {}) as Dictionary).is_empty(), "final start commit clears pending travel")
	_expect(String(committed_activity.get("spot_id", "")) == String(MOM_BED_ID), "final start commit owns the Mom bed activity")
	_expect(not committed_session.is_empty(), "committed sleep retains a stable action session")
	_expect(
		String((sleeping_record.get("action", {}) as Dictionary).get("session_id", "")) == committed_session,
		"committed activity and persistent action share one session"
	)
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1, "committed sleep owns exactly one Mom-bed claim")

	var return_plan := routes.call(
		"plan_route", BEDROOM_SCENE, YARD_SCENE, StringName(MOM_ID)
	) as Dictionary
	_expect(bool(return_plan.get("accepted", false)), "Mom's real return route plans")
	if not bool(return_plan.get("accepted", false)):
		return
	var return_pending := routes.call("attach_route_to_pending", {
		"mode": "finish",
		"target_scene_path": YARD_SCENE,
		"target_position": YARD_RETURN_POSITION,
		"action_session_id": committed_session,
		"spot_id": String(MOM_BED_ID),
	}, return_plan) as Dictionary
	sleeping_record["pending_travel"] = return_pending
	locations.npc_records[MOM_ID] = sleeping_record

	var bedroom_hop := routes.call(
		"get_current_hop", return_pending, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	var return_npc := _make_npc_with_machine(MOM_ID, committed_session)
	return_npc.position = BED_POSITION
	locations.live_npcs[MOM_ID] = return_npc
	_expect(bool(locations.call(
		"complete_pending_route_hop",
		return_npc,
		StringName(String(bedroom_hop.get("edge_id", ""))),
		HOME_SCENE
	)), "bedroom-to-home callback commits the first return leg")
	var returning_record: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(returning_record.get("scene_path", "")) == HOME_SCENE, "first return leg records Mom in the home")
	_expect(returning_record.get("last_position", Vector2.ZERO) == BEDROOM_TO_HOME_ARRIVAL, "first return leg uses its explicit home arrival")
	_expect(_pending_hop_index(returning_record) == 1, "first return leg preserves pending travel at hop one")
	_expect(
		String((returning_record.get("activity", {}) as Dictionary).get("session_id", "")) == committed_session,
		"nonterminal return travel preserves the committed sleep activity"
	)

	# This is the old-save repair boundary: the record is intentionally in the home while
	# its committed activity still belongs to the bedroom. A valid route must protect it.
	var save_data := locations.call("get_save_data") as Dictionary
	locations.call("apply_save_data", save_data)
	var restored_record: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(restored_record.get("scene_path", "")) == HOME_SCENE, "save normalization retains the intermediate return scene")
	_expect(_pending_hop_index(restored_record) == 1, "save normalization retains routed return progress")
	_expect(
		String((restored_record.get("activity", {}) as Dictionary).get("session_id", "")) == committed_session,
		"save mismatch repair does not erase a valid routed finish activity"
	)
	_expect(
		String((restored_record.get("action", {}) as Dictionary).get("session_id", "")) == committed_session,
		"save normalization retains the matching committed action"
	)

	var restored_pending: Dictionary = restored_record.get("pending_travel", {})
	var yard_hop := routes.call(
		"get_current_hop", restored_pending, HOME_SCENE, StringName(MOM_ID)
	) as Dictionary
	var final_return_npc := _make_npc_with_machine(MOM_ID, committed_session)
	final_return_npc.position = BEDROOM_TO_HOME_ARRIVAL
	locations.live_npcs[MOM_ID] = final_return_npc
	_expect(bool(locations.call(
		"complete_pending_route_hop",
		final_return_npc,
		StringName(String(yard_hop.get("edge_id", ""))),
		YARD_SCENE
	)), "home-to-yard callback commits the final return leg")
	var returned_record: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(returned_record.get("scene_path", "")) == YARD_SCENE, "final return records Mom back in the yard")
	_expect(returned_record.get("last_position", Vector2.ZERO) == YARD_RETURN_POSITION, "final return restores Mom's saved origin position")
	_expect((returned_record.get("pending_travel", {}) as Dictionary).is_empty(), "final return clears pending travel")
	_expect((returned_record.get("activity", {}) as Dictionary).is_empty(), "final return clears the completed activity")
	_expect((returned_record.get("action", {}) as Dictionary).is_empty(), "final return clears the completed action")
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 0, "final return releases the Mom-bed claim")


func _test_pending_cancellation_boundaries(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var outbound_plan := routes.call(
		"plan_route", YARD_SCENE, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	var return_plan := routes.call(
		"plan_route", BEDROOM_SCENE, YARD_SCENE, StringName(MOM_ID)
	) as Dictionary
	if not bool(outbound_plan.get("accepted", false)) or not bool(return_plan.get("accepted", false)):
		_fail("cancellation boundaries require both real Mom routes")
		return

	var matching_session := "cancel-matching-start"
	var matching_pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"activity": _sleep_activity(matching_session),
	}, outbound_plan) as Dictionary
	var matching_record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	matching_record["action"] = _action_descriptor(matching_session, "Sleep")
	matching_record["pending_travel"] = matching_pending
	locations.npc_records[MOM_ID] = matching_record
	var matching_live := _make_npc_with_machine(MOM_ID, matching_session)
	var matching_machine := matching_live.get_node("NpcStateMachine") as RouteTestMachine
	locations.live_npcs[MOM_ID] = matching_live
	_expect(bool(locations.call(
		"cancel_pending_scheduled_travel", MOM_ID, "route_test_cancel"
	)), "matching start travel cancellation succeeds")
	var matching_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect((matching_after.get("pending_travel", {}) as Dictionary).is_empty(), "matching start cancellation clears pending travel")
	_expect((matching_after.get("action", {}) as Dictionary).is_empty(), "matching start cancellation clears its exact action")
	_expect(matching_machine.cancelled_sessions == [matching_session], "matching start cancellation reaches only its live session")
	locations.live_npcs.erase(MOM_ID)
	matching_live.queue_free()

	var pending_session := "cancel-pending-start"
	var unrelated_session := "newer-unrelated-action"
	var unrelated_pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"activity": _sleep_activity(pending_session),
	}, outbound_plan) as Dictionary
	var unrelated_record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	unrelated_record["action"] = _action_descriptor(unrelated_session, "Talk")
	unrelated_record["pending_travel"] = unrelated_pending
	locations.npc_records[MOM_ID] = unrelated_record
	var unrelated_live := _make_npc_with_machine(MOM_ID, unrelated_session)
	var unrelated_machine := unrelated_live.get_node("NpcStateMachine") as RouteTestMachine
	locations.live_npcs[MOM_ID] = unrelated_live
	_expect(
		not bool(locations.call(
			"cancel_pending_scheduled_travel",
			MOM_ID,
			"wrong_watchdog_session",
			true,
			unrelated_session
		)),
		"session-bound cancellation rejects a different pending travel session"
	)
	_expect(
		not (locations.get_record_snapshot(MOM_ID).get("pending_travel", {}) as Dictionary).is_empty(),
		"rejected session-bound cancellation preserves pending travel"
	)
	_expect(bool(locations.call(
		"cancel_pending_scheduled_travel", MOM_ID, "stale_route_cancel"
	)), "stale start travel cancellation succeeds")
	var unrelated_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect((unrelated_after.get("pending_travel", {}) as Dictionary).is_empty(), "stale start cancellation still clears pending travel")
	_expect(
		String((unrelated_after.get("action", {}) as Dictionary).get("session_id", "")) == unrelated_session,
		"stale start cancellation preserves a newer unrelated action"
	)
	_expect(unrelated_machine.cancelled_sessions.is_empty(), "stale start cancellation does not reach the unrelated live action")
	locations.live_npcs.erase(MOM_ID)
	unrelated_live.queue_free()

	var finish_session := "cancel-nonterminal-finish"
	var finish_pending := routes.call("attach_route_to_pending", {
		"mode": "finish",
		"target_scene_path": YARD_SCENE,
		"target_position": YARD_RETURN_POSITION,
		"action_session_id": finish_session,
		"spot_id": String(MOM_BED_ID),
	}, return_plan) as Dictionary
	var finish_first_hop := routes.call(
		"get_current_hop", finish_pending, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	var finish_advance := routes.call(
		"advance_pending_route",
		finish_pending,
		StringName(String(finish_first_hop.get("edge_id", ""))),
		HOME_SCENE,
		StringName(MOM_ID)
	) as Dictionary
	finish_pending = finish_advance.get("pending_travel", {}) as Dictionary
	var finish_record := _base_record(HOME_SCENE, BEDROOM_TO_HOME_ARRIVAL)
	finish_record["previous_scene_path"] = BEDROOM_SCENE
	finish_record["activity"] = _sleep_activity(finish_session)
	finish_record["activity"]["status"] = "active"
	finish_record["action"] = _action_descriptor(finish_session, "Sleep")
	finish_record["action"]["status"] = "active"
	finish_record["pending_travel"] = finish_pending
	var invalid_saved_record := finish_record.duplicate(true)
	var invalid_pending: Dictionary = invalid_saved_record.get("pending_travel", {})
	var invalid_route: Dictionary = invalid_pending.get("scene_route", {})
	invalid_route["npc_id"] = "stranger"
	invalid_pending["scene_route"] = invalid_route
	invalid_saved_record["pending_travel"] = invalid_pending
	_expect(
		bool(locations.call("_repair_mismatched_activity_record", invalid_saved_record)),
		"save repair rejects an explicitly invalid intermediate route"
	)
	_expect(
		(invalid_saved_record.get("activity", {}) as Dictionary).is_empty(),
		"invalid routed save cannot preserve a mismatched committed activity"
	)
	var disabled_saved_record := finish_record.duplicate(true)
	routes.call("set_enabled", false, "save_during_route_kill_switch")
	_expect(
		not bool(locations.call("_repair_mismatched_activity_record", disabled_saved_record)),
		"save repair marks finish replanning without scheduling a destructive live reset"
	)
	routes.call("set_enabled", true, "save_during_route_kill_switch_complete")
	_expect(
		not (disabled_saved_record.get("activity", {}) as Dictionary).is_empty(),
		"save repair preserves the committed activity while routes are disabled"
	)
	_expect(
		(disabled_saved_record.get("pending_travel", {}) as Dictionary).is_empty(),
		"save repair discards the temporarily unusable route metadata"
	)
	_expect(
		NpcRouteLocationCoordinator.record_has_finish_replan_marker(
			disabled_saved_record,
			disabled_saved_record.get("activity", {}) as Dictionary
		),
		"save repair leaves a validated persisted finish-replan marker"
	)
	locations.npc_records[MOM_ID] = disabled_saved_record.duplicate(true)
	var save_live := _make_npc_with_machine(MOM_ID, finish_session)
	var save_machine := save_live.get_node("NpcStateMachine") as RouteTestMachine
	locations.live_npcs[MOM_ID] = save_live
	locations.call("synchronize_live_records")
	_expect(
		save_machine.paused_retry_sessions == [finish_session],
		"saving a migrated finish route pauses only its exact live movement session"
	)
	locations.live_npcs.erase(MOM_ID)
	save_live.queue_free()
	var newer_save_session := "save-replan-newer-session"
	var newer_save_record := disabled_saved_record.duplicate(true)
	newer_save_record["action"] = _action_descriptor(newer_save_session, "Talk")
	locations.npc_records[MOM_ID] = newer_save_record
	var newer_save_live := _make_npc_with_machine(MOM_ID, newer_save_session)
	var newer_save_machine := newer_save_live.get_node("NpcStateMachine") as RouteTestMachine
	locations.live_npcs[MOM_ID] = newer_save_live
	locations.call("synchronize_live_records")
	_expect(
		newer_save_machine.paused_retry_sessions.is_empty(),
		"save repair cannot pause a newer live action while preserving an older finish marker"
	)
	_expect(
		String((locations.get_record_snapshot(MOM_ID).get("action", {}) as Dictionary).get(
			"session_id", ""
		)) == newer_save_session,
		"save repair leaves the newer action descriptor untouched"
	)
	var newer_save_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		(newer_save_after.get("activity", {}) as Dictionary).is_empty(),
		"save repair discards the stale activity owned by the older marker"
	)
	_expect(
		(newer_save_after.get(
			NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY, {}
		) as Dictionary).is_empty(),
		"save repair removes a finish marker superseded by a newer action"
	)
	locations.live_npcs.erase(MOM_ID)
	newer_save_live.queue_free()
	locations.npc_records[MOM_ID] = finish_record
	var claim_result := simulator.call(
		"try_claim_spot", StringName(MOM_ID), finish_session, MOM_BED_ID, &"activity"
	) as Dictionary
	_expect(bool(claim_result.get("accepted", false)), "finish-cancellation fixture owns a real Mom-bed claim")
	_expect(
		not bool(locations.call(
			"cancel_pending_scheduled_travel",
			MOM_ID,
			"unregistered_finish_watchdog",
			true,
			finish_session
		)),
		"finish watchdog cancellation does not claim recovery without its registered live action"
	)
	_expect(
		not (locations.get_record_snapshot(MOM_ID).get("pending_travel", {}) as Dictionary).is_empty(),
		"failed finish watchdog recovery leaves its route retryable"
	)
	var retry_live := _make_npc_with_machine(MOM_ID, finish_session)
	var retry_machine := retry_live.get_node("NpcStateMachine") as RouteTestMachine
	locations.live_npcs[MOM_ID] = retry_live
	_expect(bool(locations.call(
		"cancel_pending_scheduled_travel",
		MOM_ID,
		"registered_finish_watchdog",
		true,
		finish_session
	)), "finish watchdog pauses the exact live session for a route retry")
	var retry_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	var retry_pending: Dictionary = retry_after.get("pending_travel", {})
	_expect(not retry_pending.is_empty(), "finish watchdog preserves its remaining route")
	_expect(int(retry_pending.get("movement_retry_count", 0)) == 1, "finish watchdog records one debuggable movement retry")
	_expect(
		String(retry_pending.get("last_movement_retry_reason", "")) == "registered_finish_watchdog",
		"finish watchdog records the latest retry reason"
	)
	_expect(
		String((retry_after.get("activity", {}) as Dictionary).get("session_id", "")) == finish_session,
		"finish watchdog preserves the committed activity"
	)
	_expect(
		String((retry_after.get("action", {}) as Dictionary).get("session_id", "")) == finish_session,
		"finish watchdog preserves the committed action"
	)
	_expect(
		int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1,
		"finish watchdog preserves the committed spot claim"
	)
	_expect(
		retry_machine.paused_retry_sessions == [finish_session],
		"finish watchdog pauses only its exact live action session"
	)
	simulator.call(
		"_rollback_pending_travel",
		StringName(MOM_ID),
		retry_pending,
		locations,
		"route_manager_disabled"
	)
	var structural_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		(structural_after.get("pending_travel", {}) as Dictionary).is_empty(),
		"structural route rollback clears an invalid route so it can be replanned"
	)
	_expect(
		NpcRouteLocationCoordinator.record_has_finish_replan_marker(
			structural_after,
			structural_after.get("activity", {}) as Dictionary
		),
		"structural route rollback persists that return replanning is still required"
	)
	var normalized_replan_record := locations.call(
		"_normalize_loaded_record", MOM_ID, structural_after
	) as Dictionary
	_expect(
		NpcRouteLocationCoordinator.record_has_finish_replan_marker(
			normalized_replan_record,
			normalized_replan_record.get("activity", {}) as Dictionary
		),
		"save/load normalization preserves a valid finish-replan marker"
	)
	_expect(
		not (normalized_replan_record.get("activity", {}) as Dictionary).is_empty(),
		"save/load normalization keeps the committed activity needed to return"
	)
	var marker_with_pending := structural_after.duplicate(true)
	marker_with_pending["pending_travel"] = finish_pending.duplicate(true)
	var normalized_marker_with_pending := locations.call(
		"_normalize_loaded_record", MOM_ID, marker_with_pending
	) as Dictionary
	_expect(
		(normalized_marker_with_pending.get(
			NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY, {}
		) as Dictionary).is_empty(),
		"save normalization never preserves a marker beside executable pending travel"
	)
	_expect(
		not (normalized_marker_with_pending.get("pending_travel", {}) as Dictionary).is_empty(),
		"a valid pending route wins over stale duplicate marker metadata"
	)
	var pending_superseded_by_action := marker_with_pending.duplicate(true)
	var superseding_session := "normalized-newer-action"
	pending_superseded_by_action["action"] = _action_descriptor(
		superseding_session, "Talk"
	)
	var normalized_superseded_pending := locations.call(
		"_normalize_loaded_record", MOM_ID, pending_superseded_by_action
	) as Dictionary
	_expect(
		(normalized_superseded_pending.get("activity", {}) as Dictionary).is_empty()
		and (normalized_superseded_pending.get("pending_travel", {}) as Dictionary).is_empty(),
		"save normalization discards an old finish route superseded by a newer action"
	)
	_expect(
		String((normalized_superseded_pending.get("action", {}) as Dictionary).get(
			"session_id", ""
		)) == superseding_session,
		"save normalization preserves the newer action that superseded the old route"
	)
	_expect(
		(normalized_superseded_pending.get(
			NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY, {}
		) as Dictionary).is_empty(),
		"save normalization removes the superseded route marker"
	)
	var orphan_marker_record := _base_record(HOME_SCENE, BEDROOM_TO_HOME_ARRIVAL)
	orphan_marker_record[NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY] = (
		structural_after.get(
			NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY, {}
		) as Dictionary
	).duplicate(true)
	var normalized_orphan := locations.call(
		"_normalize_loaded_record", MOM_ID, orphan_marker_record
	) as Dictionary
	_expect(
		(normalized_orphan.get(
			NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY, {}
		) as Dictionary).is_empty(),
		"save normalization removes a finish marker with no owning activity"
	)
	var cleanup_id := "finish-marker-cleanup-fixture"
	locations.npc_records[cleanup_id] = structural_after.duplicate(true)
	_expect(
		bool(locations.call(
			"rollback_scheduled_activity",
			cleanup_id,
			structural_after.get("activity", {}) as Dictionary,
			"marker_cleanup_test"
		)),
		"activity rollback accepts the marker cleanup fixture"
	)
	_expect(
		(locations.get_record_snapshot(cleanup_id).get(
			NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY, {}
		) as Dictionary).is_empty(),
		"activity rollback clears its obsolete finish marker"
	)
	locations.npc_records.erase(cleanup_id)
	_expect(
		String((structural_after.get("activity", {}) as Dictionary).get("session_id", "")) == finish_session,
		"structural finish rollback preserves the committed activity"
	)
	_expect(
		String((structural_after.get("action", {}) as Dictionary).get("session_id", "")) == finish_session,
		"structural finish rollback preserves the committed action"
	)
	_expect(
		int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1,
		"structural finish rollback preserves the committed spot claim"
	)
	_expect(
		retry_machine.cancelled_sessions.is_empty(),
		"structural finish rollback does not cancel the committed live action"
	)
	routes.call("set_enabled", false, "replan_marker_active_window_test")
	simulator.call(
		"_update_activity",
		StringName(MOM_ID),
		structural_after.duplicate(true),
		(structural_after.get("activity", {}) as Dictionary).duplicate(true),
		47.0,
		23.0,
		locations
	)
	routes.call("set_enabled", true, "replan_marker_active_window_test_complete")
	var active_window_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		NpcRouteLocationCoordinator.record_has_finish_replan_marker(
			active_window_after,
			active_window_after.get("activity", {}) as Dictionary
		),
		"an active sleep window cannot resume the bed from an intermediate scene"
	)
	_expect(
		not (active_window_after.get("activity", {}) as Dictionary).is_empty(),
		"failed replanning during an active sleep window preserves the activity and claim"
	)
	var terminal_record := structural_after.duplicate(true)
	var terminal_action: Dictionary = terminal_record.get("action", {})
	terminal_action["status"] = "failed"
	terminal_record["action"] = terminal_action
	var replan_door := Node2D.new()
	root.add_child(replan_door)
	var descriptor_count := retry_machine.movement_descriptors.size()
	_expect(bool(locations.call(
		"_request_pending_travel_movement",
		retry_machine,
		MOM_ID,
		retry_pending,
		replan_door,
		terminal_record
	)), "finish replanning remains executable after an interrupted route action")
	_expect(
		retry_machine.movement_descriptors.size() == descriptor_count + 1,
		"finish replanning emits one fresh movement descriptor"
	)
	if retry_machine.movement_descriptors.size() > descriptor_count:
		var replan_descriptor := retry_machine.movement_descriptors[-1]
		_expect(
			NpcActionSessionModel._descriptor_session_id(replan_descriptor) == finish_session,
			"finish replanning keeps the committed activity session"
		)
		_expect(
			String(replan_descriptor.get("status", "")) == "active",
			"finish replanning uses the active activity instead of a failed route action"
		)
	replan_door.queue_free()
	locations.live_npcs.erase(MOM_ID)
	retry_live.queue_free()
	var finish_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect((finish_after.get("pending_travel", {}) as Dictionary).is_empty(), "finish cancellation clears only the interrupted travel leg")
	_expect(
		String((finish_after.get("activity", {}) as Dictionary).get("session_id", "")) == finish_session,
		"nonterminal finish cancellation preserves the committed activity"
	)
	_expect(
		String((finish_after.get("action", {}) as Dictionary).get("session_id", "")) == finish_session,
		"nonterminal finish cancellation preserves the committed action"
	)
	_expect(
		int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1,
		"nonterminal finish cancellation preserves the committed spot claim"
	)
	simulator.call(
		"release_scheduled_activity_claim",
		MOM_BED_ID,
		"test_cleanup",
		finish_session,
		StringName(MOM_ID)
	)


func _test_finish_replan_marker_recovery(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var session_id := "offscreen-finish-marker-recovery"
	var home_plan := routes.call(
		"plan_route", HOME_SCENE, YARD_SCENE, StringName(MOM_ID)
	) as Dictionary
	_expect(bool(home_plan.get("accepted", false)), "Mom's offscreen return route plans")
	if not bool(home_plan.get("accepted", false)):
		return
	var pending := routes.call("attach_route_to_pending", {
		"mode": "finish",
		"target_scene_path": YARD_SCENE,
		"target_position": YARD_RETURN_POSITION,
		"requested_state_name": "",
		"requested_priority": 100,
		"spot_id": String(MOM_BED_ID),
		"action_session_id": session_id,
	}, home_plan) as Dictionary
	var record := _base_record(HOME_SCENE, BEDROOM_TO_HOME_ARRIVAL)
	var activity := _sleep_activity(session_id)
	activity["status"] = "active"
	record["activity"] = activity
	record["action"] = _action_descriptor(session_id, "Sleep")
	record[NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY] = (
		NpcRouteLocationCoordinator.make_finish_replan_marker(
			pending, HOME_SCENE, "offscreen_recovery_test"
		)
	)
	locations.npc_records[MOM_ID] = record
	locations.live_npcs.erase(MOM_ID)
	locations.active_scene_path = ""
	var claim_result := simulator.call(
		"try_claim_spot", StringName(MOM_ID), session_id, MOM_BED_ID, &"activity"
	) as Dictionary
	_expect(bool(claim_result.get("accepted", false)), "offscreen marker fixture owns Mom's bed claim")

	routes.call("set_enabled", false, "offscreen_marker_kill_switch_test")
	simulator.call(
		"_update_activity",
		StringName(MOM_ID),
		record.duplicate(true),
		activity.duplicate(true),
		47.0,
		23.0,
		locations
	)
	var blocked: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(blocked.get("scene_path", "")) == HOME_SCENE, "route kill switch keeps offscreen Mom in the intermediate scene")
	_expect((blocked.get("pending_travel", {}) as Dictionary).is_empty(), "failed offscreen replanning does not install partial travel")
	_expect(
		NpcRouteLocationCoordinator.record_has_finish_replan_marker(
			blocked, blocked.get("activity", {}) as Dictionary
		),
		"route kill switch preserves the offscreen finish marker"
	)
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1, "route kill switch preserves Mom's bed claim")

	routes.call("set_enabled", true, "offscreen_marker_kill_switch_test_complete")
	simulator.call(
		"_update_activity",
		StringName(MOM_ID),
		blocked.duplicate(true),
		(blocked.get("activity", {}) as Dictionary).duplicate(true),
		47.0,
		23.0,
		locations
	)
	var completed: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(completed.get("scene_path", "")) == YARD_SCENE, "re-enabled routing completes Mom's validated offscreen return")
	_expect((completed.get("activity", {}) as Dictionary).is_empty(), "offscreen return finishes the committed sleep activity")
	_expect((completed.get("pending_travel", {}) as Dictionary).is_empty(), "offscreen return consumes its temporary routed transaction")
	_expect(
		(completed.get(
			NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY, {}
		) as Dictionary).is_empty(),
		"offscreen return clears the consumed finish marker"
	)
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 0, "offscreen return releases Mom's bed claim once")

	var stale_session := "offscreen-finish-marker-cas-stale"
	var stale_pending := routes.call("attach_route_to_pending", {
		"mode": "finish",
		"target_scene_path": YARD_SCENE,
		"target_position": YARD_RETURN_POSITION,
		"spot_id": String(MOM_BED_ID),
		"action_session_id": stale_session,
	}, home_plan) as Dictionary
	var stale_record := _base_record(HOME_SCENE, BEDROOM_TO_HOME_ARRIVAL)
	var stale_activity := _sleep_activity(stale_session)
	stale_activity["status"] = "active"
	stale_record["activity"] = stale_activity
	stale_record["action"] = _action_descriptor(stale_session, "Sleep")
	stale_record[NpcRouteLocationCoordinator.FINISH_REPLAN_RECORD_KEY] = (
		NpcRouteLocationCoordinator.make_finish_replan_marker(
			stale_pending, HOME_SCENE, "offscreen_recovery_cas_test"
		)
	)
	locations.npc_records[MOM_ID] = stale_record
	var replacement := _base_record(HOME_SCENE, Vector2(91.0, 92.0))
	replacement["action"] = _action_descriptor("offscreen-finish-marker-cas-new", "Talk")
	var callback_state := {"replaced": false}
	var replace_during_plan := func(event: Dictionary) -> void:
		if not bool(callback_state["replaced"]) and String(event.get("event", "")) == "route_planned":
			callback_state["replaced"] = true
			locations.npc_records[MOM_ID] = replacement.duplicate(true)
	routes.call("_clear_cache")
	var diagnostic_signal: Signal = routes.route_diagnostic
	diagnostic_signal.connect(replace_during_plan)
	simulator.call(
		"_update_activity",
		StringName(MOM_ID),
		stale_record.duplicate(true),
		stale_activity.duplicate(true),
		47.0,
		23.0,
		locations
	)
	diagnostic_signal.disconnect(replace_during_plan)
	_expect(bool(callback_state["replaced"]), "offscreen replan CAS fixture replaced the record during diagnostics")
	_expect(
		locations.get_record_snapshot(MOM_ID) == replacement,
		"offscreen marker conversion cannot overwrite a newer record after route diagnostics"
	)


func _test_offscreen_scheduler_routes(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var original_definitions: Dictionary = simulator.spot_definitions
	var original_live_spots: Dictionary = simulator.live_spots
	var bed_definition := load("res://data/npc_spots/mom_bed.tres") as NpcSpotDefinition
	if bed_definition == null:
		_fail("offscreen scheduler route test requires Mom's bed definition")
		return
	simulator.spot_definitions = {MOM_BED_ID: bed_definition}
	simulator.live_spots = {}
	locations.active_scene_path = ""
	locations.live_npcs.erase(MOM_ID)
	var record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	record["node_state"] = {
		"social_stats": {
			"hp": 100.0,
			"sleep_need": 90.0,
		}
	}
	locations.npc_records[MOM_ID] = record
	var records := {MOM_ID: record.duplicate(true)}

	routes.call("set_enabled", false, "offscreen_scheduler_start_kill_switch_test")
	simulator.call(
		"_try_start_activity",
		StringName(MOM_ID),
		record.duplicate(true),
		47.0,
		23.0,
		locations,
		records
	)
	var blocked_start: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(blocked_start.get("scene_path", "")) == YARD_SCENE, "kill switch blocks a fresh offscreen cross-scene activity")
	_expect((blocked_start.get("pending_travel", {}) as Dictionary).is_empty(), "blocked offscreen start leaves no partial pending route")
	_expect((blocked_start.get("activity", {}) as Dictionary).is_empty(), "blocked offscreen start does not teleport Mom into bed")
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 0, "blocked offscreen start does not claim Mom's bed")

	routes.call("set_enabled", true, "offscreen_scheduler_start_kill_switch_test_complete")
	records[MOM_ID] = blocked_start.duplicate(true)
	simulator.call(
		"_try_start_activity",
		StringName(MOM_ID),
		blocked_start.duplicate(true),
		47.0,
		23.0,
		locations,
		records
	)
	var sleeping: Dictionary = locations.get_record_snapshot(MOM_ID)
	var sleeping_activity: Dictionary = sleeping.get("activity", {})
	_expect(String(sleeping.get("scene_path", "")) == BEDROOM_SCENE, "re-enabled offscreen scheduling follows Mom's validated route to the bedroom")
	_expect(String(sleeping_activity.get("spot_id", "")) == String(MOM_BED_ID), "routed offscreen scheduling commits Mom's sleep activity")
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1, "routed offscreen sleep owns exactly one bed claim")

	routes.call("set_enabled", false, "offscreen_scheduler_finish_kill_switch_test")
	simulator.call(
		"_finish_activity",
		StringName(MOM_ID),
		sleeping.duplicate(true),
		sleeping_activity.duplicate(true),
		MOM_BED_ID,
		locations
	)
	var blocked_finish: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(blocked_finish.get("scene_path", "")) == BEDROOM_SCENE, "kill switch blocks an ordinary offscreen cross-scene return")
	_expect(not (blocked_finish.get("activity", {}) as Dictionary).is_empty(), "blocked ordinary return preserves the committed sleep activity")
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1, "blocked ordinary return preserves Mom's bed claim")

	routes.call("set_enabled", true, "offscreen_scheduler_finish_kill_switch_test_complete")
	simulator.call(
		"_finish_activity",
		StringName(MOM_ID),
		blocked_finish.duplicate(true),
		(blocked_finish.get("activity", {}) as Dictionary).duplicate(true),
		MOM_BED_ID,
		locations
	)
	var returned: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(String(returned.get("scene_path", "")) == YARD_SCENE, "re-enabled offscreen finish follows Mom's validated return route")
	_expect((returned.get("activity", {}) as Dictionary).is_empty(), "routed offscreen finish clears the sleep activity")
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 0, "routed offscreen finish releases Mom's bed claim")
	simulator.spot_definitions = original_definitions
	simulator.live_spots = original_live_spots


func _test_live_scheduler_direct_door_kill_switch(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var bed_definition := load("res://data/npc_spots/mom_bed.tres") as NpcSpotDefinition
	if bed_definition == null:
		_fail("live direct-door scheduler test requires Mom's bed definition")
		return
	var original_definitions: Dictionary = simulator.spot_definitions
	var original_live_spots: Dictionary = simulator.live_spots
	var original_active_scene_path: String = locations.active_scene_path
	var routes_were_enabled := bool(routes.call("is_enabled"))
	simulator.spot_definitions = {MOM_BED_ID: bed_definition}
	simulator.live_spots = {}

	var npc := _make_npc_with_machine(MOM_ID, "")
	var machine := npc.get_node("NpcStateMachine") as RouteTestMachine
	locations.live_npcs[MOM_ID] = npc
	locations.active_scene_path = HOME_SCENE
	var start_door := _make_route_door(
		routes,
		&"household.realhometest_to_mom_bedroom",
		BEDROOM_SCENE
	)
	start_door.add_to_group(&"npc_travel_door")
	var start_record := _base_record(HOME_SCENE, Vector2(120.0, 368.0))
	start_record["node_state"] = {
		"social_stats": {
			"hp": 100.0,
			"sleep_need": 90.0,
		}
	}
	locations.npc_records[MOM_ID] = start_record
	_expect(
		simulator.call("_find_departure_door", BEDROOM_SCENE, npc) == start_door,
		"live scheduler fixture exposes the route-wired direct bedroom door"
	)
	routes.call("set_enabled", false, "live_direct_scheduler_start_kill_switch_test")
	simulator.call(
		"_try_start_activity",
		StringName(MOM_ID),
		start_record.duplicate(true),
		47.0,
		23.0,
		locations,
		{MOM_ID: start_record.duplicate(true)}
	)
	var blocked_start: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect((blocked_start.get("pending_travel", {}) as Dictionary).is_empty(), "direct-door kill switch installs no pending start")
	_expect((blocked_start.get("activity", {}) as Dictionary).is_empty(), "direct-door kill switch commits no activity")
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 0, "direct-door kill switch claims no bed before departure")
	_expect(machine.movement_descriptors.is_empty(), "direct-door kill switch assigns no movement before departure")

	var finish_session := "live-direct-finish-kill-switch"
	var finish_activity := _sleep_activity(finish_session)
	finish_activity["status"] = "active"
	finish_activity["return_scene_path"] = HOME_SCENE
	finish_activity["return_position"] = BEDROOM_TO_HOME_ARRIVAL
	var claim_result := simulator.call(
		"try_claim_spot", StringName(MOM_ID), finish_session, MOM_BED_ID, &"activity"
	) as Dictionary
	_expect(bool(claim_result.get("accepted", false)), "live direct-finish fixture owns Mom's committed bed claim")
	if bool(claim_result.get("accepted", false)):
		finish_activity["reservation_ids"] = [String(claim_result.get("reservation_id", ""))]
	var finish_record := _base_record(BEDROOM_SCENE, BED_POSITION)
	finish_record["activity"] = finish_activity
	finish_record["action"] = _action_descriptor(finish_session, "Sleep")
	locations.npc_records[MOM_ID] = finish_record
	locations.active_scene_path = BEDROOM_SCENE
	machine.active_session_id = finish_session
	machine.session_executable = true
	var finish_door := _make_route_door(
		routes,
		&"household.mom_bedroom_to_realhometest",
		HOME_SCENE
	)
	finish_door.add_to_group(&"npc_travel_door")
	_expect(
		simulator.call("_find_departure_door", HOME_SCENE, npc) == finish_door,
		"live finish fixture exposes the route-wired direct home door"
	)
	simulator.call(
		"_finish_activity",
		StringName(MOM_ID),
		finish_record.duplicate(true),
		finish_activity.duplicate(true),
		MOM_BED_ID,
		locations
	)
	var blocked_finish: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		String((blocked_finish.get("activity", {}) as Dictionary).get("session_id", "")) == finish_session,
		"direct-door kill switch preserves the committed live activity"
	)
	_expect((blocked_finish.get("pending_travel", {}) as Dictionary).is_empty(), "blocked live finish installs no pending return")
	_expect(int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 1, "blocked live finish preserves the committed bed claim")
	_expect(machine.movement_descriptors.is_empty(), "blocked live finish assigns no return movement")

	simulator.call(
		"release_scheduled_activity_claim",
		MOM_BED_ID,
		"live_direct_scheduler_test_cleanup",
		finish_session,
		StringName(MOM_ID)
	)
	routes.call("set_enabled", routes_were_enabled, "live_direct_scheduler_test_restore")
	locations.live_npcs.erase(MOM_ID)
	locations.active_scene_path = original_active_scene_path
	simulator.spot_definitions = original_definitions
	simulator.live_spots = original_live_spots
	start_door.free()
	finish_door.free()
	npc.free()


func _test_wired_direct_door_kill_switch(routes: Node, locations: Node) -> void:
	var session_id := "wired-direct-kill-switch"
	var pending := {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"requested_state_name": "Sleep",
		"requested_priority": 70,
		"activity": _sleep_activity(session_id),
	}
	var record := _base_record(HOME_SCENE, Vector2(120.0, 368.0))
	record["action"] = _action_descriptor(session_id, "Sleep")
	record["pending_travel"] = pending
	locations.npc_records[MOM_ID] = record
	var npc := _make_npc_with_machine(MOM_ID, session_id)
	npc.add_to_group(&"npc")
	locations.live_npcs[MOM_ID] = npc
	var door := _make_route_door(
		routes,
		&"household.realhometest_to_mom_bedroom",
		BEDROOM_SCENE
	)
	var pristine: Dictionary = locations.get_record_snapshot(MOM_ID)
	routes.call("set_enabled", false, "wired_direct_door_kill_switch_test")
	_expect(
		not door.try_travel_npc(npc),
		"the route kill switch blocks a route-wired direct door transaction"
	)
	_expect(
		locations.get_record_snapshot(MOM_ID) == pristine,
		"a kill-switch rejection leaves direct pending travel unchanged"
	)
	routes.call("set_enabled", true, "wired_direct_door_kill_switch_test_complete")
	locations.live_npcs.erase(MOM_ID)
	npc.queue_free()
	door.queue_free()


func _test_actual_door_handoff_chain(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var session_id := "actual-two-door-handoff"
	var plan := routes.call(
		"plan_route", YARD_SCENE, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	var pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"requested_state_name": "Sleep",
		"requested_priority": 70,
		"activity": _sleep_activity(session_id),
	}, plan) as Dictionary
	var record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	record["action"] = _action_descriptor(session_id, "Sleep")
	record["pending_travel"] = pending
	locations.npc_records[MOM_ID] = record
	locations.live_npcs.erase(MOM_ID)

	var first_npc := _make_npc_with_machine(MOM_ID, session_id)
	first_npc.add_to_group(&"npc")
	locations.live_npcs[MOM_ID] = first_npc
	var yard_door := _make_route_door(
		routes,
		&"household.realtest1_to_realhometest",
		HOME_SCENE
	)
	_expect(
		yard_door.try_travel_npc(first_npc),
		"the actual yard door accepts Mom's first scheduled route handoff"
	)
	var at_home: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		String(at_home.get("scene_path", "")) == HOME_SCENE and _pending_hop_index(at_home) == 1,
		"the actual first door commits only the home leg"
	)

	var second_npc := _make_npc_with_machine(MOM_ID, session_id)
	second_npc.add_to_group(&"npc")
	locations.live_npcs[MOM_ID] = second_npc
	var bedroom_door := _make_route_door(
		routes,
		&"household.realhometest_to_mom_bedroom",
		BEDROOM_SCENE
	)
	_expect(
		bedroom_door.try_travel_npc(second_npc),
		"the actual home door accepts Mom's final bedroom handoff"
	)
	var at_bedroom: Dictionary = locations.get_record_snapshot(MOM_ID)
	var committed_activity: Dictionary = at_bedroom.get("activity", {})
	var committed_session := String(committed_activity.get(
		"session_id", committed_activity.get("action_session_id", "")
	))
	_expect(
		String(at_bedroom.get("scene_path", "")) == BEDROOM_SCENE
		and String(committed_activity.get("spot_id", "")) == String(MOM_BED_ID),
		"the two real door APIs commit Mom's owned sleep activity in her bedroom"
	)
	locations.call(
		"finish_scheduled_activity",
		MOM_ID,
		YARD_SCENE,
		YARD_RETURN_POSITION,
		committed_session
	)
	yard_door.queue_free()
	bedroom_door.queue_free()
	_expect(
		int(simulator.spot_claim_counts.get(MOM_BED_ID, 0)) == 0,
		"actual door handoff test releases its Mom-bed claim"
	)


func _test_pending_session_guards(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var pending_session := "route-session-guard-old"
	var newer_session := "route-session-guard-new"
	var plan := routes.call(
		"plan_route", YARD_SCENE, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	var pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"activity": _sleep_activity(pending_session),
	}, plan) as Dictionary
	var record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	record["action"] = _action_descriptor(newer_session, "Talk")
	record["pending_travel"] = pending
	locations.npc_records[MOM_ID] = record
	var guarded_npc := _make_npc_with_machine(MOM_ID, newer_session)
	locations.live_npcs[MOM_ID] = guarded_npc
	var first_hop := routes.call(
		"get_current_hop", pending, YARD_SCENE, StringName(MOM_ID)
	) as Dictionary
	var pristine: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			guarded_npc,
			StringName(String(first_hop.get("edge_id", ""))),
			HOME_SCENE
		)),
		"a newer live action cannot execute an older routed transaction"
	)
	_expect(
		locations.get_record_snapshot(MOM_ID) == pristine,
		"routed session mismatch leaves the canonical record unchanged"
	)
	_expect(
		not bool(locations.call(
			"complete_pending_scheduled_travel", guarded_npc, BEDROOM_SCENE
		)),
		"a newer live action cannot execute an older direct transaction"
	)
	var guarded_machine := guarded_npc.get_node("NpcStateMachine") as RouteTestMachine
	var active_move_state := Node.new()
	active_move_state.name = "MoveToTarget"
	guarded_machine.add_child(active_move_state)
	guarded_machine.current_state = active_move_state
	var guarded_door := _make_route_door(
		routes,
		StringName(String(first_hop.get("edge_id", ""))),
		HOME_SCENE
	)
	guarded_door.add_to_group(&"npc_travel_door")
	guarded_machine.move_target = guarded_door
	_expect(
		simulator.call(
			"_get_active_departure_door",
			guarded_npc,
			HOME_SCENE,
			StringName(String(first_hop.get("edge_id", ""))),
			pending_session
		) == null,
		"the active-door shortcut rejects a newer session targeting the same door"
	)
	guarded_machine.active_session_id = pending_session
	guarded_machine.session_executable = false
	_expect(
		simulator.call(
			"_get_active_departure_door",
			guarded_npc,
			HOME_SCENE,
			StringName(String(first_hop.get("edge_id", ""))),
			pending_session
		) == null,
		"the active-door shortcut rejects a terminal matching session"
	)
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			guarded_npc,
			StringName(String(first_hop.get("edge_id", ""))),
			HOME_SCENE
		)),
		"a terminal action cannot authorize a pending route even with the same ID"
	)
	guarded_machine.session_executable = true
	_expect(
		simulator.call(
			"_get_active_departure_door",
			guarded_npc,
			HOME_SCENE,
			StringName(String(first_hop.get("edge_id", ""))),
			pending_session
		) == guarded_door,
		"the active-door shortcut accepts the exact executable session"
	)
	var swap_during_diagnostic := func(event: Dictionary) -> void:
		if String(event.get("event", "")) == "hop_advance_validated":
			guarded_machine.active_session_id = newer_session
	var diagnostic_signal: Signal = routes.route_diagnostic
	diagnostic_signal.connect(swap_during_diagnostic)
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			guarded_npc,
			StringName(String(first_hop.get("edge_id", ""))),
			HOME_SCENE
		)),
		"a synchronous route listener cannot swap sessions between validation and commit"
	)
	diagnostic_signal.disconnect(swap_during_diagnostic)
	_expect(
		locations.get_record_snapshot(MOM_ID) == pristine,
		"session replacement during diagnostics leaves the route record unchanged"
	)
	guarded_door.queue_free()
	locations.live_npcs.erase(MOM_ID)
	guarded_npc.queue_free()

	var machine_less_npc := _make_npc(MOM_ID)
	locations.live_npcs[MOM_ID] = machine_less_npc
	_expect(
		not bool(locations.call(
			"complete_pending_route_hop",
			machine_less_npc,
			StringName(String(first_hop.get("edge_id", ""))),
			HOME_SCENE
		)),
		"session-bound route callbacks require a live state machine"
	)
	_expect(
		NpcActionSessionModel.live_npc_matches_pending_travel_session(
			machine_less_npc, {"target_scene_path": HOME_SCENE}
		),
		"legacy pending travel without a session remains compatible"
	)
	locations.live_npcs.erase(MOM_ID)
	machine_less_npc.queue_free()


func _make_route_door(
	routes: Node,
	edge_id: StringName,
	target_scene_path: String
) -> NpcTravelDoor:
	var door := NpcTravelDoor.new()
	door.target_scene_path = target_scene_path
	door.route_edge = routes.call("get_edge_resource", edge_id) as NpcSceneRouteEdge
	root.add_child(door)
	return door


func _test_offscreen_route_cas_preserves_newer_pending(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var stale_session := "offscreen-route-cas-stale"
	var newer_session := "offscreen-route-cas-newer"
	var plan := routes.call(
		"plan_route", YARD_SCENE, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	var stale_pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"activity": _sleep_activity(stale_session),
	}, plan) as Dictionary
	var newer_pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"activity": _sleep_activity(newer_session),
	}, plan) as Dictionary
	var record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	record["action"] = _action_descriptor(stale_session, "Sleep")
	record["pending_travel"] = stale_pending
	locations.npc_records[MOM_ID] = record
	locations.live_npcs.erase(MOM_ID)
	locations.active_scene_path = HOME_SCENE
	var replace_pending_during_diagnostic := func(event: Dictionary) -> void:
		if String(event.get("event", "")) != "hop_advance_validated":
			return
		var replacement: Dictionary = locations.npc_records[MOM_ID].duplicate(true)
		replacement["action"] = _action_descriptor(newer_session, "Sleep")
		replacement["pending_travel"] = newer_pending
		locations.npc_records[MOM_ID] = replacement
	var diagnostic_signal: Signal = routes.route_diagnostic
	diagnostic_signal.connect(replace_pending_during_diagnostic)
	simulator.call(
		"_update_pending_travel",
		StringName(MOM_ID),
		record,
		stale_pending,
		23.0,
		locations
	)
	diagnostic_signal.disconnect(replace_pending_during_diagnostic)
	var after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		(after.get("pending_travel", {}) as Dictionary) == newer_pending,
		"offscreen stale-hop rollback cannot erase a newer pending transaction"
	)
	_expect(
		String(after.get("scene_path", "")) == YARD_SCENE,
		"offscreen CAS rejection leaves the newer transaction in its source scene"
	)

	var same_session_pending := stale_pending.duplicate(true)
	same_session_pending["movement_retry_count"] = 7
	var same_session_record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	same_session_record["action"] = _action_descriptor(stale_session, "Sleep")
	same_session_record["pending_travel"] = stale_pending
	locations.npc_records[MOM_ID] = same_session_record
	var replace_same_session_during_diagnostic := func(event: Dictionary) -> void:
		if String(event.get("event", "")) != "hop_advance_validated":
			return
		var replacement: Dictionary = locations.npc_records[MOM_ID].duplicate(true)
		replacement["pending_travel"] = same_session_pending
		locations.npc_records[MOM_ID] = replacement
	diagnostic_signal.connect(replace_same_session_during_diagnostic)
	simulator.call(
		"_update_pending_travel",
		StringName(MOM_ID),
		same_session_record,
		stale_pending,
		23.0,
		locations
	)
	diagnostic_signal.disconnect(replace_same_session_during_diagnostic)
	var same_session_after: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		(same_session_after.get("pending_travel", {}) as Dictionary) == same_session_pending,
		"offscreen stale rollback preserves a newer pending route from the same activity session"
	)
	_expect(
		String(same_session_after.get("scene_path", "")) == YARD_SCENE,
		"same-session CAS rejection leaves the replacement route at its source"
	)


func _test_offscreen_active_destination_arrival(
	routes: Node,
	locations: Node,
	simulator: Node
) -> void:
	var session_id := "offscreen-active-bedroom-entry"
	var plan := routes.call(
		"plan_route", YARD_SCENE, BEDROOM_SCENE, StringName(MOM_ID)
	) as Dictionary
	var pending := routes.call("attach_route_to_pending", {
		"mode": "start",
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"requested_state_name": "Sleep",
		"requested_priority": 70,
		"activity": _sleep_activity(session_id),
	}, plan) as Dictionary
	var record := _base_record(YARD_SCENE, YARD_RETURN_POSITION)
	record["action"] = _action_descriptor(session_id, "Sleep")
	record["pending_travel"] = pending
	locations.npc_records[MOM_ID] = record
	locations.live_npcs.erase(MOM_ID)
	locations.active_scene_path = HOME_SCENE
	simulator.call(
		"_update_pending_travel",
		StringName(MOM_ID),
		record,
		pending,
		23.0,
		locations
	)
	var intermediate: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		String(intermediate.get("scene_path", "")) == HOME_SCENE,
		"an offscreen NPC commits only one hop when that intermediate scene is loaded"
	)
	_expect(
		intermediate.get("last_position", Vector2.ZERO) == YARD_TO_HOME_ARRIVAL,
		"loaded intermediate scene uses its authored edge arrival"
	)
	_expect(
		_pending_hop_index(intermediate) == 1
		and (intermediate.get("activity", {}) as Dictionary).is_empty(),
		"loaded intermediate arrival preserves the remaining route without early activity commit"
	)
	var pending_from_home: Dictionary = intermediate.get("pending_travel", {})
	locations.active_scene_path = BEDROOM_SCENE
	simulator.call(
		"_update_pending_travel",
		StringName(MOM_ID),
		intermediate,
		pending_from_home,
		23.0,
		locations
	)
	var arrived: Dictionary = locations.get_record_snapshot(MOM_ID)
	_expect(
		String(arrived.get("scene_path", "")) == BEDROOM_SCENE,
		"offscreen multihop travel commits into the loaded final scene"
	)
	_expect(
		arrived.get("last_position", Vector2.ZERO) == Vector2(-320.0, 420.0),
		"loaded final scene uses the authored final-edge arrival instead of an ambiguous reverse-door scan"
	)
	var committed_activity: Dictionary = arrived.get("activity", {})
	var committed_session := String(committed_activity.get(
		"session_id", committed_activity.get("action_session_id", "")
	))
	locations.call(
		"finish_scheduled_activity",
		MOM_ID,
		YARD_SCENE,
		YARD_RETURN_POSITION,
		committed_session
	)
	locations.active_scene_path = ""


func _base_record(scene_path: String, position: Vector2) -> Dictionary:
	return {
		"npc_id": MOM_ID,
		"node_name": "MomRouteTestNpc",
		"npc_scene_path": "",
		"home_scene_path": YARD_SCENE,
		"home_position": YARD_RETURN_POSITION,
		"scene_path": scene_path,
		"previous_scene_path": "",
		"last_position": position,
		"node_state": {},
		"activity": {},
		"action": {},
		"pending_travel": {},
		"inventory": {},
		"spawn_random": false,
		"last_travel_msec": 0,
	}


func _sleep_activity(session_id: String) -> Dictionary:
	return {
		"session_id": session_id,
		"action_session_id": session_id,
		"activity_id": session_id,
		"action_kind": "Sleep",
		"state_name": "Sleep",
		"source": "schedule",
		"spot_id": String(MOM_BED_ID),
		"target_scene_path": BEDROOM_SCENE,
		"target_position": BED_POSITION,
		"return_scene_path": YARD_SCENE,
		"return_position": YARD_RETURN_POSITION,
		"priority": 70,
		"status": "proposed",
	}


func _action_descriptor(session_id: String, action_kind: String) -> Dictionary:
	return {
		"session_id": session_id,
		"action_session_id": session_id,
		"activity_id": session_id,
		"action_kind": action_kind,
		"state_name": action_kind,
		"source": "schedule",
		"spot_id": String(MOM_BED_ID),
		"target_persistent_id": String(MOM_BED_ID),
		"scene_path": BEDROOM_SCENE,
		"priority": 70,
		"status": "active",
	}


func _make_npc(npc_id: String) -> RouteTestNpc:
	var npc := RouteTestNpc.new(npc_id)
	root.add_child(npc)
	return npc


func _make_npc_with_machine(npc_id: String, session_id: String) -> RouteTestNpc:
	var npc := RouteTestNpc.new(npc_id)
	var machine := RouteTestMachine.new(session_id)
	machine.name = "NpcStateMachine"
	npc.add_child(machine)
	root.add_child(npc)
	return npc


func _pending_hop_index(record: Dictionary) -> int:
	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary):
		return -1
	var scene_route = pending.get("scene_route", {})
	if not (scene_route is Dictionary):
		return -1
	return int(scene_route.get("hop_index", -1))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("NPC_MULTISCENE_SCHEDULED_TRAVEL_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
