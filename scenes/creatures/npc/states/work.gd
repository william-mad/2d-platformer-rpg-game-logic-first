class_name NpcStateWork extends NpcState

@export var work_target_path: NodePath
@export var work_duration: float = -1.0
@export var work_value_name: StringName = &"work_need"
@export var work_complete_delta: float = -25.0

var work_timer: float = 0.0


func enter() -> void:
	super.enter()

	var configured_target := _resolve_work_target()
	if configured_target != null and not is_close_to(configured_target.global_position, machine.stop_distance):
		machine.move_target = configured_target
		machine.state_after_move = &"Work"
		machine.call_deferred("request_state", &"MoveToTarget", configured_target, "walk_to_work", 20)
		return

	work_timer = work_duration
	if work_timer < 0.0:
		work_timer = machine.default_work_time

	stop_horizontal()


func physics_process(delta: float) -> NpcState:
	stop_horizontal()

	if work_timer <= 0.0:
		return next_state

	work_timer -= delta
	if work_timer > 0.0:
		return next_state

	if work_value_name != &"":
		machine.apply_value_delta({String(work_value_name): work_complete_delta}, null, false)

	return get_state(&"Idle")


func _resolve_work_target() -> Node2D:
	if machine == null:
		return null

	if String(work_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(work_target_path) as Node2D
		if configured_target != null:
			return configured_target

	if machine.work_target != null and is_instance_valid(machine.work_target):
		return machine.work_target

	return null
