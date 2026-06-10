class_name ContinuousHealingArea extends Area2D

@export var healing_per_second: float = 5.0
@export var healing_tick_seconds: float = 0.25

var healing_tick_elapsed: float = 0.0


func _physics_process(delta: float) -> void:
	healing_tick_elapsed += delta
	var tick_seconds := maxf(healing_tick_seconds, 0.0)
	if tick_seconds > 0.0 and healing_tick_elapsed < tick_seconds:
		return

	var healing_delta := healing_tick_elapsed
	healing_tick_elapsed = 0.0

	for body in get_overlapping_bodies():
		if body.has_method("heal"):
			body.heal(healing_per_second * healing_delta)
