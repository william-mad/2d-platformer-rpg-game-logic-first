class_name NpcStateRest extends NpcState

@export var rest_target_path: NodePath
@export var rest_duration: float = -1.0
@export var rest_value_name: StringName = &"sleep_need"
@export var rest_complete_delta: float = -15.0

var rest_timer: float = 0.0
var active_rest_target: Node2D


func enter() -> void:
	# Walks to a rest spot first, then starts a short sleep_need relief timer.
	super.enter()

	active_rest_target = _resolve_rest_target()
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

	rest_timer = rest_duration
	if rest_timer < 0.0:
		rest_timer = machine.default_rest_time

	stop_horizontal()


func physics_process(delta: float) -> NpcState:
	# Rest only lowers sleep_need after the timer completes.
	stop_horizontal()

	if active_rest_target != null and not _target_can_be_rested_at(active_rest_target):
		machine.rest_target = null
		active_rest_target = _resolve_rest_target()
		if active_rest_target == null:
			return get_state(&"Idle")

	if active_rest_target != null and not is_close_to(active_rest_target.global_position, machine.stop_distance):
		machine.move_target = active_rest_target
		machine.state_after_move = &"Rest"
		return get_state(&"MoveToTarget")

	if rest_timer <= 0.0:
		return next_state

	rest_timer -= delta
	if rest_timer > 0.0:
		return next_state

	if rest_value_name != &"":
		machine.apply_value_delta({String(rest_value_name): rest_complete_delta}, null, false)

	return get_state(&"Idle")


func _resolve_rest_target() -> Node2D:
	# Target priority: exported path, assigned spot, then closest matching Rest spot.
	if machine == null:
		return null

	if String(rest_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(rest_target_path) as Node2D
		if _target_can_be_rested_at(configured_target):
			return configured_target

	if _target_can_be_rested_at(machine.rest_target):
		return machine.rest_target

	machine.rest_target = null
	var closest_spot := find_closest_need_spot(&"Rest", rest_value_name)
	if closest_spot != null:
		machine.rest_target = closest_spot
		return closest_spot

	return null


func _target_can_be_rested_at(rest_target: Node2D) -> bool:
	if rest_target == null or not is_instance_valid(rest_target):
		return false

	if rest_target.has_method("can_serve_npc_need"):
		return bool(rest_target.call("can_serve_npc_need", npc, &"Rest", rest_value_name))

	return true
