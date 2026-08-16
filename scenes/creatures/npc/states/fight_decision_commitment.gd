class_name NpcFightDecisionCommitment extends RefCounted

enum MovementMode {
	CHASE,
	HOLD,
	CLOSE_FOR_SCREAM,
}

var decision_seconds: float = 0.15
var facing_seconds: float = 0.12
var facing_deadzone: float = 12.0

var movement_mode: MovementMode = MovementMode.CHASE
var attack_mode: int = 0
var melee_reach: float = 0.0
var move_speed: float = 0.0

var _decision_timer: float = 0.0
var _facing_timer: float = 0.0
var _facing_direction: float = 0.0
var _target_reference: WeakRef


func configure(
	new_decision_seconds: float,
	new_facing_seconds: float,
	new_facing_deadzone: float
) -> void:
	decision_seconds = maxf(new_decision_seconds, 0.01)
	facing_seconds = maxf(new_facing_seconds, 0.0)
	facing_deadzone = maxf(new_facing_deadzone, 0.0)


func reset() -> void:
	movement_mode = MovementMode.CHASE
	attack_mode = 0
	melee_reach = 0.0
	move_speed = 0.0
	_decision_timer = 0.0
	_facing_timer = 0.0
	_facing_direction = 0.0
	_target_reference = null


func advance(delta: float) -> void:
	_decision_timer = maxf(_decision_timer - maxf(delta, 0.0), 0.0)
	_facing_timer = maxf(_facing_timer - maxf(delta, 0.0), 0.0)


func needs_decision(target: Node) -> bool:
	if _decision_timer <= 0.0:
		return true
	if _target_reference == null:
		return target != null
	return _target_reference.get_ref() != target


func commit_decision(
	target: Node,
	new_movement_mode: MovementMode,
	new_attack_mode: int,
	new_melee_reach: float,
	new_move_speed: float
) -> void:
	movement_mode = new_movement_mode
	attack_mode = new_attack_mode
	melee_reach = maxf(new_melee_reach, 0.0)
	move_speed = maxf(new_move_speed, 0.0)
	_decision_timer = decision_seconds
	_target_reference = (
		weakref(target)
		if target != null and is_instance_valid(target)
		else null
	)


func commit_facing(
	raw_direction: float,
	horizontal_distance: float,
	force: bool = false
) -> float:
	var requested_direction := signf(raw_direction)
	if requested_direction == 0.0:
		return _facing_direction if _facing_direction != 0.0 else 1.0
	if force or _facing_direction == 0.0:
		_set_facing_direction(requested_direction)
	elif (
		requested_direction != _facing_direction
		and _facing_timer <= 0.0
		and absf(horizontal_distance) > facing_deadzone
	):
		_set_facing_direction(requested_direction)
	return _facing_direction


func get_facing_direction(fallback: float = 1.0) -> float:
	return _facing_direction if _facing_direction != 0.0 else signf(fallback)


func _set_facing_direction(direction: float) -> void:
	_facing_direction = signf(direction)
	_facing_timer = facing_seconds
