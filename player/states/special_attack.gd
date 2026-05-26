class_name PlayerSpecialAttack extends PlayerState

@export var attack_tier: int = 1
@export var attack_duration: float = 0.45
@export var hitbox_duration: float = 0.16
@export var move_speed_multiplier: float = 0.25

var attack_timer: float = 0.0


func init() -> void:
	print("init ", name)


func enter() -> void:
	print("enter ", name)
	attack_timer = attack_duration
	next_state = null
	do_special_attack()


func exit() -> void:
	print("exit ", name)


func handle_input(_event: InputEvent) -> PlayerState:
	return null


func process(delta: float) -> PlayerState:
	attack_timer -= delta

	if attack_timer > 0.0:
		return null

	if player.is_on_floor():
		return idle

	return fall


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = player.direction.x * player.move_speed * move_speed_multiplier
	return null


func do_special_attack() -> void:
	match attack_tier:
		1:
			player.attack_1.activate(hitbox_duration)
			player.animation_player.play("attack_1")
		2:
			player.attack_2.activate(hitbox_duration)
			player.animation_player.play("attack_2")
		3:
			player.attack_3.activate(hitbox_duration)
			player.animation_player.play("attack_3")
		_:
			player.attack_1.activate(hitbox_duration)
			player.animation_player.play("attack_1")

	print("special attack tier ", attack_tier)
