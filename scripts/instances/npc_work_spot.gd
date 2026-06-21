class_name NpcWorkSpot extends NpcNeedSpot

signal work_needed_changed(work_needed: float, changed_by: float)
signal player_work_applied(player: Node2D, work_done: float, work_remaining: float)

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
@export var player_work_action: StringName = &"up"
@export_range(0.1, 100.0, 0.1) var player_work_per_interaction: float = 25.0
@export_range(0.0, 10.0, 0.05, "suffix:s") var player_work_cooldown_seconds: float = 0.35
@export var player_work_interaction_id: StringName = &"work"

@export_group("Optional Eat Phase")
@export var eat_world_definition: NpcSpotDefinition
@export_range(0.1, 100.0, 0.1) var food_consumed_per_full_eat: float = 25.0
@export var work_phase_label: String = "Prep Work"
@export var eat_phase_label: String = "Food"

var food_available: float = 0.0
var nearby_players: Array[Node2D] = []
var player_work_cooldown: float = 0.0


func _ready() -> void:
	request_state_name = &"Work"
	value_name = &"boredom"
	add_to_group("npc_work_spot")
	add_to_group("saveable")
	super._ready()
	_register_eat_world_spot()
	if not body_entered.is_connected(_on_work_body_entered):
		body_entered.connect(_on_work_body_entered)
	if not body_exited.is_connected(_on_work_body_exited):
		body_exited.connect(_on_work_body_exited)


func _process(delta: float) -> void:
	super._process(delta)
	player_work_cooldown = maxf(player_work_cooldown - delta, 0.0)
	if not allow_player_work or player_work_cooldown > 0.0:
		return
	if player_work_action == &"" or not InputMap.has_action(player_work_action):
		return
	if not Input.is_action_just_pressed(player_work_action):
		return

	var player := _get_closest_player_worker()
	if player != null and perform_player_work(player) > 0.0:
		player_work_cooldown = player_work_cooldown_seconds


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
	_update_visual()


func get_save_data() -> Dictionary:
	# Work areas save remaining area work separately from NPC stats.
	return {
		"work_needed": get_work_needed(),
	}


func apply_save_data(data: Dictionary) -> void:
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
	var work_rate := absf(world_definition.spot_value_delta_per_game_hour)
	if is_zero_approx(work_rate):
		return -1.0
	return get_work_needed_capacity() / work_rate


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

	var work_amount := player_work_per_interaction if requested_work < 0.0 else requested_work
	var actual_delta := apply_work_needed_delta(-absf(work_amount))
	var work_done := absf(actual_delta)
	if is_zero_approx(work_done):
		return 0.0

	player_work_applied.emit(player, work_done, get_work_needed())
	if player.has_method("on_player_work_applied"):
		player.call(
			"on_player_work_applied",
			self,
			work_done,
			player_work_interaction_id
		)
	return work_done


func can_player_work(player: Node2D) -> bool:
	return (
		allow_player_work
		and player != null
		and is_instance_valid(player)
		and player.is_in_group(String(player_group))
		and has_work_needed()
	)


func reset_work_needed() -> void:
	set_work_needed(work_needed_max)


func apply_world_work_needed(new_value: float) -> void:
	# Called when the global day cycle updates this spot while its scene may be unloaded.
	set_work_needed(new_value)


func apply_world_spot_value(changed_spot_id: StringName, new_value: float) -> void:
	if changed_spot_id == spot_id:
		apply_world_work_needed(new_value)
		return
	if eat_world_definition == null or changed_spot_id != eat_world_definition.spot_id:
		return

	food_available = clampf(
		new_value,
		minf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum),
		maxf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum)
	)
	_queue_visual_update()
	_queue_request_check()


func get_food_available() -> float:
	return food_available


func has_food_available() -> bool:
	if eat_world_definition == null:
		return false
	return food_available > eat_world_definition.spot_value_done_threshold


func get_full_eat_game_hours(requested_hunger_drop: float) -> float:
	# Eating time comes from the food phase's hunger rate, allowing per-spot meal lengths.
	if eat_world_definition == null:
		return -1.0
	var hunger_rate := absf(eat_world_definition.value_delta_per_game_hour)
	if is_zero_approx(hunger_rate):
		return -1.0
	return absf(requested_hunger_drop) / hunger_rate


func consume_eat_progress(requested_progress_fraction: float) -> float:
	# Returns the fraction of a full meal actually supplied, so hunger relief matches real food.
	if not has_food_available() or requested_progress_fraction <= 0.0:
		return 0.0

	var requested_food_delta := -food_consumed_per_full_eat * requested_progress_fraction
	var actual_food_delta := requested_food_delta
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("apply_spot_value_delta"):
		actual_food_delta = float(simulator.call(
			"apply_spot_value_delta",
			eat_world_definition.spot_id,
			requested_food_delta
		))
	else:
		var previous_food := food_available
		food_available = maxf(food_available + requested_food_delta, 0.0)
		actual_food_delta = food_available - previous_food

	if is_equal_approx(actual_food_delta, 0.0):
		return 0.0

	_queue_visual_update()
	return absf(actual_food_delta) / maxf(food_consumed_per_full_eat, 0.001)


func is_work_spot() -> bool:
	return true


func can_serve_npc_need(
	npc_node: Node2D,
	requested_state_name: StringName,
	requested_value_name: StringName = &""
) -> bool:
	if String(requested_state_name) == "Eat":
		return _can_serve_eat_phase(npc_node, requested_value_name)
	if require_work_needed_for_work and not has_work_needed():
		return false

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


func _setup_world_food_state() -> void:
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


func _publish_world_work_state() -> void:
	if spot_id == &"" or not is_inside_tree():
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("set_work_spot_value"):
		simulator.call("set_work_spot_value", spot_id, work_needed)


func _register_eat_world_spot() -> void:
	if eat_world_definition == null or eat_world_definition.spot_id == &"":
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("register_live_spot"):
		simulator.call("register_live_spot", eat_world_definition.spot_id, self)


func _unregister_eat_world_spot() -> void:
	if eat_world_definition == null or eat_world_definition.spot_id == &"":
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("unregister_live_spot"):
		simulator.call("unregister_live_spot", eat_world_definition.spot_id, self)


func _can_serve_eat_phase(npc_node: Node2D, requested_value_name: StringName) -> bool:
	if npc_node == null or eat_world_definition == null or not has_food_available():
		return false
	if requested_value_name != &"" and _canonical_value_key(requested_value_name) != "hunger":
		return false
	if not eat_world_definition.allows_npc_id(_get_npc_id(npc_node)):
		return false

	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		var hour := float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
		if not eat_world_definition.is_active_at(hour):
			return false

	return true


func _update_visual() -> void:
	if eat_world_definition == null:
		current_value = get_work_needed()
		if zone_visual != null:
			zone_visual.color = low_need_color.lerp(high_need_color, _get_work_needed_ratio(current_value))
		if label != null:
			label.text = "%s\n%d" % [label_prefix, int(round(current_value))]
		return

	if has_work_needed():
		current_value = get_work_needed()
		if zone_visual != null:
			zone_visual.color = low_need_color.lerp(high_need_color, _get_work_needed_ratio(current_value))
		if label != null:
			label.text = "%s\n%d" % [work_phase_label, int(round(current_value))]
		return

	current_value = food_available
	if zone_visual != null:
		zone_visual.color = high_need_color.lerp(low_need_color, _get_food_ratio(current_value))
	if label != null:
		label.text = "%s\n%d" % [eat_phase_label, int(round(current_value))]


func _get_food_ratio(value: float) -> float:
	if eat_world_definition == null:
		return 0.0
	var minimum := minf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum)
	var maximum := maxf(eat_world_definition.spot_value_minimum, eat_world_definition.spot_value_maximum)
	if is_equal_approx(minimum, maximum):
		return 0.0
	return clampf(inverse_lerp(minimum, maximum, value), 0.0, 1.0)


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
