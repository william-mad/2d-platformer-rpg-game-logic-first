class_name PlayerAttack3 extends PlayerState

@export var attack_duration: float = 0.4
@export var deceleration_rate : float = 1

var attack_timer: float = 0.0


func init() -> void:
	print("init ", name)


func enter() -> void:
	print("enter ", name)

	attack_timer = attack_duration
	next_state = null

	do_attack()


func exit() -> void:
	print("exit ", name)


func handle_input(_event: InputEvent) -> PlayerState:
	if _event.is_action_released("attack"):
		return get_special_attack_release_state()

	# Last attack: ignore attack/jump/crouch input while locked.
	return null


func process(delta: float) -> PlayerState:
	attack_timer -= delta

	if attack_timer > 0.0:
		return null

	return idle


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = player.direction.x * player.move_speed /2
	return null


func do_attack() -> void:
	player.attack_3.activate()
	player.animation_player.play("attack_3")
