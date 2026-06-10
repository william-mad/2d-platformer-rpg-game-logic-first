class_name PlayerStateRun extends PlayerState


func init() -> void:
	pass



func enter() -> void:
	player.animation_player.play("run")
	player.ledgegrabcolider.disabled = true
	pass



func exit() -> void:
	pass


func handle_input(_event : InputEvent) -> PlayerState:
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
	if player.direction.x == 0:
		return idle
	return next_state

func physics_process(_delta: float) -> PlayerState:
	#player going down is falling:
	if player.velocity.y > 0.5:
		return fall
	
	player.velocity.x = player.direction.x * player.move_speed
	
	return next_state
