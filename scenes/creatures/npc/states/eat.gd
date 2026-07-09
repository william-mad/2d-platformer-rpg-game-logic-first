class_name NpcStateEat extends NpcState

@export var eat_target_path: NodePath
@export var eat_duration: float = -1.0
@export var eat_value_name: StringName = &"hunger"
@export var hunger_drop_per_full_eat: float = 100.0

var eat_timer: float = 0.0
var total_eat_seconds: float = 0.0
var active_eat_target: Node2D
var resume_from_talk_overlay: bool = false
var meal_sated_marked: bool = false


func enter() -> void:
	# Walks to a configured/nearby eat spot first, then starts the eating timer.
	super.enter()
	_breadcrumb(
		"npc_eat:enter",
		"%s hunger=%.2f resume=%s" % [_npc_label(), machine.get_value(eat_value_name), str(resume_from_talk_overlay)]
	)
	if _eat_state_disabled():
		_breadcrumb("npc_eat:disabled", _npc_label())
		eat_timer = 0.0
		active_eat_target = null
		next_state = get_state(&"Idle")
		stop_horizontal()
		return

	if not resume_from_talk_overlay:
		meal_sated_marked = false

	if resume_from_talk_overlay:
		resume_from_talk_overlay = false
		if active_eat_target == null or not is_instance_valid(active_eat_target):
			active_eat_target = _resolve_eat_target()
		if (
			active_eat_target == null
			or eat_timer <= 0.0
			or _hunger_is_sated()
			or not _target_can_be_eaten_at(active_eat_target)
		):
			if _hunger_is_sated():
				_mark_meal_sated_if_needed()
				_breadcrumb("npc_eat:sated_on_resume", _npc_label())
			next_state = get_state(&"Idle")
			stop_horizontal()
			return
		stop_horizontal()
		return

	active_eat_target = _resolve_eat_target()
	if active_eat_target == null:
		_breadcrumb("npc_eat:missing_target", _npc_label())
		eat_timer = 0.0
		machine.call_deferred("request_state", &"Idle", null, "missing_eat_spot", 20)
		return
	if active_eat_target != null and not is_close_to(active_eat_target.global_position, machine.stop_distance):
		_breadcrumb("npc_eat:walk_to_target", "%s -> %s" % [_npc_label(), active_eat_target.name])
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
	_breadcrumb(
		"npc_eat:start_timer",
		"%s target=%s seconds=%.2f" % [_npc_label(), active_eat_target.name, total_eat_seconds]
	)
	stop_horizontal()


func exit() -> void:
	_breadcrumb(
		"npc_eat:exit",
		"%s hunger=%.2f timer=%.2f" % [_npc_label(), machine.get_value(eat_value_name), eat_timer]
	)
	super.exit()


func physics_process(delta: float) -> NpcState:
	# Hunger drains gradually while the NPC stays at the eat spot.
	stop_horizontal()
	if active_eat_target == null or not is_instance_valid(active_eat_target):
		active_eat_target = _resolve_eat_target()
		if active_eat_target == null:
			_breadcrumb("npc_eat:lost_target", _npc_label())
			return get_state(&"Idle")

	if active_eat_target != null and not _target_can_be_eaten_at(active_eat_target):
		_breadcrumb("npc_eat:target_rejected", "%s %s" % [_npc_label(), active_eat_target.name])
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
	var made_progress := _apply_eat_progress(delta)
	if not made_progress and not _hunger_is_sated():
		_breadcrumb("npc_eat:no_progress", _npc_label())
		return get_state(&"Idle")

	if _hunger_is_sated() or eat_timer <= 0.0:
		return get_state(&"Idle")

	return next_state


func can_continue_during_talk() -> bool:
	var eat_target := active_eat_target
	if eat_target == null or not is_instance_valid(eat_target):
		eat_target = _resolve_eat_target()

	return (
		eat_target != null
		and is_instance_valid(eat_target)
		and _target_can_be_eaten_at(eat_target)
		and is_close_to(eat_target.global_position, machine.stop_distance)
		and eat_timer > 0.0
		and not _hunger_is_sated()
	)


func process_talk_overlay(delta: float) -> StringName:
	stop_horizontal()

	if active_eat_target == null or not is_instance_valid(active_eat_target):
		active_eat_target = _resolve_eat_target()
		if active_eat_target == null:
			return &"Idle"

	if active_eat_target != null and not _target_can_be_eaten_at(active_eat_target):
		return &"Idle"

	if active_eat_target != null and not is_close_to(active_eat_target.global_position, machine.stop_distance):
		return &"Eat"

	if eat_timer <= 0.0 or _hunger_is_sated():
		return &"Idle"

	eat_timer -= delta
	var made_progress := _apply_eat_progress(delta)
	if not made_progress and not _hunger_is_sated():
		return &"Idle"

	if _hunger_is_sated() or eat_timer <= 0.0:
		return &"Idle"

	return &"Eat"


func prepare_resume_from_talk_overlay() -> void:
	resume_from_talk_overlay = true


func _resolve_eat_target() -> Node2D:
	# Target priority: exported path, assigned spot, then closest matching Eat spot.
	if machine == null:
		return null

	if String(eat_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(eat_target_path) as Node2D
		if _target_can_be_eaten_at(configured_target):
			_breadcrumb("npc_eat:target_configured", "%s -> %s" % [_npc_label(), configured_target.name])
			return configured_target

	if _target_can_be_eaten_at(machine.eat_target):
		_breadcrumb("npc_eat:target_assigned", "%s -> %s" % [_npc_label(), machine.eat_target.name])
		return machine.eat_target

	machine.eat_target = null
	var closest_spot := find_closest_need_spot(&"Eat", eat_value_name)
	if closest_spot != null:
		machine.eat_target = closest_spot
		_breadcrumb("npc_eat:target_closest", "%s -> %s" % [_npc_label(), closest_spot.name])
		return closest_spot

	return null


func _target_can_be_eaten_at(eat_target: Node2D) -> bool:
	if eat_target == null or not is_instance_valid(eat_target):
		return false

	if eat_target.has_method("can_serve_npc_need"):
		var accepted := bool(eat_target.call("can_serve_npc_need", npc, &"Eat", eat_value_name))
		if not accepted:
			_breadcrumb("npc_eat:spot_reject", "%s %s" % [_npc_label(), eat_target.name])
		return accepted

	return true


func _apply_eat_progress(delta: float) -> bool:
	if eat_value_name == &"":
		return true

	var requested_progress_fraction := maxf(delta / total_eat_seconds, 0.0)
	var requested_hunger_drop := minf(
		machine.get_value(eat_value_name),
		absf(hunger_drop_per_full_eat) * requested_progress_fraction
	)
	if requested_hunger_drop <= 0.0:
		return _hunger_is_sated()

	var actual_hunger_drop := requested_hunger_drop
	if active_eat_target != null and active_eat_target.has_method("consume_eat_amount"):
		actual_hunger_drop = clampf(
			float(active_eat_target.call("consume_eat_amount", requested_hunger_drop)),
			0.0,
			requested_hunger_drop
		)
	elif active_eat_target != null and active_eat_target.has_method("consume_eat_progress"):
		var actual_progress_fraction := clampf(
			float(active_eat_target.call("consume_eat_progress", requested_progress_fraction)),
			0.0,
			requested_progress_fraction
		)
		actual_hunger_drop = absf(hunger_drop_per_full_eat) * actual_progress_fraction

	var hunger_delta := -actual_hunger_drop
	if is_equal_approx(hunger_delta, 0.0):
		return false

	var previous_hunger := machine.get_value(eat_value_name)
	machine.apply_value_delta({String(eat_value_name): hunger_delta}, null, false)
	var next_hunger := machine.get_value(eat_value_name)
	_log_hunger_progress(previous_hunger, next_hunger)
	if _hunger_is_sated():
		_mark_meal_sated_if_needed()
	return next_hunger < previous_hunger or _hunger_is_sated()


func _mark_meal_sated_if_needed() -> void:
	if meal_sated_marked:
		return
	if active_eat_target == null or not is_instance_valid(active_eat_target):
		return
	if not active_eat_target.has_method("mark_npc_meal_sated"):
		return

	meal_sated_marked = bool(active_eat_target.call(
		"mark_npc_meal_sated",
		npc,
		eat_value_name
	))


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


func _log_hunger_progress(previous_hunger: float, next_hunger: float) -> void:
	if not _verbose_enabled():
		return
	for threshold in [100.0, 90.0, 75.0, 70.0, 0.0]:
		if previous_hunger > threshold and next_hunger <= threshold:
			_breadcrumb(
				"npc_eat:hunger_cross",
				"%s %.2f->%.2f <= %.1f" % [_npc_label(), previous_hunger, next_hunger, threshold]
			)


func _eat_state_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_EAT_STATE
	)


func _verbose_enabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_ENABLE_VERBOSE_NPC_LOGS
	)


func _npc_label() -> String:
	if npc != null and is_instance_valid(npc):
		if npc.has_method("get_npc_location_id"):
			var npc_id := String(npc.call("get_npc_location_id")).strip_edges()
			if not npc_id.is_empty():
				return "%s(%s)" % [npc.name, npc_id]
		return npc.name
	return name


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
