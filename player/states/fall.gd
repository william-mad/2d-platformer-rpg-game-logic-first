class_name PlayerStateFall extends PlayerState

#accelerated fall:
@export var fall_gravity_multiplier : float = 1.25

#coyote time:
@export var coyote_time : float = 0.1
var coyote_timer: float = 0
var air_movement_speed: float = 220.0
var using_running_profile: bool = false


func init() -> void:
	pass



func enter() -> void:
	_capture_air_profile()
	if player.previous_state != crouch:
		player.ledgedetec.enabled = true
	player.animation_player.play("jump")
	player.animation_player.pause()
	#fall faster
	if player.gravity_multiplier < fall_gravity_multiplier:
		player.gravity_multiplier = fall_gravity_multiplier
	
	# Keep coyote time for either grounded movement state.
	if player.previous_state == run or player.previous_state == walk:
		coyote_timer = coyote_time
	else:
		coyote_timer = 0
	
	
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
	player.velocity.x = player.direction.x * air_movement_speed


func physics_update_after_move(_delta: float) -> PlayerState:
	#player on the floor, is idle:
	if (
		player.is_on_floor()
		and Input.is_action_pressed("crouch")
		and not player.is_rope_pay_out_control_active()
	):
		return crouch
	elif player.is_on_floor():
		if not player.ongrounddetection.is_colliding():
			return ledge_grab
		else:
			return get_ground_movement_state_for_profile(using_running_profile)
	return next_state



func set_jump_frame() -> void:
	#this is mapped to the timelino in the frames of the jump 
	#second number on remap is the max fall velocity 
	var frame : float = remap(player.velocity.y, 0.0, 1000, 0.5, 1.0)
	player.animation_player.seek(frame, true)
	pass


func get_air_movement_speed() -> float:
	return air_movement_speed


func is_using_running_profile() -> bool:
	return using_running_profile


func _capture_air_profile() -> void:
	if player.previous_state == jump:
		using_running_profile = jump.is_using_running_profile()
		air_movement_speed = jump.get_air_movement_speed()
		return

	using_running_profile = (
		player.previous_state == run
		or player.previous_state == dash_state
		or player.previous_state == roll
		or (player.previous_state == idle and run.is_running)
	)
	air_movement_speed = get_profile_movement_speed(using_running_profile)
