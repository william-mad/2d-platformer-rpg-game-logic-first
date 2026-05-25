class_name ContinuousHealingArea extends Area2D

@export var healing_per_second: float = 5.0


func _physics_process(delta: float) -> void:
	for body in get_overlapping_bodies():
		if body.has_method("heal"):
			body.heal(healing_per_second * delta)
