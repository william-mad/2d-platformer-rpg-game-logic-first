class_name NpcStateEat extends NpcState

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")

@export var eat_target_path: NodePath
@export var eat_duration: float = -1.0
@export var eat_value_name: StringName = &"hunger"
@export var hunger_drop_per_full_eat: float = 100.0

var eat_timer: float = 0.0
var total_eat_seconds: float = 0.0
var active_eat_target: Node2D
var meal_sated_marked: bool = false
var inventory_food_item_id: StringName = &""
var inventory_food_reservation_id: StringName = &""
var using_inventory_food: bool = false
var inventory_food_retry_until_msec: int = 0
var food_service := FoodConsumptionService.new()


func on_action_session_refreshed() -> void:
	active_eat_target = machine.get_eat_target()


func enter() -> void:
	# Walks to a configured/nearby eat spot first, then starts the eating timer.
	super.enter()
	_breadcrumb(
		"npc_eat:enter",
		"%s hunger=%.2f" % [_npc_label(), machine.get_value(eat_value_name)]
	)
	if _eat_state_disabled():
		_breadcrumb("npc_eat:disabled", _npc_label())
		eat_timer = 0.0
		active_eat_target = null
		next_state = get_state(&"Idle")
		stop_horizontal()
		return

	meal_sated_marked = false
	active_eat_target = machine.get_eat_target()
	if _hunger_is_sated():
		_mark_meal_sated_if_needed()
		eat_timer = 0.0
		total_eat_seconds = 0.0
		next_state = get_state(&"Idle")
		stop_horizontal()
		return

	active_eat_target = _resolve_eat_target()
	if active_eat_target == null:
		_breadcrumb("npc_eat:missing_target", _npc_label())
		eat_timer = 0.0
		inventory_food_retry_until_msec = Time.get_ticks_msec() + 10000
		machine.call_deferred("request_state", &"Idle", null, "missing_eat_spot", 20)
		return
	if not _prepare_inventory_food_if_needed():
		_breadcrumb("npc_eat:no_inventory_food", _npc_label())
		eat_timer = 0.0
		inventory_food_retry_until_msec = Time.get_ticks_msec() + 10000
		machine.call_deferred("request_state", &"Idle", null, "no_available_food", 20)
		return
	if active_eat_target != null and not is_close_to(active_eat_target.global_position, machine.stop_distance):
		_breadcrumb("npc_eat:walk_to_target", "%s -> %s" % [_npc_label(), active_eat_target.name])
		machine.call_deferred(
			"request_active_action_approach",
			action_session_id,
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
	# Talk no longer exits Eat, so a real exit can release synchronously and exactly once.
	_release_inventory_food_if_cancelled()


func physics_process(delta: float) -> NpcState:
	if not action_session_is_current():
		return reconcile_invalid_action_session()
	# Hunger drains gradually while the NPC stays at the eat spot.
	stop_horizontal()
	if _hunger_is_sated():
		_mark_meal_sated_if_needed()
		return get_state(&"Idle")
	if active_eat_target == null or not is_instance_valid(active_eat_target):
		active_eat_target = _resolve_eat_target()
		if active_eat_target == null:
			_breadcrumb("npc_eat:lost_target", _npc_label())
			return get_state(&"Idle")

	if active_eat_target != null and not _target_can_be_eaten_at(active_eat_target):
		_breadcrumb("npc_eat:target_rejected", "%s %s" % [_npc_label(), active_eat_target.name])
		machine.set_action_target(&"Eat", null, action_session_id)
		active_eat_target = _resolve_eat_target()
		if active_eat_target == null:
			return get_state(&"Idle")

	if active_eat_target != null and not is_close_to(active_eat_target.global_position, machine.stop_distance):
		machine.begin_active_action_approach(action_session_id)
		return get_state(&"MoveToTarget")

	if eat_timer <= 0.0:
		return get_state(&"Idle")

	eat_timer -= delta
	if using_inventory_food:
		if eat_timer <= 0.0:
			_complete_inventory_food()
			return get_state(&"Idle")
		return next_state
	var made_progress := _apply_eat_progress(delta)
	if not made_progress and not _hunger_is_sated():
		_breadcrumb("npc_eat:no_progress", _npc_label())
		return get_state(&"Idle")

	if _hunger_is_sated():
		_mark_meal_sated_if_needed()
		return get_state(&"Idle")
	if eat_timer <= 0.0:
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
		and (not using_inventory_food or _inventory_food_reservation_is_valid())
	)


func process_talk_overlay(delta: float) -> StringName:
	stop_horizontal()
	if _hunger_is_sated():
		_mark_meal_sated_if_needed()
		return &"Idle"

	if active_eat_target == null or not is_instance_valid(active_eat_target):
		active_eat_target = _resolve_eat_target()
		if active_eat_target == null:
			return &"Idle"

	if active_eat_target != null and not _target_can_be_eaten_at(active_eat_target):
		return &"Idle"

	if active_eat_target != null and not is_close_to(active_eat_target.global_position, machine.stop_distance):
		machine.begin_active_action_approach(action_session_id)
		return &"MoveToTarget"

	if _hunger_is_sated():
		_mark_meal_sated_if_needed()
		return &"Idle"
	if eat_timer <= 0.0:
		return &"Idle"

	eat_timer -= delta
	if using_inventory_food:
		if eat_timer <= 0.0:
			_complete_inventory_food()
			return &"Idle"
		return &"Eat"
	var made_progress := _apply_eat_progress(delta)
	if not made_progress and not _hunger_is_sated():
		return &"Idle"

	if _hunger_is_sated():
		_mark_meal_sated_if_needed()
		return &"Idle"
	if eat_timer <= 0.0:
		return &"Idle"

	return &"Eat"

func _resolve_eat_target() -> Node2D:
	# Target priority: exported path, assigned spot, then closest matching Eat spot.
	if machine == null:
		return null

	var assigned_target := machine.get_eat_target()
	if _target_can_be_eaten_at(assigned_target):
		_breadcrumb("npc_eat:target_assigned", "%s -> %s" % [_npc_label(), assigned_target.name])
		return assigned_target

	if String(eat_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(eat_target_path) as Node2D
		if _target_can_be_eaten_at(configured_target):
			machine.set_action_target(&"Eat", configured_target, action_session_id)
			_breadcrumb("npc_eat:target_configured", "%s -> %s" % [_npc_label(), configured_target.name])
			return configured_target

	machine.set_action_target(&"Eat", null, action_session_id)
	var closest_spot := find_closest_need_spot(&"Eat", eat_value_name)
	if closest_spot != null:
		machine.set_action_target(&"Eat", closest_spot, action_session_id)
		_breadcrumb("npc_eat:target_closest", "%s -> %s" % [_npc_label(), closest_spot.name])
		return closest_spot
	if Time.get_ticks_msec() >= inventory_food_retry_until_msec and _has_available_inventory_food():
		machine.set_action_target(&"Eat", npc, action_session_id)
		return npc

	return null


func _target_can_be_eaten_at(eat_target: Node2D) -> bool:
	if eat_target == null or not is_instance_valid(eat_target):
		return false
	# The NPC itself is the deliberate inventory-food target. Every other target
	# must be an authored need spot; people must never become moving Eat spots.
	if eat_target == npc:
		return true
	if not eat_target.has_method("can_serve_npc_need"):
		_breadcrumb("npc_eat:spot_reject", "%s %s" % [_npc_label(), eat_target.name])
		return false

	var accepted := bool(eat_target.call("can_serve_npc_need", npc, &"Eat", eat_value_name))
	if not accepted:
		_breadcrumb("npc_eat:spot_reject", "%s %s" % [_npc_label(), eat_target.name])
	return accepted


func _target_uses_spot_food(eat_target: Node2D) -> bool:
	return (
		eat_target != null
		and (
			eat_target.has_method("consume_eat_amount")
			or eat_target.has_method("consume_eat_progress")
		)
	)


func _prepare_inventory_food_if_needed() -> bool:
	using_inventory_food = not _target_uses_spot_food(active_eat_target)
	if not using_inventory_food:
		_release_inventory_food_reservation()
		return true
	if _inventory_food_reservation_is_valid():
		return true
	if Time.get_ticks_msec() < inventory_food_retry_until_msec:
		return false
	_release_inventory_food_reservation()
	using_inventory_food = true
	var inventory := _get_npc_inventory()
	if inventory == null:
		return false
	inventory_food_item_id = food_service.select_best_available_food(inventory)
	if inventory_food_item_id == &"":
		return false
	inventory_food_reservation_id = StringName("eat:%s" % _get_npc_id())
	if machine != null:
		machine.register_active_action_reservation(
			String(inventory_food_reservation_id), action_session_id
		)
	var reservation := inventory.reserve_items(
		inventory_food_reservation_id,
		{inventory_food_item_id: 1}
	)
	if not reservation.success:
		inventory_food_item_id = &""
		inventory_food_reservation_id = &""
		using_inventory_food = false
		return false
	return true


func _complete_inventory_food() -> bool:
	if not using_inventory_food or not _inventory_food_reservation_is_valid():
		_release_inventory_food_reservation()
		return false
	var consumed_item_id := inventory_food_item_id
	var result := food_service.consume_for_npc(
		_get_npc_inventory(),
		npc,
		inventory_food_item_id,
		inventory_food_reservation_id
	)
	if not result.success:
		_breadcrumb("npc_eat:inventory_consume_failed", "%s %s" % [_npc_label(), result.message])
		_release_inventory_food_reservation()
		return false
	_breadcrumb("npc_eat:inventory_consumed", "%s item=%s" % [_npc_label(), String(consumed_item_id)])
	inventory_food_item_id = &""
	inventory_food_reservation_id = &""
	using_inventory_food = false
	return true


func _release_inventory_food_if_cancelled() -> void:
	if _should_preserve_inventory_food_reservation():
		return
	_release_inventory_food_reservation()


func _should_preserve_inventory_food_reservation() -> bool:
	if not using_inventory_food or machine == null or machine.current_state == null:
		return false
	var destination_name := machine.get_pending_primary_state_name()
	if destination_name == &"":
		destination_name = StringName(machine.current_state.name)
	if destination_name == &"MoveToTarget":
		return (
			machine.get_active_action_session_id() == action_session_id
			and machine.active_action != null
			and machine.active_action.action_kind == &"Eat"
		)
	return (
		destination_name == &"Eat"
		and machine.get_active_action_session_id() == action_session_id
	)


func _release_inventory_food_reservation() -> void:
	var inventory := _get_npc_inventory()
	var may_release := true
	if machine != null and inventory_food_reservation_id != &"":
		may_release = machine.claim_active_action_reservation_release(
			String(inventory_food_reservation_id), action_session_id
		)
	if may_release and inventory != null and inventory_food_reservation_id != &"" and inventory.has_reservation(inventory_food_reservation_id):
		inventory.release_reservation(inventory_food_reservation_id)
	inventory_food_item_id = &""
	inventory_food_reservation_id = &""
	using_inventory_food = false


func _inventory_food_reservation_is_valid() -> bool:
	var inventory := _get_npc_inventory()
	if inventory == null or inventory_food_reservation_id == &"" or inventory_food_item_id == &"":
		return false
	var reservation := inventory.get_reservation(inventory_food_reservation_id)
	return reservation.size() == 1 and int(reservation.get(String(inventory_food_item_id), 0)) == 1


func _has_available_inventory_food() -> bool:
	if npc != null and npc.has_method("has_available_inventory_food"):
		return bool(npc.call("has_available_inventory_food"))
	return food_service.select_best_available_food(_get_npc_inventory()) != &""


func _get_npc_inventory() -> InventoryModel:
	if npc == null or not is_instance_valid(npc) or not npc.has_method("get_inventory"):
		return null
	return npc.call("get_inventory") as InventoryModel


func _get_npc_id() -> String:
	var actor_id := NpcIdentity.get_actor_id(npc, true)
	if not actor_id.is_empty():
		return actor_id
	return "instance:%s" % get_instance_id()


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
