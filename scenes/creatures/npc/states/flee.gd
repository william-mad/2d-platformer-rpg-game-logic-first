class_name NpcStateFlee extends NpcState

@export var flee_duration: float = -1.0
@export var safe_fear_value: float = 35.0
@export var fear_value_name: StringName = &"fear"
@export var keep_fleeing_while_afraid: bool = true

var flee_timer: float = 0.0
var threat: Node2D


func enter() -> void:
	super.enter()
	threat = machine.last_actor if machine.last_actor != null else machine.get_active_target()
	_reset_timer()


func physics_process(delta: float) -> NpcState:
	if threat == null or not is_instance_valid(threat):
		stop_horizontal()
		return get_state(&"Idle")

	move_away_from_position(threat.global_position, machine.run_speed)
	flee_timer -= delta

	if flee_timer > 0.0:
		return next_state

	# Fear is checked only when the flee timer ends, not as a global every-frame rule scan.
	if keep_fleeing_while_afraid and machine.get_value(fear_value_name) > safe_fear_value:
		_reset_timer()
		return next_state

	return get_state(&"Idle")


func _reset_timer() -> void:
	flee_timer = flee_duration

	if flee_timer < 0.0:
		flee_timer = machine.default_flee_time
