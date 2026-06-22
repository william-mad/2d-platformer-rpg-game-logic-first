class_name NpcState extends Node

# Set this on each state node to match an AnimationPlayer animation name.
# Later, add animations like idle, walk, work, talk, run, sleep, disabled, and dead.
@export var animation_name: StringName = &""
@export var stop_horizontal_on_enter: bool = false
@export var allows_scheduled_activity_interrupt: bool = false

# The state machine assigns these when it initializes child state nodes.
var npc: CharacterBody2D
var machine: NpcStateMachine
var next_state: NpcState


func init() -> void:
	pass


func enter() -> void:
	next_state = null

	if stop_horizontal_on_enter:
		stop_horizontal()

	# This is the shared animation hook for every NPC state.
	if animation_name != &"":
		play_animation(animation_name)


func exit() -> void:
	pass


func target_seen(_target: Node2D) -> NpcState:
	# Override this in a state if seeing a target should immediately change state.
	return next_state


func target_lost(_target: Node2D) -> NpcState:
	return next_state


func values_changed(
	_values: Dictionary,
	_changed_values: Dictionary,
	_actor: Node2D
) -> NpcState:
	# Override this only when a state needs custom handling for value changes.
	return next_state


func physics_process(_delta: float) -> NpcState:
	# Active-state movement/timers live here; global value rules are not checked every frame.
	return next_state


func can_exit_to(_new_state: NpcState, _request_priority: int) -> bool:
	return true


func can_be_interrupted_by_scheduled_activity(_request_priority: int) -> bool:
	return allows_scheduled_activity_interrupt


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


func find_closest_need_spot(
	requested_state_name: StringName,
	requested_value_name: StringName = &""
) -> Node2D:
	# Finds the closest scene spot that says it can serve this NPC and this need.
	if npc == null or not npc.is_inside_tree():
		return null

	var closest_spot: Node2D = null
	var closest_distance := INF

	for candidate in npc.get_tree().get_nodes_in_group("npc_need_spot"):
		var spot := candidate as Node2D
		if spot == null or not is_instance_valid(spot):
			continue

		if not spot.has_method("can_serve_npc_need"):
			continue

		if not bool(spot.call(
			"can_serve_npc_need",
			npc,
			requested_state_name,
			requested_value_name
		)):
			continue

		var distance := npc.global_position.distance_to(spot.global_position)
		if distance >= closest_distance:
			continue

		closest_distance = distance
		closest_spot = spot

	return closest_spot


func find_weighted_casual_spot(
	requested_state_name: StringName,
	rng: RandomNumberGenerator
) -> Node2D:
	# Casual spots have no need values; preference only weights valid destinations.
	if npc == null or not npc.is_inside_tree() or rng == null:
		return null

	var candidates: Array[Node2D] = []
	var weights: Array[float] = []
	var total_weight := 0.0
	for candidate in npc.get_tree().get_nodes_in_group("npc_casual_spot"):
		var spot := candidate as Node2D
		if spot == null or not is_instance_valid(spot):
			continue
		if not spot.has_method("can_serve_npc_casual_activity"):
			continue
		if not bool(spot.call(
			"can_serve_npc_casual_activity",
			npc,
			requested_state_name
		)):
			continue

		var weight := 1.0
		if spot.has_method("get_npc_preference_weight"):
			weight = maxf(float(spot.call("get_npc_preference_weight", npc)), 0.0)
		if weight <= 0.0:
			continue

		candidates.append(spot)
		weights.append(weight)
		total_weight += weight

	if candidates.is_empty() or total_weight <= 0.0:
		return null

	var roll := rng.randf_range(0.0, total_weight)
	for index in candidates.size():
		roll -= weights[index]
		if roll <= 0.0:
			return candidates[index]

	return candidates.back()


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
