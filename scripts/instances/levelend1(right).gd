extends Area2D

@export var next_level1 = ""



#function to detect the player

func _on_body_entered(body: Node2D) -> void:
	call_deferred("load_next_scene")
	
#function to define in which area the player is

#function to call the next scene
func load_next_scene():
	var scene_path := "res://scenes/levels/" + next_level1 + ".tscn"
	if _change_scene_with_loader(scene_path):
		return

	get_tree().change_scene_to_file(scene_path)


func _change_scene_with_loader(scene_path: String) -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false

	return bool(scene_loader.call("change_scene", scene_path))
