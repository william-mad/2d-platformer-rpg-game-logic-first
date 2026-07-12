extends Node

var pending_player_data: Dictionary = {}
var pending_target_spawn_id: StringName = &""
var travel_session: Dictionary = _empty_travel_session()
var _pending_companion_restore: bool = false


func capture_player(
	player: Node,
	target_spawn_id: StringName = &"",
	destination_scene_path: String = ""
) -> void:
	pending_player_data.clear()
	pending_target_spawn_id = target_spawn_id

	if player == null or not is_instance_valid(player):
		return
	if not player.has_method("get_save_data"):
		return

	var data = player.call("get_save_data")
	if not (data is Dictionary):
		return

	pending_player_data = data.duplicate(true)
	pending_player_data.erase("global_position")
	if is_travel_active() and not destination_scene_path.is_empty():
		_capture_companion_for_scene(destination_scene_path)
		travel_session["destination_scene_path"] = destination_scene_path
		_pending_companion_restore = true


func apply_to_player(player: Node) -> bool:
	if player == null or not is_instance_valid(player):
		return false
	if pending_player_data.is_empty():
		if is_travel_active():
			call_deferred("_restore_companion_after_scene_change", player)
		return false

	var data := pending_player_data.duplicate(true)
	var target_spawn_id := pending_target_spawn_id
	pending_player_data.clear()
	pending_target_spawn_id = &""

	if player.has_method("apply_save_data"):
		player.call("apply_save_data", data)

	_move_player_to_spawn(player, target_spawn_id)
	if is_travel_active():
		call_deferred("_restore_companion_after_scene_change", player)
	return true


func start_travel(npc: Node, player: Node, policy: TravelPolicy) -> Dictionary:
	if npc == null or player == null:
		return {"success": false, "reason": "Traveler unavailable."}
	var npc_id := String(npc.call("get_npc_location_id")) if npc.has_method("get_npc_location_id") else ""
	if npc_id.is_empty():
		return {"success": false, "reason": "Traveler has no persistent identity."}
	if is_travel_active():
		if String(travel_session.get("companion_npc_id", "")) == npc_id:
			_enable_live_companion_follow(npc)
			return {"success": true, "reason": "Already traveling together."}
		return {"success": false, "reason": "Another companion is already traveling."}
	var current_scene := get_tree().current_scene
	var scene_path := current_scene.scene_file_path if current_scene != null else ""
	var world_time := get_node_or_null("/root/WorldTime")
	var total_hours := float(world_time.call("get_total_hours")) if world_time != null else 0.0
	travel_session = {
		"active": true,
		"companion_npc_id": npc_id,
		"origin_scene_path": scene_path,
		"origin_spawn_id": "from_companion_route",
		"destination_scene_path": scene_path,
		"departure_total_hours": total_hours,
		"travel_policy_id": String(policy.policy_id if policy != null else &"default_companion"),
		"ending": false,
	}
	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("synchronize_live_records"):
		locations.call("synchronize_live_records")
	_enable_live_companion_follow(npc)
	return {"success": true, "reason": "Travel started."}


func request_stop_travel(npc: Node) -> Dictionary:
	if not is_travel_active():
		return {"success": true, "reason": "No active travel session."}
	var current_scene := get_tree().current_scene
	var scene_path := current_scene.scene_file_path if current_scene != null else ""
	if scene_path != String(travel_session.get("origin_scene_path", "")):
		return {"success": false, "reason": "Return to the village before ending travel."}
	_end_travel(npc)
	return {"success": true, "reason": "Travel ended."}


func is_travel_active() -> bool:
	return bool(travel_session.get("active", false)) and not String(travel_session.get("companion_npc_id", "")).is_empty()


func is_active_companion(npc_or_id) -> bool:
	if not is_travel_active():
		return false
	var npc_id := ""
	if npc_or_id is Node and npc_or_id.has_method("get_npc_location_id"):
		npc_id = String(npc_or_id.call("get_npc_location_id"))
	else:
		npc_id = String(npc_or_id)
	return npc_id == String(travel_session.get("companion_npc_id", ""))


func get_active_travel_policy() -> TravelPolicy:
	if not is_travel_active():
		return null
	return load("res://data/travel_policies/default_companion.tres") as TravelPolicy


func get_save_data() -> Dictionary:
	return {"travel_session": travel_session.duplicate(true)}


func apply_save_data(data: Dictionary) -> void:
	var loaded = data.get("travel_session", {})
	travel_session = loaded.duplicate(true) if loaded is Dictionary else _empty_travel_session()
	if not is_travel_active():
		travel_session = _empty_travel_session()
	else:
		_pending_companion_restore = true


func return_to_origin(target_total_hours: float) -> bool:
	if not is_travel_active():
		return false
	var world_time := get_node_or_null("/root/WorldTime")
	var simulation := get_node_or_null("/root/NpcWorldSimulation")
	var player := get_tree().get_first_node_in_group(&"player")
	if world_time == null or simulation == null or player == null:
		return false
	var start_total := float(world_time.call("get_total_hours"))
	var end_total := maxf(target_total_hours, start_total)
	_capture_companion_for_scene(String(travel_session.get("origin_scene_path", "")))
	if simulation.has_method("simulate_companion_return_skip"):
		simulation.call(
			"simulate_companion_return_skip",
			start_total,
			end_total,
			String(travel_session.get("companion_npc_id", "")),
			get_active_travel_policy()
		)
	world_time.call("set_total_hours", end_total)
	travel_session["ending"] = true
	var origin_scene := String(travel_session.get("origin_scene_path", ""))
	capture_player(player, StringName(String(travel_session.get("origin_spawn_id", ""))), origin_scene)
	var loader := get_node_or_null("/root/SceneLoader")
	if loader != null and loader.has_method("change_scene"):
		return bool(loader.call("change_scene", origin_scene))
	return get_tree().change_scene_to_file(origin_scene) == OK


func _capture_companion_for_scene(destination_scene_path: String) -> void:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null:
		return
	locations.call("synchronize_live_records")
	var npc_id := String(travel_session.get("companion_npc_id", ""))
	var record: Dictionary = locations.call("get_record_snapshot", npc_id)
	if record.is_empty():
		return
	record["scene_path"] = destination_scene_path
	record["activity"] = {}
	record["pending_travel"] = {}
	locations.call("apply_simulated_record", npc_id, record, false)


func _restore_companion_after_scene_change(player: Node) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null:
		return
	var npc := locations.call("get_live_npc", String(travel_session.get("companion_npc_id", ""))) as Node2D
	if npc == null:
		await get_tree().process_frame
		npc = locations.call("get_live_npc", String(travel_session.get("companion_npc_id", ""))) as Node2D
	if npc == null or not (player is Node2D):
		return
	var companion_spawn := get_tree().get_first_node_in_group(&"companion_spawn") as Node2D
	npc.global_position = companion_spawn.global_position if companion_spawn != null else (player as Node2D).global_position + Vector2(-72.0, -8.0)
	_enable_live_companion_follow(npc)
	_pending_companion_restore = false
	if bool(travel_session.get("ending", false)):
		_end_travel(npc)


func _enable_live_companion_follow(npc: Node) -> void:
	var machine := npc.get_node_or_null("NpcStateMachine") as NpcStateMachine
	if machine != null:
		machine.request_state(&"TravelFollow", null, "travel_companion", 90)


func _end_travel(npc: Node) -> void:
	travel_session = _empty_travel_session()
	_pending_companion_restore = false
	var machine := npc.get_node_or_null("NpcStateMachine") as NpcStateMachine if npc != null else null
	if machine != null and machine.current_state != null and String(machine.current_state.name) == "TravelFollow":
		machine.request_state(&"Idle", null, "travel_ended", 100)


func _empty_travel_session() -> Dictionary:
	return {
		"active": false,
		"companion_npc_id": "",
		"origin_scene_path": "",
		"origin_spawn_id": "",
		"destination_scene_path": "",
		"departure_total_hours": 0.0,
		"travel_policy_id": "default_companion",
		"ending": false,
	}


func has_pending_player_data() -> bool:
	return not pending_player_data.is_empty()


func _move_player_to_spawn(player: Node, target_spawn_id: StringName) -> void:
	if target_spawn_id == &"" or not (player is Node2D):
		return

	var spawn := _find_spawn(target_spawn_id)
	if spawn == null:
		return

	(player as Node2D).global_position = spawn.global_position


func _find_spawn(target_spawn_id: StringName) -> Node2D:
	var tree := get_tree()
	if tree == null:
		return null

	for spawn_node in tree.get_nodes_in_group(&"player_spawn"):
		var spawn := spawn_node as Node2D
		if spawn == null or not is_instance_valid(spawn):
			continue
		if String(_get_spawn_id(spawn)) == String(target_spawn_id):
			return spawn

	return null


func _get_spawn_id(spawn: Node) -> StringName:
	if spawn.has_method("get_spawn_id"):
		return StringName(spawn.call("get_spawn_id"))

	var property_value = _get_property_if_present(spawn, &"spawn_id")
	if property_value != null:
		return StringName(String(property_value))

	return &""


func _get_property_if_present(object: Object, property_name: StringName):
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return object.get(property_name)

	return null
