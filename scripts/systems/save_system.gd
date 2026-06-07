class_name GameSaveSystem extends Node

signal save_finished(success: bool, save_path: String)
signal load_finished(success: bool, save_path: String)

const SAVE_VERSION: int = 2
const DEFAULT_SLOT: String = "slot_1"
const SAVEABLE_GROUP: StringName = &"saveable"
const SAVE_DIR: String = "user://saves"
const NPC_LOCATIONS_PATH: String = "/root/NpcLocations"
const RELATIONSHIPS_PATH: String = "/root/Relationships"

var global_values: Dictionary = {}
var pending_save_data: Dictionary = {}
var active_slot: String = DEFAULT_SLOT


func save_game(slot: String = DEFAULT_SLOT) -> bool:
	active_slot = slot

	var save_data := _build_save_data()
	var save_path := get_save_path(slot)
	var success := _write_save_file(save_path, save_data)

	save_finished.emit(success, save_path)
	return success


func save_current_game(slot: String = DEFAULT_SLOT) -> bool:
	return save_game(slot)


func load_game(slot: String = DEFAULT_SLOT) -> bool:
	active_slot = slot

	var save_path := get_save_path(slot)
	var save_data := _read_save_file(save_path)
	if save_data.is_empty():
		load_finished.emit(false, save_path)
		return false

	pending_save_data = save_data
	var loaded_global_values = _decode_value(save_data.get("global_values", {}))
	global_values = loaded_global_values if loaded_global_values is Dictionary else {}
	_apply_system_save_data(RELATIONSHIPS_PATH, save_data.get("relationships", {}))
	_apply_system_save_data(NPC_LOCATIONS_PATH, save_data.get("npc_locations", {}))

	var scene_path := String(save_data.get("scene_path", ""))
	if scene_path.is_empty():
		call_deferred("_apply_pending_save_data")
		return true

	var error := get_tree().change_scene_to_file(scene_path)
	if error != OK:
		push_warning("Could not load saved scene: %s" % scene_path)
		pending_save_data.clear()
		load_finished.emit(false, save_path)
		return false

	call_deferred("_apply_pending_save_data")
	return true


func continue_game(slot: String = DEFAULT_SLOT) -> bool:
	return load_game(slot)


func save_exists(slot: String = DEFAULT_SLOT) -> bool:
	return FileAccess.file_exists(get_save_path(slot))


func delete_save(slot: String = DEFAULT_SLOT) -> bool:
	var save_path := get_save_path(slot)
	if not FileAccess.file_exists(save_path):
		return true

	var error := DirAccess.remove_absolute(save_path)
	return error == OK


func get_save_path(slot: String = DEFAULT_SLOT) -> String:
	return "%s/%s.json" % [SAVE_DIR, slot]


func set_value(key: StringName, value) -> void:
	# Use this for values that are not owned by one scene node, like quest flags or world counters.
	global_values[String(key)] = value


func get_value(key: StringName, fallback = null):
	return global_values.get(String(key), fallback)


func erase_value(key: StringName) -> void:
	global_values.erase(String(key))


func clear_runtime_values() -> void:
	global_values.clear()
	pending_save_data.clear()
	_apply_system_save_data(RELATIONSHIPS_PATH, {})
	_apply_system_save_data(NPC_LOCATIONS_PATH, {})


func _build_save_data() -> Dictionary:
	var current_scene := get_tree().current_scene
	var scene_path := ""
	if current_scene != null:
		scene_path = current_scene.scene_file_path

	var save_data := {
		"version": SAVE_VERSION,
		"saved_at_unix_time": Time.get_unix_time_from_system(),
		"scene_path": scene_path,
		"global_values": _encode_value(global_values),
		"npc_locations": _encode_value(_get_system_save_data(NPC_LOCATIONS_PATH)),
		"relationships": _encode_value(_get_system_save_data(RELATIONSHIPS_PATH)),
		"nodes": {},
	}

	for node in get_tree().get_nodes_in_group(SAVEABLE_GROUP):
		if node == null or not is_instance_valid(node):
			continue

		var save_id := _get_node_save_id(node)
		if save_id.is_empty():
			continue

		var node_data := _get_node_save_data(node)
		if node_data.is_empty():
			continue

		save_data["nodes"][save_id] = _encode_value(node_data)

	return save_data


func _apply_pending_save_data() -> void:
	# Scene changes finish on the next frame, so wait before looking for saveable nodes.
	await get_tree().process_frame
	await get_tree().process_frame

	if pending_save_data.is_empty():
		return

	var save_data := pending_save_data.duplicate(true)
	pending_save_data.clear()
	_apply_save_data_to_current_scene(save_data)
	load_finished.emit(true, get_save_path(active_slot))


func _apply_save_data_to_current_scene(save_data: Dictionary) -> void:
	var saved_nodes = save_data.get("nodes", {})
	if not (saved_nodes is Dictionary):
		return

	for node in get_tree().get_nodes_in_group(SAVEABLE_GROUP):
		if node == null or not is_instance_valid(node):
			continue

		var save_id := _get_node_save_id(node)
		if save_id.is_empty() or not saved_nodes.has(save_id):
			continue

		var decoded_node_data = _decode_value(saved_nodes[save_id])
		if not (decoded_node_data is Dictionary):
			continue

		var node_data: Dictionary = decoded_node_data
		_apply_node_save_data(node, node_data)


func _get_node_save_id(node: Node) -> String:
	# Prefer an explicit id. Node paths work for experiments, but named ids survive scene refactors.
	if node.has_method("get_save_id"):
		return String(node.call("get_save_id")).strip_edges()

	var configured_id = _get_property_if_present(node, &"save_id")
	if configured_id != null:
		return String(configured_id).strip_edges()

	return ""


func _get_node_save_data(node: Node) -> Dictionary:
	# Add get_save_data/apply_save_data on complex nodes. For simple nodes, use SaveableValues.
	if node.has_method("get_save_data"):
		var method_data = node.call("get_save_data")
		if method_data is Dictionary:
			return method_data

	var property_names = _get_property_if_present(node, &"save_properties")
	if property_names is Array:
		var data := {}
		for property_name in property_names:
			data[String(property_name)] = node.get(StringName(String(property_name)))
		return data

	return {}


func _apply_node_save_data(node: Node, node_data: Dictionary) -> void:
	if node.has_method("apply_save_data"):
		node.call("apply_save_data", node_data)
		return

	var property_names = _get_property_if_present(node, &"save_properties")
	if property_names is Array:
		for property_name in property_names:
			var key := String(property_name)
			if node_data.has(key):
				node.set(StringName(key), node_data[key])


func _get_system_save_data(system_path: String) -> Dictionary:
	var system := get_node_or_null(system_path)
	if system == null or not system.has_method("get_save_data"):
		return {}

	var system_data = system.call("get_save_data")
	if system_data is Dictionary:
		return system_data

	return {}


func _apply_system_save_data(system_path: String, encoded_data) -> void:
	var system := get_node_or_null(system_path)
	if system == null or not system.has_method("apply_save_data"):
		return

	var decoded_data = _decode_value(encoded_data)
	var system_data := {}
	if decoded_data is Dictionary:
		system_data = decoded_data

	system.call("apply_save_data", system_data)


func _get_property_if_present(node: Object, property_name: StringName):
	for property in node.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return node.get(property_name)

	return null


func _write_save_file(save_path: String, save_data: Dictionary) -> bool:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		var dir_error := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
		if dir_error != OK:
			push_warning("Could not create save directory: %s" % SAVE_DIR)
			return false

	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not write save file: %s" % save_path)
		return false

	file.store_string(JSON.stringify(save_data, "\t"))
	return true


func _read_save_file(save_path: String) -> Dictionary:
	if not FileAccess.file_exists(save_path):
		return {}

	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		push_warning("Could not read save file: %s" % save_path)
		return {}

	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		push_warning("Save file is not valid JSON data: %s" % save_path)
		return {}

	return parsed


func _encode_value(value):
	match typeof(value):
		TYPE_DICTIONARY:
			var encoded := {}
			for key in value.keys():
				encoded[String(key)] = _encode_value(value[key])
			return encoded
		TYPE_ARRAY:
			var encoded_array := []
			for item in value:
				encoded_array.append(_encode_value(item))
			return encoded_array
		TYPE_VECTOR2:
			return {"__type": "Vector2", "x": value.x, "y": value.y}
		TYPE_VECTOR2I:
			return {"__type": "Vector2i", "x": value.x, "y": value.y}
		TYPE_COLOR:
			return {"__type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_STRING_NAME:
			return String(value)
		TYPE_NODE_PATH:
			return String(value)
		TYPE_OBJECT:
			return null
		_:
			return value


func _decode_value(value):
	if value is Dictionary:
		if value.has("__type"):
			match String(value["__type"]):
				"Vector2":
					return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
				"Vector2i":
					return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
				"Color":
					return Color(
						float(value.get("r", 1.0)),
						float(value.get("g", 1.0)),
						float(value.get("b", 1.0)),
						float(value.get("a", 1.0))
					)

		var decoded := {}
		for key in value.keys():
			decoded[String(key)] = _decode_value(value[key])
		return decoded

	if value is Array:
		var decoded_array := []
		for item in value:
			decoded_array.append(_decode_value(item))
		return decoded_array

	return value
