extends CharacterBody2D


@export var gravity: float = 1200.0
@export var friction: float = 900.0

@onready var sprite_2d: Sprite2D = %Sprite2D
@onready var rope_attach_point: Marker2D = %RopeAttachPoint


var direction : Vector2 = Vector2.ZERO



func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += gravity * delta

	velocity.x = move_toward(velocity.x, 0.0, friction * delta)

	move_and_slide()
	
	
func update_direction()->void:
	
	var previous_direction: Vector2 = direction
	

	
	if previous_direction.x != direction.x:

		if direction.x < 0:
			sprite_2d.flip_h = true
		elif direction.x > 0:
			sprite_2d.flip_h = false
			
	pass
	
func get_rope_attach_point() -> Node2D:
	return rope_attach_point
