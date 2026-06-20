class_name NpcNeedSpot extends Area2D

const VALUE_ALIASES := {
	"sleepiness": "sleep_need",
	"work_need": "boredom",
	"talk_interest": "talk_need",
}

@export_group("Save")
@export var save_id: String = ""
@export var spot_id: StringName = &""

@export_group("World Simulation")
@export var world_definition: NpcSpotDefinition

@export_group("Target")
@export var target_npc_path: NodePath
@export var value_name: StringName = &"hunger"
@export var value_min: float = 0.0
@export var value_max: float = 100.0

@export_group("Serving")
@export var restrict_to_target_npc: bool = true
# Clear owner controls for plug-and-play spots. Leave these empty to use the legacy target_npc_path rule.
@export var owner_npc_paths: Array[NodePath] = []
@export var owner_npc_ids: Array[StringName] = []
# Legacy name kept for older scenes; owner_npc_ids is the clearer version.
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
var owner_npcs: Array[Node2D] = []
var machine: NpcStateMachine
var connected_machine: NpcStateMachine
var request_cooldown: float = 0.0
var current_value: float = 0.0
var visual_refresh_timer: float = 0.0
var request_check_timer: float = 0.0
var visual_dirty: bool = true
var request_dirty: bool = true


func _ready() -> void:
	_apply_world_definition()
	add_to_group("npc_need_spot")
	_register_world_spot()
	call_deferred("_setup")


func _exit_tree() -> void:
	_unregister_world_spot()
	if connected_machine == null or not is_instance_valid(connected_machine):
		return

	var callback := Callable(self, "_on_machine_values_changed")
	if connected_machine.values_changed.is_connected(callback):
		connected_machine.values_changed.disconnect(callback)


func _process(delta: float) -> void:
	request_cooldown = maxf(request_cooldown - delta, 0.0)

	var target_needs_resolve := (
		String(target_npc_path) != ""
		and (target_npc == null or not is_instance_valid(target_npc))
	)
	if target_needs_resolve or _owner_paths_need_resolve():
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


func get_world_spot_id() -> StringName:
	return spot_id


func _apply_world_definition() -> void:
	# Cross-scene spots share one resource for live behavior and unloaded simulation.
	if world_definition == null:
		return

	spot_id = world_definition.spot_id
	value_name = world_definition.value_name
	need_threshold = world_definition.need_threshold
	request_state_name = world_definition.state_name
	request_priority = world_definition.priority
	target_assignment_method = world_definition.target_assignment_method
	owner_npc_ids = world_definition.owner_npc_ids.duplicate()
	active_time_windows = world_definition.active_time_windows.duplicate(true)


func get_save_data() -> Dictionary:
	return {}


func apply_save_data(_data: Dictionary) -> void:
	pass


func _resolve_target() -> void:
	# Finds the target NPC and its state machine, if this spot is assigned to one.
	target_npc = get_node_or_null(target_npc_path)
	owner_npcs = _resolve_owner_npcs()
	machine = _get_machine(target_npc)
	_connect_machine_signals()


func _resolve_owner_npcs() -> Array[Node2D]:
	var resolved_owners: Array[Node2D] = []
	for owner_path in owner_npc_paths:
		if String(owner_path) == "":
			continue

		var owner_npc := get_node_or_null(owner_path) as Node2D
		if owner_npc == null or not is_instance_valid(owner_npc):
			continue

		if resolved_owners.has(owner_npc):
			continue

		resolved_owners.append(owner_npc)

	return resolved_owners


func _owner_paths_need_resolve() -> bool:
	if owner_npc_paths.is_empty():
		return false

	var configured_path_count := 0
	for owner_path in owner_npc_paths:
		if String(owner_path) != "":
			configured_path_count += 1

	for owner_npc in owner_npcs:
		if owner_npc == null or not is_instance_valid(owner_npc):
			return true

	return owner_npcs.size() != configured_path_count


func _get_auto_request_npcs() -> Array[Node2D]:
	# Ownership filters candidates; it does not require one permanently linked live target.
	var request_npcs: Array[Node2D] = []
	for owner_npc in owner_npcs:
		if owner_npc == null or not is_instance_valid(owner_npc):
			continue
		if not request_npcs.has(owner_npc):
			request_npcs.append(owner_npc)

	var target_node := target_npc as Node2D
	if target_node != null and is_instance_valid(target_node) and not request_npcs.has(target_node):
		request_npcs.append(target_node)

	_append_live_owner_id_npcs(request_npcs)

	return request_npcs


func _append_live_owner_id_npcs(request_npcs: Array[Node2D]) -> void:
	if not is_inside_tree():
		return

	for candidate in get_tree().get_nodes_in_group("npc"):
		var npc_node := candidate as Node2D
		if npc_node == null or not is_instance_valid(npc_node):
			continue
		if request_npcs.has(npc_node):
			continue
		if not _npc_owner_is_allowed(npc_node):
			continue
		if not _npc_has_required_tags(npc_node):
			continue

		request_npcs.append(npc_node)


func _update_visual() -> void:
	# Multiple owners show the highest relevant need; ID owners can be read while off-screen.
	var display_value := _get_owner_display_value()
	if is_work_spot():
		current_value = _get_display_value()
	elif bool(display_value.get("found", false)):
		current_value = float(display_value.get("value", 0.0))
	elif not _has_explicit_owner_configuration():
		if zone_visual != null:
			zone_visual.color = low_need_color
		if label != null:
			label.text = "%s\nReady" % label_prefix
		return
	else:
		if zone_visual != null:
			zone_visual.color = missing_target_color
		if label != null:
			label.text = "%s\n--" % label_prefix
		return

	var ratio := _get_display_ratio(current_value)
	if zone_visual != null:
		zone_visual.color = low_need_color.lerp(high_need_color, ratio)

	if label != null:
		label.text = "%s\n%d" % [label_prefix, int(round(current_value))]


func _get_owner_display_value() -> Dictionary:
	var found := false
	var highest_value := 0.0
	for npc_node in _get_auto_request_npcs():
		var npc_machine := _get_machine(npc_node)
		var candidate_value := _get_npc_value(npc_node, npc_machine)
		if not found or candidate_value > highest_value:
			highest_value = candidate_value
			found = true

	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("get_npc_location"):
		for owner_id in _get_configured_owner_ids():
			var record: Dictionary = locations.call("get_npc_location", String(owner_id))
			var saved_value = _get_saved_record_value(record)
			if saved_value == null:
				continue
			var saved_candidate_value := float(saved_value)
			if not found or saved_candidate_value > highest_value:
				highest_value = saved_candidate_value
				found = true

	return {"found": found, "value": highest_value}


func _get_configured_owner_ids() -> Array[StringName]:
	var configured_ids: Array[StringName] = []
	for owner_id in owner_npc_ids:
		if not configured_ids.has(owner_id):
			configured_ids.append(owner_id)
	for allowed_id in allowed_npc_ids:
		if not configured_ids.has(allowed_id):
			configured_ids.append(allowed_id)

	return configured_ids


func _get_saved_record_value(record: Dictionary):
	if record.is_empty():
		return null
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return null
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return null

	var key := _canonical_value_key(value_name)
	if not social_stats.has(key):
		return null

	return float(social_stats[key])


func _has_explicit_owner_configuration() -> bool:
	return (
		(restrict_to_target_npc and String(target_npc_path) != "")
		or not owner_npc_paths.is_empty()
		or not owner_npc_ids.is_empty()
		or not allowed_npc_ids.is_empty()
	)


func _maybe_request_state() -> void:
	# If this spot's gate is open and the NPC is idle, ask it to use this exact spot.
	if not auto_request_when_idle:
		return
	if request_cooldown > 0.0:
		return
	if not _is_inside_active_time_window():
		return
	if request_state_name == &"":
		return

	for request_npc in _get_auto_request_npcs():
		if _maybe_request_state_for(request_npc):
			_record_watchdog_marker(&"need_spot:request", "%s -> %s" % [name, String(request_state_name)])
			request_cooldown = request_cooldown_seconds
			return


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


func _maybe_request_state_for(request_npc: Node2D) -> bool:
	if request_npc == null or not is_instance_valid(request_npc):
		return false
	if not can_serve_npc_need(request_npc, request_state_name, value_name):
		return false

	var request_machine := _get_machine(request_npc)
	if request_machine == null:
		return false
	if require_target_need_threshold and _get_npc_value(request_npc, request_machine) < need_threshold:
		return false
	if not _machine_is_idle(request_machine):
		return false

	return _request_target_state(request_machine)


func _request_target_state(request_machine: NpcStateMachine) -> bool:
	# Prefer specific assignment helpers so states know this exact spot is their target.
	var assignment_method := _get_target_assignment_method()
	if assignment_method != &"" and request_machine.has_method(assignment_method):
		return bool(request_machine.call(assignment_method, self))

	if request_machine.has_method("request_state"):
		return bool(request_machine.call(
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

	if not _npc_owner_is_allowed(npc_node):
		return false

	return _npc_has_required_tags(npc_node)


func _npc_owner_is_allowed(npc_node: Node2D) -> bool:
	# Empty owner lists mean "serve anyone" unless legacy target_npc_path restriction is set.
	var has_legacy_target_owner := restrict_to_target_npc and String(target_npc_path) != ""
	var has_owner_paths := not owner_npc_paths.is_empty()
	var has_owner_ids := not owner_npc_ids.is_empty() or not allowed_npc_ids.is_empty()
	if not has_legacy_target_owner and not has_owner_paths and not has_owner_ids:
		return true

	if has_legacy_target_owner:
		if target_npc == null or not is_instance_valid(target_npc):
			_resolve_target()
		if target_npc == npc_node:
			return true

	for owner_npc in owner_npcs:
		if owner_npc == npc_node:
			return true

	var npc_id := _get_npc_id(npc_node)
	for owner_id in owner_npc_ids:
		if String(owner_id) == String(npc_id):
			return true

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
	return _get_npc_value(target_npc, machine)


func _get_npc_value(npc_node: Node, npc_machine: NpcStateMachine) -> float:
	if npc_node == null or not is_instance_valid(npc_node):
		return 0.0

	var key := _canonical_value_key(value_name)
	if npc_machine != null and npc_machine.has_method("get_value"):
		return float(npc_machine.call("get_value", StringName(key), 0.0))

	var stats = npc_node.get("social_stats")
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


func _machine_is_idle(target_machine: NpcStateMachine = null) -> bool:
	# Spots only auto-request actions when they will not interrupt the current state.
	if target_machine == null:
		target_machine = machine
	if target_machine == null:
		return false

	if target_machine.current_state == null:
		return true

	return String(target_machine.current_state.name) == String(idle_state_name)


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


func _register_world_spot() -> void:
	if spot_id == &"":
		return

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("register_live_spot"):
		simulator.call("register_live_spot", spot_id, self)


func _unregister_world_spot() -> void:
	if spot_id == &"":
		return

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("unregister_live_spot"):
		simulator.call("unregister_live_spot", spot_id, self)
