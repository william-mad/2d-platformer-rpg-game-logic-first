class_name PlayerStateRun extends PlayerState


func init() -> void:
	print("init", name)
	pass



func enter() -> void:
	player.animation_player.play("run")
	player.ledgegrabcolider.disabled = true
	print("enter", name)
	pass



func exit() -> void:
	print("exit", name)
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	if _event.is_action_pressed("attack"):
		return attack_1
		
	if _event.is_action_pressed( "jump" ):
		print("trying to jump")
		return jump
	
	if _event.is_action_pressed("crouch"):
		return crouch
	
	print(next_state)
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
