class_name Zenith extends CharacterBody2D


@export var gravity: float = 1200.0
@export var rope_weight: float = 0.1
@export var move_speed: float = 400
@export var max_hp: float = 3.0
@export_range(1.0, 100.0, 0.1, "suffix:hp/day") var passive_healing_per_game_day: float = 10.0
@export var knockback_force: Vector2 = Vector2(180, -120)
@export var knockback_time: float = 0.15
@export_group("Knockout")
@export var max_knockout: float = 100.0
@export var knockout_decay_per_second: float = 55.0
@export var downed_decay_per_second: float = 32.0

@onready var sprite_2d: Sprite2D = %Sprite2D
@onready var rope_attach_point: Marker2D = %RopeAttachPoint


@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var damage_area: Damage_Area = $Damage_Area
@onready var hp_bar: CreatureHpBar = get_node_or_null("HPBar") as CreatureHpBar
@onready var knockout_bar: ProgressBar = get_node_or_null("KnockoutBar") as ProgressBar


var dir : float = 1.0
var move_tween : Tween
var hp: float = 0.0
var knockback_timer: float = 0.0
var knockout_amount: float = 0.0
var knockout_bar_active: bool = false
var is_downed: bool = false

func _ready() -> void:
	hp = max_hp
	setup_hp_bar()
	setup_knockout_bar()
	animation_player.play("walk")
	pass

func _physics_process(delta: float) -> void:
	if is_on_wall():
		update_direction(-dir)
	velocity += get_gravity() * delta
	var velocity_after_gravity := velocity
	process_knockout(delta)
	process_passive_healing(delta)

	if is_downed:
		velocity.x = 0.0
		_move_and_slide_with_rope(delta, velocity_after_gravity)
		return

	if knockback_timer > 0.0:
		knockback_timer -= delta
		_move_and_slide_with_rope(delta, velocity_after_gravity)
		return

	velocity.x = dir * move_speed

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
	
	
func update_direction(new_dir : float)->void:
	dir = new_dir
	if dir < 0:
		sprite_2d.flip_h = true
	elif dir > 0:
		sprite_2d.flip_h = false
			
	pass
	
func get_rope_attach_point() -> Node2D:
	return rope_attach_point


func get_rope_weight() -> float:
	return rope_weight


func is_rope_immovable() -> bool:
	return false


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
	if not is_downed:
		apply_knockback(damage_source_position)


func die() -> void:
	queue_free()


func apply_knockback(damage_source_position: Vector2) -> void:
	var knockback_direction := signf(global_position.x - damage_source_position.x)
	if knockback_direction == 0.0:
		knockback_direction = -dir

	velocity = Vector2(knockback_force.x * knockback_direction, knockback_force.y)
	knockback_timer = knockback_time


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
		is_downed = true
		knockback_timer = 0.0
		velocity.x = 0.0
	update_knockout_bar()


func process_knockout(delta: float) -> void:
	if not knockout_bar_active:
		return

	var decay_rate := downed_decay_per_second if is_downed else knockout_decay_per_second
	knockout_amount = move_toward(knockout_amount, 0.0, maxf(decay_rate, 0.0) * maxf(delta, 0.0))
	if knockout_amount <= 0.0:
		knockout_bar_active = false
		is_downed = false

	update_knockout_bar()
