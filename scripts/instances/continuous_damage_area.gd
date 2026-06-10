class_name ContinuousDamageArea extends Area2D

@export var damage_per_second: float = 5.0
@export var damage_tick_seconds: float = 0.25

var damage_tick_elapsed: float = 0.0


func _physics_process(delta: float) -> void:
	damage_tick_elapsed += delta
	var tick_seconds := maxf(damage_tick_seconds, 0.0)
	if tick_seconds > 0.0 and damage_tick_elapsed < tick_seconds:
		return

	var damage_delta := damage_tick_elapsed
	damage_tick_elapsed = 0.0

	for body in get_overlapping_bodies():
		if body.has_method("take_damage"):
			body.take_damage(damage_per_second * damage_delta, global_position, self)
