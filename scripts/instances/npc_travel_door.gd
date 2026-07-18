class_name NpcTravelDoor extends Area2D

@export_file("*.tscn") var target_scene_path: String = ""
@export var target_spawn_id: StringName = &""
@export var traveller_groups: Array[StringName] = [&"npc"]
@export var player_group: StringName = &"player"
@export var interaction_action: StringName = &"up"
@export var cooldown_seconds: float = 1.5
@export var npc_arrival_offset: Vector2 = Vector2(80.0, 0.0)
@export var allow_unscheduled_npc_travel: bool = false

@export_group("Owners")
@export var owner_ids: Array[StringName] = []
@export var player_owner_id: StringName = &"player"

@export_group("NPC Permissions")
# Empty allow-list means every NPC may use the door unless explicitly blocked.
@export var allowed_npc_ids: Array[StringName] = []
@export var blocked_npc_ids: Array[StringName] = []
@export var required_npc_tags: Array[StringName] = []

var cooldowns: Dictionary = {}
var player_inside: bool = false
var active_player: Node2D
var player_transition_accepted: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	for traveller_id in cooldowns.keys():
		var next_time := float(cooldowns[traveller_id]) - delta
		if next_time <= 0.0:
			cooldowns.erase(traveller_id)
		else:
			cooldowns[traveller_id] = next_time

	if player_inside and Input.is_action_just_pressed(interaction_action):
		call_deferred("load_target_scene")


func load_target_scene() -> void:
	if player_transition_accepted:
		return
	if target_scene_path.is_empty():
		push_warning("NpcTravelDoor has no target scene.")
		return

	var player := _get_active_player()
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null:
		if not scene_loader.has_method("request_player_scene_transition"):
			_log_player_transition_result(false, &"transaction_api_unavailable")
			return
		var result: Dictionary = scene_loader.call(
			"request_player_scene_transition",
			player,
			target_scene_path,
			target_spawn_id,
			&"npc_travel_door"
		)
		player_transition_accepted = bool(result.get("accepted", false))
		if (
			player_transition_accepted
			and scene_loader.has_signal(&"scene_load_finished")
		):
			scene_loader.connect(
				&"scene_load_finished", _on_player_scene_load_finished, CONNECT_ONE_SHOT
			)
		_log_player_transition_result(
			player_transition_accepted,
			StringName(result.get("reason", &"transition_rejected"))
		)
		return

	_load_player_scene_direct_fallback(player)


func _on_player_scene_load_finished(success: bool, scene_path: String) -> void:
	if scene_path == target_scene_path and not success:
		player_transition_accepted = false


func _on_body_entered(body: Node2D) -> void:
	if target_scene_path.is_empty():
		push_warning("NpcTravelDoor has no target scene.")
		return

	if body.is_in_group(String(player_group)):
		if not _owner_id_is_allowed(player_owner_id):
			return
		player_inside = true
		active_player = body
		_preload_target_scene()
		return

	if not _is_traveller(body):
		return

	try_travel_npc(body)


func try_travel_npc(body: Node2D) -> bool:
	# Scheduled NPC travel commits here, after the NPC has actually reached the door.
	if body == null or not is_instance_valid(body) or not _is_traveller(body):
		return false
	if target_scene_path.is_empty():
		return false

	var tracker := get_node_or_null("/root/NpcLocations")
	if tracker == null or not tracker.has_method("request_travel"):
		return false

	var traveller_id := _get_traveller_id(body)
	if float(cooldowns.get(traveller_id, 0.0)) > 0.0:
		return false

	cooldowns[traveller_id] = cooldown_seconds
	if tracker.has_method("complete_pending_scheduled_travel"):
		if bool(tracker.call("complete_pending_scheduled_travel", body, target_scene_path)):
			return true

	# Idle wandering near a door must not silently move an NPC to another scene.
	if not allow_unscheduled_npc_travel:
		cooldowns.erase(traveller_id)
		return false

	tracker.call("request_travel", body, target_scene_path)
	return true


func get_npc_arrival_position() -> Vector2:
	return global_position + npc_arrival_offset


func can_npc_use(npc: Node) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false
	var npc_id := StringName(_get_traveller_id(npc))
	if not _owner_id_is_allowed(npc_id):
		return false
	if not _npc_id_is_allowed(npc_id):
		return false
	return _npc_has_required_tags(npc)


func can_npc_id_use(npc_id: StringName) -> bool:
	# ID-only gate is available to unloaded simulation; tag gates require a live NPC.
	return _owner_id_is_allowed(npc_id) and _npc_id_is_allowed(npc_id) and required_npc_tags.is_empty()


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group(String(player_group)):
		player_inside = false
		if body == active_player:
			active_player = null


func _is_traveller(body: Node) -> bool:
	var has_traveller_group := false
	for group_name in traveller_groups:
		if body.is_in_group(String(group_name)):
			has_traveller_group = true
			break
	if not has_traveller_group:
		return false

	return can_npc_use(body)


func _npc_id_is_allowed(npc_id: StringName) -> bool:
	for blocked_id in blocked_npc_ids:
		if String(blocked_id) == String(npc_id):
			return false
	if allowed_npc_ids.is_empty():
		return true
	for allowed_id in allowed_npc_ids:
		if String(allowed_id) == String(npc_id):
			return true
	return false


func _owner_id_is_allowed(owner_id: StringName) -> bool:
	if owner_ids.is_empty():
		return true
	for configured_owner_id in owner_ids:
		if String(configured_owner_id) == String(owner_id):
			return true

	return false


func _npc_has_required_tags(npc: Node) -> bool:
	if required_npc_tags.is_empty():
		return true
	for required_tag in required_npc_tags:
		var tag_text := String(required_tag)
		if npc.is_in_group(tag_text):
			continue
		var tags = npc.get_meta("npc_tags", [])
		if tags is Array and tags.has(required_tag):
			continue
		return false

	return true


func _get_traveller_id(body: Node) -> String:
	if body.has_method("get_npc_location_id"):
		var npc_id := String(body.call("get_npc_location_id"))
		if not npc_id.is_empty():
			return npc_id

	return str(body.get_instance_id())


func _load_player_scene_direct_fallback(player: Node) -> void:
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if runtime != null and runtime.has_method("capture_player"):
		runtime.call("capture_player", player, target_spawn_id, target_scene_path)
	var error := get_tree().change_scene_to_file(target_scene_path)
	player_transition_accepted = error == OK
	if (
		error != OK
		and runtime != null
		and runtime.has_method("clear_pending_player_transfer")
	):
		runtime.call("clear_pending_player_transfer")
	_log_player_transition_result(
		player_transition_accepted,
		&"direct_fallback" if error == OK else &"direct_fallback_failed"
	)


func _get_active_player() -> Node2D:
	if active_player != null and is_instance_valid(active_player):
		return active_player

	for body in get_overlapping_bodies():
		var body_node := body as Node2D
		if body_node != null and body_node.is_in_group(String(player_group)):
			return body_node

	return null


func _preload_target_scene() -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", target_scene_path)


func _log_player_transition_result(accepted: bool, result: StringName) -> void:
	if not OS.is_debug_build():
		return
	print("NPC travel door player transition: source=%s target=%s spawn=%s accepted=%s result=%s" % [
		name, target_scene_path, String(target_spawn_id), str(accepted), String(result),
	])
