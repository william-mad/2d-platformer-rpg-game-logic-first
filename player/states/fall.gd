class_name PlayerStateFall extends PlayerState

#accelerated fall:
@export var fall_gravity_multiplier : float = 1.25

#coyote time:
@export var coyote_time : float = 0.1
var coyote_timer: float = 0


func init() -> void:
	pass



func enter() -> void:
	if player.previous_state != crouch:
		player.ledgedetec.enabled = true
	player.animation_player.play("jump")
	player.animation_player.pause()
	#fall faster
	if player.gravity_multiplier < fall_gravity_multiplier:
		player.gravity_multiplier = fall_gravity_multiplier
	
	#coyote timer if coming from run/idle:
	if player.previous_state != run:
		coyote_timer = 0
	else:
		coyote_timer = coyote_time
	
	
	pass



func exit() -> void:
	player.ledgedetec.enabled = false
	player.gravity_multiplier = 1.0
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	var requested_dash := get_dash_state_from_input(_event)

	if requested_dash != null:
		return requested_dash
	
	if _event.is_action_released("attack"):
		return get_attack_release_state()
	
	if _event.is_action_pressed( "jump" ) and coyote_timer > 0:
		return jump
	
	#if press down, go down 5x faster
	if _event.is_action_pressed("crouch"):
		player.gravity_multiplier = player.gravity_multiplier * 5
		player.ledgedetec.enabled = false
		return fall
	
	if _event.is_action_released("crouch"):
		player.gravity_multiplier = fall_gravity_multiplier
		player.ledgedetec.enabled = true
		return fall
		
	return next_state


func process(_delta: float) -> PlayerState:
	coyote_timer -= _delta 
	if player.ledgedetec.is_colliding() == true:
		player.ledgegrabcolider.disabled = false
	else:
		player.ledgegrabcolider.disabled = true
	set_jump_frame()
	return next_state

func physics_update_before_move(_delta: float) -> void:
	player.velocity.x = player.direction.x * player.move_speed


func physics_update_after_move(_delta: float) -> PlayerState:
	#player on the floor, is idle:
	if player.is_on_floor() and Input.is_action_pressed("crouch"):
		return crouch
	elif player.is_on_floor():
		if not player.ongrounddetection.is_colliding():
			return ledge_grab
		else:
			return idle
	return next_state



func set_jump_frame() -> void:
	#this is mapped to the timelino in the frames of the jump 
	#second number on remap is the max fall velocity 
	var frame : float = remap(player.velocity.y, 0.0, 1000, 0.5, 1.0)
	player.animation_player.seek(frame, true)
	pass
