class_name PlayerStateHidden extends PlayerState

const PLAYER_LAYER := 2
const HIDDEN_LAYER := 4

@export var hidden_move_speed: float = 100.0

var previous_collision_layer: int = 0
var hidden_spot: Area2D = null


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
	print("enter", name)
	pass


func exit() -> void:
	player.collision_layer = previous_collision_layer
	player.colider_stand.disabled = false
	player.colider_crouch.disabled = true
	player.sprite_2d.visible = true
	hidden_spot = null
	print("exit", name)
	pass


func handle_input(_event: InputEvent) -> PlayerState:
	if _event.is_action_pressed("up") and player.is_on_floor():
		return get_floor_exit_state()

	return next_state


func process(_delta: float) -> PlayerState:
	if hidden_spot == null or not is_instance_valid(hidden_spot):
		if player.is_on_floor():
			return get_floor_exit_state()

	return next_state


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = player.direction.x * hidden_move_speed

	if hidden_spot != null and is_instance_valid(hidden_spot):
		hidden_spot.global_position.x = player.global_position.x

	return next_state


func get_floor_exit_state() -> PlayerState:
	if player.direction.x != 0:
		return run

	return idle
