class_name NpcRouteLocationCoordinator extends RefCounted

const NpcActionSessionModel = preload("res://scripts/systems/npc_action_session.gd")
const FINISH_REPLAN_RECORD_KEY := "finish_route_replan"

# Owns the route-specific half of a location transaction. NpcLocations retains
# canonical record mutation and signals through one narrow commit method.


static func supports_offscreen_route_transactions(locations: Node) -> bool:
	return (
		locations != null
		and locations.has_method("get_record_snapshot")
		and locations.has_method("is_npc_live")
		and locations.has_method("update_simulated_record")
	)


static func complete_pending_hop(
	locations: Node,
	npc: Node,
	route_edge_id: StringName,
	door_target_scene_path: String
) -> bool:
	if (
		locations == null
		or npc == null
		or route_edge_id == &""
		or door_target_scene_path.is_empty()
	):
		return false
	var npc_id := String(locations.call("get_npc_id", npc))
	if npc_id.is_empty():
		return false
	var record = (
		locations.call("get_record_snapshot", npc_id)
		if locations.has_method("get_record_snapshot")
		else locations.call("get_npc_location", npc_id)
	)
	if not (record is Dictionary) or record.is_empty():
		return false
	# Only the body currently registered for this persistent NPC may mutate its
	# travel transaction. This rejects stale callbacks from queued bodies.
	if (
		not locations.has_method("get_live_npc")
		or locations.call("get_live_npc", npc_id) != npc
	):
		return false
	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary) or pending.is_empty():
		return false
	# A newer live action must never execute an older pending route merely because
	# both happened to target the same door.
	if not NpcActionSessionModel.live_npc_matches_pending_travel_session(
		npc, pending, &"MoveToTarget"
	):
		return false
	var scene_route = pending.get("scene_route", {})
	var route_manager := locations.get_node_or_null("/root/NpcSceneRoutes")
	if not (scene_route is Dictionary) or scene_route.is_empty():
		if route_manager == null or not route_manager.has_method("validate_edge_execution"):
			return false
		var edge_validation = route_manager.call(
			"validate_edge_execution",
			route_edge_id,
			String(record.get("scene_path", "")),
			door_target_scene_path,
			StringName(npc_id)
		)
		if (
			not (edge_validation is Dictionary)
			or not bool(edge_validation.get("accepted", false))
		):
			return false
		var latest = locations.call("get_record_snapshot", npc_id)
		if not (latest is Dictionary) or latest.is_empty():
			return false
		var latest_pending = latest.get("pending_travel", {})
		if (
			locations.call("get_live_npc", npc_id) != npc
			or String(latest.get("scene_path", "")) != String(record.get("scene_path", ""))
			or not (latest_pending is Dictionary)
			or latest_pending != pending
			or not NpcActionSessionModel.live_npc_matches_pending_travel_session(
				npc, pending, &"MoveToTarget"
			)
		):
			return false
		return bool(locations.call(
			"complete_pending_scheduled_travel", npc, door_target_scene_path
		))

	if route_manager == null or not route_manager.has_method("advance_pending_route"):
		return false
	var advance_result = route_manager.call(
		"advance_pending_route",
		pending,
		route_edge_id,
		door_target_scene_path,
		StringName(npc_id),
		String(record.get("scene_path", ""))
	)
	if not (advance_result is Dictionary) or not bool(advance_result.get("accepted", false)):
		return false
	# Route diagnostics are synchronous extension points. Recheck after planning so
	# a listener cannot replace the live action between validation and commit.
	if not NpcActionSessionModel.live_npc_matches_pending_travel_session(
		npc, pending, &"MoveToTarget"
	):
		return false
	var updated_pending = advance_result.get("pending_travel", {})
	if not (updated_pending is Dictionary):
		return false
	var arrival_position = advance_result.get("arrival_position", Vector2.ZERO)
	if not (arrival_position is Vector2):
		arrival_position = Vector2.ZERO
	var route_complete := bool(advance_result.get("complete", false))
	if route_complete:
		# NpcLocations performs the same live-identity and pending-record CAS used
		# for intermediate hops before entering the existing destination transaction.
		if not locations.has_method("_commit_pending_route_destination"):
			return false
		return bool(locations.call(
			"_commit_pending_route_destination",
			npc_id,
			npc,
			pending,
			updated_pending,
			String(record.get("scene_path", "")),
			door_target_scene_path,
			arrival_position
		))
	if not bool(locations.call(
		"_commit_pending_route_advance",
		npc_id,
		npc,
		pending,
		updated_pending,
		String(record.get("scene_path", "")),
		door_target_scene_path,
		arrival_position
	)):
		return false
	return true


static func commit_route_destination(
	locations: Node,
	npc_id: String,
	pending_travel: Dictionary,
	door_target_scene_path: String,
	arrival_position: Vector2
) -> bool:
	var target_position = pending_travel.get("target_position", Vector2.ZERO)
	if not (target_position is Vector2):
		target_position = Vector2.ZERO
	var mode := String(pending_travel.get("mode", "start"))
	if mode == "finish":
		return bool(locations.call(
			"finish_scheduled_activity",
			npc_id,
			door_target_scene_path,
			target_position,
			String(pending_travel.get("action_session_id", "")),
			arrival_position
		))
	if mode == "social":
		locations.call(
			"cancel_pending_scheduled_travel",
			npc_id,
			"unsupported_routed_social_travel",
			true
		)
		return false

	var activity = pending_travel.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return false
	activity = activity.duplicate(true)
	var world_time := locations.get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		activity["last_total_hours"] = float(snapshot.get("total_hours", 0.0))
	return bool(locations.call(
		"begin_scheduled_activity",
		npc_id,
		activity,
		door_target_scene_path,
		target_position,
		arrival_position
	))


static func make_finish_replan_marker(
	pending_travel: Dictionary,
	current_scene_path: String,
	reason: String
) -> Dictionary:
	var session_id := NpcActionSessionModel.pending_travel_session_id(pending_travel)
	var target_scene_path := String(pending_travel.get("target_scene_path", ""))
	if session_id.is_empty() or current_scene_path.is_empty() or target_scene_path.is_empty():
		return {}
	var marker := {
		"session_id": session_id,
		"current_scene_path": current_scene_path,
		"target_scene_path": target_scene_path,
		"reason": reason,
	}
	var target_position = pending_travel.get("target_position", null)
	if target_position is Vector2:
		marker["target_position"] = target_position
	return marker


static func clear_finish_replan_marker(record: Dictionary) -> void:
	record[FINISH_REPLAN_RECORD_KEY] = {}


static func record_has_finish_replan_marker(
	record: Dictionary,
	activity: Dictionary
) -> bool:
	var marker = record.get(FINISH_REPLAN_RECORD_KEY, {})
	var pending = record.get("pending_travel", {})
	if (
		not (marker is Dictionary)
		or marker.is_empty()
		or activity.is_empty()
		or not (pending is Dictionary)
		or not pending.is_empty()
	):
		return false
	var activity_session := NpcActionSessionModel._descriptor_session_id(activity)
	var return_scene_path := String(activity.get("return_scene_path", ""))
	var action = record.get("action", {})
	if not (action is Dictionary):
		return false
	var action_session := NpcActionSessionModel._descriptor_session_id(action)
	return (
		not activity_session.is_empty()
		and (action.is_empty() or action_session == activity_session)
		and String(marker.get("session_id", "")) == activity_session
		and String(marker.get("current_scene_path", ""))
			== String(record.get("scene_path", ""))
		and not return_scene_path.is_empty()
		and String(marker.get("target_scene_path", "")) == return_scene_path
	)


static func install_offscreen_finish_route(
	locations: Node,
	route_manager: Node,
	npc_id: StringName,
	expected_record: Dictionary,
	expected_activity: Dictionary,
	pending_travel: Dictionary,
	require_replan_marker: bool = false
) -> bool:
	# Route planning emits synchronous diagnostics, so the canonical record is
	# re-read and compared after validation before the marker becomes executable.
	var npc_key := String(npc_id)
	if (
		locations == null
		or route_manager == null
		or npc_key.is_empty()
		or expected_record.is_empty()
		or expected_activity.is_empty()
		or pending_travel.is_empty()
		or not locations.has_method("get_record_snapshot")
		or not locations.has_method("is_npc_live")
		or not locations.has_method("update_simulated_record")
		or not route_manager.has_method("validate_pending_route")
	):
		return false
	if bool(locations.call("is_npc_live", npc_key)):
		return false
	var expected_pending = expected_record.get("pending_travel", {})
	var expected_action = expected_record.get("action", {})
	var expected_marker = expected_record.get(FINISH_REPLAN_RECORD_KEY, {})
	if (
		not (expected_pending is Dictionary)
		or not expected_pending.is_empty()
		or not (expected_action is Dictionary)
		or not (expected_marker is Dictionary)
	):
		return false

	var expected_session := NpcActionSessionModel._descriptor_session_id(expected_activity)
	var expected_action_session := NpcActionSessionModel._descriptor_session_id(expected_action)
	var expected_scene_path := String(expected_record.get("scene_path", ""))
	if (
		expected_session.is_empty()
		or expected_scene_path.is_empty()
		or (not expected_action.is_empty() and expected_action_session != expected_session)
		or (
			require_replan_marker
			and not record_has_finish_replan_marker(expected_record, expected_activity)
		)
		or (not require_replan_marker and not expected_marker.is_empty())
		or String(pending_travel.get("mode", "")) != "finish"
		or NpcActionSessionModel.pending_travel_session_id(pending_travel) != expected_session
		or String(pending_travel.get("target_scene_path", ""))
			!= String(expected_activity.get("return_scene_path", ""))
	):
		return false

	var validation = route_manager.call(
		"validate_pending_route", pending_travel, expected_scene_path, npc_id
	)
	if not (validation is Dictionary) or not bool(validation.get("accepted", false)):
		return false

	var latest = locations.call("get_record_snapshot", npc_key)
	if not (latest is Dictionary) or latest.is_empty():
		return false
	var latest_activity = latest.get("activity", {})
	var latest_action = latest.get("action", {})
	var latest_marker = latest.get(FINISH_REPLAN_RECORD_KEY, {})
	var latest_pending = latest.get("pending_travel", {})
	if (
		bool(locations.call("is_npc_live", npc_key))
		or String(latest.get("scene_path", "")) != expected_scene_path
		or not (latest_activity is Dictionary)
		or latest_activity != expected_activity
		or not (latest_action is Dictionary)
		or latest_action != expected_action
		or not (latest_marker is Dictionary)
		or latest_marker != expected_marker
		or not (latest_pending is Dictionary)
		or not latest_pending.is_empty()
		or (
			require_replan_marker
			and not record_has_finish_replan_marker(latest, latest_activity)
		)
	):
		return false

	var updated_record: Dictionary = latest.duplicate(true)
	updated_record["pending_travel"] = pending_travel.duplicate(true)
	clear_finish_replan_marker(updated_record)
	locations.call("update_simulated_record", npc_key, updated_record)

	var committed = locations.call("get_record_snapshot", npc_key)
	return (
		committed is Dictionary
		and not bool(locations.call("is_npc_live", npc_key))
		and committed.get("pending_travel", {}) == pending_travel
		and (committed.get(FINISH_REPLAN_RECORD_KEY, {}) as Dictionary).is_empty()
		and committed.get("activity", {}) == expected_activity
	)


static func install_offscreen_start_route(
	locations: Node,
	route_manager: Node,
	npc_id: StringName,
	expected_record: Dictionary,
	pending_travel: Dictionary
) -> bool:
	var npc_key := String(npc_id)
	var activity = pending_travel.get("activity", {})
	if (
		locations == null
		or route_manager == null
		or npc_key.is_empty()
		or expected_record.is_empty()
		or not (activity is Dictionary)
		or activity.is_empty()
		or String(pending_travel.get("mode", "")) != "start"
		or not locations.has_method("get_record_snapshot")
		or not locations.has_method("is_npc_live")
		or not locations.has_method("update_simulated_record")
		or not route_manager.has_method("validate_pending_route")
	):
		return false
	var expected_pending = expected_record.get("pending_travel", {})
	var expected_activity = expected_record.get("activity", {})
	var expected_action = expected_record.get("action", {})
	if (
		not (expected_pending is Dictionary)
		or not (expected_activity is Dictionary)
		or not (expected_action is Dictionary)
	):
		return false
	var activity_session := NpcActionSessionModel._descriptor_session_id(activity)
	if (
		activity_session.is_empty()
		or NpcActionSessionModel.pending_travel_session_id(pending_travel)
			!= activity_session
		or not expected_pending.is_empty()
		or not expected_activity.is_empty()
		or _action_blocks_offscreen_start(expected_action)
		or bool(locations.call("is_npc_live", npc_key))
	):
		return false
	var source_scene_path := String(expected_record.get("scene_path", ""))
	var validation = route_manager.call(
		"validate_pending_route", pending_travel, source_scene_path, npc_id
	)
	if not (validation is Dictionary) or not bool(validation.get("accepted", false)):
		return false
	var latest = locations.call("get_record_snapshot", npc_key)
	if (
		not (latest is Dictionary)
		or latest != expected_record
		or bool(locations.call("is_npc_live", npc_key))
	):
		return false
	var action_session := NpcActionSessionModel.from_legacy_activity(npc_key, activity)
	if action_session == null:
		return false
	action_session.status = NpcActionSessionModel.Status.ACTIVE
	var updated_record: Dictionary = latest.duplicate(true)
	updated_record["action"] = action_session.to_descriptor()
	updated_record["pending_travel"] = pending_travel.duplicate(true)
	clear_finish_replan_marker(updated_record)
	locations.call("update_simulated_record", npc_key, updated_record)
	var committed = locations.call("get_record_snapshot", npc_key)
	return (
		committed is Dictionary
		and not bool(locations.call("is_npc_live", npc_key))
		and committed.get("pending_travel", {}) == pending_travel
		and NpcActionSessionModel._descriptor_session_id(committed.get("action", {}))
			== activity_session
	)


static func _action_blocks_offscreen_start(action: Dictionary) -> bool:
	if action.is_empty():
		return false
	# A terminal live action can be captured during scene teardown before the
	# state machine clears it. It cannot execute offscreen and must not deadlock
	# the next scheduled route. Non-terminal actions remain protected.
	return String(action.get("status", "active")).to_lower() not in [
		"cancelling", "cancelled", "completed", "failed",
	]


static func record_can_migrate_finish_route_to_replan(
	record: Dictionary,
	activity: Dictionary
) -> bool:
	var pending = record.get("pending_travel", {})
	if (
		not (pending is Dictionary)
		or pending.is_empty()
		or String(pending.get("mode", "start")) != "finish"
	):
		return false
	var activity_session := NpcActionSessionModel._descriptor_session_id(activity)
	if (
		activity_session.is_empty()
		or NpcActionSessionModel.pending_travel_session_id(pending) != activity_session
		or String(pending.get("target_scene_path", ""))
			!= String(activity.get("return_scene_path", ""))
	):
		return false
	var route = pending.get("scene_route", {})
	if not (route is Dictionary) or route.is_empty():
		return false
	if (
		String(route.get("npc_id", "")) != String(record.get("npc_id", ""))
		or String(route.get("final_scene_path", ""))
			!= String(pending.get("target_scene_path", ""))
	):
		return false
	var scene_paths = route.get("scene_paths", [])
	if not (scene_paths is Array or scene_paths is PackedStringArray):
		return false
	var hop_index := int(route.get("hop_index", -1))
	return (
		hop_index >= 0
		and hop_index < scene_paths.size()
		and String(scene_paths[hop_index]) == String(record.get("scene_path", ""))
		and String(scene_paths[scene_paths.size() - 1])
			== String(pending.get("target_scene_path", ""))
	)
