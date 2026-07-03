class_name PlayerSpawn extends Marker2D

@export var spawn_id: StringName = &"default"


func _ready() -> void:
	add_to_group(&"player_spawn")


func get_spawn_id() -> StringName:
	return spawn_id
