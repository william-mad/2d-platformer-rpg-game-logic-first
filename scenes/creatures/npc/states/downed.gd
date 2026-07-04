class_name NpcStateDowned extends NpcState

@export var knockout_value_name: StringName = &"knockout"
@export var recovery_state_name: StringName = &"Idle"
@export var revive_priority: int = 1000


func enter() -> void:
	next_state = null
	super.enter()
	stop_horizontal()


func physics_process(_delta: float) -> NpcState:
	stop_horizontal()

	if machine.get_value(knockout_value_name, 0.0) > 0.0:
		return next_state

	return get_state(recovery_state_name)


func can_exit_to(new_state: NpcState, request_priority: int) -> bool:
	if new_state != null and String(new_state.name) == "DisabledDead":
		return true
	if request_priority >= revive_priority:
		return true

	return machine.get_value(knockout_value_name, 0.0) <= 0.0
