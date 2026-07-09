class_name PlayerState extends Node

const SPECIAL_MANA_THRESHOLD_MARGIN_RATIO := 0.001
const SPECIAL_MANA_MIN_THRESHOLD_MARGIN := 0.01

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
@onready var downed: PlayerStateDowned = %Downed




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
	if player.max_mana <= 0.0:
		clear_attack_charge()
		return null

	var one_third_mana := player.max_mana / 3.0
	var two_thirds_mana := one_third_mana * 2.0
	var full_mana := player.max_mana
	var current_mana := player.mana_amount

	if has_mana_for_special(current_mana, full_mana):
		return use_special_attack(full_mana, special_attack_3)

	if has_mana_for_special(current_mana, two_thirds_mana):
		return use_special_attack(two_thirds_mana, special_attack_2)

	if has_mana_for_special(current_mana, one_third_mana):
		return use_special_attack(one_third_mana, special_attack_1)

	clear_attack_charge()
	return null


func has_mana_for_special(current_mana: float, required_mana: float) -> bool:
	if current_mana >= required_mana or is_equal_approx(current_mana, required_mana):
		return true

	return required_mana - current_mana <= get_special_mana_threshold_margin(required_mana)


func get_special_mana_threshold_margin(required_mana: float) -> float:
	return maxf(required_mana * SPECIAL_MANA_THRESHOLD_MARGIN_RATIO, SPECIAL_MANA_MIN_THRESHOLD_MARGIN)


func clear_attack_charge() -> void:
	player.clear_mana_charge()


func use_special_attack(mana_cost: float, special_state: PlayerState) -> PlayerState:
	player.spend_mana_2(mana_cost)
	clear_attack_charge()
	return special_state


func get_current_hidden_spot() -> Node2D:
	var closest: Node2D = null
	var closest_distance := INF

	for hidden_spot in get_tree().get_nodes_in_group("hidden_spot"):
		var hidden_spot_node := hidden_spot as Node2D

		if hidden_spot_node == null:
			continue

		if not can_hide_in_spot(hidden_spot_node):
			continue

		var distance := player.global_position.distance_to(hidden_spot_node.global_position)

		if distance < closest_distance:
			closest_distance = distance
			closest = hidden_spot_node

	return closest


func can_hide_in_spot(hidden_spot: Node2D) -> bool:
	if hidden_spot.has_method("contains_player"):
		return bool(hidden_spot.call("contains_player", player))

	var hidden_spot_area := hidden_spot as Area2D

	if hidden_spot_area == null:
		return false

	return hidden_spot_area.get_overlapping_bodies().has(player)
