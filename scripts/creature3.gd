class_name Creature3 extends CharacterBody2D

signal dialog_requested(creature: Creature3)

enum State {
	HOME_IDLE,
	FOLLOW,
	DEFEND,
	FIGHT,
	DOWNED
}

@export_group("Movement")
@export var walk_speed: float = 75.0
@export var run_speed: float = 150.0
@export var gravity: float = 1200.0
@export var follow_distance: float = 70.0
@export var too_far_distance: float = 420.0
@export var too_far_time: float = 4.0
@export var defend_distance: float = 90.0
@export var home_stop_distance: float = 10.0

@export_group("Combat")
@export var attack_damage: int = 1
@export var attack_knockout_damage: float = 0.0
@export var attack_distance: float = 80.0
@export var attack_windup: float = 0.2
@export var attack_cooldown: float = 0.8
@export var max_hp: float = 100.0
@export_range(1.0, 100.0, 0.1, "suffix:hp/day") var passive_healing_per_game_day: float = 10.0
@export var knockback_force: Vector2 = Vector2(180, -120)
@export var knockback_time: float = 0.15
@export_group("Knockout")
@export var max_knockout: float = 100.0
@export var knockout_decay_per_second: float = 55.0
@export var downed_decay_per_second: float = 32.0

@export_group("Prototype Dialog")
@export_enum("follow", "kiss", "none") var prototype_dialog_choice: String = "follow"
@export var interaction_priority: int = 60
@export var interaction_prompt: String = "Talk"

@export_group("Rope")
@export var rope_weight: float = 0.1

@onready var sprite_2d: Sprite2D = %Sprite2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var interaction_area: Area2D = $InteractionArea
@onready var monster_detect: Area2D = $MonsterDetect
@onready var attack_area: Area2D = $AttackArea
@onready var rope_attach_point: Marker2D = %RopeAttachPoint
@onready var hp_bar: CreatureHpBar = get_node_or_null("HPBar") as CreatureHpBar
@onready var knockout_bar: ProgressBar = get_node_or_null("KnockoutBar") as ProgressBar

var state: State = State.HOME_IDLE
var state_after_fight: State = State.HOME_IDLE
var state_before_downed: State = State.HOME_IDLE
var home_position: Vector2
var player: Node2D = null
var direction: int = 1
var too_far_timer: float = 0.0
var returning_home: bool = false
var can_attack: bool = true
var is_attacking: bool = false
var hp: float = 0.0
var knockback_timer: float = 0.0
var knockout_amount: float = 0.0
var knockout_bar_active: bool = false


func _ready() -> void:
	hp = max_hp
	setup_hp_bar()
	setup_knockout_bar()
	home_position = global_position
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	_change_state(State.HOME_IDLE)


func _unhandled_input(event: InputEvent) -> void:
	if state != State.HOME_IDLE:
		return

	if player == null or not is_instance_valid(player):
		return

	if event.is_action_pressed("attack"):
		_change_state(State.DEFEND)


func can_interact(actor: Node) -> bool:
	return (
		state == State.HOME_IDLE
		and actor == player
		and actor is Node2D
	)


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	request_dialog()
	return true


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return interaction_prompt


func _physics_process(delta: float) -> void:
	_apply_gravity(delta)
	var velocity_after_gravity := velocity
	process_knockout(delta)
	process_passive_healing(delta)

	if state == State.DOWNED:
		velocity.x = 0.0
		_move_and_slide_with_rope(delta, velocity_after_gravity)
		return

	if knockback_timer > 0.0:
		knockback_timer -= delta
		_move_and_slide_with_rope(delta, velocity_after_gravity)
		return

	if state in [State.FOLLOW, State.DEFEND]:
		var nearby_monster := get_nearest_monster()
		if nearby_monster != null:
			state_after_fight = state
			_change_state(State.FIGHT)

	match state:
		State.HOME_IDLE:
			_process_home_idle()
		State.FOLLOW:
			_process_follow(delta)
		State.DEFEND:
			_process_defend()
		State.FIGHT:
			_process_fight()

	_move_and_slide_with_rope(delta, velocity_after_gravity)


func _move_and_slide_with_rope(
	delta: float,
	velocity_after_gravity: Vector2
) -> void:
	velocity = Rope.finalize_attached_body_velocity(
		self,
		velocity,
		velocity_after_gravity,
		delta
	)
	move_and_slide()


func request_dialog() -> void:
	dialog_requested.emit(self)

	match prototype_dialog_choice:
		"kiss":
			choose_kiss()
		"follow":
			choose_follow()
		_:
			print("Creature3 dialog requested. Call choose_kiss() or choose_follow().")


func choose_kiss() -> void:
	if state != State.HOME_IDLE:
		return

	_play_animation("kiss")
	await animation_player.animation_finished

	if state == State.HOME_IDLE:
		_play_animation("idle")


func choose_follow() -> void:
	if state == State.HOME_IDLE:
		_change_state(State.FOLLOW)


func take_damage_from_player(_attack) -> void:
	if state != State.FIGHT:
		_change_state(State.DEFEND)


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	knockout_damage: float = 0.0
) -> void:
	var previous_hp := hp
	hp = maxf(hp - amount, 0.0)
	var damage_taken := previous_hp - hp
	DamageEvents.emit_damage_dealt(damage_taken, damage_source, self)
	update_hp_bar()
	print(name, " hp: ", hp, "/", max_hp)

	if hp <= 0.0:
		die()
		return

	apply_knockout(knockout_damage)
	if state == State.DOWNED:
		return

	apply_knockback(damage_source_position)
	_face_x_direction(global_position.x - damage_source_position.x)

	if state != State.FIGHT:
		_change_state(State.DEFEND)


func die() -> void:
	velocity = Vector2.ZERO
	set_physics_process(false)
	queue_free()


func apply_knockback(damage_source_position: Vector2) -> void:
	var knockback_direction := signf(global_position.x - damage_source_position.x)
	if knockback_direction == 0.0:
		knockback_direction = -float(direction)

	velocity = Vector2(knockback_force.x * knockback_direction, knockback_force.y)
	knockback_timer = knockback_time


func _change_state(new_state: State) -> void:
	if state == new_state:
		return

	state = new_state

	match state:
		State.HOME_IDLE:
			returning_home = false
			too_far_timer = 0.0
			velocity.x = 0
			_play_animation("idle")
		State.FOLLOW:
			returning_home = false
			too_far_timer = 0.0
			_play_animation("walk")
		State.DEFEND:
			returning_home = false
			too_far_timer = 0.0
			_play_animation("idle")
		State.FIGHT:
			_play_animation("run")
		State.DOWNED:
			is_attacking = false
			knockback_timer = 0.0
			velocity.x = 0.0
			_play_animation("idle")


func _process_home_idle() -> void:
	velocity.x = 0
	_face_player()


func _process_follow(delta: float) -> void:
	if returning_home:
		_return_to_house()
		return

	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player") as Node2D

	if player == null:
		_start_returning_home()
		return

	var distance_to_player := global_position.distance_to(player.global_position)
	if distance_to_player > too_far_distance:
		too_far_timer += delta
		if too_far_timer >= too_far_time:
			_start_returning_home()
			return
	else:
		too_far_timer = 0.0

	var x_distance := player.global_position.x - global_position.x
	_face_x_direction(x_distance)

	if absf(x_distance) > follow_distance:
		velocity.x = direction * walk_speed
		_play_animation("walk")
	else:
		velocity.x = 0
		_play_animation("idle")


func _process_defend() -> void:
	_face_player()

	if player == null or not is_instance_valid(player):
		velocity.x = 0
		return

	var x_distance := player.global_position.x - global_position.x
	if absf(x_distance) < defend_distance:
		velocity.x = -signf(x_distance) * walk_speed
		_play_animation("walk")
	else:
		velocity.x = 0
		_play_animation("idle")


func _process_fight() -> void:
	var monster := get_nearest_monster()

	if monster == null:
		_change_state(state_after_fight)
		return

	var x_distance := monster.global_position.x - global_position.x
	_face_x_direction(x_distance)

	if absf(x_distance) > attack_distance:
		velocity.x = direction * run_speed
		_play_animation("run")
		return

	velocity.x = 0

	if can_attack:
		_start_attack(monster)


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += gravity * delta
	elif velocity.y > 0:
		velocity.y = 0


func _start_returning_home() -> void:
	returning_home = true
	too_far_timer = 0.0


func _return_to_house() -> void:
	var x_distance := home_position.x - global_position.x
	_face_x_direction(x_distance)

	if absf(x_distance) <= home_stop_distance:
		global_position.x = home_position.x
		velocity.x = 0
		_change_state(State.HOME_IDLE)
		return

	velocity.x = direction * walk_speed
	_play_animation("walk")


func _start_attack(monster: Node2D) -> void:
	if is_attacking or not can_attack:
		return

	is_attacking = true
	can_attack = false
	_play_animation("attack")

	await get_tree().create_timer(attack_windup).timeout

	if state == State.FIGHT and is_instance_valid(monster) and _monster_in_attack_range(monster):
		_damage_monster(monster)

	await get_tree().create_timer(attack_cooldown).timeout

	can_attack = true
	is_attacking = false


func _damage_monster(monster: Node) -> void:
	if monster.has_method("take_damage"):
		monster.take_damage(attack_damage, global_position, self, attack_knockout_damage)
	elif monster.has_method("damage"):
		monster.damage(attack_damage)
		DamageEvents.emit_damage_dealt(attack_damage, self, monster)


func _monster_in_attack_range(monster: Node2D) -> bool:
	if attack_area.get_overlapping_bodies().has(monster):
		return true

	return global_position.distance_to(monster.global_position) <= attack_distance


func get_nearest_monster() -> Node2D:
	var closest: Node2D = null
	var closest_distance := INF

	for body in monster_detect.get_overlapping_bodies():
		var monster := body as Node2D
		if monster == null or not is_instance_valid(monster):
			continue

		if not _is_monster(monster):
			continue

		var distance := global_position.distance_to(monster.global_position)
		if distance < closest_distance:
			closest_distance = distance
			closest = monster

	return closest


func _is_monster(body: Node) -> bool:
	if body == self:
		return false

	if body.is_in_group("player") or body.is_in_group("ally") or body.is_in_group("creature3"):
		return false

	if body.is_in_group("monster") or body.is_in_group("monsters") or body.is_in_group("enemy") or body.is_in_group("enemies"):
		return true

	return body.has_method("take_damage")


func _face_player() -> void:
	if player == null or not is_instance_valid(player):
		return

	_face_x_direction(player.global_position.x - global_position.x)


func _face_x_direction(x_direction: float) -> void:
	if x_direction == 0:
		return

	direction = int(signf(x_direction))
	sprite_2d.flip_h = direction < 0
	attack_area.position.x = absf(attack_area.position.x) * direction


func _play_animation(animation_name: StringName) -> void:
	if animation_player.current_animation == animation_name:
		return

	if animation_player.has_animation(animation_name):
		animation_player.play(animation_name)


func _on_interaction_area_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player = body
		if body.has_method("register_interaction_candidate"):
			body.call("register_interaction_candidate", self)


func _on_interaction_area_body_exited(body: Node2D) -> void:
	if body.has_method("unregister_interaction_candidate"):
		body.call("unregister_interaction_candidate", self)
	if body == player and state == State.HOME_IDLE:
		player = null


func get_rope_attach_point() -> Node2D:
	return rope_attach_point


func get_rope_weight() -> float:
	return rope_weight


func is_rope_immovable() -> bool:
	return false


func setup_hp_bar() -> void:
	if hp_bar != null:
		hp_bar.setup_hp(max_hp, hp)


func update_hp_bar() -> void:
	if hp_bar != null:
		hp_bar.set_hp(hp)


func heal(amount: float) -> void:
	if amount <= 0.0 or hp <= 0.0:
		return
	hp = minf(hp + amount, max_hp)
	update_hp_bar()


func restore_full_health() -> void:
	heal(max_hp - hp)


func process_passive_healing(delta: float) -> void:
	if passive_healing_per_game_day <= 0.0 or hp <= 0.0 or hp >= max_hp:
		return

	var game_hours := _get_game_hours_for_real_seconds(delta)
	if game_hours <= 0.0:
		return

	heal((passive_healing_per_game_day / 24.0) * game_hours)


func _get_game_hours_for_real_seconds(real_seconds: float) -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null:
		return 0.0

	var real_seconds_per_day := float(world_time.get("real_seconds_per_day"))
	if real_seconds_per_day <= 0.0:
		return 0.0

	return (maxf(real_seconds, 0.0) / real_seconds_per_day) * 24.0


func setup_knockout_bar() -> void:
	if knockout_bar == null:
		knockout_bar = ProgressBar.new()
		knockout_bar.name = "KnockoutBar"
		knockout_bar.offset_left = -36.0
		knockout_bar.offset_top = -109.0
		knockout_bar.offset_right = 36.0
		knockout_bar.offset_bottom = -105.0
		knockout_bar.show_percentage = false
		add_child(knockout_bar)

	knockout_bar.min_value = 0.0
	knockout_bar.max_value = maxf(max_knockout, 1.0)
	update_knockout_bar()


func update_knockout_bar() -> void:
	if knockout_bar == null:
		return

	knockout_bar.value = clampf(knockout_amount, 0.0, maxf(max_knockout, 1.0))
	knockout_bar.visible = knockout_bar_active and knockout_amount > 0.0


func apply_knockout(amount: float) -> void:
	if amount <= 0.0 or max_knockout <= 0.0:
		return

	knockout_amount = clampf(knockout_amount + amount, 0.0, max_knockout)
	knockout_bar_active = knockout_amount > 0.0
	if knockout_amount >= max_knockout:
		enter_downed_state()
	update_knockout_bar()


func process_knockout(delta: float) -> void:
	if not knockout_bar_active:
		return

	var decay_rate := downed_decay_per_second if state == State.DOWNED else knockout_decay_per_second
	knockout_amount = move_toward(knockout_amount, 0.0, maxf(decay_rate, 0.0) * maxf(delta, 0.0))
	if knockout_amount <= 0.0:
		knockout_bar_active = false
		if state == State.DOWNED:
			_change_state(state_before_downed)

	update_knockout_bar()


func enter_downed_state() -> void:
	if state != State.DOWNED:
		state_before_downed = state
	_change_state(State.DOWNED)
