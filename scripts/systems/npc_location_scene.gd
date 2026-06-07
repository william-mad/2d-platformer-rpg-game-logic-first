class_name NpcLocationScene extends Node

@export_file("*.tscn") var scene_path: String = ""
@export var spawn_parent_path: NodePath = NodePath("..")
@export var ground_y: float = 368.0
@export var spawn_x_min: float = -900.0
@export var spawn_x_max: float = 900.0

var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	call_deferred("_activate_scene_tracker")


func get_tracked_scene_path() -> String:
	if not scene_path.is_empty():
		return scene_path

	var current_scene := get_tree().current_scene
	if current_scene == null:
		return ""

	return current_scene.scene_file_path


func get_spawn_parent() -> Node:
	var spawn_parent := get_node_or_null(spawn_parent_path)
	if spawn_parent != null:
		return spawn_parent

	return get_tree().current_scene


func get_random_ground_spawn_position(_npc_id: String) -> Vector2:
	return Vector2(rng.randf_range(spawn_x_min, spawn_x_max), ground_y)


func _activate_scene_tracker() -> void:
	var tracker := get_node_or_null("/root/NpcLocations")
	if tracker == null or not tracker.has_method("activate_scene"):
		return

	tracker.call("activate_scene", self)
