class_name NpcNeedSpot extends Area2D

const VALUE_ALIASES := {
	"sleepiness": "sleep_need",
	"work_need": "boredom",
	"talk_interest": "talk_need",
}

@export_group("Save")
@export var save_id: String = ""

@export_group("Target")
@export var target_npc_path: NodePath
@export var value_name: StringName = &"hunger"
@export var value_min: float = 0.0
@export var value_max: float = 100.0

@export_group("Serving")
@export var restrict_to_target_npc: bool = true
@export var allowed_npc_ids: Array[StringName] = []
@export var required_npc_tags: Array[StringName] = []

@export_group("State Request")
@export var auto_request_when_idle: bool = true
@export var require_target_need_threshold: bool = true
@export var need_threshold: float = 61.0
@export var request_state_name: StringName = &""
@export var request_priority: int = 20
@export var request_reason: String = "need_spot"
@export var target_assignment_method: StringName = &""
@export var idle_state_name: StringName = &"Idle"
@export var request_cooldown_seconds: float = 1.5

@export_group("Schedule")
@export var active_time_windows: Array[Dictionary] = []

@export_group("Visual")
@export var label_prefix: String = "Need"
@export var low_need_color: Color = Color(0.18, 0.82, 0.28, 0.46)
@export var high_need_color: Color = Color(0.95, 0.12, 0.08, 0.54)
@export var missing_target_color: Color = Color(0.45, 0.45, 0.45, 0.32)

@export_group("Performance")
@export var visual_refresh_seconds: float = 1.0
@export var request_check_seconds: float = 1.0

@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D
@onready var label: Label = get_node_or_null("%Label") as Label

var target_npc: Node
var machine: NpcStateMachine
var connected_machine: NpcStateMachine
var request_cooldown: float = 0.0
var current_value: float = 0.0
var visual_refresh_timer: float = 0.0
var request_check_timer: float = 0.0
var visual_dirty: bool = true
var request_dirty: bool = true


func _ready() -> void:
	add_to_group("npc_need_spot")
	call_deferred("_setup")


func _exit_tree() -> void:
	if connected_machine == null or not is_instance_valid(connected_machine):
		return

	var callback := Callable(self, "_on_machine_values_changed")
	if connected_machine.values_changed.is_connected(callback):
		connected_machine.values_changed.disconnect(callback)


func _process(delta: float) -> void:
	request_cooldown = maxf(request_cooldown - delta, 0.0)

	if target_npc == null or not is_instance_valid(target_npc):
		_resolve_target()
		visual_dirty = true
		request_dirty = true

	_update_visual_if_due(delta)
	_check_request_if_due(delta)


func _setup() -> void:
	# Resolves the NPC once the scene tree is ready, then draws the first value readout.
	_resolve_target()
	_update_visual()


func get_save_id() -> String:
	# Empty ids are ignored by SaveSystem, so only important spots need a configured id.
	return save_id.strip_edges()


func get_save_data() -> Dictionary:
	return {}


func apply_save_data(_data: Dictionary) -> void:
	pass


func _resolve_target() -> void:
	# Finds the target NPC and its state machine, if this spot is assigned to one.
	target_npc = get_node_or_null(target_npc_path)
	machine = _get_machine(target_npc)
	_connect_machine_signals()


func _update_visual() -> void:
	# Generic need spots show the target NPC's matching value.
	if target_npc == null or not is_instance_valid(target_npc):
		if zone_visual != null:
			zone_visual.color = missing_target_color
		if label != null:
			label.text = "%s\n--" % label_prefix
		return

	current_value = _get_display_value()
	var ratio := _get_display_ratio(current_value)
	if zone_visual != null:
		zone_visual.color = low_need_color.lerp(high_need_color, ratio)

	if label != null:
		label.text = "%s\n%d" % [label_prefix, int(round(current_value))]


func _maybe_request_state() -> void:
	# If this spot's gate is open and the NPC is idle, ask it to use this exact spot.
	if not auto_request_when_idle:
		return
	if machine == null or request_cooldown > 0.0:
		return
	if not _is_inside_active_time_window():
		return
	if require_target_need_threshold and _get_target_value() < need_threshold:
		return
	if not _machine_is_idle():
		return
	if request_state_name == &"":
		return

	if _request_target_state():
		_record_watchdog_marker(&"need_spot:request", "%s -> %s" % [name, String(request_state_name)])
		request_cooldown = request_cooldown_seconds


func _on_machine_values_changed(
	_values: Dictionary,
	_changed_values: Dictionary,
	_actor: Node2D
) -> void:
	# Keeps the visual and auto-request behavior synced to machine value changes.
	current_value = _get_display_value()
	_queue_request_check()
	_queue_visual_update()


func _update_visual_if_due(delta: float) -> void:
	if visual_refresh_seconds <= 0.0:
		_update_visual()
		visual_dirty = false
		return

	visual_refresh_timer -= delta
	if not visual_dirty and visual_refresh_timer > 0.0:
		return

	visual_refresh_timer = visual_refresh_seconds
	visual_dirty = false
	_update_visual()


func _check_request_if_due(delta: float) -> void:
	if request_check_seconds <= 0.0:
		_maybe_request_state()
		request_dirty = false
		return

	request_check_timer -= delta
	if not request_dirty and request_check_timer > 0.0:
		return

	request_check_timer = request_check_seconds
	request_dirty = false
	_maybe_request_state()


func _queue_visual_update() -> void:
	visual_dirty = true


func _queue_request_check() -> void:
	request_dirty = true


func _request_target_state() -> bool:
	# Prefer specific assignment helpers so states know this exact spot is their target.
	var assignment_method := _get_target_assignment_method()
	if assignment_method != &"" and machine.has_method(assignment_method):
		return bool(machine.call(assignment_method, self))

	if machine.has_method("request_state"):
		return bool(machine.call(
			"request_state",
			request_state_name,
			self,
			request_reason,
			request_priority
		))

	return false


func _get_target_assignment_method() -> StringName:
	# Converts request_state_name like "Sleep" into "assign_sleep_target".
	if target_assignment_method != &"":
		return target_assignment_method

	var state_text := String(request_state_name).to_snake_case()
	if state_text.is_empty():
		return &""

	return StringName("assign_%s_target" % state_text)


func can_serve_npc_need(
	npc_node: Node2D,
	requested_state_name: StringName,
	requested_value_name: StringName = &""
) -> bool:
	# Used by states searching the scene for a valid work/eat/rest/sleep spot.
	if npc_node == null or not is_instance_valid(npc_node):
		return false

	if requested_state_name != &"" and String(request_state_name) != String(requested_state_name):
		return false

	if not _is_inside_active_time_window():
		return false

	if (
		requested_value_name != &""
		and _canonical_value_key(value_name) != _canonical_value_key(requested_value_name)
	):
		return false

	if restrict_to_target_npc and String(target_npc_path) != "":
		if target_npc == null or not is_instance_valid(target_npc):
			_resolve_target()

		if target_npc != npc_node:
			return false

	if not _npc_id_is_allowed(npc_node):
		return false

	return _npc_has_required_tags(npc_node)


func _npc_id_is_allowed(npc_node: Node2D) -> bool:
	# Optional whitelist for spots that should only serve specific NPC ids.
	if allowed_npc_ids.is_empty():
		return true

	var npc_id := _get_npc_id(npc_node)
	for allowed_id in allowed_npc_ids:
		if String(allowed_id) == String(npc_id):
			return true

	return false


func _npc_has_required_tags(npc_node: Node2D) -> bool:
	# Optional tag gate, useful for spots reserved for family, workers, etc.
	if required_npc_tags.is_empty():
		return true

	for required_tag in required_npc_tags:
		if _npc_has_tag(npc_node, required_tag):
			continue

		return false

	return true


func _is_inside_active_time_window() -> bool:
	# Empty schedule means always active. Windows can cross midnight, like 22 -> 6.
	if active_time_windows.is_empty():
		return true

	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_method("get_snapshot"):
		return false

	var snapshot: Dictionary = world_time.call("get_snapshot")
	var hour := float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
	for window in active_time_windows:
		if not (window is Dictionary):
			continue

		if _time_window_contains_hour(window, hour):
			return true

	return false


func _time_window_contains_hour(window: Dictionary, hour: float) -> bool:
	var start_hour := _get_window_hour(window, "start_hour", "start", 0.0)
	var end_hour := _get_window_hour(window, "end_hour", "end", 24.0)
	start_hour = fposmod(start_hour, 24.0)
	end_hour = fposmod(end_hour, 24.0)
	var normalized_hour := fposmod(hour, 24.0)

	if is_equal_approx(start_hour, end_hour):
		return true

	if start_hour < end_hour:
		return normalized_hour >= start_hour and normalized_hour < end_hour

	return normalized_hour >= start_hour or normalized_hour < end_hour


func _get_window_hour(
	window: Dictionary,
	primary_key: String,
	fallback_key: String,
	default_value: float
) -> float:
	if window.has(primary_key):
		return float(window[primary_key])
	if window.has(fallback_key):
		return float(window[fallback_key])

	return default_value


func _npc_has_tag(npc_node: Node2D, tag: StringName) -> bool:
	# Checks both Godot groups and the custom npc_tags metadata set by SocialNpc.
	var tag_text := String(tag)
	if npc_node.is_in_group(tag_text):
		return true

	if not npc_node.has_meta("npc_tags"):
		return false

	var npc_tags = npc_node.get_meta("npc_tags")
	if not (npc_tags is Array):
		return false

	for npc_tag in npc_tags:
		if String(npc_tag) == tag_text:
			return true

	return false


func _get_npc_id(npc_node: Node2D) -> StringName:
	# Stable id lookup used by allowed_npc_ids.
	if npc_node.has_method("get_npc_location_id"):
		return StringName(String(npc_node.call("get_npc_location_id")))

	if npc_node.has_meta("npc_location_id"):
		return StringName(String(npc_node.get_meta("npc_location_id")))

	return StringName(String(npc_node.name))


func _get_display_value() -> float:
	return _get_target_value()


func _get_display_ratio(value: float) -> float:
	return _get_value_ratio(value)


func _get_target_value() -> float:
	# Reads from the state machine first, then falls back to raw SocialNpc stats.
	var key := _canonical_value_key(value_name)
	if machine != null and machine.has_method("get_value"):
		return float(machine.call("get_value", StringName(key), 0.0))

	var stats = target_npc.get("social_stats") if target_npc != null else null
	if not (stats is Dictionary):
		return 0.0

	var social_stats: Dictionary = stats
	if social_stats.has(key):
		return float(social_stats[key])

	return 0.0


func _get_value_ratio(value: float) -> float:
	# Normalized target value used to blend the spot color.
	if is_equal_approx(value_min, value_max):
		return 0.0

	return clampf(inverse_lerp(value_min, value_max, value), 0.0, 1.0)


func _machine_is_idle() -> bool:
	# Spots only auto-request actions when they will not interrupt the current state.
	if machine.current_state == null:
		return true

	return String(machine.current_state.name) == String(idle_state_name)


func _get_machine(target_node: Node) -> NpcStateMachine:
	# Accepts either a machine node or an NPC body with a child named NpcStateMachine.
	if target_node == null:
		return null

	var target_machine := target_node as NpcStateMachine
	if target_machine != null:
		return target_machine

	return target_node.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _connect_machine_signals() -> void:
	# Reconnects safely if the target NPC changes or gets recreated.
	if connected_machine == machine:
		return

	if connected_machine != null and is_instance_valid(connected_machine):
		var old_callback := Callable(self, "_on_machine_values_changed")
		if connected_machine.values_changed.is_connected(old_callback):
			connected_machine.values_changed.disconnect(old_callback)

	connected_machine = machine
	if connected_machine == null:
		return

	var callback := Callable(self, "_on_machine_values_changed")
	if not connected_machine.values_changed.is_connected(callback):
		connected_machine.values_changed.connect(callback)


func is_work_spot() -> bool:
	return false


func _canonical_value_key(value_key) -> String:
	# Allows old exported names like work_need/talk_interest to keep working.
	var key := String(value_key)
	if VALUE_ALIASES.has(key):
		return String(VALUE_ALIASES[key])

	return key


func _record_watchdog_marker(source: StringName, detail: String = "") -> void:
	var watchdog := get_node_or_null("/root/PerformanceWatchdog")
	if watchdog != null and watchdog.has_method("record_marker"):
		watchdog.call("record_marker", source, detail)
