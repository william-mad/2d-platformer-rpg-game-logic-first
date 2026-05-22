class_name Zenith extends CharacterBody2D


@export var gravity: float = 1200.0
@export var friction: float = 900.0
@export var rope_anchor_strength: float = 1.0
@export var rope_weight: float = 0.1
@export var move_speed: float = 400

@onready var sprite_2d: Sprite2D = %Sprite2D
@onready var rope_attach_point: Marker2D = %RopeAttachPoint


@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var damage_area: Damage_Area = $Damage_Area


var dir : float = 1.0
var move_tween : Tween

func _ready() -> void:
	animation_player.play("walk")
	pass

func _physics_process(delta: float) -> void:
	if is_on_wall():
		update_direction(-dir)
	velocity += get_gravity() * delta
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
