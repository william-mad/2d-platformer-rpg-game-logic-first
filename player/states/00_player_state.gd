class_name PlayerState extends Node

var player : Player
var next_state : PlayerState

#state references
@onready var idle: PlayerStateIdle = %Idle
@onready var run: PlayerStateRun = %Run
@onready var jump: PlayerStateJump = %Jump
@onready var fall: PlayerStateFall = %Fall
@onready var crouch: PlayerStateCrouch = %Crouch
@onready var hidden: PlayerStateHidden = %Hidden
@onready var attack_3: PlayerAttack3 = %Attack3
@onready var attack_2: PlayerAttack2 = %Attack2
@onready var attack_1: PlayerAttack1 = %Attack1
@onready var ledge_grab: PlayerStateLedgeGrab = %LedgeGrab




# what happens when state initialized:
func init() -> void:
	pass


#entering state:
func enter() -> void:
	pass


#exiting state:
func exit() -> void:
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	return next_state


func process(_delta: float) -> PlayerState:
	return next_state


func physics_process(_delta: float) -> PlayerState:
	return next_state


func can_hide() -> bool:
	return get_current_hidden_spot() != null


func get_current_hidden_spot() -> Area2D:
	var closest: Area2D = null
	var closest_distance := INF

	for hidden_spot in get_tree().get_nodes_in_group("hidden_spot"):
		var hidden_spot_area := hidden_spot as Area2D

		if hidden_spot_area == null:
			continue

		if not hidden_spot_area.get_overlapping_bodies().has(player):
			continue

		var distance := player.global_position.distance_to(hidden_spot_area.global_position)

		if distance < closest_distance:
			closest_distance = distance
			closest = hidden_spot_area

	return closest
