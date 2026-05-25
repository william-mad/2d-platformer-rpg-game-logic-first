class_name PlayerAttack2 extends PlayerState

@export var deceleration_rate : float = 1
@export var attack_duration: float = 0.4
@export var combo_time_window: float = 0.2
@export var speed: float = 150.0

var attack_timer: float = 0.0
var combo_timer: float = 0.0
var combo_requested: bool = false


func init() -> void:
	print("init ", name)


func enter() -> void:
	print("enter ", name)

	# Reset state values every time this state starts.
	attack_timer = attack_duration
	combo_timer = 0.0
	combo_requested = false
	next_state = null

	do_attack()


func exit() -> void:
	print("exit ", name)

	# Optional: make sure attack hitbox turns off when leaving.


func handle_input(_event: InputEvent) -> PlayerState:
	if _event.is_action_pressed( "jump" ) and player.is_on_floor():
		print("trying to jump")
		return jump
	# Allow attack input to queue the next combo attack.
	if _event.is_action_pressed("attack"):
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
		return attack_3
		
	if player.is_on_floor():
		return idle
	else:
		return fall


func physics_process(_delta: float) -> PlayerState:
	# Optional: reduce/control movement during attack.
	player.velocity.x = player.direction.x * player.move_speed /2
	# Stay in this state unless process() changes it.
	return null


func do_attack() -> void:
	player.attack_2.activate()
	player.animation_player.play("attack_2")
