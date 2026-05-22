extends CharacterBody2D

enum State {
	IDLE,
	PATROL,
	CHASE,
	ATTACK,
	HURT,
	DEAD
}

@export_group("Movement")
@export var move_speed: float = 70.0
@export var chase_speed: float = 120.0
@export var gravity: float = 1200.0
@export var idle_time: float = 1.0

@export_group("Combat")
@export var max_health: int = 3
@export var damage: int = 1
@export var attack_cooldown: float = 1.0
@export var attack_windup: float = 0.25
@export var hurt_time: float = 0.25
@export var knockback_force: Vector2 = Vector2(180, -120)

@export_group("Behavior")
@export var starts_moving_right: bool = true
@export var chase_player: bool = true
@export var stop_at_ledges: bool = true

@onready var sprite: Sprite2D = $Sprite2D
@onready var wall_check: RayCast2D = $WallCheck
@onready var floor_check: RayCast2D = $FloorCheck
@onready var player_detect: Area2D = $PlayerDetect
@onready var attack_area: Area2D = $AttackArea

var state: State = State.PATROL
var direction: int = 1
var health: int
var player: Node2D = null
var can_attack: bool = true
var is_attacking: bool = false


func _ready() -> void:
	health = max_health
	direction = 1 if starts_moving_right else -1

	player_detect.body_entered.connect(_on_player_detect_body_entered)
	player_detect.body_exited.connect(_on_player_detect_body_exited)
	attack_area.body_entered.connect(_on_attack_area_body_entered)

	_update_raycasts()
	_change_state(State.PATROL)


func _physics_process(delta: float) -> void:
	if state == State.DEAD:
		return

	_apply_gravity(delta)

	match state:
		State.IDLE:
			_process_idle()
		State.PATROL:
			_process_patrol()
		State.CHASE:
			_process_chase()
		State.ATTACK:
			_process_attack()
		State.HURT:
			pass

	move_and_slide()


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += gravity * delta
	else:
		if velocity.y > 0:
			velocity.y = 0


func _process_idle() -> void:
	velocity.x = move_toward(velocity.x, 0.0, move_speed)

	if player and chase_player:
		_change_state(State.CHASE)


func _process_patrol() -> void:
	if player and chase_player:
		_change_state(State.CHASE)
		return

	velocity.x = direction * move_speed

	if _should_turn_around():
		_turn_around()


func _process_chase() -> void:
	if not player:
		_change_state(State.PATROL)
		return

	var to_player := player.global_position.x - global_position.x
	direction = sign(to_player) as int

	if direction == 0:
		direction = 1

	_update_raycasts()

	if _player_in_attack_range():
		_change_state(State.ATTACK)
		return

	if stop_at_ledges and not floor_check.is_colliding():
		velocity.x = 0
	else:
		velocity.x = direction * chase_speed


func _process_attack() -> void:
	velocity.x = 0


func _should_turn_around() -> bool:
	var hit_wall := wall_check.is_colliding()
	var no_floor_ahead := stop_at_ledges and not floor_check.is_colliding()
	return hit_wall or no_floor_ahead


func _turn_around() -> void:
	direction *= -1
	_update_raycasts()


func _update_raycasts() -> void:
	wall_check.target_position.x = abs(wall_check.target_position.x) * direction
	floor_check.position.x = abs(floor_check.position.x) * direction

	if sprite:
		sprite.flip_h = direction < 0


func _player_in_attack_range() -> bool:
	if not player:
		return false

	var bodies := attack_area.get_overlapping_bodies()
	return bodies.has(player)


func _change_state(new_state: State) -> void:
	if state == State.DEAD:
		return

	state = new_state

	match state:
		State.IDLE:
			velocity.x = 0
			_start_idle_timer()

		State.PATROL:
			is_attacking = false

		State.CHASE:
			is_attacking = false

		State.ATTACK:
			_start_attack()

		State.HURT:
			is_attacking = false
			_start_hurt_timer()

		State.DEAD:
			_die()


func _start_idle_timer() -> void:
	await get_tree().create_timer(idle_time).timeout

	if state == State.IDLE:
		_change_state(State.PATROL)


func _start_attack() -> void:
	if is_attacking or not can_attack:
		_change_state(State.CHASE)
		return

	is_attacking = true
	can_attack = false
	velocity.x = 0

	await get_tree().create_timer(attack_windup).timeout

	if state == State.ATTACK and player and _player_in_attack_range():
		_damage_player(player)

	await get_tree().create_timer(attack_cooldown).timeout

	can_attack = true
	is_attacking = false

	if state == State.ATTACK:
		if player:
			_change_state(State.CHASE)
		else:
			_change_state(State.PATROL)

func _damage_player(target: Node) -> void:
	if target.has_method("take_damage"):
		target.take_damage(damage, global_position)
	elif target.has_method("damage"):
		target.damage(damage)


func take_damage(amount: int, damage_source_position: Vector2 = Vector2.ZERO) -> void:
	if state == State.DEAD:
		return

	health -= amount

	if health <= 0:
		_change_state(State.DEAD)
		return

	var knockback_direction: int = int(sign(global_position.x - damage_source_position.x))
	if knockback_direction == 0:
		knockback_direction = -direction

	velocity = Vector2(knockback_force.x * knockback_direction, knockback_force.y)
	_change_state(State.HURT)


func _start_hurt_timer() -> void:
	await get_tree().create_timer(hurt_time).timeout

	if state == State.HURT:
		if player and chase_player:
			_change_state(State.CHASE)
		else:
			_change_state(State.PATROL)


func _die() -> void:
	velocity = Vector2.ZERO
	set_physics_process(false)
	queue_free()



func _on_player_detect_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player = body

		if chase_player and state not in [State.ATTACK, State.HURT, State.DEAD]:
			_change_state(State.CHASE)


func _on_player_detect_body_exited(body: Node2D) -> void:
	if body == player:
		player = null

		if state not in [State.ATTACK, State.HURT, State.DEAD]:
			_change_state(State.PATROL)


func _on_attack_area_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player = body

		if can_attack and state not in [State.ATTACK, State.HURT, State.DEAD]:
			_change_state(State.ATTACK)
