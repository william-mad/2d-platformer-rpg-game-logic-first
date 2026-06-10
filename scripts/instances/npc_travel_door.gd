class_name NpcTravelDoor extends Area2D

@export_file("*.tscn") var target_scene_path: String = ""
@export var traveller_groups: Array[StringName] = [&"npc"]
@export var player_group: StringName = &"player"
@export var interaction_action: StringName = &"up"
@export var cooldown_seconds: float = 1.5

var cooldowns: Dictionary = {}
var player_inside: bool = false


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
	if target_scene_path.is_empty():
		push_warning("NpcTravelDoor has no target scene.")
		return

	if _change_scene_with_loader():
		return

	get_tree().change_scene_to_file(target_scene_path)


func _on_body_entered(body: Node2D) -> void:
	if target_scene_path.is_empty():
		push_warning("NpcTravelDoor has no target scene.")
		return

	if body.is_in_group(String(player_group)):
		player_inside = true
		_preload_target_scene()
		return

	if not _is_traveller(body):
		return

	var tracker := get_node_or_null("/root/NpcLocations")
	if tracker == null or not tracker.has_method("request_travel"):
		return

	var traveller_id := _get_traveller_id(body)
	if float(cooldowns.get(traveller_id, 0.0)) > 0.0:
		return

	cooldowns[traveller_id] = cooldown_seconds
	tracker.call("request_travel", body, target_scene_path)


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group(String(player_group)):
		player_inside = false


func _is_traveller(body: Node) -> bool:
	for group_name in traveller_groups:
		if body.is_in_group(String(group_name)):
			return true

	return false


func _get_traveller_id(body: Node) -> String:
	if body.has_method("get_npc_location_id"):
		var npc_id := String(body.call("get_npc_location_id"))
		if not npc_id.is_empty():
			return npc_id

	return str(body.get_instance_id())


func _preload_target_scene() -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", target_scene_path)


func _change_scene_with_loader() -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false

	return bool(scene_loader.call("change_scene", target_scene_path))
