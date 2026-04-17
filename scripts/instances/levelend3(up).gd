extends Area2D

@export var next_level3 = ""



#function to detect the player

func _on_body_entered(body: Node2D) -> void:
	call_deferred("load_next_scene")
	
#function to define in which area the player is

#function to call the next scene
func load_next_scene():
	get_tree().change_scene_to_file("res://scenes/levels/" + next_level3 + ".tscn")
	print("going to area 3")
