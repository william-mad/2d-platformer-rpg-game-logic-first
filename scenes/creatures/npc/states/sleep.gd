class_name NpcStateSleep extends NpcState

@export var sleep_duration: float = -1.0
@export var sleep_value_name: StringName = &"sleepiness"
@export var sleep_complete_delta: float = -50.0
@export var wake_on_target_seen: bool = true

var sleep_timer: float = 0.0


func enter() -> void:
	super.enter()
	stop_horizontal()
	sleep_timer = sleep_duration

	if sleep_timer < 0.0:
		sleep_timer = machine.default_sleep_time


func physics_process(delta: float) -> NpcState:
	stop_horizontal()

	if sleep_timer <= 0.0:
		return next_state

	sleep_timer -= delta
	if sleep_timer > 0.0:
		return next_state

	if sleep_value_name != &"":
		machine.apply_value_delta({String(sleep_value_name): sleep_complete_delta}, null, false)

	return get_state(&"Idle")


func target_seen(seen_target: Node2D) -> NpcState:
	if not wake_on_target_seen:
		return next_state

	if seen_target.is_in_group("player"):
		return get_state(&"ReactToPlayer")

	return get_state(&"Idle")
