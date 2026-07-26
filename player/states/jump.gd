class_name PlayerStateJump extends PlayerState

@export_group("Jump Profiles")
@export var walk_jump_velocity: float = 700.0
@export var run_jump_velocity: float = 850.0
@export var ledge_jump_velocity: float = 600.0

var active_jump_velocity: float = 700.0
var air_movement_speed: float = 260.0
var using_running_profile: bool = false

func init() -> void:
	
	pass



func enter() -> void:
	_capture_jump_profile()
	player.ledgedetec.enabled = true
	player.animation_player.play("jump")
	player.animation_player.pause()
	if player.previous_state == ledge_grab:
		active_jump_velocity = ledge_jump_velocity
		player.velocity.y = -ledge_jump_velocity
	else:
		player.velocity.y = -active_jump_velocity
	pass



func exit() -> void:
	player.ledgedetec.enabled = false
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

func physics_update_before_move(_delta: float) -> void:
	player.velocity.x = player.direction.x * air_movement_speed


func physics_update_after_move(_delta: float) -> PlayerState:
	#player on the floor, is idle:
	if player.is_on_floor():
		if player.ongrounddetection.is_colliding():
			return ledge_grab
		else:
			return run if player.direction.x != 0.0 else idle
	#player going down is falling:
	if player.velocity.y >= 0:
		return fall

	return next_state


#func to decide the frame while in the air (responsive to velocity)

func set_jump_frame() -> void:
	#this is mapped to the timelino in the frames of the jump/fall anim
	var frame : float = remap(player.velocity.y, -active_jump_velocity, 0.0, 0.0, 0.5)
	player.animation_player.seek(frame, true)
	pass


func get_air_movement_speed() -> float:
	return air_movement_speed


func is_using_running_profile() -> bool:
	return using_running_profile


func _capture_jump_profile() -> void:
	if player.previous_state == fall:
		using_running_profile = fall.is_using_running_profile()
	else:
		using_running_profile = (
			run.is_running
			and player.previous_state != ledge_grab
		)

	active_jump_velocity = (
		run_jump_velocity if using_running_profile else walk_jump_velocity
	)
	air_movement_speed = run.get_movement_speed_for_mode(using_running_profile)
