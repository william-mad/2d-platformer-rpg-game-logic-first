class_name NpcStateEat extends NpcState

@export var eat_target_path: NodePath
@export var eat_duration: float = -1.0
@export var eat_value_name: StringName = &"hunger"
@export var hunger_drop_per_full_eat: float = 100.0

var eat_timer: float = 0.0
var total_eat_seconds: float = 0.0
var active_eat_target: Node2D


func enter() -> void:
	# Walks to a configured/nearby eat spot first, then starts the eating timer.
	super.enter()

	active_eat_target = _resolve_eat_target()
	if active_eat_target == null:
		eat_timer = 0.0
		machine.call_deferred("request_state", &"Idle", null, "missing_eat_spot", 20)
		return
	if active_eat_target != null and not is_close_to(active_eat_target.global_position, machine.stop_distance):
		machine.move_target = active_eat_target
		machine.state_after_move = &"Eat"
		machine.call_deferred(
			"request_state",
			&"MoveToTarget",
			active_eat_target,
			"walk_to_eat",
			20
		)
		return

	eat_timer = eat_duration
	if eat_timer < 0.0:
		eat_timer = _get_full_eat_seconds(active_eat_target)

	total_eat_seconds = maxf(eat_timer, 0.001)
	stop_horizontal()


func physics_process(delta: float) -> NpcState:
	# Hunger drains gradually while the NPC stays at the eat spot.
	stop_horizontal()
	if active_eat_target == null or not is_instance_valid(active_eat_target):
		active_eat_target = _resolve_eat_target()
		if active_eat_target == null:
			return get_state(&"Idle")

	if active_eat_target != null and not _target_can_be_eaten_at(active_eat_target):
		machine.eat_target = null
		active_eat_target = _resolve_eat_target()
		if active_eat_target == null:
			return get_state(&"Idle")

	if active_eat_target != null and not is_close_to(active_eat_target.global_position, machine.stop_distance):
		machine.move_target = active_eat_target
		machine.state_after_move = &"Eat"
		return get_state(&"MoveToTarget")

	if eat_timer <= 0.0:
		return get_state(&"Idle")

	eat_timer -= delta
	_apply_eat_progress(delta)

	if _hunger_is_sated() or eat_timer <= 0.0:
		return get_state(&"Idle")

	return next_state


func _resolve_eat_target() -> Node2D:
	# Target priority: exported path, assigned spot, then closest matching Eat spot.
	if machine == null:
		return null

	if String(eat_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(eat_target_path) as Node2D
		if _target_can_be_eaten_at(configured_target):
			return configured_target

	if _target_can_be_eaten_at(machine.eat_target):
		return machine.eat_target

	machine.eat_target = null
	var closest_spot := find_closest_need_spot(&"Eat", eat_value_name)
	if closest_spot != null:
		machine.eat_target = closest_spot
		return closest_spot

	return null


func _target_can_be_eaten_at(eat_target: Node2D) -> bool:
	if eat_target == null or not is_instance_valid(eat_target):
		return false

	if eat_target.has_method("can_serve_npc_need"):
		return bool(eat_target.call("can_serve_npc_need", npc, &"Eat", eat_value_name))

	return true


func _apply_eat_progress(delta: float) -> void:
	if eat_value_name == &"":
		return

	var requested_progress_fraction := maxf(delta / total_eat_seconds, 0.0)
	var actual_progress_fraction := requested_progress_fraction
	if active_eat_target != null and active_eat_target.has_method("consume_eat_progress"):
		actual_progress_fraction = clampf(
			float(active_eat_target.call("consume_eat_progress", requested_progress_fraction)),
			0.0,
			requested_progress_fraction
		)

	var hunger_delta := -absf(hunger_drop_per_full_eat) * actual_progress_fraction
	if is_equal_approx(hunger_delta, 0.0):
		return

	machine.apply_value_delta({String(eat_value_name): hunger_delta}, null, false)


func _hunger_is_sated() -> bool:
	if eat_value_name == &"":
		return eat_timer <= 0.0

	return machine.get_value(eat_value_name) <= 0.0


func _get_full_eat_seconds(eat_target: Node2D) -> float:
	# Prefer the selected spot's hunger rate, then fall back to the NPC-wide meal duration.
	var game_minutes := machine.default_eat_game_minutes
	if eat_target != null and eat_target.has_method("get_full_eat_game_hours"):
		var spot_game_hours := float(eat_target.call(
			"get_full_eat_game_hours",
			hunger_drop_per_full_eat
		))
		if spot_game_hours > 0.0:
			game_minutes = spot_game_hours * 60.0

	return machine.get_real_seconds_for_game_minutes(
		game_minutes,
		machine.default_eat_time
	)
