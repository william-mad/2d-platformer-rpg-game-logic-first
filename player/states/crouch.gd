class_name PlayerStateCrouch extends PlayerState

@export var deceleration_rate : float = 10

func init() -> void:
	
	pass



func enter() -> void:
	player.ledgegrabcolider.disabled = true
	player.animation_player.play("crouch")
	player.colider_stand.disabled = true
	player.colider_crouch.disabled = false
	pass



func exit() -> void:
	player.colider_stand.disabled = false
	player.colider_crouch.disabled = true
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	if _event.is_action_released("attack"):
		return get_attack_release_state()
	
	if _event.is_action_released("crouch"):
		if player.is_on_floor():
			return idle
		else:
			return fall
	elif _event.is_action_pressed("jump"):
		if player.small_platform_detection.is_colliding() == false:
			player.position.y += 4
	return next_state


func process(_delta: float) -> PlayerState:
	if not player.is_on_floor():
		return fall

	return next_state
	

func physics_process(_delta: float) -> PlayerState:
	player.velocity.x -= player.velocity.x * deceleration_rate *_delta
	return next_state
	#player on the floor, is idle:
