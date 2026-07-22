class_name NpcSceneRouteBridge extends RefCounted

# Thin integration helpers keep graph-format knowledge out of the large world
# simulation. They allocate only when a scene route is actually requested.


static func prepare_pending_route(
	route_manager: Node,
	pending_travel: Dictionary,
	source_scene_path: String,
	target_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	if route_manager == null:
		return {"accepted": false, "reason": "route_service_missing"}
	if (
		not route_manager.has_method("plan_route")
		or not route_manager.has_method("attach_route_to_pending")
	):
		return {"accepted": false, "reason": "route_service_api_missing"}

	var plan = route_manager.call(
		"plan_route", source_scene_path, target_scene_path, npc_id
	)
	if not (plan is Dictionary) or not bool(plan.get("accepted", false)):
		return (
			plan
			if plan is Dictionary
			else {"accepted": false, "reason": "invalid_route_plan"}
		)

	var routed_pending = route_manager.call(
		"attach_route_to_pending", pending_travel, plan
	)
	if not _has_route_metadata(routed_pending):
		return {"accepted": false, "reason": "route_attach_failed"}
	var leg := resolve_pending_leg(
		route_manager, routed_pending, source_scene_path, npc_id
	)
	if not bool(leg.get("accepted", false)):
		return leg
	leg["pending_travel"] = routed_pending
	return leg


static func resolve_pending_leg(
	route_manager: Node,
	pending_travel: Dictionary,
	current_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	if not _has_route_metadata(pending_travel):
		var direct_target := String(pending_travel.get("target_scene_path", ""))
		return {
			"accepted": not direct_target.is_empty(),
			"reason": (
				"legacy_direct" if not direct_target.is_empty() else "target_scene_missing"
			),
			"target_scene_path": direct_target,
			"edge_id": "",
		}
	if route_manager == null or not route_manager.has_method("get_current_hop"):
		return {"accepted": false, "reason": "route_service_missing"}
	var result = route_manager.call(
		"get_current_hop", pending_travel, current_scene_path, npc_id
	)
	return (
		result
		if result is Dictionary
		else {"accepted": false, "reason": "invalid_route_hop_result"}
	)


static func validate_direct_route_wired_door(
	route_manager: Node,
	door: Node2D,
	source_scene_path: String,
	target_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	if door == null or not is_instance_valid(door):
		return {"accepted": false, "reason": "departure_door_missing"}
	if not door.has_method("get_route_edge_id"):
		return {"accepted": true, "reason": "legacy_direct_door"}
	var edge_id := StringName(String(door.call("get_route_edge_id")))
	if edge_id == &"":
		return {"accepted": true, "reason": "legacy_direct_door"}
	if route_manager == null or not route_manager.has_method("validate_edge_execution"):
		return {"accepted": false, "reason": "route_service_missing"}
	var result = route_manager.call(
		"validate_edge_execution",
		edge_id,
		source_scene_path,
		target_scene_path,
		npc_id
	)
	return (
		result
		if result is Dictionary
		else {"accepted": false, "reason": "invalid_edge_validation_result"}
	)


static func resolve_final_arrival(
	route_manager: Node,
	pending_travel: Dictionary,
	npc_id: StringName
) -> Dictionary:
	if not _has_route_metadata(pending_travel):
		return {"accepted": false, "reason": "legacy_direct"}
	if route_manager == null or not route_manager.has_method("get_edge_resource"):
		return {"accepted": false, "reason": "route_service_missing"}
	var scene_route: Dictionary = pending_travel.get("scene_route", {})
	var edge_ids = scene_route.get("edge_ids", [])
	if not (edge_ids is Array or edge_ids is PackedStringArray) or edge_ids.is_empty():
		return {"accepted": false, "reason": "route_pending_malformed"}
	var final_edge = route_manager.call(
		"get_edge_resource", StringName(String(edge_ids[edge_ids.size() - 1]))
	) as NpcSceneRouteEdge
	if final_edge == null or not final_edge.enabled or not final_edge.allows_npc(npc_id):
		return {"accepted": false, "reason": "route_final_edge_invalid"}
	if final_edge.target_scene_path != String(pending_travel.get("target_scene_path", "")):
		return {"accepted": false, "reason": "route_final_target_mismatch"}
	return {
		"accepted": true,
		"reason": "route_final_arrival_ready",
		"edge_id": String(final_edge.edge_id),
		"target_scene_path": final_edge.target_scene_path,
		"target_arrival_position": final_edge.target_arrival_position,
	}


static func advance_resolved_leg(
	route_manager: Node,
	pending_travel: Dictionary,
	leg: Dictionary,
	npc_id: StringName,
	current_scene_path: String
) -> Dictionary:
	if (
		route_manager == null
		or not route_manager.has_method("advance_pending_route")
		or not bool(leg.get("accepted", false))
		or bool(leg.get("complete", false))
	):
		return {"accepted": false, "reason": "route_leg_not_advanceable"}
	var edge_id := StringName(String(leg.get("edge_id", "")))
	var target_scene_path := String(leg.get("target_scene_path", ""))
	if edge_id == &"" or target_scene_path.is_empty():
		return {"accepted": false, "reason": "route_leg_malformed"}
	var result = route_manager.call(
		"advance_pending_route",
		pending_travel,
		edge_id,
		target_scene_path,
		npc_id,
		current_scene_path
	)
	return (
		result
		if result is Dictionary
		else {"accepted": false, "reason": "invalid_route_advance_result"}
	)


static func _has_route_metadata(pending_travel) -> bool:
	if not (pending_travel is Dictionary):
		return false
	var scene_route = pending_travel.get("scene_route", {})
	return scene_route is Dictionary and not scene_route.is_empty()
