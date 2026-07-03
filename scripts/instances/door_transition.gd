class_name DoorTransition extends Area2D

@export_file("*.tscn") var target_scene_path: String = ""
@export var target_spawn_id: StringName = &""
@export var interaction_action: StringName = &"up"
@export_group("Owners")
@export var owner_ids: Array[StringName] = []
@export var player_group: StringName = &"player"
@export var player_owner_id: StringName = &"player"

var player_inside: bool = false
var active_player: Node2D


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(_delta: float) -> void:
	if not player_inside:
		return

	if Input.is_action_just_pressed(interaction_action):
		call_deferred("load_target_scene")


func load_target_scene() -> void:
	if target_scene_path.is_empty():
		push_warning("DoorTransition has no target scene.")
		return

	_capture_player_runtime_state()
	if _change_scene_with_loader():
		return

	get_tree().change_scene_to_file(target_scene_path)


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group(String(player_group)) and _owner_id_is_allowed(player_owner_id):
		player_inside = true
		active_player = body
		_preload_target_scene()


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group(String(player_group)):
		player_inside = false
		if body == active_player:
			active_player = null


func _owner_id_is_allowed(owner_id: StringName) -> bool:
	if owner_ids.is_empty():
		return true
	for configured_owner_id in owner_ids:
		if String(configured_owner_id) == String(owner_id):
			return true

	return false


func _capture_player_runtime_state() -> void:
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if runtime == null or not runtime.has_method("capture_player"):
		return

	var player := _get_active_player()
	if player == null:
		return

	runtime.call("capture_player", player, target_spawn_id)


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


func _change_scene_with_loader() -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false

	return bool(scene_loader.call("change_scene", target_scene_path))
