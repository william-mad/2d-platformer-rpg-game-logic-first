class_name NpcState extends Node

@export var animation_name: StringName = &""
@export var stop_horizontal_on_enter: bool = false

var npc: CharacterBody2D
var machine: NpcStateMachine
var next_state: NpcState


func init() -> void:
	pass


func enter() -> void:
	next_state = null

	if stop_horizontal_on_enter:
		stop_horizontal()

	if animation_name != &"":
		play_animation(animation_name)


func exit() -> void:
	pass


func target_seen(_target: Node2D) -> NpcState:
	return next_state


func target_lost(_target: Node2D) -> NpcState:
	return next_state


func values_changed(
	_values: Dictionary,
	_changed_values: Dictionary,
	_actor: Node2D
) -> NpcState:
	return next_state


func physics_process(_delta: float) -> NpcState:
	return next_state


func can_exit_to(_new_state: NpcState, _request_priority: int) -> bool:
	return true


func get_state(state_name: StringName) -> NpcState:
	if machine == null:
		return null

	return machine.get_state(state_name)


func get_active_target() -> Node2D:
	if machine == null:
		return null

	return machine.get_active_target()


func stop_horizontal() -> void:
	if npc != null:
		npc.velocity.x = 0.0


func play_animation(state_animation_name: StringName) -> void:
	if machine != null:
		machine.play_animation(state_animation_name)


func face_x_direction(x_direction: float) -> void:
	if machine != null:
		machine.face_x_direction(x_direction)


func is_valid_target(target: Node2D) -> bool:
	return target != null and is_instance_valid(target)


func is_close_to(target_position: Vector2, stop_distance: float) -> bool:
	if npc == null:
		return true

	return absf(target_position.x - npc.global_position.x) <= stop_distance


func move_toward_position(
	target_position: Vector2,
	speed: float,
	stop_distance: float
) -> bool:
	if npc == null:
		return true

	var x_distance := target_position.x - npc.global_position.x

	if absf(x_distance) <= stop_distance:
		npc.velocity.x = 0.0
		return true

	var move_direction := signf(x_distance)
	face_x_direction(move_direction)
	npc.velocity.x = move_direction * speed
	return false


func move_away_from_position(
	threat_position: Vector2,
	speed: float
) -> void:
	if npc == null:
		return

	var x_distance := npc.global_position.x - threat_position.x
	var move_direction := signf(x_distance)

	if move_direction == 0.0:
		move_direction = 1.0

	face_x_direction(move_direction)
	npc.velocity.x = move_direction * speed
