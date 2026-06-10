class_name PlayerStateIdle extends PlayerState


func init() -> void:
	pass



func enter() -> void:
	player.ledgegrabcolider.disabled = true
	player.animation_player.play( "idle" )
	pass



func exit() -> void:
	pass


func handle_input( _event : InputEvent) -> PlayerState:
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
	if player.direction.x != 0:
		return run
	return next_state


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = 0
	
	#player going down is falling:
	if player.velocity.y > 0.5:
		return fall
		
	return next_state
