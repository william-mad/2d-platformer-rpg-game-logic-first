class_name PlayerStateJump extends PlayerState

@export var jump_velocity : float = 900

func init() -> void:
	
	pass



func enter() -> void:
	player.animation_player.play("jump")
	player.animation_player.pause()
	print("enter", name)
	player.velocity.y = -jump_velocity
	pass



func exit() -> void:
	print("exit", name)
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	if _event.is_action_released("jump"):
		player.velocity.y *= 0.5
		
	#if press down, go down 5x faster
	if _event.is_action_pressed("crouch"):
		player.gravity_multiplier = player.gravity_multiplier * 5
		return fall
	return next_state


func process(_delta: float) -> PlayerState:
	set_jump_frame()
	return next_state

func physics_process(_delta: float) -> PlayerState:
	#player on the floor, is idle:
	if player.is_on_floor():
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
