class_name NpcStateSleep extends NpcState

@export var sleep_target_path: NodePath
@export var sleep_duration: float = -1.0
@export var sleep_value_name: StringName = &"sleep_need"
@export var sleep_need_drop_per_full_sleep: float = 100.0
@export var sleep_progress_tick_seconds: float = 1.0
@export var wake_on_target_seen: bool = true

var sleep_timer: float = 0.0
var total_sleep_seconds: float = 0.0
var sleep_progress_elapsed: float = 0.0
var active_sleep_target: Node2D


func enter() -> void:
	# Walks to a sleep spot first, then starts the long sleep timer.
	super.enter()

	active_sleep_target = _resolve_sleep_target()
	if active_sleep_target != null and not is_close_to(active_sleep_target.global_position, machine.stop_distance):
		machine.move_target = active_sleep_target
		machine.state_after_move = &"Sleep"
		machine.call_deferred(
			"request_state",
			&"MoveToTarget",
			active_sleep_target,
			"walk_to_sleep",
			20
		)
		return

	stop_horizontal()
	sleep_timer = sleep_duration
	sleep_progress_elapsed = 0.0

	if sleep_timer < 0.0:
		sleep_timer = machine.get_real_seconds_for_game_hours(
			machine.default_sleep_game_hours,
			machine.default_sleep_time
		)

	total_sleep_seconds = maxf(sleep_timer, 0.001)


func physics_process(delta: float) -> NpcState:
	# Sleep need drains gradually while the NPC stays asleep at the sleep spot.
	stop_horizontal()

	if active_sleep_target != null and not _target_can_be_slept_at(active_sleep_target):
		machine.sleep_target = null
		active_sleep_target = _resolve_sleep_target()
		if active_sleep_target == null:
			_flush_sleep_progress()
			return get_state(&"Idle")

	if active_sleep_target != null and not is_close_to(active_sleep_target.global_position, machine.stop_distance):
		machine.move_target = active_sleep_target
		machine.state_after_move = &"Sleep"
		return get_state(&"MoveToTarget")

	if sleep_timer <= 0.0:
		return get_state(&"Idle")

	sleep_timer -= delta
	_apply_sleep_progress(delta)

	if sleep_timer <= 0.0:
		_flush_sleep_progress()
		return get_state(&"Idle")

	if _sleep_need_is_sated():
		return get_state(&"Idle")

	return next_state


func target_seen(seen_target: Node2D) -> NpcState:
	# Optional wake-up behavior when another body enters sight while sleeping.
	if not wake_on_target_seen:
		return next_state

	if seen_target.is_in_group("player"):
		return get_state(&"ReactToEvent")

	return get_state(&"Idle")


func _resolve_sleep_target() -> Node2D:
	# Target priority: exported path, assigned spot, then closest matching Sleep spot.
	if machine == null:
		return null

	if String(sleep_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(sleep_target_path) as Node2D
		if _target_can_be_slept_at(configured_target):
			return configured_target

	if _target_can_be_slept_at(machine.sleep_target):
		return machine.sleep_target

	machine.sleep_target = null
	var closest_spot := find_closest_need_spot(&"Sleep", sleep_value_name)
	if closest_spot != null:
		machine.sleep_target = closest_spot
		return closest_spot

	return null


func _target_can_be_slept_at(sleep_target: Node2D) -> bool:
	if sleep_target == null or not is_instance_valid(sleep_target):
		return false

	if sleep_target.has_method("can_serve_npc_need"):
		return bool(sleep_target.call("can_serve_npc_need", npc, &"Sleep", sleep_value_name))

	return true


func _apply_sleep_progress(delta: float) -> void:
	sleep_progress_elapsed += delta
	var tick_seconds := maxf(sleep_progress_tick_seconds, 0.0)
	if tick_seconds > 0.0 and sleep_progress_elapsed < tick_seconds:
		return

	_flush_sleep_progress()


func _flush_sleep_progress() -> void:
	if sleep_value_name == &"":
		sleep_progress_elapsed = 0.0
		return

	var progress_delta := sleep_progress_elapsed
	sleep_progress_elapsed = 0.0

	var sleep_delta := -(absf(sleep_need_drop_per_full_sleep) / total_sleep_seconds) * progress_delta
	if is_equal_approx(sleep_delta, 0.0):
		return

	machine.apply_value_delta({String(sleep_value_name): sleep_delta}, null, false)


func _sleep_need_is_sated() -> bool:
	if sleep_value_name == &"":
		return sleep_timer <= 0.0

	return machine.get_value(sleep_value_name) <= 0.0
