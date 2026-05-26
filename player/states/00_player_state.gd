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
@onready var dash_state = %Dash
@onready var special_attack_3: PlayerState = %SpecialAttack3
@onready var special_attack_2: PlayerState = %SpecialAttack2
@onready var special_attack_1: PlayerState = %SpecialAttack1
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


func get_dash_state_from_input(_event: InputEvent) -> PlayerState:
	return dash_state.get_dash_state_from_input(_event)


func get_attack_release_state() -> PlayerState:
	var special_state := get_special_attack_release_state()

	if special_state != null:
		return special_state

	return attack_1


func get_special_attack_release_state() -> PlayerState:
	var one_third_mana := player.mana.max_value / 3.0
	var two_thirds_mana := one_third_mana * 2.0
	var full_mana := player.mana.max_value
	var current_mana := player.mana.value

	if current_mana >= full_mana:
		return use_special_attack(full_mana, special_attack_3)

	if current_mana >= two_thirds_mana:
		return use_special_attack(two_thirds_mana, special_attack_2)

	if current_mana >= one_third_mana:
		return use_special_attack(one_third_mana, special_attack_1)

	clear_attack_charge()
	return null


func clear_attack_charge() -> void:
	player.mana.value = 0.0


func use_special_attack(mana_cost: float, special_state: PlayerState) -> PlayerState:
	player.spend_mana_2(mana_cost)
	clear_attack_charge()
	return special_state


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
