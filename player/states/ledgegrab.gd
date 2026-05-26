class_name PlayerStateLedgeGrab extends PlayerState


func init() -> void:
	print("init", name)
	pass



func enter() -> void:
	player.animation_player.play( "idle" )
	player.ledgegrabcolider.disabled = false
	print("enter", name)
	pass



func exit() -> void:
	player.ledgegrabcolider.disabled = true
	print("exit", name)
	pass


func handle_input( _event : InputEvent) -> PlayerState:
	if _event.is_action_released("attack"):
		clear_attack_charge()
		return next_state
	
	if _event.is_action_pressed( "jump" ):
		print("trying to jump")
		return jump
	if _event.is_action_pressed("crouch"):
		player.position.y += 4
		return fall
	print(next_state)
	return next_state


func process(_delta: float) -> PlayerState:
	if player.ongrounddetection.is_colliding():
		return idle
	return next_state


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = 0
	
	#player going down is falling:
	if player.velocity.y > 0.5:
		return fall
		
	return next_state
