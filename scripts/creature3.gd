class_name Creature3 extends CharacterBody2D

signal dialog_requested(creature: Creature3)

enum State {
	HOME_IDLE,
	FOLLOW,
	DEFEND,
	FIGHT
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
@export var attack_distance: float = 80.0
@export var attack_windup: float = 0.2
@export var attack_cooldown: float = 0.8
@export var max_hp: float = 100.0
@export var knockback_force: Vector2 = Vector2(180, -120)
@export var knockback_time: float = 0.15

@export_group("Prototype Dialog")
@export_enum("follow", "kiss", "none") var prototype_dialog_choice: String = "follow"

@onready var sprite_2d: Sprite2D = %Sprite2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var interaction_area: Area2D = $InteractionArea
@onready var monster_detect: Area2D = $MonsterDetect
@onready var attack_area: Area2D = $AttackArea
@onready var rope_attach_point: Marker2D = %RopeAttachPoint
@onready var hp_bar: CreatureHpBar = get_node_or_null("HPBar") as CreatureHpBar

var state: State = State.HOME_IDLE
var state_after_fight: State = State.HOME_IDLE
var home_position: Vector2
var player: Node2D = null
var direction: int = 1
var too_far_timer: float = 0.0
var returning_home: bool = false
var can_attack: bool = true
var is_attacking: bool = false
var hp: float = 0.0
var knockback_timer: float = 0.0


func _ready() -> void:
	hp = max_hp
	setup_hp_bar()
	home_position = global_position
	interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	_change_state(State.HOME_IDLE)


func _unhandled_input(event: InputEvent) -> void:
	if state != State.HOME_IDLE:
		return

	if player == null or not is_instance_valid(player):
		return

	if event.is_action_pressed("up"):
		request_dialog()

	if event.is_action_pressed("attack"):
		_change_state(State.DEFEND)


func _physics_process(delta: float) -> void:
	_apply_gravity(delta)

	if knockback_timer > 0.0:
		knockback_timer -= delta
		move_and_slide()
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


func take_damage(amount: float, damage_source_position: Vector2 = Vector2.ZERO, damage_source: Node = null) -> void:
	var previous_hp := hp
	hp = maxf(hp - amount, 0.0)
	var damage_taken := previous_hp - hp
	DamageEvents.emit_damage_dealt(damage_taken, damage_source, self)
	update_hp_bar()
	print(name, " hp: ", hp, "/", max_hp)

	if hp <= 0.0:
		die()
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
		monster.take_damage(attack_damage, global_position, self)
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


func _on_interaction_area_body_exited(body: Node2D) -> void:
	if body == player and state == State.HOME_IDLE:
		player = null


func get_rope_attach_point() -> Node2D:
	return rope_attach_point


func setup_hp_bar() -> void:
	if hp_bar != null:
		hp_bar.setup_hp(max_hp, hp)


func update_hp_bar() -> void:
	if hp_bar != null:
		hp_bar.set_hp(hp)
