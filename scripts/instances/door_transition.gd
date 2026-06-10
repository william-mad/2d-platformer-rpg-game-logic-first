class_name DoorTransition extends Area2D

@export_file("*.tscn") var target_scene_path: String = ""
@export var interaction_action: StringName = &"up"

var player_inside: bool = false


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

	if _change_scene_with_loader():
		return

	get_tree().change_scene_to_file(target_scene_path)


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player_inside = true
		_preload_target_scene()


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group("player"):
		player_inside = false


func _preload_target_scene() -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", target_scene_path)


func _change_scene_with_loader() -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false

	return bool(scene_loader.call("change_scene", target_scene_path))
