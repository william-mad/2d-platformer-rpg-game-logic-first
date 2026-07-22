class_name NpcSceneRouteManager extends Node

signal route_planned(result: Dictionary)
signal route_diagnostic(event: Dictionary)
signal runtime_enabled_changed(enabled: bool, reason: String)

const DEFAULT_ROUTE_MAP: NpcSceneRouteMap = preload(
	"res://data/npc_routes/household_routes.tres"
)
const PENDING_ROUTE_SCHEMA_VERSION := 1
const MAX_CACHE_ENTRIES := 128
const MAX_DIAGNOSTIC_EVENTS := 64
const MAX_ROUTE_HOPS := 32
const MAX_VISITED_SCENES := 256

@export var route_map: NpcSceneRouteMap = DEFAULT_ROUTE_MAP
@export var runtime_enabled: bool = true
@export var debug_logging_enabled: bool = false

var _graph_ready: bool = false
var _graph_revision: int = 0
var _edges_by_id: Dictionary = {}
var _adjacency: Dictionary = {}
var _validation_errors: Array[String] = []
var _route_cache: Dictionary = {}
var _cache_order: Array[String] = []
var _diagnostic_events: Array[Dictionary] = []
var _diagnostic_sequence: int = 0


func _ready() -> void:
	if DebugToolsConfig.TROUBLESHOOTING_MODE:
		if DebugToolsConfig.DEBUG_DISABLE_NPC_SCENE_ROUTES:
			runtime_enabled = false
		if DebugToolsConfig.DEBUG_ENABLE_NPC_SCENE_ROUTE_LOGS:
			debug_logging_enabled = true
	rebuild_graph()


func set_route_map(next_route_map: NpcSceneRouteMap) -> Dictionary:
	route_map = next_route_map if next_route_map != null else DEFAULT_ROUTE_MAP
	return rebuild_graph()


func set_runtime_enabled(enabled: bool, reason: String = "manual") -> void:
	if runtime_enabled == enabled:
		return
	runtime_enabled = enabled
	# Treat kill-switch changes as execution revisions. Any validation already in
	# flight must fail if a synchronous diagnostic listener changes route state.
	_graph_revision += 1
	_clear_cache()
	_record_diagnostic(
		"runtime_enabled" if enabled else "runtime_disabled",
		{"reason": reason}
	)
	runtime_enabled_changed.emit(enabled, reason)


func set_enabled(enabled: bool, reason: String = "manual") -> void:
	set_runtime_enabled(enabled, reason)


func is_enabled() -> bool:
	return runtime_enabled


func rebuild_graph() -> Dictionary:
	_graph_ready = true
	_graph_revision += 1
	_edges_by_id.clear()
	_adjacency.clear()
	_validation_errors.clear()
	_clear_cache()

	if route_map == null:
		_validation_errors.append("route_map is null")
		_record_diagnostic("graph_invalid", {"errors": _validation_errors.duplicate()})
		return _make_rebuild_result()

	_validation_errors = route_map.get_validation_errors()
	if not _validation_errors.is_empty():
		push_warning(
			"NPC scene route graph is disabled until these errors are fixed: %s" %
			"; ".join(_validation_errors)
		)
	var duplicate_ids := _get_duplicate_edge_ids(route_map.edges)
	for edge in route_map.edges:
		if edge == null or not edge.enabled:
			continue
		var edge_id := String(edge.edge_id).strip_edges()
		if edge_id.is_empty() or duplicate_ids.has(edge_id):
			continue
		if not edge.get_validation_errors().is_empty():
			continue
		_edges_by_id[edge_id] = edge
		var outgoing: Array = _adjacency.get(edge.source_scene_path, [])
		outgoing.append(edge)
		_adjacency[edge.source_scene_path] = outgoing

	for source_scene_value in _adjacency.keys():
		var source_scene := String(source_scene_value)
		var outgoing: Array = _adjacency[source_scene]
		outgoing.sort_custom(Callable(self, "_edge_comes_before"))
		_adjacency[source_scene] = outgoing

	_record_diagnostic(
		"graph_ready" if _validation_errors.is_empty() else "graph_invalid",
		{
			"edge_count": _edges_by_id.size(),
			"errors": _validation_errors.duplicate(),
			"revision": _graph_revision,
		}
	)
	return _make_rebuild_result()


func plan_route(
	source_scene_path: String,
	target_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	_ensure_graph()
	var base_result := _make_plan_result(source_scene_path, target_scene_path, npc_id)
	if not runtime_enabled:
		base_result["reason"] = "route_manager_disabled"
		_record_plan_result(base_result)
		return base_result
	if not _validation_errors.is_empty():
		base_result["reason"] = "route_map_invalid"
		base_result["validation_errors"] = _validation_errors.duplicate()
		_record_plan_result(base_result)
		return base_result
	if source_scene_path.is_empty() or target_scene_path.is_empty():
		base_result["reason"] = "scene_path_empty"
		_record_plan_result(base_result)
		return base_result
	if not _scene_path_is_valid(source_scene_path):
		base_result["reason"] = "source_scene_invalid"
		_record_plan_result(base_result)
		return base_result
	if not _scene_path_is_valid(target_scene_path):
		base_result["reason"] = "target_scene_invalid"
		_record_plan_result(base_result)
		return base_result
	if source_scene_path == target_scene_path:
		base_result["accepted"] = true
		base_result["reason"] = "already_at_destination"
		base_result["scene_paths"] = [source_scene_path]
		_record_plan_result(base_result)
		return base_result

	var cache_key := _make_cache_key(source_scene_path, target_scene_path, npc_id)
	if _route_cache.has(cache_key):
		var cached: Dictionary = _route_cache[cache_key]
		var cached_copy := cached.duplicate(true)
		cached_copy["cache_hit"] = true
		return cached_copy

	var frontier: Array[String] = [source_scene_path]
	var frontier_index := 0
	var visited: Dictionary = {source_scene_path: true}
	var parent_edge_by_scene: Dictionary = {}
	var hop_count_by_scene: Dictionary = {source_scene_path: 0}
	var found := false
	var search_limit_reached := false

	while frontier_index < frontier.size() and not found:
		var current_scene := frontier[frontier_index]
		frontier_index += 1
		var current_hop_count := int(hop_count_by_scene.get(current_scene, 0))
		if current_hop_count >= MAX_ROUTE_HOPS:
			search_limit_reached = true
			continue
		var outgoing: Array = _adjacency.get(current_scene, [])
		for edge_value in outgoing:
			var edge := edge_value as NpcSceneRouteEdge
			if edge == null or not edge.enabled or not edge.allows_npc(npc_id):
				continue
			var next_scene := edge.target_scene_path
			if visited.has(next_scene):
				continue
			if visited.size() >= MAX_VISITED_SCENES:
				search_limit_reached = true
				break
			visited[next_scene] = true
			parent_edge_by_scene[next_scene] = String(edge.edge_id)
			hop_count_by_scene[next_scene] = current_hop_count + 1
			frontier.append(next_scene)
			if next_scene == target_scene_path:
				found = true
				break

	if not found:
		base_result["reason"] = (
			"route_search_limit_reached" if search_limit_reached else "route_not_found"
		)
		_cache_result(cache_key, base_result)
		_record_plan_result(base_result)
		return base_result

	var reversed_edge_ids: Array[String] = []
	var reconstruction_scene := target_scene_path
	var reconstruction_hops := 0
	while reconstruction_scene != source_scene_path:
		reconstruction_hops += 1
		if reconstruction_hops > MAX_ROUTE_HOPS:
			base_result["reason"] = "route_reconstruction_limit_reached"
			_record_plan_result(base_result)
			return base_result
		var parent_edge_id := String(parent_edge_by_scene.get(reconstruction_scene, ""))
		var parent_edge := _edges_by_id.get(parent_edge_id, null) as NpcSceneRouteEdge
		if parent_edge == null:
			base_result["reason"] = "route_reconstruction_failed"
			_record_plan_result(base_result)
			return base_result
		reversed_edge_ids.append(parent_edge_id)
		reconstruction_scene = parent_edge.source_scene_path
	reversed_edge_ids.reverse()

	var scene_paths: Array[String] = [source_scene_path]
	for route_edge_id in reversed_edge_ids:
		var route_edge := _edges_by_id.get(route_edge_id, null) as NpcSceneRouteEdge
		if route_edge == null:
			base_result["reason"] = "route_reconstruction_failed"
			_record_plan_result(base_result)
			return base_result
		scene_paths.append(route_edge.target_scene_path)

	base_result["accepted"] = true
	base_result["reason"] = "route_found"
	base_result["edge_ids"] = reversed_edge_ids
	base_result["scene_paths"] = scene_paths
	base_result["hop_count"] = reversed_edge_ids.size()
	_cache_result(cache_key, base_result)
	_record_plan_result(base_result)
	return base_result.duplicate(true)


func attach_route_to_pending(pending: Dictionary, plan: Dictionary) -> Dictionary:
	var attached := pending.duplicate(true)
	if not bool(plan.get("accepted", false)):
		_record_diagnostic("attach_rejected", {"reason": "plan_not_accepted"})
		return attached
	_ensure_graph()
	if not runtime_enabled or int(plan.get("graph_revision", -1)) != _graph_revision:
		_record_diagnostic("attach_rejected", {"reason": "plan_stale_or_disabled"})
		return attached

	var raw_edge_ids = plan.get("edge_ids", [])
	var raw_scene_paths = plan.get("scene_paths", [])
	if (
		not (raw_edge_ids is Array or raw_edge_ids is PackedStringArray)
		or not (raw_scene_paths is Array or raw_scene_paths is PackedStringArray)
		or raw_edge_ids.size() > MAX_ROUTE_HOPS
		or raw_scene_paths.size() > MAX_ROUTE_HOPS + 1
	):
		_record_diagnostic("attach_rejected", {"reason": "plan_size_invalid"})
		return attached
	var edge_ids := _variant_to_string_array(raw_edge_ids)
	var scene_paths := _variant_to_string_array(raw_scene_paths)
	var source_scene_path := String(plan.get("source_scene_path", ""))
	var final_scene_path := String(plan.get("final_scene_path", ""))
	if (
		source_scene_path.is_empty()
		or final_scene_path.is_empty()
		or scene_paths.size() != edge_ids.size() + 1
		or scene_paths.is_empty()
		or scene_paths.front() != source_scene_path
		or scene_paths.back() != final_scene_path
		or edge_ids.size() > MAX_ROUTE_HOPS
		or int(plan.get("hop_count", -1)) != edge_ids.size()
	):
		_record_diagnostic("attach_rejected", {"reason": "plan_malformed"})
		return attached
	var plan_npc_id := StringName(String(plan.get("npc_id", "")))
	for edge_index in edge_ids.size():
		var edge := _edges_by_id.get(edge_ids[edge_index], null) as NpcSceneRouteEdge
		if (
			edge == null
			or not edge.enabled
			or not edge.allows_npc(plan_npc_id)
			or edge.source_scene_path != scene_paths[edge_index]
			or edge.target_scene_path != scene_paths[edge_index + 1]
		):
			_record_diagnostic(
				"attach_rejected",
				{"reason": "plan_edge_invalid", "edge_id": edge_ids[edge_index]}
			)
			return attached

	var existing_final := String(attached.get("target_scene_path", ""))
	if not existing_final.is_empty() and existing_final != final_scene_path:
		_record_diagnostic(
			"attach_rejected",
			{
				"reason": "final_target_mismatch",
				"pending_final": existing_final,
				"plan_final": final_scene_path,
			}
		)
		return attached

	attached["target_scene_path"] = final_scene_path
	attached["scene_route"] = {
		"schema_version": PENDING_ROUTE_SCHEMA_VERSION,
		"route_map_id": String(route_map.map_id),
		"route_map_schema_version": route_map.schema_version,
		"npc_id": String(plan.get("npc_id", "")),
		"source_scene_path": source_scene_path,
		"final_scene_path": final_scene_path,
		"edge_ids": edge_ids.duplicate(),
		"scene_paths": scene_paths.duplicate(),
		"hop_index": 0,
	}
	return attached


func get_current_hop(
	pending: Dictionary,
	current_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	_ensure_graph()
	var result := _make_hop_result(pending, current_scene_path)
	if not runtime_enabled:
		result["reason"] = "route_manager_disabled"
		return result
	if not _validation_errors.is_empty():
		result["reason"] = "route_map_invalid"
		return result
	var scene_route_value = pending.get("scene_route", {})
	if not (scene_route_value is Dictionary):
		result["reason"] = "route_pending_malformed"
		return result
	var scene_route: Dictionary = scene_route_value
	if int(scene_route.get("schema_version", 0)) != PENDING_ROUTE_SCHEMA_VERSION:
		result["reason"] = "route_schema_invalid"
		return result
	# Persist stable authored map identity, not the in-memory graph revision. A
	# revision restarts at one on boot and would otherwise invalidate good saves.
	# Older pending records without these fields remain safe because every
	# remaining edge is validated below before it can be used.
	var saved_map_id := String(scene_route.get("route_map_id", "")).strip_edges()
	if not saved_map_id.is_empty() and saved_map_id != String(route_map.map_id):
		result["reason"] = "route_map_changed"
		return result
	var saved_map_schema := int(scene_route.get("route_map_schema_version", -1))
	if saved_map_schema >= 0 and saved_map_schema != route_map.schema_version:
		result["reason"] = "route_map_changed"
		return result

	var bound_npc_id := String(scene_route.get("npc_id", "")).strip_edges()
	if not bound_npc_id.is_empty() and bound_npc_id != String(npc_id).strip_edges():
		result["reason"] = "route_npc_mismatch"
		return result

	var raw_edge_ids = scene_route.get("edge_ids", [])
	var raw_scene_paths = scene_route.get("scene_paths", [])
	if (
		not (raw_edge_ids is Array or raw_edge_ids is PackedStringArray)
		or not (raw_scene_paths is Array or raw_scene_paths is PackedStringArray)
		or raw_edge_ids.size() > MAX_ROUTE_HOPS
		or raw_scene_paths.size() > MAX_ROUTE_HOPS + 1
	):
		result["reason"] = "route_pending_size_invalid"
		return result
	var edge_ids := _variant_to_string_array(raw_edge_ids)
	var scene_paths := _variant_to_string_array(raw_scene_paths)
	var route_index := int(scene_route.get("hop_index", -1))
	var final_scene_path := String(scene_route.get(
		"final_scene_path", pending.get("target_scene_path", "")
	))
	if String(pending.get("target_scene_path", "")) != final_scene_path:
		result["reason"] = "route_final_target_mismatch"
		return result
	if (
		route_index < 0
		or route_index > edge_ids.size()
		or scene_paths.size() != edge_ids.size() + 1
		or scene_paths.is_empty()
		or scene_paths.back() != final_scene_path
	):
		result["reason"] = "route_pending_malformed"
		return result
	if route_index >= scene_paths.size() or scene_paths[route_index] != current_scene_path:
		result["reason"] = "route_current_scene_mismatch"
		return result

	var validation_scene := current_scene_path
	for edge_index in range(route_index, edge_ids.size()):
		var validation_edge := _edges_by_id.get(edge_ids[edge_index], null) as NpcSceneRouteEdge
		if validation_edge == null or not validation_edge.enabled:
			result["reason"] = "route_edge_missing"
			return result
		if not validation_edge.allows_npc(npc_id):
			result["reason"] = "route_edge_forbidden"
			return result
		if validation_edge.source_scene_path != validation_scene:
			result["reason"] = "route_edge_disconnected"
			return result
		if scene_paths[edge_index + 1] != validation_edge.target_scene_path:
			result["reason"] = "route_scene_path_mismatch"
			return result
		validation_scene = validation_edge.target_scene_path
	if validation_scene != final_scene_path:
		result["reason"] = "route_does_not_reach_final"
		return result

	result["accepted"] = true
	result["hop_index"] = route_index
	result["hop_count"] = edge_ids.size()
	if route_index == edge_ids.size():
		result["complete"] = true
		result["reason"] = "route_complete"
		return result

	var edge := _edges_by_id.get(edge_ids[route_index], null) as NpcSceneRouteEdge
	if edge == null:
		result["accepted"] = false
		result["reason"] = "route_edge_missing"
		return result
	result["reason"] = "route_hop_ready"
	result["edge_id"] = String(edge.edge_id)
	result["source_scene_path"] = edge.source_scene_path
	result["target_scene_path"] = edge.target_scene_path
	result["target_arrival_position"] = edge.target_arrival_position
	return result


func validate_pending_route(
	pending: Dictionary,
	current_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	return get_current_hop(pending, current_scene_path, npc_id)


func validate_edge_execution(
	edge_id: StringName,
	source_scene_path: String,
	target_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	_ensure_graph()
	var validation_revision := _graph_revision
	var result := {
		"accepted": false,
		"reason": "route_edge_invalid",
		"edge_id": String(edge_id),
		"source_scene_path": source_scene_path,
		"target_scene_path": target_scene_path,
		"npc_id": String(npc_id),
		"graph_revision": validation_revision,
	}
	if not runtime_enabled:
		result["reason"] = "route_manager_disabled"
	elif not _validation_errors.is_empty():
		result["reason"] = "route_map_invalid"
	else:
		var edge := _edges_by_id.get(String(edge_id), null) as NpcSceneRouteEdge
		if edge == null or not edge.enabled:
			result["reason"] = "route_edge_missing"
		elif edge.source_scene_path != source_scene_path:
			result["reason"] = "route_edge_source_mismatch"
		elif edge.target_scene_path != target_scene_path:
			result["reason"] = "route_edge_target_mismatch"
		elif not edge.allows_npc(npc_id):
			result["reason"] = "route_edge_forbidden"
		else:
			result["accepted"] = true
			result["reason"] = "route_edge_ready"
	_record_diagnostic(
		"edge_execution_validated" if bool(result["accepted"]) else "edge_execution_rejected",
		result
	)
	if (
		bool(result["accepted"])
		and (
			not runtime_enabled
			or not _validation_errors.is_empty()
			or _graph_revision != validation_revision
		)
	):
		result["accepted"] = false
		result["reason"] = "route_state_changed_during_validation"
	return result


func advance_pending_route(
	pending: Dictionary,
	edge_id: StringName,
	actual_target_scene_path: String,
	npc_id: StringName,
	authoritative_current_scene_path: String = ""
) -> Dictionary:
	var scene_route_value = pending.get("scene_route", {})
	var scene_route: Dictionary = (
		scene_route_value if scene_route_value is Dictionary else {}
	)
	var current_scene_path := authoritative_current_scene_path
	if current_scene_path.is_empty():
		var raw_scene_paths = scene_route.get("scene_paths", [])
		if (
			not (raw_scene_paths is Array or raw_scene_paths is PackedStringArray)
			or raw_scene_paths.size() > MAX_ROUTE_HOPS + 1
		):
			return {
				"accepted": false,
				"reason": "route_pending_size_invalid",
				"complete": false,
			}
		var scene_paths := _variant_to_string_array(raw_scene_paths)
		var route_index := int(scene_route.get("hop_index", -1))
		if route_index >= 0 and route_index < scene_paths.size():
			current_scene_path = scene_paths[route_index]
	var hop := get_current_hop(pending, current_scene_path, npc_id)
	var validation_revision := _graph_revision
	var result := {
		"accepted": false,
		"reason": String(hop.get("reason", "route_hop_invalid")),
		"complete": false,
		"pending_travel": {},
		"pending": {},
		"arrival_position": Vector2.ZERO,
		"graph_revision": validation_revision,
	}
	if not bool(hop.get("accepted", false)) or bool(hop.get("complete", false)):
		return result
	if String(hop.get("edge_id", "")) != String(edge_id):
		result["reason"] = "route_edge_callback_mismatch"
		return result
	if String(hop.get("target_scene_path", "")) != actual_target_scene_path:
		result["reason"] = "route_target_callback_mismatch"
		return result

	var advanced: Dictionary = pending.duplicate(true)
	result["pending_travel"] = pending.duplicate(true)
	result["pending"] = pending.duplicate(true)
	var next_index := int(hop.get("hop_index", 0)) + 1
	var advanced_scene_route_value = advanced.get("scene_route", {})
	if not (advanced_scene_route_value is Dictionary):
		result["reason"] = "route_pending_malformed"
		return result
	var advanced_scene_route: Dictionary = advanced_scene_route_value
	advanced_scene_route["hop_index"] = next_index
	advanced["scene_route"] = advanced_scene_route
	result["accepted"] = true
	result["reason"] = "route_complete" if next_index >= int(hop.get("hop_count", 0)) else "route_hop_advanced"
	result["complete"] = next_index >= int(hop.get("hop_count", 0))
	result["pending_travel"] = advanced
	result["pending"] = advanced.duplicate(true)
	result["arrival_position"] = hop.get("target_arrival_position", Vector2.ZERO)
	result["completed_edge_id"] = String(edge_id)
	result["target_scene_path"] = actual_target_scene_path
	_record_diagnostic(
		"hop_advance_validated",
		{
			"edge_id": String(edge_id),
			"npc_id": String(npc_id),
			"route_index": next_index,
			"target_scene_path": actual_target_scene_path,
		}
	)
	if (
		not runtime_enabled
		or not _validation_errors.is_empty()
		or _graph_revision != validation_revision
	):
		result["accepted"] = false
		result["reason"] = "route_state_changed_during_validation"
	return result


func get_edge_descriptor(edge_id: StringName) -> Dictionary:
	_ensure_graph()
	var edge := _edges_by_id.get(String(edge_id), null) as NpcSceneRouteEdge
	return edge.to_descriptor() if edge != null else {}


func get_edge_resource(edge_id: StringName) -> NpcSceneRouteEdge:
	_ensure_graph()
	return _edges_by_id.get(String(edge_id), null) as NpcSceneRouteEdge


func get_debug_snapshot() -> Dictionary:
	_ensure_graph()
	var edge_descriptors: Array[Dictionary] = []
	var edge_ids: Array[String] = []
	for edge_id_value in _edges_by_id.keys():
		edge_ids.append(String(edge_id_value))
	edge_ids.sort()
	for edge_id in edge_ids:
		var edge := _edges_by_id.get(edge_id, null) as NpcSceneRouteEdge
		if edge != null:
			edge_descriptors.append(edge.to_descriptor())
	return {
		"runtime_enabled": runtime_enabled,
		"debug_logging_enabled": debug_logging_enabled,
		"graph_ready": _graph_ready,
		"graph_revision": _graph_revision,
		"map_id": String(route_map.map_id) if route_map != null else "",
		"edge_count": _edges_by_id.size(),
		"scene_count": _adjacency.size(),
		"cache_entry_count": _route_cache.size(),
		"validation_errors": _validation_errors.duplicate(),
		"edges": edge_descriptors,
		"diagnostic_event_count": _diagnostic_events.size(),
	}


func get_diagnostic_events(limit: int = MAX_DIAGNOSTIC_EVENTS) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var clamped_limit := clampi(limit, 0, MAX_DIAGNOSTIC_EVENTS)
	var start_index := maxi(_diagnostic_events.size() - clamped_limit, 0)
	for index in range(start_index, _diagnostic_events.size()):
		result.append(_diagnostic_events[index].duplicate(true))
	return result


func clear_diagnostic_events() -> void:
	_diagnostic_events.clear()


func _ensure_graph() -> void:
	if not _graph_ready:
		rebuild_graph()


func _make_plan_result(
	source_scene_path: String,
	target_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	return {
		"accepted": false,
		"reason": "route_not_evaluated",
		"edge_ids": [] as Array[String],
		"scene_paths": [] as Array[String],
		"hop_count": 0,
		"source_scene_path": source_scene_path,
		"final_scene_path": target_scene_path,
		"npc_id": String(npc_id),
		"graph_revision": _graph_revision,
		"cache_hit": false,
	}


func _make_hop_result(pending: Dictionary, current_scene_path: String) -> Dictionary:
	var scene_route_value = pending.get("scene_route", {})
	var scene_route: Dictionary = (
		scene_route_value if scene_route_value is Dictionary else {}
	)
	return {
		"accepted": false,
		"reason": "route_hop_not_evaluated",
		"complete": false,
		"edge_id": "",
		"source_scene_path": current_scene_path,
		"target_scene_path": "",
		"target_arrival_position": Vector2.ZERO,
		"hop_index": int(scene_route.get("hop_index", -1)),
		"hop_count": 0,
		"final_scene_path": String(scene_route.get(
			"final_scene_path", pending.get("target_scene_path", "")
		)),
	}


func _make_rebuild_result() -> Dictionary:
	return {
		"accepted": _validation_errors.is_empty(),
		"reason": "graph_ready" if _validation_errors.is_empty() else "route_map_invalid",
		"graph_revision": _graph_revision,
		"edge_count": _edges_by_id.size(),
		"validation_errors": _validation_errors.duplicate(),
	}


func _scene_path_is_valid(path: String) -> bool:
	return (
		path.begins_with("res://")
		and path.get_extension().to_lower() == "tscn"
		and ResourceLoader.exists(path)
	)


func _get_duplicate_edge_ids(edges: Array[NpcSceneRouteEdge]) -> Dictionary:
	var counts: Dictionary = {}
	for edge in edges:
		if edge == null:
			continue
		var edge_id := String(edge.edge_id).strip_edges()
		if edge_id.is_empty():
			continue
		counts[edge_id] = int(counts.get(edge_id, 0)) + 1
	var duplicates: Dictionary = {}
	for edge_id_value in counts.keys():
		if int(counts[edge_id_value]) > 1:
			duplicates[String(edge_id_value)] = true
	return duplicates


func _edge_comes_before(left, right) -> bool:
	var left_edge := left as NpcSceneRouteEdge
	var right_edge := right as NpcSceneRouteEdge
	if left_edge == null:
		return false
	if right_edge == null:
		return true
	return String(left_edge.edge_id) < String(right_edge.edge_id)


func _make_cache_key(
	source_scene_path: String,
	target_scene_path: String,
	npc_id: StringName
) -> String:
	return JSON.stringify([
		_graph_revision,
		source_scene_path,
		target_scene_path,
		String(npc_id),
	])


func _cache_result(cache_key: String, result: Dictionary) -> void:
	if _route_cache.has(cache_key):
		_cache_order.erase(cache_key)
	while _route_cache.size() >= MAX_CACHE_ENTRIES and not _cache_order.is_empty():
		var oldest_key: String = _cache_order.pop_front()
		_route_cache.erase(oldest_key)
	_route_cache[cache_key] = result.duplicate(true)
	_cache_order.append(cache_key)


func _clear_cache() -> void:
	_route_cache.clear()
	_cache_order.clear()


func _variant_to_string_array(value) -> Array[String]:
	var result: Array[String] = []
	if not (value is Array or value is PackedStringArray):
		return result
	for item in value:
		result.append(String(item))
	return result


func _record_plan_result(result: Dictionary) -> void:
	var stored_result := result.duplicate(true)
	_record_diagnostic(
		"route_planned" if bool(result.get("accepted", false)) else "route_rejected",
		stored_result
	)
	route_planned.emit(stored_result.duplicate(true))


func _record_diagnostic(event_name: String, detail: Dictionary) -> void:
	_diagnostic_sequence += 1
	var event := {
		"sequence": _diagnostic_sequence,
		"event": event_name,
		"detail": detail.duplicate(true),
		"ticks_msec": Time.get_ticks_msec(),
	}
	_diagnostic_events.append(event)
	while _diagnostic_events.size() > MAX_DIAGNOSTIC_EVENTS:
		_diagnostic_events.pop_front()
	if debug_logging_enabled:
		print("NPC route %s: %s" % [event_name, str(detail)])
	route_diagnostic.emit(event.duplicate(true))
