class_name PlayerStateHidden extends PlayerState

const PLAYER_LAYER := 2
const HIDDEN_LAYER := 4

@export var hidden_move_speed: float = 100.0

var previous_collision_layer: int = 0
var hidden_spot: Node2D = null


func init() -> void:
	pass


func enter() -> void:
	hidden_spot = get_current_hidden_spot()
	previous_collision_layer = player.collision_layer
	player.set_collision_layer_value(PLAYER_LAYER, false)
	player.set_collision_layer_value(HIDDEN_LAYER, true)
	player.velocity.x = 0
	player.ledgegrabcolider.disabled = true
	player.colider_stand.disabled = true
	player.colider_crouch.disabled = false
	player.sprite_2d.visible = false
	player.animation_player.play("crouch")
	pass


func exit() -> void:
	if hidden_spot != null and is_instance_valid(hidden_spot) and hidden_spot.has_method("stop_hidden_control"):
		hidden_spot.call("stop_hidden_control")

	player.collision_layer = previous_collision_layer
	player.colider_stand.disabled = false
	player.colider_crouch.disabled = true
	player.sprite_2d.visible = true
	hidden_spot = null
	pass


func handle_input(_event: InputEvent) -> PlayerState:
	if _event.is_action_released("attack"):
		clear_attack_charge()
		return next_state

	if _event.is_action_pressed("up") and player.is_on_floor():
		return get_floor_exit_state()

	return next_state


func process(_delta: float) -> PlayerState:
	if hidden_spot == null or not is_instance_valid(hidden_spot):
		if player.is_on_floor():
			return get_floor_exit_state()

	return next_state


func physics_process(_delta: float) -> PlayerState:
	if should_move_with_hidden_spot():
		var move_velocity_x := player.direction.x * hidden_move_speed

		if hidden_spot != null and is_instance_valid(hidden_spot) and hidden_spot.has_method("set_hidden_move_velocity_x"):
			player.velocity.x = 0.0
			hidden_spot.call("set_hidden_move_velocity_x", move_velocity_x)
			sync_player_to_hidden_spot()
		else:
			player.velocity.x = move_velocity_x
			hidden_spot.global_position.x = player.global_position.x
	else:
		player.velocity.x = 0.0

	return next_state


func get_floor_exit_state() -> PlayerState:
	if player.direction.x != 0:
		return run

	return idle


func should_move_with_hidden_spot() -> bool:
	if hidden_spot == null or not is_instance_valid(hidden_spot):
		return false

	if hidden_spot.has_method("should_move_with_player_while_hidden"):
		return bool(hidden_spot.call("should_move_with_player_while_hidden"))

	return true


func sync_player_to_hidden_spot() -> void:
	if hidden_spot == null or not is_instance_valid(hidden_spot):
		return

	if hidden_spot.has_method("get_hidden_player_position"):
		var hidden_player_position: Vector2 = hidden_spot.call("get_hidden_player_position")
		player.global_position = hidden_player_position
