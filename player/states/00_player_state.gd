class_name PlayerState extends Node

var player : Player
var next_state : PlayerState

#state references
@onready var idle: PlayerStateIdle = %Idle
@onready var run: PlayerStateRun = %Run
@onready var jump: PlayerStateJump = %Jump
@onready var fall: PlayerStateFall = %Fall
@onready var crouch: PlayerStateCrouch = %Crouch
@onready var attack_3: PlayerAttack3 = %Attack3
@onready var attack_1: PlayerAttack1 = %Attack1
@onready var attack_2: Node = %Attack2



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
