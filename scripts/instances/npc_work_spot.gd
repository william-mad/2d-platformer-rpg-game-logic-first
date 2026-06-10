class_name NpcWorkSpot extends NpcNeedSpot

signal work_needed_changed(work_needed: float, changed_by: float)

@export_group("Work Need")
@export var require_work_needed_for_work: bool = true
@export var work_needed: float = 100.0
@export var work_needed_min: float = 0.0
@export var work_needed_max: float = 100.0
@export var work_needed_done_threshold: float = 0.0
@export var work_needed_daily_growth: float = 50.0
@export var show_work_needed_for_work: bool = true


func _ready() -> void:
	request_state_name = &"Work"
	value_name = &"boredom"
	add_to_group("npc_work_spot")
	add_to_group("saveable")
	super._ready()


func _exit_tree() -> void:
	_disconnect_world_time_day_signal()
	super._exit_tree()


func _setup() -> void:
	# Work spots own their work meter, then use the base spot logic for requests/visuals.
	super._setup()
	set_work_needed(work_needed)
	_connect_world_time_day_signal()
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
	_queue_visual_update()
	_queue_request_check()


func get_work_needed() -> float:
	return clampf(work_needed, _get_work_needed_floor(), _get_work_needed_ceiling())


func get_work_needed_capacity() -> float:
	return maxf(_get_work_needed_ceiling() - _get_work_needed_floor(), 0.001)


func has_work_needed() -> bool:
	return get_work_needed() > work_needed_done_threshold


func is_work_complete() -> bool:
	return not has_work_needed()


func apply_work_needed_delta(delta: float) -> float:
	# Returns the actual change after clamping, so NPC boredom falls only for real work done.
	var previous_value := get_work_needed()
	set_work_needed(previous_value + delta)
	return get_work_needed() - previous_value


func reset_work_needed() -> void:
	set_work_needed(work_needed_max)


func is_work_spot() -> bool:
	return true


func can_serve_npc_need(
	npc_node: Node2D,
	requested_state_name: StringName,
	requested_value_name: StringName = &""
) -> bool:
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
