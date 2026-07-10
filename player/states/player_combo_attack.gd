class_name PlayerComboAttackState
extends PlayerState

@export var combo_definition: ComboDefinition
@export var attack_index: int = 0

var attack_timer: float = 0.0
var combo_timer: float = 0.0
var combo_requested: bool = false
var current_attack: AttackDefinition


func enter() -> void:
	current_attack = _get_current_attack()
	attack_timer = current_attack.state_duration if current_attack != null else 0.0
	combo_timer = 0.0
	combo_requested = false
	next_state = null
	_do_attack()


func handle_input(event: InputEvent) -> PlayerState:
	if current_attack != null and current_attack.allow_ground_jump_cancel:
		if event.is_action_pressed("jump") and player.is_on_floor():
			return jump

	if event.is_action_released("attack"):
		var special_state := get_special_attack_release_state()
		if special_state != null:
			return special_state

		if _has_next_combo_state() and current_attack != null:
			combo_requested = true
			combo_timer = maxf(current_attack.combo_window_seconds, 0.0)

	return null


func process(delta: float) -> PlayerState:
	attack_timer -= delta
	if combo_timer > 0.0:
		combo_timer -= delta

	if attack_timer > 0.0:
		return null

	if combo_requested and combo_timer > 0.0:
		var next_combo_state := _get_next_combo_state()
		if next_combo_state != null:
			return next_combo_state

	if current_attack != null and current_attack.return_to_crouch_if_held:
		if Input.is_action_pressed("crouch") and player.is_on_floor():
			return crouch

	if player.is_on_floor():
		return idle

	return fall


func physics_process(_delta: float) -> PlayerState:
	if current_attack == null:
		player.velocity.x = 0.0
		return null

	player.velocity.x = player.direction.x * player.move_speed * current_attack.move_speed_multiplier
	return null


func _do_attack() -> void:
	if current_attack == null:
		return

	if current_attack.animation_name != &"":
		player.animation_player.play(String(current_attack.animation_name))

	var facing_x := -1.0 if player.sprite_2d.flip_h else 1.0
	player.attack_hitbox.activate(current_attack, player, facing_x)


func _get_current_attack() -> AttackDefinition:
	if combo_definition == null:
		return null

	return combo_definition.get_attack(attack_index)


func _has_next_combo_state() -> bool:
	return _get_next_combo_state() != null


func _get_next_combo_state() -> PlayerComboAttackState:
	var states_node := get_parent()
	if states_node == null:
		return null

	for child in states_node.get_children():
		var combo_state := child as PlayerComboAttackState
		if combo_state == null or combo_state == self:
			continue
		if combo_state.combo_definition == combo_definition and combo_state.attack_index == attack_index + 1:
			return combo_state

	return null
