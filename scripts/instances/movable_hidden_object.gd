class_name MovableHiddenObject extends RigidBody2D

@export var move_with_player_while_hidden: bool = true

@onready var hide_area: Area2D = %HideArea
@onready var rope_attach_point: Marker2D = %RopeAttachPoint
@onready var hidden_player_point: Marker2D = %HiddenPlayerPoint


func contains_player(player: Node2D) -> bool:
	return hide_area.get_overlapping_bodies().has(player)


func should_move_with_player_while_hidden() -> bool:
	return move_with_player_while_hidden


func set_hidden_move_velocity_x(move_velocity_x: float) -> void:
	sleeping = false
	linear_velocity.x = move_velocity_x


func stop_hidden_control() -> void:
	linear_velocity.x = 0.0


func get_hidden_player_position() -> Vector2:
	return hidden_player_point.global_position


func get_rope_attach_point() -> Node2D:
	return rope_attach_point
