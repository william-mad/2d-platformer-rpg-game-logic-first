class_name NpcWorkSpot extends NpcNeedSpot

signal work_needed_changed(work_needed: float, changed_by: float)
signal player_work_applied(player: Node2D, work_done: float, work_remaining: float)

const MEAL_STAGE_PREP_WORK := "prep_work"
const MEAL_STAGE_FOOD := "food"
const MEAL_STAGE_CLEANUP_WORK := "cleanup_work"
const MEAL_OWNER_PREP := "prep"
const MEAL_OWNER_FOOD := "food"
const MEAL_OWNER_CLEANUP := "cleanup"

@export_group("Work Need")
@export var require_work_needed_for_work: bool = true
@export var work_needed: float = 100.0
@export var work_needed_min: float = 0.0
@export var work_needed_max: float = 100.0
@export var work_needed_done_threshold: float = 0.0
@export var work_needed_daily_growth: float = 50.0
@export var show_work_needed_for_work: bool = true

@export_group("Player Work")
@export var allow_player_work: bool = true
@export var player_group: StringName = &"player"
@export var player_owner_id: StringName = &"player"
@export var player_work_action: StringName = &"up"
@export_range(0.1, 100.0, 0.1) var player_work_per_interaction: float = 25.0
@export_range(0.05, 30.0, 0.05, "suffix:s") var player_work_duration_seconds: float = 2.0
@export_range(0.0, 10.0, 0.05, "suffix:s") var player_work_cooldown_seconds: float = 0.35
@export var player_work_interaction_id: StringName = &"work"

@export_group("Optional Eat Phase")
@export var eat_world_definition: NpcSpotDefinition
@export_range(0.1, 100.0, 0.1) var food_consumed_per_full_eat: float = 25.0
@export_range(0.1, 100.0, 0.1) var player_hunger_drop_per_meal: float = 35.0
@export_range(0.05, 30.0, 0.05, "suffix:s") var player_eat_duration_seconds: float = 2.0
@export var work_phase_label: String = "Prep Work"
@export var eat_phase_label: String = "Food"

var food_available: float = 0.0
var nearby_players: Array[Node2D] = []
var player_work_cooldown: float = 0.0
var active_player: Node2D
var active_player_action: StringName = &""
var active_player_action_timer: float = 0.0
var active_player_action_duration: float = 0.0
var meal_cycle_enabled: bool = false
var meal_cycle_stage: String = MEAL_STAGE_PREP_WORK
var meal_cycle_meal: String = ""
var meal_cycle_food_available: bool = false
var meal_cycle_meal_called: bool = false
var meal_cycle_work_call_active: bool = false
var meal_cycle_prep_owner_ids: Array[StringName] = []
var meal_cycle_food_owner_ids: Array[StringName] = []
var meal_cycle_cleanup_owner_ids: Array[StringName] = []
var meal_cycle_owner_meal_data: Dictionary = {}
var debug_meal_spot_disabled_logged: bool = false
var debug_work_spot_disabled_logged: bool = false
var debug_last_meal_cycle_label: String = ""


func _ready() -> void:
	request_state_name = &"Work"
	value_name = &"boredom"
	require_target_need_threshold = false
	add_to_group("npc_work_spot")
	add_to_group("saveable")
	_breadcrumb(
		"work_spot:ready",
		"%s spot=%s eat=%s" % [
			name,
			String(spot_id),
			String(eat_world_definition.spot_id) if eat_world_definition != null else "",
		]
	)
	super._ready()
	_register_eat_world_spot()
	if not body_entered.is_connected(_on_work_body_entered):
		body_entered.connect(_on_work_body_entered)
	if not body_exited.is_connected(_on_work_body_exited):
		body_exited.connect(_on_work_body_exited)


func _process(delta: float) -> void:
	super._process(delta)
	player_work_cooldown = maxf(player_work_cooldown - delta, 0.0)
	if _update_active_player_action(delta):
		return
	if not allow_player_work or player_work_cooldown > 0.0:
		return
	if player_work_action == &"" or not InputMap.has_action(player_work_action):
		return

	var player := _get_closest_player_worker()
	if player == null:
		return
	if can_player_work(player) and Input.is_action_pressed(player_work_action):
		_start_player_action(player, &"work", 0.0)
	elif has_food_available() and _player_can_eat(player):
		if Input.is_action_just_pressed(player_work_action):
			_start_player_action(player, &"eat", player_eat_duration_seconds)


func _apply_world_definition() -> void:
	super._apply_world_definition()
	if world_definition == null or world_definition.spot_value_name != &"work_needed":
		return

	work_needed = world_definition.spot_value_initial
	work_needed_min = world_definition.spot_value_minimum
	work_needed_max = world_definition.spot_value_maximum
	work_needed_done_threshold = world_definition.spot_value_done_threshold
	work_needed_daily_growth = world_definition.spot_value_daily_growth


func _exit_tree() -> void:
	_breadcrumb("work_spot:exit", "%s spot=%s" % [name, String(spot_id)])
	_disconnect_world_time_day_signal()
	_unregister_eat_world_spot()
	super._exit_tree()


func _setup() -> void:
	# Work spots own their work meter, then use the base spot logic for requests/visuals.
	super._setup()
	var uses_world_state := _setup_world_work_state()
	if not uses_world_state:
		set_work_needed(work_needed)
		_connect_world_time_day_signal()
	_setup_world_food_state()
	_sync_meal_cycle_state_from_world()
	_update_visual()


func get_save_data() -> Dictionary:
	# Work areas save remaining area work separately from NPC stats.
	if _uses_world_spot_state():
		return {}
	return {
		"work_needed": get_work_needed(),
	}


func apply_save_data(data: Dictionary) -> void:
	if _uses_world_spot_state():
		return
	if data.has("work_needed"):
		set_work_needed(float(data["work_needed"]))


func set_work_needed(new_value: float) -> void:
	# Keeps work progress in range and refreshes the spot display when it changes.
	var previous_value := work_needed
	work_needed = clampf(new_value, _get_work_needed_floor(), _get_work_needed_ceiling())

	if is_equal_approx(previous_value, work_needed):
		return

	work_needed_changed.emit(work_needed, work_needed - previous_value)
	_publish_world_work_state()
	_queue_visual_update()
	_queue_request_check()


func get_work_needed() -> float:
	return clampf(work_needed, _get_work_needed_floor(), _get_work_needed_ceiling())


func get_work_needed_capacity() -> float:
	return maxf(_get_work_needed_ceiling() - _get_work_needed_floor(), 0.001)


func get_full_work_game_hours() -> float:
	# A spot's own work rate controls its live duration as well as off-screen simulation.
	if world_definition == null:
		return -1.0
	var work_rate := absf(world_definition.spot_value_delta_per_game_hour) * _get_meal_cycle_work_multiplier()
	if is_zero_approx(work_rate):
		return -1.0
	return get_work_needed_capacity() / work_rate


func get_full_work_real_seconds() -> float:
	var game_hours := get_full_work_game_hours()
	if game_hours > 0.0:
		var real_seconds_per_day := _get_real_seconds_per_day()
		if real_seconds_per_day > 0.0:
			return maxf(real_seconds_per_day * (game_hours / 24.0), 0.001)

	return _get_legacy_full_work_real_seconds()


func get_work_delta_for_elapsed_seconds(delta: float, speed_multiplier: float = 1.0) -> float:
	var elapsed_seconds := maxf(delta, 0.0)
	var multiplier := maxf(speed_multiplier, 0.0)
	if elapsed_seconds <= 0.0 or multiplier <= 0.0:
		return 0.0

	var full_work_seconds := get_full_work_real_seconds()
	if full_work_seconds <= 0.0:
		return 0.0

	return -(get_work_needed_capacity() / full_work_seconds) * elapsed_seconds * multiplier


func apply_worker_work_progress(
	worker: Node,
	delta: float,
	speed_multiplier: float = 1.0
) -> float:
	if worker == null or not is_instance_valid(worker):
		return 0.0
	if _worker_is_player(worker) and not can_player_work(worker as Node2D):
		return 0.0
	if not has_work_needed():
		return 0.0

	var requested_delta := get_work_delta_for_elapsed_seconds(delta, speed_multiplier)
	if is_equal_approx(requested_delta, 0.0):
		return 0.0

	var actual_delta := apply_work_needed_delta(requested_delta)
	if is_equal_approx(actual_delta, 0.0):
		return 0.0

	if _worker_is_player(worker):
		_notify_player_work_applied(worker as Node2D, absf(actual_delta))
		_award_player_work_time_xp(worker as Node2D, delta, absf(actual_delta))
	return actual_delta


func get_value_drop_per_full_work(requested_value_name: StringName) -> float:
	# Keeps the worker's need change consistent with this spot's configured hourly rate.
	if world_definition == null:
		return -1.0
	if _canonical_value_key(requested_value_name) != _canonical_value_key(world_definition.value_name):
		return -1.0
	var game_hours := get_full_work_game_hours()
	if game_hours <= 0.0:
		return -1.0
	return absf(world_definition.value_delta_per_game_hour) * game_hours


func has_work_needed() -> bool:
	if _debug_realtest1_meal_spot_disabled() or _debug_realtest1_work_spot_disabled():
		_log_debug_disabled_once()
		return false
	if meal_cycle_enabled and meal_cycle_stage == MEAL_STAGE_FOOD:
		return false
	return get_work_needed() > work_needed_done_threshold


func is_work_complete() -> bool:
	return not has_work_needed()


func apply_work_needed_delta(delta: float) -> float:
	# Returns the actual change after clamping, so NPC boredom falls only for real work done.
	var previous_value := get_work_needed()
	set_work_needed(previous_value + delta)
	return get_work_needed() - previous_value


func perform_player_work(player: Node2D, requested_work: float = -1.0) -> float:
	# Shared player hook for meal prep and future work types; returns positive work completed.
	if not can_player_work(player):
		return 0.0

	var actual_delta := 0.0
	if requested_work < 0.0:
		actual_delta = apply_worker_work_progress(player, player_work_duration_seconds, 1.0)
	else:
		actual_delta = apply_work_needed_delta(-absf(requested_work))
	var work_done := absf(actual_delta)
	if is_zero_approx(work_done):
		return 0.0

	if requested_work >= 0.0:
		_notify_player_work_applied(player, work_done)
	return work_done


func perform_player_eat(player: Node2D) -> float:
	# Player eating consumes the same food pool as NPC eating, but finishes faster.
	if not _player_can_eat(player):
		return 0.0

	var requested_hunger_drop := minf(
		absf(player_hunger_drop_per_meal),
		_get_player_hunger(player, absf(player_hunger_drop_per_meal))
	)
	var supplied_food := consume_eat_amount(requested_hunger_drop)
	if supplied_food <= 0.0:
		return 0.0

	if player.has_method("apply_hunger_delta"):
		player.call("apply_hunger_delta", -supplied_food)
	player_work_cooldown = player_work_cooldown_seconds
	_queue_visual_update()
	return supplied_food


func can_player_work(player: Node2D) -> bool:
	if _debug_realtest1_meal_spot_disabled() or _debug_realtest1_work_spot_disabled():
		_log_debug_disabled_once()
		return false
	return (
		allow_player_work
		and player != null
		and is_instance_valid(player)
		and player.is_in_group(String(player_group))
		and _player_owner_is_allowed_for_current_work_stage(player)
		and has_work_needed()
	)


func _player_can_eat(player: Node2D) -> bool:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return false
	if player == null or not is_instance_valid(player):
		return false
	if not player.is_in_group(String(player_group)):
		return false
	if not _player_owner_is_allowed_for_eat(player):
		return false
	if not has_food_available():
		return false
	if meal_cycle_enabled and not meal_cycle_meal_called:
		return false
	if player.has_method("can_eat") and not bool(player.call("can_eat")):
		return false

	return true


func reset_work_needed() -> void:
	set_work_needed(work_needed_max)


func apply_world_work_needed(new_value: float) -> void:
	# Called when the global day cycle updates this spot while its scene may be unloaded.
	set_work_needed(new_value)


func apply_world_spot_value(changed_spot_id: StringName, new_value: float) -> void:
	if changed_spot_id == spot_id:
		apply_world_work_needed(new_value)
		_sync_meal_cycle_state_from_world()
		return
	if eat_world_definition == null or changed_spot_id != eat_world_definition.spot_id:
		return

	food_available = clampf(
		new_value,
		minf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum),
		maxf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum)
	)
	_sync_meal_cycle_state_from_world()
	_queue_visual_update()
	_queue_request_check()


func apply_world_meal_cycle_state(controller_spot_id: StringName, state: Dictionary) -> void:
	if controller_spot_id != spot_id:
		return

	_apply_meal_cycle_state(state)


func get_food_available() -> float:
	if meal_cycle_enabled:
		if meal_cycle_stage != MEAL_STAGE_FOOD or not meal_cycle_food_available:
			return 0.0
		return maxf(food_available, 0.0)
	return food_available


func has_food_available() -> bool:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return false
	if meal_cycle_enabled:
		return (
			meal_cycle_stage == MEAL_STAGE_FOOD
			and meal_cycle_food_available
			and food_available > _get_food_done_threshold()
		)
	if eat_world_definition == null:
		return false
	return food_available > _get_food_done_threshold()


func get_full_eat_game_hours(requested_hunger_drop: float) -> float:
	# Eating time comes from the food phase's hunger rate, allowing per-spot meal lengths.
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return -1.0
	if eat_world_definition == null:
		return -1.0
	var hunger_rate := absf(eat_world_definition.value_delta_per_game_hour)
	if is_zero_approx(hunger_rate):
		return -1.0
	return absf(requested_hunger_drop) / hunger_rate


func consume_eat_amount(requested_hunger_amount: float) -> float:
	# Food points are hunger points: 12 food consumed lowers hunger by 12.
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return 0.0
	if eat_world_definition == null:
		return 0.0
	if not has_food_available() or requested_hunger_amount <= 0.0:
		return 0.0

	var requested_food_delta := -minf(
		requested_hunger_amount,
		maxf(get_food_available() - _get_food_done_threshold(), 0.0)
	)
	var actual_food_delta := requested_food_delta
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if (
		simulator != null
		and simulator.has_method("apply_spot_value_delta")
		and _simulator_has_spot_state(simulator, eat_world_definition.spot_id)
	):
		actual_food_delta = float(simulator.call(
			"apply_spot_value_delta",
			eat_world_definition.spot_id,
			requested_food_delta
		))
	else:
		var previous_food := food_available
		food_available = clampf(
			food_available + requested_food_delta,
			_get_food_floor(),
			_get_food_ceiling()
		)
		actual_food_delta = food_available - previous_food
		if food_available <= _get_food_done_threshold():
			_start_local_meal_cycle_cleanup_if_food_depleted()

	if is_equal_approx(actual_food_delta, 0.0):
		return 0.0

	_breadcrumb(
		"work_spot:eat_progress",
		"%s requested=%.3f actual=%.3f food=%.2f" % [
			name,
			requested_hunger_amount,
			absf(actual_food_delta),
			food_available,
		]
	)
	_queue_visual_update()
	return absf(actual_food_delta)


func consume_eat_progress(requested_progress_fraction: float) -> float:
	# Older callers request a fraction of a meal; newer callers use consume_eat_amount().
	var full_meal_amount := maxf(food_consumed_per_full_eat, 0.001)
	var supplied_food := consume_eat_amount(full_meal_amount * requested_progress_fraction)
	return supplied_food / full_meal_amount


func _simulator_has_spot_state(simulator: Node, requested_spot_id: StringName) -> bool:
	var runtime_states = simulator.get("spot_runtime_states")
	return runtime_states is Dictionary and runtime_states.has(String(requested_spot_id))


func is_work_spot() -> bool:
	return true


func can_serve_npc_need(
	npc_node: Node2D,
	requested_state_name: StringName,
	requested_value_name: StringName = &""
) -> bool:
	if _debug_realtest1_meal_spot_disabled() and (
		String(requested_state_name) == "Eat"
		or (meal_cycle_enabled and String(requested_state_name) == "Work")
	):
		_log_debug_disabled_once()
		return false
	if _debug_realtest1_work_spot_disabled() and String(requested_state_name) == "Work":
		_log_debug_disabled_once()
		return false
	if String(requested_state_name) == "Eat":
		return _can_serve_eat_phase(npc_node, requested_value_name)
	if meal_cycle_enabled and String(requested_state_name) == "Work":
		return _can_serve_meal_cycle_work_phase(npc_node, requested_value_name)
	if require_work_needed_for_work and not has_work_needed():
		return false
	if String(requested_state_name) == "Work":
		return super.can_serve_npc_need(npc_node, requested_state_name, &"")

	return super.can_serve_npc_need(npc_node, requested_state_name, requested_value_name)


func _maybe_request_state() -> void:
	if require_work_needed_for_work and not has_work_needed():
		return

	super._maybe_request_state()


func _get_display_value() -> float:
	if show_work_needed_for_work:
		return get_work_needed()

	return super._get_display_value()


func _get_display_ratio(value: float) -> float:
	if eat_world_definition != null and not has_work_needed():
		return 1.0 - _get_food_ratio(value)
	if show_work_needed_for_work:
		return _get_work_needed_ratio(value)

	return super._get_display_ratio(value)


func _start_player_action(player: Node2D, action_name: StringName, duration: float) -> void:
	active_player = player
	active_player_action = action_name
	active_player_action_duration = maxf(duration, 0.0)
	active_player_action_timer = active_player_action_duration
	if active_player.has_method("begin_spot_action"):
		active_player.call("begin_spot_action", self, action_name)
	_queue_visual_update()


func _update_active_player_action(delta: float) -> bool:
	if active_player_action == &"":
		return false
	if active_player == null or not is_instance_valid(active_player) or not nearby_players.has(active_player):
		_cancel_player_action()
		return false

	_stop_player_horizontal(active_player)
	if active_player_action == &"work":
		return _update_active_player_work(delta)

	active_player_action_timer -= delta
	_queue_visual_update()
	if active_player_action_timer > 0.0:
		return true

	var completed_action := active_player_action
	var completed_player := active_player
	if active_player.has_method("end_spot_action"):
		active_player.call("end_spot_action", self, active_player_action, true)
	_clear_player_action()
	if completed_action == &"work":
		if perform_player_work(completed_player) > 0.0:
			player_work_cooldown = player_work_cooldown_seconds
	elif completed_action == &"eat":
		perform_player_eat(completed_player)

	return true


func _update_active_player_work(delta: float) -> bool:
	if not Input.is_action_pressed(player_work_action):
		_cancel_player_action()
		return true
	if is_work_complete():
		_finish_player_action(true)
		return true
	if not can_player_work(active_player):
		_cancel_player_action()
		return true

	apply_worker_work_progress(active_player, delta, 1.0)
	_queue_visual_update()
	if is_work_complete():
		_finish_player_action(true)

	return true


func _finish_player_action(completed: bool) -> void:
	if active_player != null and is_instance_valid(active_player) and active_player.has_method("end_spot_action"):
		active_player.call("end_spot_action", self, active_player_action, completed)
	if completed and active_player_action == &"work":
		player_work_cooldown = player_work_cooldown_seconds
	_clear_player_action()


func _cancel_player_action() -> void:
	if active_player != null and is_instance_valid(active_player) and active_player.has_method("end_spot_action"):
		active_player.call("end_spot_action", self, active_player_action, false)
	_clear_player_action()


func _clear_player_action() -> void:
	active_player = null
	active_player_action = &""
	active_player_action_timer = 0.0
	active_player_action_duration = 0.0
	_queue_visual_update()


func _stop_player_horizontal(player: Node2D) -> void:
	var player_body := player as CharacterBody2D
	if player_body != null:
		player_body.velocity.x = 0.0


func _notify_player_work_applied(player: Node2D, work_done: float) -> void:
	if player == null or not is_instance_valid(player) or work_done <= 0.0:
		return

	player_work_applied.emit(player, work_done, get_work_needed())
	if player.has_method("on_player_work_applied"):
		player.call(
			"on_player_work_applied",
			self,
			work_done,
			player_work_interaction_id
		)


func _award_player_work_time_xp(player: Node2D, delta: float, work_done: float) -> void:
	if player == null or not is_instance_valid(player) or work_done <= 0.0:
		return

	var progression := get_node_or_null("/root/ProgressionSystem")
	if progression == null or not progression.has_method("add_time_xp"):
		return

	progression.call("add_time_xp", &"work_activity.basic", delta, {
		"spot_id": String(spot_id),
		"work_done": work_done,
		"interaction_id": String(player_work_interaction_id),
	})


func _worker_is_player(worker: Node) -> bool:
	return (
		worker != null
		and is_instance_valid(worker)
		and worker.is_in_group(String(player_group))
	)


func _get_real_seconds_per_day() -> float:
	if not is_inside_tree():
		return 0.0

	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null:
		return 0.0

	var value = world_time.get("real_seconds_per_day")
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return maxf(float(value), 0.0)

	return 0.0


func _get_legacy_full_work_real_seconds() -> float:
	var work_amount := maxf(absf(player_work_per_interaction), 0.001)
	var interaction_seconds := maxf(player_work_duration_seconds, 0.001)
	return maxf((get_work_needed_capacity() / work_amount) * interaction_seconds, 0.001)


func _connect_world_time_day_signal() -> void:
	# Work spots regain some required work at the start of each new day cycle.
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_signal(&"day_changed"):
		return

	var callback := Callable(self, "_on_world_time_day_changed")
	if not world_time.is_connected(&"day_changed", callback):
		world_time.connect(&"day_changed", callback)


func _disconnect_world_time_day_signal() -> void:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_signal(&"day_changed"):
		return

	var callback := Callable(self, "_on_world_time_day_changed")
	if world_time.is_connected(&"day_changed", callback):
		world_time.disconnect(&"day_changed", callback)


func _on_world_time_day_changed(_day: int, _snapshot: Dictionary) -> void:
	if is_equal_approx(work_needed_daily_growth, 0.0):
		return

	set_work_needed(get_work_needed() + work_needed_daily_growth)


func _setup_world_work_state() -> bool:
	if _debug_realtest1_meal_spot_disabled() or _debug_realtest1_work_spot_disabled():
		_log_debug_disabled_once()
		return false
	if spot_id == &"":
		return false
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("register_work_spot_state"):
		return false

	var stored_value := float(simulator.call(
		"register_work_spot_state",
		spot_id,
		work_needed,
		_get_work_needed_floor(),
		_get_work_needed_ceiling(),
		work_needed_daily_growth
	))
	set_work_needed(stored_value)
	return true


func _uses_world_spot_state() -> bool:
	return world_definition != null and world_definition.spot_value_name != &""


func _setup_world_food_state() -> void:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		food_available = 0.0
		return
	if eat_world_definition == null:
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("get_spot_value"):
		food_available = eat_world_definition.spot_value_initial
		return

	food_available = float(simulator.call(
		"get_spot_value",
		eat_world_definition.spot_id,
		eat_world_definition.spot_value_initial
	))


func _sync_meal_cycle_state_from_world() -> void:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		meal_cycle_enabled = false
		meal_cycle_food_available = false
		meal_cycle_meal_called = false
		meal_cycle_work_call_active = false
		food_available = 0.0
		return
	if world_definition == null or world_definition.meal_cycle_id == &"":
		return

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("get_meal_cycle_state"):
		return

	var state = simulator.call("get_meal_cycle_state", spot_id)
	if state is Dictionary and not state.is_empty():
		_apply_meal_cycle_state(state)


func _apply_meal_cycle_state(state: Dictionary) -> void:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		meal_cycle_enabled = false
		meal_cycle_food_available = false
		meal_cycle_meal_called = false
		meal_cycle_work_call_active = false
		food_available = 0.0
		_queue_visual_update()
		return

	meal_cycle_enabled = bool(state.get("meal_cycle_enabled", false))
	if not meal_cycle_enabled:
		return

	meal_cycle_stage = String(state.get("stage", MEAL_STAGE_PREP_WORK))
	meal_cycle_meal = String(state.get("meal", ""))
	meal_cycle_food_available = bool(state.get("food_available", false))
	meal_cycle_meal_called = bool(state.get("meal_called", false))
	meal_cycle_work_call_active = bool(state.get("work_call_active", false))
	meal_cycle_prep_owner_ids = _variant_owner_ids_to_string_names(state.get("prep_owner_ids", []))
	meal_cycle_food_owner_ids = _variant_owner_ids_to_string_names(state.get("food_owner_ids", []))
	meal_cycle_cleanup_owner_ids = _variant_owner_ids_to_string_names(state.get("cleanup_owner_ids", []))
	var owner_meal_data = state.get("owner_meal_data", {})
	meal_cycle_owner_meal_data = owner_meal_data.duplicate(true) if owner_meal_data is Dictionary else {}
	var fallback_food_value := food_available if meal_cycle_stage == MEAL_STAGE_FOOD else 0.0
	food_available = clampf(
		float(state.get("food_value", fallback_food_value)),
		_get_food_floor(),
		_get_food_ceiling()
	)
	meal_cycle_food_available = meal_cycle_food_available and food_available > _get_food_done_threshold()

	var previous_work_needed := work_needed
	work_needed = clampf(
		float(state.get("value", work_needed)),
		_get_work_needed_floor(),
		_get_work_needed_ceiling()
	)
	if not is_equal_approx(previous_work_needed, work_needed):
		work_needed_changed.emit(work_needed, work_needed - previous_work_needed)

	var state_label := "%s %s food=%s called=%s work=%s value=%.2f" % [
		meal_cycle_stage,
		meal_cycle_meal,
		"%.2f" % food_available,
		str(meal_cycle_meal_called),
		str(meal_cycle_work_call_active),
		work_needed,
	]
	if state_label != debug_last_meal_cycle_label:
		debug_last_meal_cycle_label = state_label
		_breadcrumb("work_spot:meal_state", "%s %s" % [name, state_label])

	_queue_visual_update()
	_queue_request_check()


func _publish_world_work_state() -> void:
	if spot_id == &"" or not is_inside_tree():
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("set_work_spot_value"):
		simulator.call("set_work_spot_value", spot_id, work_needed)


func _register_world_spot() -> void:
	if _debug_realtest1_meal_spot_disabled() or _debug_realtest1_work_spot_disabled():
		_log_debug_disabled_once()
		return
	_breadcrumb("work_spot:register_work", "%s spot=%s" % [name, String(spot_id)])
	super._register_world_spot()


func _unregister_world_spot() -> void:
	_breadcrumb("work_spot:unregister_work", "%s spot=%s" % [name, String(spot_id)])
	super._unregister_world_spot()


func _register_eat_world_spot() -> void:
	if eat_world_definition == null or eat_world_definition.spot_id == &"":
		return
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("register_live_spot"):
		_breadcrumb(
			"work_spot:register_eat",
			"%s eat_spot=%s" % [name, String(eat_world_definition.spot_id)]
		)
		simulator.call("register_live_spot", eat_world_definition.spot_id, self)


func _unregister_eat_world_spot() -> void:
	if eat_world_definition == null or eat_world_definition.spot_id == &"":
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("unregister_live_spot"):
		_breadcrumb(
			"work_spot:unregister_eat",
			"%s eat_spot=%s" % [name, String(eat_world_definition.spot_id)]
		)
		simulator.call("unregister_live_spot", eat_world_definition.spot_id, self)


func _can_serve_eat_phase(npc_node: Node2D, requested_value_name: StringName) -> bool:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return false
	if npc_node == null or eat_world_definition == null or not has_food_available():
		_breadcrumb("work_spot:eat_reject", "%s missing_or_no_food" % name)
		return false
	if requested_value_name != &"" and _canonical_value_key(requested_value_name) != "hunger":
		_breadcrumb("work_spot:eat_reject", "%s value=%s" % [name, String(requested_value_name)])
		return false
	if meal_cycle_enabled:
		var npc_id := _get_npc_id(npc_node)
		var accepted := (
			meal_cycle_meal_called
			and _meal_cycle_owner_allows(MEAL_OWNER_FOOD, npc_id)
			and not _meal_cycle_owner_has_had_current_meal(npc_id)
			and _npc_has_required_tags(npc_node)
		)
		_breadcrumb(
			"work_spot:eat_%s" % ("accept" if accepted else "reject"),
			"%s npc=%s meal=%s called=%s had=%s" % [
				name,
				String(npc_id),
				meal_cycle_meal,
				str(meal_cycle_meal_called),
				str(_meal_cycle_owner_has_had_current_meal(npc_id)),
			]
		)
		return accepted
	if not eat_world_definition.allows_npc_id(_get_npc_id(npc_node)):
		_breadcrumb("work_spot:eat_reject", "%s owner=%s" % [name, String(_get_npc_id(npc_node))])
		return false

	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		var hour := float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
		if not eat_world_definition.is_active_at(hour):
			_breadcrumb("work_spot:eat_reject", "%s inactive hour=%.2f" % [name, hour])
			return false

	_breadcrumb("work_spot:eat_accept", "%s npc=%s" % [name, String(_get_npc_id(npc_node))])
	return true


func _can_serve_meal_cycle_work_phase(
	npc_node: Node2D,
	requested_value_name: StringName
) -> bool:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return false
	if npc_node == null or not is_instance_valid(npc_node):
		return false
	if requested_value_name != &"" and _canonical_value_key(requested_value_name) != "boredom":
		_breadcrumb("work_spot:meal_work_reject", "%s value=%s" % [name, String(requested_value_name)])
		return false
	if not meal_cycle_work_call_active:
		_breadcrumb("work_spot:meal_work_reject", "%s no_call" % name)
		return false
	if not has_work_needed():
		_breadcrumb("work_spot:meal_work_reject", "%s complete" % name)
		return false
	if meal_cycle_stage != MEAL_STAGE_PREP_WORK and meal_cycle_stage != MEAL_STAGE_CLEANUP_WORK:
		_breadcrumb("work_spot:meal_work_reject", "%s stage=%s" % [name, meal_cycle_stage])
		return false
	if not _meal_cycle_owner_allows(_get_meal_cycle_current_work_owner_type(), _get_npc_id(npc_node)):
		_breadcrumb("work_spot:meal_work_reject", "%s owner=%s" % [name, String(_get_npc_id(npc_node))])
		return false

	var accepted := _npc_has_required_tags(npc_node)
	_breadcrumb(
		"work_spot:meal_work_%s" % ("accept" if accepted else "reject"),
		"%s npc=%s stage=%s" % [name, String(_get_npc_id(npc_node)), meal_cycle_stage]
	)
	return accepted


func _player_owner_is_allowed(player: Node2D) -> bool:
	return _character_owner_id_is_allowed(_get_player_owner_id(player))


func _player_owner_is_allowed_for_current_work_stage(player: Node2D) -> bool:
	if not meal_cycle_enabled:
		return _player_owner_is_allowed(player)
	if not meal_cycle_work_call_active:
		return false
	if meal_cycle_stage != MEAL_STAGE_PREP_WORK and meal_cycle_stage != MEAL_STAGE_CLEANUP_WORK:
		return false
	return _meal_cycle_owner_allows(
		_get_meal_cycle_current_work_owner_type(),
		_get_player_owner_id(player)
	)


func _player_owner_is_allowed_for_eat(player: Node2D) -> bool:
	if eat_world_definition == null:
		return _player_owner_is_allowed(player)

	var owner_id := _get_player_owner_id(player)
	if meal_cycle_enabled:
		return _meal_cycle_owner_allows(MEAL_OWNER_FOOD, owner_id)

	var eat_owner_ids := eat_world_definition.get_owner_ids()
	if eat_owner_ids.is_empty():
		return _player_owner_is_allowed(player)

	for eat_owner_id in eat_owner_ids:
		if String(eat_owner_id) == String(owner_id):
			return true

	return false


func mark_npc_meal_sated(npc_node: Node2D, need_value_name: StringName = &"hunger") -> bool:
	if _debug_realtest1_meal_spot_disabled():
		_log_debug_disabled_once()
		return false
	if not meal_cycle_enabled:
		return false
	if npc_node == null or not is_instance_valid(npc_node):
		return false

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("mark_meal_owner_sated"):
		return false

	var marked := bool(simulator.call(
		"mark_meal_owner_sated",
		spot_id,
		_get_npc_id(npc_node),
		need_value_name
	))
	if marked:
		_breadcrumb(
			"work_spot:meal_sated",
			"%s npc=%s value=%s" % [name, String(_get_npc_id(npc_node)), String(need_value_name)]
		)
		_sync_meal_cycle_state_from_world()
	return marked


func _get_player_owner_id(player: Node2D) -> StringName:
	if player != null and player.has_meta("owner_id"):
		var owner_id := String(player.get_meta("owner_id"))
		if not owner_id.is_empty():
			return StringName(owner_id)

	return player_owner_id


func _get_player_hunger(player: Node2D, fallback: float) -> float:
	if player == null:
		return fallback

	var hunger_value = player.get("hunger")
	if typeof(hunger_value) == TYPE_FLOAT or typeof(hunger_value) == TYPE_INT:
		return clampf(float(hunger_value), 0.0, 100.0)

	return fallback


func _get_meal_cycle_current_work_owner_type() -> String:
	if meal_cycle_stage == MEAL_STAGE_CLEANUP_WORK:
		return MEAL_OWNER_CLEANUP
	return MEAL_OWNER_PREP


func _get_meal_cycle_work_multiplier() -> float:
	if not meal_cycle_enabled or world_definition == null:
		return 1.0

	return world_definition.get_meal_cycle_work_multiplier_for_stage(meal_cycle_stage)


func _meal_cycle_owner_allows(owner_type: String, owner_id: StringName) -> bool:
	var cycle_owner_ids := _get_meal_cycle_owner_ids(owner_type)
	if cycle_owner_ids.is_empty():
		return true

	for configured_id in cycle_owner_ids:
		if String(configured_id) == String(owner_id):
			return true

	return false


func _meal_cycle_owner_has_had_current_meal(owner_id: StringName) -> bool:
	if meal_cycle_meal.is_empty():
		return false
	if not meal_cycle_owner_meal_data.has(String(owner_id)):
		return false
	var meal_data = meal_cycle_owner_meal_data[String(owner_id)]
	if not (meal_data is Dictionary):
		return false
	return bool(meal_data.get("has_had_%s" % meal_cycle_meal.to_snake_case(), false))


func _get_meal_cycle_owner_ids(owner_type: String) -> Array[StringName]:
	if owner_type == MEAL_OWNER_FOOD:
		return meal_cycle_food_owner_ids
	if owner_type == MEAL_OWNER_CLEANUP:
		return meal_cycle_cleanup_owner_ids
	return meal_cycle_prep_owner_ids


func _variant_owner_ids_to_string_names(values) -> Array[StringName]:
	var ids: Array[StringName] = []
	if not (values is Array):
		return ids

	for value in values:
		var text := String(value).strip_edges()
		if text.is_empty():
			continue
		var owner_id := StringName(text)
		if not ids.has(owner_id):
			ids.append(owner_id)

	return ids


func _start_local_meal_cycle_cleanup_if_food_depleted() -> void:
	if not meal_cycle_enabled or meal_cycle_stage != MEAL_STAGE_FOOD:
		return
	if food_available > _get_food_done_threshold():
		return

	meal_cycle_stage = MEAL_STAGE_CLEANUP_WORK
	meal_cycle_food_available = false
	meal_cycle_meal_called = false
	meal_cycle_work_call_active = true
	work_needed = _get_work_needed_ceiling()


func _update_visual() -> void:
	if meal_cycle_enabled:
		_update_meal_cycle_visual()
		return

	if eat_world_definition == null:
		current_value = get_work_needed()
		if zone_visual != null:
			zone_visual.color = low_need_color.lerp(high_need_color, _get_work_needed_ratio(current_value))
		if label != null:
			label.text = _format_spot_label(label_prefix, _get_phase_value_text(current_value))
		return

	if has_work_needed():
		current_value = get_work_needed()
		if zone_visual != null:
			zone_visual.color = low_need_color.lerp(high_need_color, _get_work_needed_ratio(current_value))
		if label != null:
			label.text = _format_spot_label(
				work_phase_label,
				_get_phase_value_text(current_value),
				_get_owner_debug_text()
			)
		return

	current_value = food_available
	if zone_visual != null:
		zone_visual.color = high_need_color.lerp(low_need_color, _get_food_ratio(current_value))
	if label != null:
		label.text = _format_spot_label(
			eat_phase_label,
			_get_phase_value_text(current_value),
			_get_eat_owner_debug_text()
		)


func _update_meal_cycle_visual() -> void:
	if meal_cycle_stage == MEAL_STAGE_FOOD:
		current_value = get_food_available()
		if zone_visual != null:
			zone_visual.color = high_need_color.lerp(low_need_color, _get_food_ratio(current_value))
		if label != null:
			var value_text := "ready" if meal_cycle_food_available else "waiting"
			if not meal_cycle_meal.is_empty():
				value_text = "%s %s" % [meal_cycle_meal, value_text]
			value_text = "%s %d" % [value_text, int(round(current_value))]
			value_text = _get_player_action_value_text(value_text)
			label.text = _format_spot_label(
				"Food",
				value_text,
				_get_meal_cycle_owner_debug_text(MEAL_OWNER_FOOD)
			)
		return

	current_value = get_work_needed()
	if zone_visual != null:
		zone_visual.color = low_need_color.lerp(high_need_color, _get_work_needed_ratio(current_value))
	if label == null:
		return

	var title := "Prep Work"
	var owner_type := MEAL_OWNER_PREP
	if meal_cycle_stage == MEAL_STAGE_CLEANUP_WORK:
		title = "Cleanup Work"
		owner_type = MEAL_OWNER_CLEANUP
	if not meal_cycle_meal.is_empty():
		title = "%s %s" % [meal_cycle_meal.capitalize(), title]

	label.text = _format_spot_label(
		title,
		_get_phase_value_text(current_value),
		_get_meal_cycle_owner_debug_text(owner_type)
	)


func _get_phase_value_text(value: float) -> String:
	if active_player_action == &"work":
		return "%d | player working" % int(round(value))
	if active_player_action != &"" and active_player_action_duration > 0.0:
		var progress := 1.0 - clampf(active_player_action_timer / active_player_action_duration, 0.0, 1.0)
		return "%d | player %s %d%%" % [
			int(round(value)),
			_get_player_action_label(active_player_action),
			int(round(progress * 100.0)),
		]

	return str(int(round(value)))


func _get_player_action_value_text(base_text: String) -> String:
	if active_player_action == &"work":
		return "%s | player working" % base_text
	if active_player_action != &"" and active_player_action_duration > 0.0:
		var progress := 1.0 - clampf(active_player_action_timer / active_player_action_duration, 0.0, 1.0)
		return "%s | player %s %d%%" % [
			base_text,
			_get_player_action_label(active_player_action),
			int(round(progress * 100.0)),
		]

	return base_text


func _get_player_action_label(action_name: StringName) -> String:
	if action_name == &"eat":
		return "eating"
	if action_name == &"work":
		return "working"

	return String(action_name)


func _get_eat_owner_debug_text() -> String:
	if eat_world_definition == null:
		return _get_owner_debug_text()
	if eat_world_definition.owner_npc_ids.is_empty():
		return "owners:any"

	var owner_texts: Array[String] = []
	for owner_id in eat_world_definition.owner_npc_ids:
		owner_texts.append(String(owner_id))

	return "owners:%s" % ",".join(owner_texts)


func _get_meal_cycle_owner_debug_text(owner_type: String) -> String:
	var owner_ids := _get_meal_cycle_owner_ids(owner_type)
	if owner_ids.is_empty():
		return "owners:any"

	var owner_texts: Array[String] = []
	for owner_id in owner_ids:
		owner_texts.append(String(owner_id))

	return "owners:%s" % ",".join(owner_texts)


func _get_food_ratio(value: float) -> float:
	if eat_world_definition == null:
		return 0.0
	var minimum := _get_food_floor()
	var maximum := _get_food_ceiling()
	if is_equal_approx(minimum, maximum):
		return 0.0
	return clampf(inverse_lerp(minimum, maximum, value), 0.0, 1.0)


func _get_food_floor() -> float:
	if eat_world_definition == null:
		return 0.0

	return minf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum)


func _get_food_ceiling() -> float:
	if eat_world_definition == null:
		return 100.0

	return maxf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum)


func _get_food_done_threshold() -> float:
	if eat_world_definition == null:
		return 0.0

	return eat_world_definition.spot_value_done_threshold


func _get_work_needed_ratio(value: float) -> float:
	# Work is red when much is left and green when the area is nearly done.
	var floor_value := _get_work_needed_floor()
	var ceiling_value := _get_work_needed_ceiling()
	if is_equal_approx(floor_value, ceiling_value):
		return 0.0

	return clampf(inverse_lerp(floor_value, ceiling_value, value), 0.0, 1.0)


func _get_work_needed_floor() -> float:
	return minf(work_needed_min, work_needed_max)


func _get_work_needed_ceiling() -> float:
	return maxf(work_needed_min, work_needed_max)


func _on_work_body_entered(body: Node2D) -> void:
	if body == null or not body.is_in_group(String(player_group)):
		return
	if not nearby_players.has(body):
		nearby_players.append(body)


func _on_work_body_exited(body: Node2D) -> void:
	nearby_players.erase(body)
	if body == active_player:
		_cancel_player_action()


func _get_closest_player_worker() -> Node2D:
	var closest_player: Node2D
	var closest_distance := INF
	for player in nearby_players.duplicate():
		if player == null or not is_instance_valid(player):
			nearby_players.erase(player)
			continue
		var distance := global_position.distance_squared_to(player.global_position)
		if distance >= closest_distance:
			continue
		closest_distance = distance
		closest_player = player
	return closest_player


func _debug_realtest1_meal_spot_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_REALTEST1_MEAL_SPOT
		and _is_realtest1_scene()
		and _is_realtest1_meal_spot()
	)


func _debug_realtest1_work_spot_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_REALTEST1_WORK_SPOT
		and _is_realtest1_scene()
		and _is_realtest1_work_spot()
	)


func _is_realtest1_scene() -> bool:
	if is_inside_tree() and get_tree() != null:
		var current_scene := get_tree().current_scene
		if current_scene != null and current_scene.scene_file_path == "res://scenes/testscenes/realtest1.tscn":
			return true
	if owner != null and owner.scene_file_path == "res://scenes/testscenes/realtest1.tscn":
		return true
	return false


func _is_realtest1_meal_spot() -> bool:
	if name == "MomMealCycleSpot" or save_id == "realtest1_mom_meal_cycle":
		return true
	if spot_id == &"mom_eat_prep":
		return true
	if world_definition != null and world_definition.spot_id == &"mom_eat_prep":
		return true
	return eat_world_definition != null and eat_world_definition.spot_id == &"mom_eat"


func _is_realtest1_work_spot() -> bool:
	if name == "MomWorkNeedSpot" or save_id == "realtest1_mom_work":
		return true
	if spot_id == &"mom_work":
		return true
	return world_definition != null and world_definition.spot_id == &"mom_work"


func _log_debug_disabled_once() -> void:
	if _debug_realtest1_meal_spot_disabled() and not debug_meal_spot_disabled_logged:
		debug_meal_spot_disabled_logged = true
		_breadcrumb("work_spot:realtest1_meal_disabled", "%s spot=%s" % [name, String(spot_id)])
	if _debug_realtest1_work_spot_disabled() and not debug_work_spot_disabled_logged:
		debug_work_spot_disabled_logged = true
		_breadcrumb("work_spot:realtest1_work_disabled", "%s spot=%s" % [name, String(spot_id)])


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
