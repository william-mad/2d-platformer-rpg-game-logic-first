class_name PlayerStateCrouch extends PlayerState

@export var deceleration_rate : float = 10
@export var mana_charge_rate: float = 300.0

func init() -> void:
	
	pass



func enter() -> void:
	player.animation_player.play("crouch")
	player.colider_stand.disabled = true
	player.colider_crouch.disabled = false
	print("enter", name)
	pass



func exit() -> void:
	player.colider_stand.disabled = false
	player.colider_crouch.disabled = true
	print("exit", name)
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	
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

	if Input.is_action_pressed("attack"):
		charge(_delta)

	if Input.is_action_just_released("attack"):
		return next_state

	return next_state
	

func physics_process(_delta: float) -> PlayerState:
	player.velocity.x -= player.velocity.x * deceleration_rate *_delta
	return next_state
	#player on the floor, is idle:
	


func charge(delta) -> void:
	player.mana.value += mana_charge_rate *delta
	print("charging: ", player.mana.value)
		
