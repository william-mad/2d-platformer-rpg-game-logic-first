class_name NpcStateDisabledDead extends NpcState

@export var dead_animation_name: StringName = &"dead"
@export var disabled_animation_name: StringName = &"disabled"
@export var revive_priority: int = 1000
@export var queue_free_when_dead: bool = false
@export var queue_free_delay: float = 0.0


func enter() -> void:
	next_state = null
	stop_horizontal()

	if machine.get_value(&"hp", 1.0) <= 0.0:
		play_animation(dead_animation_name)
		_queue_free_if_needed()
	else:
		play_animation(disabled_animation_name)


func physics_process(_delta: float) -> NpcState:
	stop_horizontal()
	return next_state


func can_exit_to(_new_state: NpcState, request_priority: int) -> bool:
	return request_priority >= revive_priority


func _queue_free_if_needed() -> void:
	if not queue_free_when_dead or npc == null:
		return

	if queue_free_delay <= 0.0:
		npc.queue_free()
		return

	await get_tree().create_timer(queue_free_delay).timeout

	if npc != null and is_instance_valid(npc):
		npc.queue_free()
