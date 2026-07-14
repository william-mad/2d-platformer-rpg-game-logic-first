class_name NpcStateRecreation extends NpcState

@export var recreation_target_path: NodePath
@export var recreation_value_name: StringName = &"boredom"
@export_range(0.0, 100.0, 0.1, "suffix:/h") var boredom_drop_per_game_hour: float = 25.0
@export_range(0.0, 100.0, 0.1) var boredom_floor: float = 40.0
@export var progress_tick_seconds: float = 1.0

var active_recreation_target: Node2D
var progress_elapsed: float = 0.0
var choice_rng := RandomNumberGenerator.new()


func init() -> void:
	choice_rng.randomize()


func enter() -> void:
	# Recreation always uses a valid spot, walking there before boredom begins to fall.
	super.enter()
	active_recreation_target = _resolve_recreation_target()
	progress_elapsed = 0.0

	if active_recreation_target == null:
		machine.call_deferred("request_state", &"Idle", null, "missing_recreation_spot", 20)
		return
	if not is_close_to(active_recreation_target.global_position, machine.stop_distance):
		machine.move_target = active_recreation_target
		machine.state_after_move = &"Recreation"
		machine.call_deferred(
			"request_state",
			&"MoveToTarget",
			active_recreation_target,
			"walk_to_recreation",
			20
		)
		return

	stop_horizontal()


func physics_process(delta: float) -> NpcState:
	# Boredom falls gradually at the chosen spot; fatigue still rises through the machine.
	stop_horizontal()
	if active_recreation_target == null or not is_instance_valid(active_recreation_target):
		active_recreation_target = _resolve_recreation_target()
		if active_recreation_target == null:
			return get_state(&"Idle")

	if not _target_can_be_used(active_recreation_target):
		machine.recreation_target = null
		active_recreation_target = _resolve_recreation_target()
		if active_recreation_target == null:
			return get_state(&"Idle")

	if not is_close_to(active_recreation_target.global_position, machine.stop_distance):
		machine.move_target = active_recreation_target
		machine.state_after_move = &"Recreation"
		return get_state(&"MoveToTarget")

	_apply_recreation_progress(delta)
	if recreation_value_name == &"" or machine.get_value(recreation_value_name) <= boredom_floor:
		machine.recreation_target = null
		return get_state(&"Idle")

	return next_state


func can_continue_during_talk() -> bool:
	return (
		active_recreation_target != null
		and is_instance_valid(active_recreation_target)
		and _target_can_be_used(active_recreation_target)
		and is_close_to(active_recreation_target.global_position, machine.stop_distance)
		and recreation_value_name != &""
		and machine.get_value(recreation_value_name) > boredom_floor
	)


func process_talk_overlay(delta: float) -> StringName:
	stop_horizontal()
	if active_recreation_target == null or not is_instance_valid(active_recreation_target):
		machine.recreation_target = null
		return &"Idle"
	if not _target_can_be_used(active_recreation_target):
		machine.recreation_target = null
		return &"Idle"
	if not is_close_to(active_recreation_target.global_position, machine.stop_distance):
		machine.move_target = active_recreation_target
		machine.state_after_move = &"Recreation"
		return &"MoveToTarget"

	_apply_recreation_progress(delta)
	if recreation_value_name == &"" or machine.get_value(recreation_value_name) <= boredom_floor:
		machine.recreation_target = null
		return &"Idle"
	return &"Recreation"


func _apply_recreation_progress(delta: float) -> void:
	progress_elapsed += delta
	var tick_seconds := maxf(progress_tick_seconds, 0.0)
	if tick_seconds > 0.0 and progress_elapsed < tick_seconds:
		return

	var game_hours := machine.get_game_hours_for_real_seconds(progress_elapsed)
	progress_elapsed = 0.0
	if game_hours <= 0.0 or recreation_value_name == &"":
		return

	var current_boredom := machine.get_value(recreation_value_name)
	var requested_drop := boredom_drop_per_game_hour * game_hours
	var actual_drop := minf(requested_drop, maxf(current_boredom - boredom_floor, 0.0))
	if actual_drop <= 0.0:
		return
	machine.apply_value_delta(
		{String(recreation_value_name): -actual_drop},
		null,
		false
	)


func _resolve_recreation_target() -> Node2D:
	# Explicit assignments win; otherwise choose among valid local spots by preference weight.
	if machine == null:
		return null

	if String(recreation_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(recreation_target_path) as Node2D
		if _target_can_be_used(configured_target):
			return configured_target

	if _target_can_be_used(machine.recreation_target):
		return machine.recreation_target

	machine.recreation_target = null
	var preferred_spot := find_weighted_casual_spot(&"Recreation", choice_rng)
	if preferred_spot != null:
		machine.recreation_target = preferred_spot

	return preferred_spot


func _target_can_be_used(recreation_spot: Node2D) -> bool:
	if recreation_spot == null or not is_instance_valid(recreation_spot):
		return false
	if recreation_spot.has_method("can_serve_npc_casual_activity"):
		return bool(recreation_spot.call(
			"can_serve_npc_casual_activity",
			npc,
			&"Recreation"
		))

	return true
