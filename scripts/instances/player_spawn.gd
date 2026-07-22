class_name PlayerSpawn extends Marker2D

@export var spawn_id: StringName = &"default"


func _enter_tree() -> void:
	# PlayerRuntime can restore a sibling player synchronously during _ready().
	# Register before any sibling's ready callback so scene child order is irrelevant.
	add_to_group(&"player_spawn")


func get_spawn_id() -> StringName:
	return spawn_id
