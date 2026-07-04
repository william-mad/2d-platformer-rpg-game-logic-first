class_name PlayerStateDowned extends PlayerState

@export var animation_name: StringName = &""


func enter() -> void:
	next_state = null
	player.velocity.x = 0.0
	player.knockback_timer = 0.0
	player.ledgegrabcolider.disabled = true
	if animation_name != &"" and player.animation_player.has_animation(animation_name):
		player.animation_player.play(animation_name)
	elif player.animation_player.has_animation("idle"):
		player.animation_player.play("idle")


func handle_input(_event: InputEvent) -> PlayerState:
	return null


func process(_delta: float) -> PlayerState:
	if player.is_downed:
		return null

	if player.is_on_floor():
		return idle

	return fall


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = 0.0
	return null
