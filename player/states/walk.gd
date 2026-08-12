class_name PlayerStateWalk extends PlayerState

@export var walk_speed: float = 220.0
@export var walk_animation: StringName = &"walk"


func enter() -> void:
	run.clear_running()
	player.animation_player.play(walk_animation)
	player.ledgegrabcolider.disabled = true


func handle_input(event: InputEvent) -> PlayerState:
	var requested_dash := get_dash_state_from_input(event)
	if requested_dash != null:
		return requested_dash

	if event.is_action_pressed("charm") and can_hide():
		return hidden

	if event.is_action_released("attack"):
		return get_attack_release_state()

	if event.is_action_pressed("jump"):
		return jump

	if event.is_action_pressed("crouch"):
		return crouch

	return next_state


func process(_delta: float) -> PlayerState:
	if is_zero_approx(player.direction.x):
		return idle
	return next_state


func physics_update_before_move(_delta: float) -> void:
	player.velocity.x = player.direction.x * walk_speed


func physics_update_after_move(_delta: float) -> PlayerState:
	if player.velocity.y > 0.5:
		return fall
	return next_state
