class_name PlayerAttack1 extends PlayerState

@export var attack_duration: float = 0.4
@export var combo_time_window: float = 0.3
@export var speed: float = 150.0
#@export var deceleration_rate : float = 5

var attack_timer: float = 0.0
var combo_timer: float = 0.0
var combo_requested: bool = false


func init() -> void:
	pass


func enter() -> void:
	# Reset state values every time this state starts.
	attack_timer = attack_duration
	combo_timer = 0.0
	combo_requested = false
	next_state = null

	do_attack()


func exit() -> void:
	# Optional: make sure attack hitbox turns off when leaving.
	pass


func handle_input(_event: InputEvent) -> PlayerState:
	# Allow attack release to queue the next combo attack.
	if _event.is_action_released("attack"):
		var special_state := get_special_attack_release_state()

		if special_state != null:
			return special_state

		combo_requested = true
		combo_timer = combo_time_window

	# Lock the player in this attack state.
	# Jump and crouch are ignored while attacking.
	return null


func process(delta: float) -> PlayerState:
	attack_timer -= delta

	if combo_timer > 0.0:
		combo_timer -= delta

	# While the attack timer is active, stay in this state.
	if attack_timer > 0.0:
		return null

	# Attack duration is finished, so choose the next state.
	if combo_requested and combo_timer > 0.0:
		return attack_2
	
	if player.is_on_floor():
		return idle
	else:
		return fall
		 
	


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = player.direction.x * player.move_speed /2
	# Stay in this state unless process() changes it.
	return null


func do_attack() -> void:
	player.attack_1.activate()
	player.animation_player.play("attack_1")
