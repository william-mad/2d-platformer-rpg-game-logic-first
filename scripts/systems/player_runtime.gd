extends Node

const NpcRouteLocationCoordinator = preload(
	"res://scripts/systems/npc_route_location_coordinator.gd"
)
const COMPANION_RESTORE_RETRY_SECONDS: float = 0.05
const COMPANION_RESTORE_MAX_ATTEMPTS: int = 20
var pending_player_data: Dictionary = {}
var pending_target_spawn_id: StringName = &""
var travel_session: Dictionary = _empty_travel_session()
var _pending_companion_restore: bool = false
var _companion_restore_player_ref: WeakRef
var _companion_restore_generation: int = 0
var _companion_restore_attempts: int = 0
var _companion_restore_retry_scheduled: bool = false
var _companion_restore_exhaustion_warned: bool = false


func _ready() -> void:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null:
		return
	var callback := Callable(self, "_on_npc_available_for_companion_restore")
	for signal_name in [&"npc_registered", &"npc_spawned"]:
		if locations.has_signal(signal_name) and not locations.is_connected(signal_name, callback):
			locations.connect(signal_name, callback)


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
		_prepare_pending_companion_restore()


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
	player.set_meta(&"arrival_spawn_id", target_spawn_id)
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
			if _activate_live_companion_context(npc, player, false):
				return {"success": true, "reason": "Already traveling together."}
			return {"success": false, "reason": "Traveler context is not ready yet."}
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
	if not _activate_live_companion_context(npc, player, true):
		travel_session = _empty_travel_session()
		return {"success": false, "reason": "Traveler context is not ready yet."}
	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("synchronize_live_records"):
		locations.call("synchronize_live_records")
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
	if npc_or_id is Node:
		if not npc_or_id.has_method("get_npc_location_id"):
			return false
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
		_prepare_pending_companion_restore()


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
	record["action"] = {}
	record["activity"] = {}
	record["pending_travel"] = {}
	NpcRouteLocationCoordinator.clear_finish_replan_marker(record)
	locations.call("apply_simulated_record", npc_id, record, false)


func _restore_companion_after_scene_change(player: Node) -> void:
	if not is_travel_active() or not (player is Node2D):
		return
	_prepare_pending_companion_restore()
	_companion_restore_player_ref = weakref(player)
	_attempt_companion_restore(_companion_restore_generation)


func _attempt_companion_restore(generation: int) -> void:
	if generation != _companion_restore_generation or not _pending_companion_restore:
		return
	_companion_restore_retry_scheduled = false
	if not is_travel_active():
		_cancel_pending_companion_restore()
		return
	var player := _get_pending_restore_player()
	if not _restore_context_is_current(player):
		_schedule_companion_restore_retry(generation)
		return
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null:
		_schedule_companion_restore_retry(generation)
		return
	var npc_id := String(travel_session.get("companion_npc_id", ""))
	var npc := locations.call("get_live_npc", npc_id) as Node2D
	if (
		npc == null
		or not is_instance_valid(npc)
		or npc.is_queued_for_deletion()
		or not npc.is_node_ready()
		or locations.call("get_live_npc", npc_id) != npc
	):
		_schedule_companion_restore_retry(generation)
		return
	var companion_spawn := get_tree().get_first_node_in_group(&"companion_spawn") as Node2D
	npc.global_position = companion_spawn.global_position if companion_spawn != null else (player as Node2D).global_position + Vector2(-72.0, -8.0)
	if npc is CharacterBody2D:
		(npc as CharacterBody2D).velocity = Vector2.ZERO
	if not _activate_live_companion_context(npc, player, true):
		_schedule_companion_restore_retry(generation)
		return
	_pending_companion_restore = false
	_companion_restore_player_ref = null
	_companion_restore_attempts = 0
	_companion_restore_retry_scheduled = false
	if bool(travel_session.get("ending", false)):
		_end_travel(npc)


func _schedule_companion_restore_retry(generation: int) -> void:
	if generation != _companion_restore_generation or not _pending_companion_restore:
		return
	if _companion_restore_retry_scheduled:
		return
	if _companion_restore_attempts >= COMPANION_RESTORE_MAX_ATTEMPTS:
		if not _companion_restore_exhaustion_warned and OS.is_debug_build():
			_companion_restore_exhaustion_warned = true
			push_warning(
				"Companion restore is waiting for NPC registration: %s"
				% String(travel_session.get("companion_npc_id", ""))
			)
		return
	_companion_restore_attempts += 1
	_companion_restore_retry_scheduled = true
	var timer := get_tree().create_timer(COMPANION_RESTORE_RETRY_SECONDS)
	timer.timeout.connect(
		Callable(self, "_attempt_companion_restore").bind(generation),
		CONNECT_ONE_SHOT
	)


func _on_npc_available_for_companion_restore(
	npc_id: String,
	_npc: Node,
	scene_path: String
) -> void:
	if not _pending_companion_restore or not is_travel_active():
		return
	if npc_id != String(travel_session.get("companion_npc_id", "")):
		return
	var expected_scene := String(travel_session.get("destination_scene_path", ""))
	if not expected_scene.is_empty() and scene_path != expected_scene:
		return
	# Registration can be emitted from inside the NPC's own _ready path. Let that
	# stack finish before binding its state machine and presentation.
	_companion_restore_attempts = 0
	_companion_restore_exhaustion_warned = false
	call_deferred("_attempt_companion_restore", _companion_restore_generation)


func _restore_context_is_current(player: Node) -> bool:
	if (
		player == null
		or not is_instance_valid(player)
		or player.is_queued_for_deletion()
		or not player.is_inside_tree()
		or not (player is Node2D)
	):
		return false
	var current := get_tree().current_scene
	if current == null or (current != player and not current.is_ancestor_of(player)):
		return false
	var expected_scene := String(travel_session.get("destination_scene_path", ""))
	return expected_scene.is_empty() or current.scene_file_path == expected_scene


func _get_pending_restore_player() -> Node:
	if _companion_restore_player_ref == null:
		return null
	return _companion_restore_player_ref.get_ref() as Node


func _prepare_pending_companion_restore() -> void:
	_companion_restore_generation += 1
	_pending_companion_restore = true
	_companion_restore_player_ref = null
	_companion_restore_attempts = 0
	_companion_restore_retry_scheduled = false
	_companion_restore_exhaustion_warned = false


func _cancel_pending_companion_restore() -> void:
	_companion_restore_generation += 1
	_pending_companion_restore = false
	_companion_restore_player_ref = null
	_companion_restore_attempts = 0
	_companion_restore_retry_scheduled = false
	_companion_restore_exhaustion_warned = false


func _activate_live_companion_context(
	npc: Node,
	player: Node = null,
	cleanup_previous_activity: bool = true
) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false
	var component := npc.get_node_or_null("TravelCompanion") as TravelCompanionComponent
	if component == null:
		return false
	return component.activate_travel_context(player, cleanup_previous_activity)


func _end_travel(npc: Node) -> void:
	_cancel_pending_companion_restore()
	var component := (
		npc.get_node_or_null("TravelCompanion") as TravelCompanionComponent
		if npc != null
		else null
	)
	travel_session = _empty_travel_session()
	if component != null:
		component.deactivate_travel_context(true)


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


func clear_pending_player_transfer() -> void:
	pending_player_data.clear()
	pending_target_spawn_id = &""
	if is_travel_active() and _pending_companion_restore:
		# SceneLoader calls this on a rejected/failed transfer. Put the persistent
		# companion record back in the still-active scene before cancelling retries.
		var current := get_tree().current_scene
		var current_scene_path := current.scene_file_path if current != null else ""
		if not current_scene_path.is_empty():
			_capture_companion_for_scene(current_scene_path)
			travel_session["destination_scene_path"] = current_scene_path
		_cancel_pending_companion_restore()


func _move_player_to_spawn(player: Node, target_spawn_id: StringName) -> void:
	if target_spawn_id == &"" or not (player is Node2D):
		return

	var spawn := _find_spawn(target_spawn_id)
	if spawn == null:
		push_warning("PlayerRuntime could not find target spawn: %s" % String(target_spawn_id))
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
