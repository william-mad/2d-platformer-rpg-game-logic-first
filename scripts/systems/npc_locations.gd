extends Node

signal npc_registered(npc_id: String, npc: Node, scene_path: String)
signal npc_travelled(npc_id: String, from_scene_path: String, to_scene_path: String)
signal npc_spawned(npc_id: String, npc: Node, scene_path: String)

@export var return_check_seconds: float = 60.0
@export_range(0.0, 1.0, 0.01) var return_chance_per_check: float = 0.18
@export var randomize_spawn_positions: bool = true

var npc_records: Dictionary = {}
var live_npcs: Dictionary = {}
var active_scene_context: Node
var active_scene_path: String = ""
var return_timer: float = 0.0

var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	_update_return_processing()


func _process(delta: float) -> void:
	return_timer += delta
	if return_timer < return_check_seconds:
		return

	return_timer = 0.0
	_try_return_travelling_npcs()


func register_npc(npc: Node) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false

	var npc_id := get_npc_id(npc)
	if npc_id.is_empty():
		return true

	var current_scene_path := get_current_scene_path()
	var npc_scene_path := _get_npc_scene_path(npc)
	var created_record := false

	if not npc_records.has(npc_id):
		npc_records[npc_id] = _build_initial_record(npc_id, npc, current_scene_path, npc_scene_path)
		created_record = true
	else:
		_refresh_record_from_node(npc_records[npc_id], npc, npc_scene_path)

	var record: Dictionary = npc_records[npc_id]
	var expected_scene_path := String(record.get("scene_path", current_scene_path))
	if not expected_scene_path.is_empty() and expected_scene_path != current_scene_path:
		return false

	if not created_record:
		var should_randomize_position := bool(record.get("spawn_random", false)) and active_scene_path == current_scene_path
		_apply_record_to_npc(npc, record, should_randomize_position)
		if should_randomize_position:
			record["spawn_random"] = false

	var existing_npc = live_npcs.get(npc_id, null) as Node
	if existing_npc != null and is_instance_valid(existing_npc) and not existing_npc.is_queued_for_deletion() and existing_npc != npc:
		return false

	live_npcs[npc_id] = npc
	record["scene_path"] = current_scene_path
	record["last_position"] = _get_node_position(npc)
	record["node_state"] = _get_npc_state(npc)
	npc_records[npc_id] = record

	npc_registered.emit(npc_id, npc, current_scene_path)
	_record_watchdog_marker(&"npc_locations:register", "%s %s" % [npc_id, current_scene_path.get_file()])
	return true


func unregister_npc(npc: Node) -> void:
	if npc == null:
		return

	var npc_id := get_npc_id(npc)
	if npc_id.is_empty():
		return

	var existing_npc = live_npcs.get(npc_id, null) as Node
	if existing_npc == npc:
		if npc_records.has(npc_id):
			var record: Dictionary = npc_records[npc_id]
			record["node_state"] = _get_npc_state(npc)
			record["last_position"] = _get_node_position(npc)
			npc_records[npc_id] = record

		live_npcs.erase(npc_id)


func request_travel(npc: Node, target_scene_path: String) -> bool:
	if npc == null or target_scene_path.is_empty():
		return false

	if target_scene_path == get_current_scene_path():
		return false

	var npc_id := get_npc_id(npc)
	if npc_id.is_empty():
		return false

	if not npc_records.has(npc_id):
		register_npc(npc)

	if not npc_records.has(npc_id):
		return false

	var record: Dictionary = npc_records[npc_id]
	record["node_state"] = _get_npc_state(npc)
	record["last_position"] = _get_node_position(npc)
	_move_record_to_scene(npc_id, record, target_scene_path, true)
	_record_watchdog_marker(&"npc_locations:travel", "%s -> %s" % [npc_id, target_scene_path.get_file()])

	live_npcs.erase(npc_id)
	npc.queue_free()
	return true


func activate_scene(scene_context: Node) -> void:
	active_scene_context = scene_context
	active_scene_path = _get_context_scene_path(scene_context)
	_record_watchdog_marker(&"npc_locations:activate", "%s records=%d" % [active_scene_path.get_file(), npc_records.size()])
	call_deferred("_spawn_missing_npcs_for_active_scene")


func get_npc_location(npc_id: String) -> Dictionary:
	if not npc_records.has(npc_id):
		return {}

	return npc_records[npc_id].duplicate(true)


func get_all_locations() -> Dictionary:
	return npc_records.duplicate(true)


func get_save_data() -> Dictionary:
	_refresh_live_records_for_save()
	return {
		"active_scene_path": active_scene_path,
		"return_timer": return_timer,
		"records": npc_records.duplicate(true),
	}


func apply_save_data(data: Dictionary) -> void:
	live_npcs.clear()
	npc_records.clear()
	active_scene_context = null
	active_scene_path = ""
	return_timer = 0.0

	var saved_records = data.get("records", data)
	if not (saved_records is Dictionary):
		_update_return_processing()
		return

	for npc_id_key in saved_records.keys():
		var saved_record = saved_records[npc_id_key]
		if not (saved_record is Dictionary):
			continue

		var npc_id := String(npc_id_key).strip_edges()
		if npc_id.is_empty():
			npc_id = String(saved_record.get("npc_id", "")).strip_edges()
		if npc_id.is_empty():
			continue

		npc_records[npc_id] = _normalize_loaded_record(npc_id, saved_record)

	_update_return_processing()


func get_npc_id(npc: Node) -> String:
	if npc == null:
		return ""

	if npc.has_method("get_npc_location_id"):
		var method_id := String(npc.call("get_npc_location_id")).strip_edges()
		if not method_id.is_empty():
			return method_id

	if npc.has_meta("npc_location_id"):
		var meta_id := String(npc.get_meta("npc_location_id")).strip_edges()
		if not meta_id.is_empty():
			return meta_id

	if npc.has_method("get_relationship_id"):
		var relationship_id := String(npc.call("get_relationship_id")).strip_edges()
		if not relationship_id.is_empty():
			return relationship_id

	if npc.is_inside_tree():
		return String(npc.get_path())

	return ""


func get_current_scene_path() -> String:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return ""

	return current_scene.scene_file_path


func _build_initial_record(
	npc_id: String,
	npc: Node,
	current_scene_path: String,
	npc_scene_path: String
) -> Dictionary:
	return {
		"npc_id": npc_id,
		"node_name": npc.name,
		"npc_scene_path": npc_scene_path,
		"home_scene_path": current_scene_path,
		"scene_path": current_scene_path,
		"previous_scene_path": "",
		"last_position": _get_node_position(npc),
		"node_state": _get_npc_state(npc),
		"spawn_random": false,
		"last_travel_msec": 0,
	}


func _refresh_record_from_node(record: Dictionary, npc: Node, npc_scene_path: String) -> void:
	record["node_name"] = npc.name
	if String(record.get("npc_scene_path", "")).is_empty() and not npc_scene_path.is_empty():
		record["npc_scene_path"] = npc_scene_path


func _refresh_live_records_for_save() -> void:
	for npc_id_key in live_npcs.keys():
		var npc_id := String(npc_id_key)
		var live_npc = live_npcs[npc_id_key] as Node
		if live_npc == null or not is_instance_valid(live_npc) or live_npc.is_queued_for_deletion():
			live_npcs.erase(npc_id_key)
			continue

		var current_scene_path := get_current_scene_path()
		var npc_scene_path := _get_npc_scene_path(live_npc)
		var record: Dictionary = {}

		if npc_records.has(npc_id) and npc_records[npc_id] is Dictionary:
			record = npc_records[npc_id]
		else:
			record = _build_initial_record(npc_id, live_npc, current_scene_path, npc_scene_path)

		if current_scene_path.is_empty():
			current_scene_path = String(record.get("scene_path", ""))

		_refresh_record_from_node(record, live_npc, npc_scene_path)
		record["scene_path"] = current_scene_path
		record["last_position"] = _get_node_position(live_npc)
		record["node_state"] = _get_npc_state(live_npc)
		npc_records[npc_id] = record


func _normalize_loaded_record(npc_id: String, saved_record: Dictionary) -> Dictionary:
	var record := saved_record.duplicate(true)
	record["npc_id"] = String(record.get("npc_id", npc_id))
	record["node_name"] = String(record.get("node_name", npc_id))
	record["npc_scene_path"] = String(record.get("npc_scene_path", ""))
	record["home_scene_path"] = String(record.get("home_scene_path", ""))
	record["scene_path"] = String(record.get("scene_path", ""))
	record["previous_scene_path"] = String(record.get("previous_scene_path", ""))
	record["spawn_random"] = bool(record.get("spawn_random", false))

	if not (record.get("last_position", null) is Vector2):
		record["last_position"] = Vector2.ZERO

	if not (record.get("node_state", null) is Dictionary):
		record["node_state"] = {}

	if String(record.get("scene_path", "")).is_empty():
		record["scene_path"] = String(record.get("home_scene_path", ""))

	if not String(record.get("previous_scene_path", "")).is_empty():
		record["last_travel_msec"] = Time.get_ticks_msec()
	else:
		record["last_travel_msec"] = int(record.get("last_travel_msec", 0))

	return record


func _move_record_to_scene(
	npc_id: String,
	record: Dictionary,
	target_scene_path: String,
	spawn_random: bool
) -> void:
	var from_scene_path := String(record.get("scene_path", ""))
	if from_scene_path == target_scene_path:
		return

	record["previous_scene_path"] = from_scene_path
	record["scene_path"] = target_scene_path
	record["spawn_random"] = spawn_random
	record["last_travel_msec"] = Time.get_ticks_msec()
	npc_records[npc_id] = record

	npc_travelled.emit(npc_id, from_scene_path, target_scene_path)
	_emit_location_event(npc_id, from_scene_path, target_scene_path)

	if target_scene_path == active_scene_path:
		call_deferred("_spawn_missing_npcs_for_active_scene")

	_update_return_processing()


func _try_return_travelling_npcs() -> void:
	var now := Time.get_ticks_msec()
	var min_travel_age_msec := int(return_check_seconds * 1000.0)
	var returned_count := 0

	for npc_id in npc_records.keys():
		var record: Dictionary = npc_records[npc_id]
		var previous_scene_path := String(record.get("previous_scene_path", ""))
		var scene_path := String(record.get("scene_path", ""))
		if previous_scene_path.is_empty() or previous_scene_path == scene_path:
			continue

		var last_travel_msec := int(record.get("last_travel_msec", 0))
		if now - last_travel_msec < min_travel_age_msec:
			continue

		if rng.randf() > return_chance_per_check:
			continue

		_return_npc_to_previous_scene(String(npc_id), record)
		returned_count += 1

	_update_return_processing()
	if returned_count > 0:
		_record_watchdog_marker(&"npc_locations:return", "%d" % returned_count)


func _return_npc_to_previous_scene(npc_id: String, record: Dictionary) -> void:
	var return_scene_path := String(record.get("previous_scene_path", ""))
	if return_scene_path.is_empty():
		return

	var live_npc = live_npcs.get(npc_id, null) as Node
	if live_npc != null and is_instance_valid(live_npc):
		record["node_state"] = _get_npc_state(live_npc)
		record["last_position"] = _get_node_position(live_npc)
		live_npc.queue_free()
		live_npcs.erase(npc_id)

	_move_record_to_scene(npc_id, record, return_scene_path, true)


func _spawn_missing_npcs_for_active_scene() -> void:
	if active_scene_context == null or not is_instance_valid(active_scene_context):
		return

	var spawned_count := 0
	var refreshed_count := 0
	for npc_id in npc_records.keys():
		var record: Dictionary = npc_records[npc_id]
		if String(record.get("scene_path", "")) != active_scene_path:
			continue

		var live_npc = live_npcs.get(npc_id, null) as Node
		if live_npc != null and is_instance_valid(live_npc) and not live_npc.is_queued_for_deletion():
			var should_randomize_position := bool(record.get("spawn_random", false))
			_apply_record_to_npc(live_npc, record, should_randomize_position)
			record["node_state"] = _get_npc_state(live_npc)
			record["last_position"] = _get_node_position(live_npc)
			record["spawn_random"] = false
			npc_records[npc_id] = record
			refreshed_count += 1
			continue

		if _spawn_record_in_active_scene(String(npc_id), record):
			spawned_count += 1

	if spawned_count > 0 or refreshed_count > 0:
		_record_watchdog_marker(
			&"npc_locations:spawn_missing",
			"spawned=%d refreshed=%d" % [spawned_count, refreshed_count]
		)


func _spawn_record_in_active_scene(npc_id: String, record: Dictionary) -> bool:
	var npc_scene_path := String(record.get("npc_scene_path", ""))
	if npc_scene_path.is_empty():
		return false

	var packed_scene := load(npc_scene_path) as PackedScene
	if packed_scene == null:
		push_warning("Could not load NPC scene: %s" % npc_scene_path)
		return false

	var parent := _get_context_spawn_parent(active_scene_context)
	if parent == null:
		return false

	var npc := packed_scene.instantiate()
	npc.name = String(record.get("node_name", npc_id))

	if _has_property(npc, &"location_id"):
		npc.set("location_id", StringName(npc_id))
	if _has_property(npc, &"npc_scene_path"):
		npc.set("npc_scene_path", npc_scene_path)
	if npc.has_method("apply_npc_location_save_data"):
		npc.call("apply_npc_location_save_data", record.get("node_state", {}))
	if _has_property(npc, &"location_id"):
		npc.set("location_id", StringName(npc_id))
	if _has_property(npc, &"npc_scene_path"):
		npc.set("npc_scene_path", npc_scene_path)

	var spawn_position := _get_spawn_position(active_scene_context, npc_id, record)
	record["last_position"] = spawn_position
	record["spawn_random"] = false
	npc_records[npc_id] = record

	var npc_2d := npc as Node2D
	if npc_2d != null:
		npc_2d.position = spawn_position

	parent.add_child(npc)

	_place_npc(npc, spawn_position)

	live_npcs[npc_id] = npc
	record["last_position"] = spawn_position
	npc_records[npc_id] = record

	npc_spawned.emit(npc_id, npc, active_scene_path)
	return true


func _apply_record_to_npc(npc: Node, record: Dictionary, use_random_position: bool) -> void:
	if npc.has_method("apply_npc_location_save_data"):
		npc.call("apply_npc_location_save_data", record.get("node_state", {}))

	if use_random_position:
		_place_npc(npc, _get_spawn_position(active_scene_context, get_npc_id(npc), record))
		return

	var position_value = record.get("last_position", null)
	if position_value is Vector2:
		_place_npc(npc, position_value)


func _place_npc(npc: Node, spawn_position: Vector2) -> void:
	if npc.has_method("set_npc_location_position"):
		npc.call("set_npc_location_position", spawn_position)
		return

	var npc_2d := npc as Node2D
	if npc_2d != null:
		npc_2d.global_position = spawn_position


func _get_spawn_position(scene_context: Node, npc_id: String, record: Dictionary) -> Vector2:
	if randomize_spawn_positions and scene_context != null and scene_context.has_method("get_random_ground_spawn_position"):
		return scene_context.call("get_random_ground_spawn_position", npc_id)

	var position_value = record.get("last_position", Vector2.ZERO)
	if position_value is Vector2:
		return position_value

	return Vector2.ZERO


func _get_context_spawn_parent(scene_context: Node) -> Node:
	if scene_context != null and scene_context.has_method("get_spawn_parent"):
		var spawn_parent := scene_context.call("get_spawn_parent") as Node
		if spawn_parent != null:
			return spawn_parent

	return get_tree().current_scene


func _get_context_scene_path(scene_context: Node) -> String:
	if scene_context != null and scene_context.has_method("get_tracked_scene_path"):
		return String(scene_context.call("get_tracked_scene_path"))

	return get_current_scene_path()


func _get_npc_scene_path(npc: Node) -> String:
	if npc.has_method("get_npc_scene_path"):
		var method_path := String(npc.call("get_npc_scene_path")).strip_edges()
		if not method_path.is_empty():
			return method_path

	if _has_property(npc, &"npc_scene_path"):
		var property_path := String(npc.get("npc_scene_path")).strip_edges()
		if not property_path.is_empty():
			return property_path

	if not npc.scene_file_path.is_empty():
		return npc.scene_file_path

	return ""


func _get_npc_state(npc: Node) -> Dictionary:
	if npc.has_method("get_npc_location_save_data"):
		var state = npc.call("get_npc_location_save_data")
		if state is Dictionary:
			return state.duplicate(true)

	return {}


func _get_node_position(node: Node) -> Vector2:
	var node_2d := node as Node2D
	if node_2d == null:
		return Vector2.ZERO

	return node_2d.global_position


func _emit_location_event(npc_id: String, from_scene_path: String, to_scene_path: String) -> void:
	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null or not event_bus.has_method("emit_scene_event"):
		return

	event_bus.call("emit_scene_event", &"npc_location_changed", {
		"npc_id": npc_id,
		"from_scene_path": from_scene_path,
		"to_scene_path": to_scene_path,
		"tags": [&"npc", &"location"],
	}, get_tree().current_scene)


func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return true

	return false


func _update_return_processing() -> void:
	set_process(_has_travelling_records())


func _has_travelling_records() -> bool:
	for npc_id in npc_records.keys():
		var record = npc_records[npc_id]
		if not (record is Dictionary):
			continue

		var previous_scene_path := String(record.get("previous_scene_path", ""))
		if previous_scene_path.is_empty():
			continue

		if previous_scene_path != String(record.get("scene_path", "")):
			return true

	return false


func _record_watchdog_marker(source: StringName, detail: String = "") -> void:
	var watchdog := get_node_or_null("/root/PerformanceWatchdog")
	if watchdog != null and watchdog.has_method("record_marker"):
		watchdog.call("record_marker", source, detail)
