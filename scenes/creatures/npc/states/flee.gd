class_name NpcStateFlee extends NpcState

@export var flee_duration: float = -1.0
@export var safe_distance_from_threat: float = 280.0
@export var stop_when_safe_distance_reached: bool = true
@export var minimum_interrupt_priority: int = 95

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

	flee_timer -= delta
	if flee_timer <= 0.0 or _safe_distance_reached():
		stop_horizontal()
		return get_state(&"Idle")

	move_away_from_position(threat.global_position, machine.run_speed)
	return next_state


func can_exit_to(new_state: NpcState, request_priority: int) -> bool:
	# Event reactions should not interrupt an active flee burst; death/collapse still can.
	if new_state != null and String(new_state.name) == "Idle":
		return true

	return request_priority >= minimum_interrupt_priority


func _reset_timer() -> void:
	flee_timer = flee_duration

	if flee_timer < 0.0:
		flee_timer = machine.default_flee_time


func _safe_distance_reached() -> bool:
	if not stop_when_safe_distance_reached:
		return false

	if npc == null:
		return true

	return npc.global_position.distance_to(threat.global_position) >= safe_distance_from_threat
