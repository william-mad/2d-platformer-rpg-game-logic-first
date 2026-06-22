class_name NpcStateRest extends NpcState

@export var rest_target_path: NodePath
@export var rest_value_name: StringName = &"tired"
@export_range(0.0, 100.0, 0.1) var tired_floor: float = 40.0
@export_range(0.0, 1.0, 0.01) var rest_in_place_chance: float = 0.4

var active_rest_target: Node2D
var resting_in_place: bool = false
var choice_rng := RandomNumberGenerator.new()


func init() -> void:
	choice_rng.randomize()


func enter() -> void:
	# Chooses an assigned/preferred rest spot or occasionally rests where the NPC stands.
	super.enter()

	active_rest_target = _resolve_rest_target()
	resting_in_place = active_rest_target == null
	if active_rest_target != null and not is_close_to(active_rest_target.global_position, machine.stop_distance):
		machine.move_target = active_rest_target
		machine.state_after_move = &"Rest"
		machine.call_deferred(
			"request_state",
			&"MoveToTarget",
			active_rest_target,
			"walk_to_rest",
			20
		)
		return

	stop_horizontal()


func physics_process(_delta: float) -> NpcState:
	# The state machine's 10-second fatigue tick lowers tired while this state remains active.
	stop_horizontal()

	if active_rest_target != null and not _target_can_be_rested_at(active_rest_target):
		machine.rest_target = null
		active_rest_target = _resolve_rest_target()
		resting_in_place = active_rest_target == null

	if active_rest_target != null and not is_close_to(active_rest_target.global_position, machine.stop_distance):
		machine.move_target = active_rest_target
		machine.state_after_move = &"Rest"
		return get_state(&"MoveToTarget")

	if rest_value_name == &"" or machine.get_value(rest_value_name) <= tired_floor:
		machine.rest_target = null
		return get_state(&"Idle")

	return next_state


func is_resting_in_place() -> bool:
	return resting_in_place and active_rest_target == null


func get_tired_floor() -> float:
	return tired_floor


func _resolve_rest_target() -> Node2D:
	# Explicit assignments win; otherwise the NPC rolls in-place rest before weighted spot choice.
	if machine == null:
		return null

	if String(rest_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(rest_target_path) as Node2D
		if _target_can_be_rested_at(configured_target):
			return configured_target

	if _target_can_be_rested_at(machine.rest_target):
		return machine.rest_target

	machine.rest_target = null
	if choice_rng.randf() < clampf(rest_in_place_chance, 0.0, 1.0):
		return null

	var preferred_spot := find_weighted_casual_spot(&"Rest", choice_rng)
	if preferred_spot != null:
		machine.rest_target = preferred_spot
		return preferred_spot

	return null


func _target_can_be_rested_at(rest_target: Node2D) -> bool:
	if rest_target == null or not is_instance_valid(rest_target):
		return false

	if rest_target.has_method("can_serve_npc_casual_activity"):
		return bool(rest_target.call("can_serve_npc_casual_activity", npc, &"Rest"))

	return true
