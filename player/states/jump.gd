class_name PlayerStateJump extends PlayerState

@export var jump_velocity : float = 900

func init() -> void:
	
	pass



func enter() -> void:
	player.ledgedetec.enabled = true
	player.animation_player.play("jump")
	player.animation_player.pause()
	print("enter", name)
	if player.previous_state == ledge_grab:
		player.velocity.y = -jump_velocity/1.5
	else:
		player.velocity.y = -jump_velocity
	pass



func exit() -> void:
	player.ledgedetec.enabled = false
	print("exit", name)
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	var requested_dash := get_dash_state_from_input(_event)

	if requested_dash != null:
		return requested_dash
	
	if _event.is_action_released("attack"):
		return get_attack_release_state()
		
	if _event.is_action_released("jump"):
		player.velocity.y *= 0.5
		
	#if press down, go down 5x faster
	if _event.is_action_pressed("crouch"):
		player.gravity_multiplier = player.gravity_multiplier * 5
		player.ledgedetec.enabled = false
		return fall
	return next_state


func process(_delta: float) -> PlayerState:
	if player.ledgedetec.is_colliding() == true:
		player.ledgegrabcolider.disabled = false
	else:
		player.ledgegrabcolider.disabled = true
	set_jump_frame()
	return next_state

func physics_process(_delta: float) -> PlayerState:
	#player on the floor, is idle:
	if player.is_on_floor():
		if player.ongrounddetection.is_colliding():
			return ledge_grab
		else:
			return idle
	#player going down is falling:
	if player.velocity.y >= 0:
		return fall
	
	player.velocity.x = player.direction.x * player.move_speed
	return next_state


#func to decide the frame while in the air (responsive to velocity)

func set_jump_frame() -> void:
	#this is mapped to the timelino in the frames of the jump/fall anim
	var frame : float = remap(player.velocity.y, -jump_velocity, 0.0, 0.0, 0.5)
	player.animation_player.seek(frame, true)
	pass
