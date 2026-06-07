class_name ContinuousDamageArea extends Area2D

@export var damage_per_second: float = 5.0


func _physics_process(delta: float) -> void:
	for body in get_overlapping_bodies():
		if body.has_method("take_damage"):
			body.take_damage(damage_per_second * delta, global_position, self)
