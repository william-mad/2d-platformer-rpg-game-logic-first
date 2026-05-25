class_name Zenith extends CharacterBody2D


@export var gravity: float = 1200.0
@export var friction: float = 900.0
@export var rope_anchor_strength: float = 1.0
@export var rope_weight: float = 0.1
@export var move_speed: float = 400
@export var max_hp: float = 3.0
@export var knockback_force: Vector2 = Vector2(180, -120)
@export var knockback_time: float = 0.15

@onready var sprite_2d: Sprite2D = %Sprite2D
@onready var rope_attach_point: Marker2D = %RopeAttachPoint


@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var damage_area: Damage_Area = $Damage_Area
@onready var hp_bar: CreatureHpBar = get_node_or_null("HPBar") as CreatureHpBar


var dir : float = 1.0
var move_tween : Tween
var hp: float = 0.0
var knockback_timer: float = 0.0

func _ready() -> void:
	hp = max_hp
	setup_hp_bar()
	animation_player.play("walk")
	pass

func _physics_process(delta: float) -> void:
	if is_on_wall():
		update_direction(-dir)
	velocity += get_gravity() * delta

	if knockback_timer > 0.0:
		knockback_timer -= delta
		move_and_slide()
		return

	velocity.x = dir * move_speed

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


func take_damage(amount: float, damage_source_position: Vector2 = Vector2.ZERO) -> void:
	hp = maxf(hp - amount, 0.0)
	update_hp_bar()
	print(name, " hp: ", hp, "/", max_hp)

	if hp <= 0.0:
		die()
		return

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
