extends CharacterBody2D

enum State {
	IDLE,
	PATROL,
	CHASE,
	ATTACK,
	HURT,
	DOWNED,
	DEAD
}

@export_group("Movement")
@export var move_speed: float = 70.0
@export var chase_speed: float = 120.0
@export var gravity: float = 1200.0
@export var idle_time: float = 1.0

@export_group("Combat")
@export var max_hp: float = 100.0
@export_range(1.0, 100.0, 0.1, "suffix:hp/day") var passive_healing_per_game_day: float = 10.0
@export var damage: int = 1
@export var attack_cooldown: float = 1.0
@export var attack_windup: float = 0.25
@export var hurt_time: float = 0.25
@export var knockback_force: Vector2 = Vector2(180, -120)
@export var attack_knockout_damage: float = 0.0
@export_group("Knockout")
@export var max_knockout: float = 100.0
@export var knockout_decay_per_second: float = 55.0
@export var downed_decay_per_second: float = 32.0

@export_group("Behavior")
@export var starts_moving_right: bool = true
@export var chase_player: bool = true
@export var stop_at_ledges: bool = true

@onready var sprite_2d: Sprite2D = %Sprite2D
@onready var wall_check: RayCast2D = $WallCheck
@onready var floor_check: RayCast2D = $FloorCheck
@onready var player_detect: Area2D = $PlayerDetect
@onready var attack_area: Area2D = $AttackArea
@onready var attack_area_collision: CollisionShape2D = $AttackArea/CollisionShape2D
@onready var hp_bar: CreatureHpBar = get_node_or_null("HPBar") as CreatureHpBar
@onready var knockout_bar: ProgressBar = get_node_or_null("KnockoutBar") as ProgressBar

@export_group("Rope")
@export var rope_weight: float = 0.1
@onready var rope_attach_point: Marker2D = %RopeAttachPoint


var state: State = State.PATROL
var direction: int = 1
var hp: float
var player: Node2D = null
var can_attack: bool = true
var is_attacking: bool = false
var knockout_amount: float = 0.0
var knockout_bar_active: bool = false


func _ready() -> void:
	hp = max_hp
	setup_hp_bar()
	setup_knockout_bar()
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
	process_knockout(delta)
	process_passive_healing(delta)

	if state == State.DOWNED:
		velocity.x = 0.0
		_move_and_slide_with_rope(delta)
		return

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
		State.DOWNED:
			velocity.x = 0.0

	_move_and_slide_with_rope(delta)


func _move_and_slide_with_rope(delta: float) -> void:
	velocity = Rope.constrain_attached_velocity(self, velocity, delta)
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
	attack_area_collision.position.x = abs(attack_area_collision.position.x) * direction

	
	sprite_2d.flip_h = direction < 0


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

		State.DOWNED:
			is_attacking = false
			velocity.x = 0.0

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
		target.take_damage(damage, global_position, self, attack_knockout_damage)
	elif target.has_method("damage"):
		target.damage(damage)
		DamageEvents.emit_damage_dealt(damage, self, target)


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	knockout_damage: float = 0.0
) -> void:
	if state == State.DEAD:
		return

	var previous_hp := hp
	hp = maxf(hp - amount, 0.0)
	var damage_taken := previous_hp - hp
	DamageEvents.emit_damage_dealt(damage_taken, damage_source, self)
	update_hp_bar()
	print(name, " hp: ", hp, "/", max_hp)

	if hp <= 0.0:
		_change_state(State.DEAD)
		return

	apply_knockout(knockout_damage)
	if state == State.DOWNED:
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

		if chase_player and state not in [State.ATTACK, State.HURT, State.DOWNED, State.DEAD]:
			_change_state(State.CHASE)


func _on_player_detect_body_exited(body: Node2D) -> void:
	if body == player:
		player = null

		if state not in [State.ATTACK, State.HURT, State.DOWNED, State.DEAD]:
			_change_state(State.PATROL)


func _on_attack_area_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player = body

		if can_attack and state not in [State.ATTACK, State.HURT, State.DOWNED, State.DEAD]:
			_change_state(State.ATTACK)



func get_rope_attach_point() -> Node2D:
	return rope_attach_point


func setup_hp_bar() -> void:
	if hp_bar != null:
		hp_bar.setup_hp(max_hp, hp)


func update_hp_bar() -> void:
	if hp_bar != null:
		hp_bar.set_hp(hp)


func heal(amount: float) -> void:
	if amount <= 0.0 or hp <= 0.0 or state == State.DEAD:
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
		_change_state(State.DOWNED)
	update_knockout_bar()


func process_knockout(delta: float) -> void:
	if not knockout_bar_active:
		return

	var decay_rate := downed_decay_per_second if state == State.DOWNED else knockout_decay_per_second
	knockout_amount = move_toward(knockout_amount, 0.0, maxf(decay_rate, 0.0) * maxf(delta, 0.0))
	if knockout_amount <= 0.0:
		knockout_bar_active = false
		if state == State.DOWNED:
			if player and chase_player:
				_change_state(State.CHASE)
			else:
				_change_state(State.PATROL)

	update_knockout_bar()
