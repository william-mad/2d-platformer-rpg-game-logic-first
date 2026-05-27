class_name HiddenSpot extends Area2D

@export var move_with_player_while_hidden: bool = true


func should_move_with_player_while_hidden() -> bool:
	return move_with_player_while_hidden
