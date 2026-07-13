class_name PlayerStateIdle extends PlayerState


func init() -> void:
	pass



func enter() -> void:
	run.begin_idle_to_walk_countdown()
	player.ledgegrabcolider.disabled = true
	player.animation_player.play( "idle" )
	pass



func exit() -> void:
	run.update_idle_to_walk_countdown()
	run.cancel_idle_to_walk_countdown()


func handle_input( _event : InputEvent) -> PlayerState:
	run.update_idle_to_walk_countdown()

	var requested_dash := get_dash_state_from_input(_event)

	if requested_dash != null:
		return requested_dash

	if _event.is_action_pressed("up") and can_hide():
		return hidden

	if _event.is_action_released("attack"):
		return get_attack_release_state()
	
	if _event.is_action_pressed( "jump" ):
		return jump
	if _event.is_action_pressed("crouch"):
		return crouch
	return next_state


func process(_delta: float) -> PlayerState:
	run.update_idle_to_walk_countdown()
	if player.direction.x != 0:
		return run
	return next_state


func physics_update_before_move(_delta: float) -> void:
	player.velocity.x = 0


func physics_update_after_move(_delta: float) -> PlayerState:
	#player going down is falling:
	if player.velocity.y > 0.5:
		return fall
		
	return next_state
