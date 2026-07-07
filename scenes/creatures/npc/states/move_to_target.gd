class_name NpcStateMoveToTarget extends NpcState

@export var target_node_path: NodePath
@export var speed_override: float = 0.0
@export var arrive_state_name: StringName = &"Idle"
@export var target_refresh_seconds: float = 0.12

var tracked_target: Node2D
var cached_target_position: Vector2
var refresh_timer: float = 0.0


func enter() -> void:
	super.enter()
	tracked_target = _resolve_target()
	refresh_timer = 0.0

	if tracked_target != null and is_instance_valid(tracked_target):
		cached_target_position = tracked_target.global_position


func physics_process(delta: float) -> NpcState:
	if tracked_target == null or not is_instance_valid(tracked_target):
		return get_state(machine.consume_state_after_move(arrive_state_name))

	# Refresh the target position on a small interval instead of doing extra target work every frame.
	refresh_timer -= delta
	if refresh_timer <= 0.0:
		cached_target_position = tracked_target.global_position
		refresh_timer = target_refresh_seconds

	var speed := speed_override
	if speed <= 0.0:
		speed = machine.get_effective_walk_speed()

	if move_toward_position(cached_target_position, speed, machine.stop_distance):
		return get_state(machine.consume_state_after_move(arrive_state_name))

	return next_state


func _resolve_target() -> Node2D:
	if machine == null:
		return null

	if String(target_node_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(target_node_path) as Node2D
		if configured_target != null:
			return configured_target

	if machine.move_target != null and is_instance_valid(machine.move_target):
		return machine.move_target

	return machine.get_active_target()
