class_name GameSaveSystem extends Node

signal save_finished(success: bool, save_path: String)
signal load_finished(success: bool, save_path: String)

const SAVE_VERSION: int = 5
const DEFAULT_SLOT: String = "slot_1"
const SAVEABLE_GROUP: StringName = &"saveable"
const SAVE_DIR: String = "user://saves"
const WORLD_TIME_PATH: String = "/root/WorldTime"
const NPC_LOCATIONS_PATH: String = "/root/NpcLocations"
const NPC_WORLD_SIMULATION_PATH: String = "/root/NpcWorldSimulation"
const RELATIONSHIPS_PATH: String = "/root/Relationships"
const PROGRESSION_PATH: String = "/root/ProgressionSystem"

enum SaveFileReadStatus {
	VALID,
	MISSING,
	OPEN_FAILED,
	READ_FAILED,
	INVALID_JSON,
	NOT_DICTIONARY,
}

@export_range(1, 9, 1) var save_slot_count: int = 3

var global_values: Dictionary = {}
var pending_save_data: Dictionary = {}
var active_slot: String = DEFAULT_SLOT


func save_game(slot: String = "") -> bool:
	var normalized_slot := _normalize_slot(slot)
	active_slot = normalized_slot

	var save_data := _build_save_data()
	save_data["slot"] = normalized_slot

	var save_path := get_save_path(normalized_slot)
	var success := _write_save_file(save_path, save_data)

	save_finished.emit(success, save_path)
	return success


func save_current_game(slot: String = "") -> bool:
	return save_game(slot)


func load_game(slot: String = "") -> bool:
	var normalized_slot := _normalize_slot(slot)
	active_slot = normalized_slot

	var save_path := get_save_path(normalized_slot)
	var save_data := _read_save_file(save_path)
	if save_data.is_empty():
		load_finished.emit(false, save_path)
		return false

	pending_save_data = save_data
	var loaded_global_values = _decode_value(save_data.get("global_values", {}))
	global_values = loaded_global_values if loaded_global_values is Dictionary else {}
	_apply_system_save_data(WORLD_TIME_PATH, save_data.get("world_time", {}))
	_apply_system_save_data(RELATIONSHIPS_PATH, save_data.get("relationships", {}))
	_apply_system_save_data(PROGRESSION_PATH, save_data.get("progression", {}))
	_apply_system_save_data(NPC_WORLD_SIMULATION_PATH, save_data.get("npc_world_simulation", {}))
	_apply_system_save_data(NPC_LOCATIONS_PATH, save_data.get("npc_locations", {}))

	var scene_path := String(save_data.get("scene_path", ""))
	if scene_path.is_empty():
		call_deferred("_apply_pending_save_data")
		return true

	if _change_scene_with_loader_for_save(scene_path, save_path):
		return true

	var error := get_tree().change_scene_to_file(scene_path)
	if error != OK:
		push_warning("Could not load saved scene: %s" % scene_path)
		pending_save_data.clear()
		load_finished.emit(false, save_path)
		return false

	call_deferred("_apply_pending_save_data")
	return true


func continue_game(slot: String = "") -> bool:
	return load_game(slot)


func save_exists(slot: String = "") -> bool:
	var save_path := get_save_path(slot)
	if FileAccess.file_exists(save_path):
		return true

	var backup_result := _read_save_file_result(_get_backup_save_path(save_path))
	return _save_file_read_result_is_valid(backup_result)


func delete_save(slot: String = "") -> bool:
	var save_path := get_save_path(slot)
	var success := true
	success = _remove_save_file_if_exists(save_path) and success
	success = _remove_save_file_if_exists(_get_temporary_save_path(save_path)) and success
	success = _remove_save_file_if_exists(_get_backup_save_path(save_path)) and success
	return success


func get_save_path(slot: String = "") -> String:
	return "%s/%s.json" % [SAVE_DIR, _normalize_slot(slot)]


func set_active_slot(slot: String) -> void:
	active_slot = _normalize_slot(slot)


func get_active_slot() -> String:
	return _normalize_slot(active_slot)


func get_save_slots() -> Array[String]:
	var slots: Array[String] = []
	var slot_count := save_slot_count
	if slot_count < 1:
		slot_count = 1

	for index in range(slot_count):
		slots.append("slot_%d" % [index + 1])

	return slots


func has_any_save() -> bool:
	for slot in get_save_slots():
		if save_exists(slot):
			return true

	return false


func get_save_summaries() -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	for slot in get_save_slots():
		summaries.append(get_save_summary(slot))

	return summaries


func get_save_summary(slot: String = "") -> Dictionary:
	var normalized_slot := _normalize_slot(slot)
	var save_path := get_save_path(normalized_slot)
	var primary_exists := FileAccess.file_exists(save_path)
	var summary := {
		"slot": normalized_slot,
		"display_name": get_save_slot_display_name(normalized_slot),
		"save_path": save_path,
		"exists": save_exists(normalized_slot),
		"valid": false,
		"version": 0,
		"scene_path": "",
		"scene_name": "",
		"saved_at_unix_time": 0.0,
		"has_progression": false,
		"global_level": 1,
		"global_xp": 0,
		"progression": {},
	}

	if not bool(summary["exists"]):
		return summary

	var save_data: Dictionary
	if primary_exists:
		save_data = _read_save_file(save_path)
	else:
		var backup_result := _read_save_file_result(_get_backup_save_path(save_path))
		var backup_data = backup_result.get("data", {})
		if _save_file_read_result_is_valid(backup_result) and backup_data is Dictionary:
			save_data = backup_data
	if save_data.is_empty():
		return summary

	var scene_path := String(save_data.get("scene_path", ""))
	summary["valid"] = true
	summary["version"] = int(save_data.get("version", 0))
	summary["scene_path"] = scene_path
	summary["scene_name"] = _get_scene_display_name(scene_path)
	summary["saved_at_unix_time"] = float(save_data.get("saved_at_unix_time", 0.0))
	var progression_summary := _get_progression_summary_from_save_data(save_data)
	summary["progression"] = progression_summary
	summary["has_progression"] = bool(progression_summary.get("has_progression", false))
	summary["global_level"] = int(progression_summary.get("global_level", 1))
	summary["global_xp"] = int(progression_summary.get("global_xp", 0))
	return summary


func get_save_slot_display_name(slot: String = "") -> String:
	var normalized_slot := _normalize_slot(slot)
	if normalized_slot.begins_with("slot_"):
		var number_text := normalized_slot.substr(5)
		if number_text.is_valid_int():
			return "File %d" % int(number_text)

	return normalized_slot.replace("_", " ").capitalize()


func format_save_summary(summary: Dictionary, empty_label: String = "Empty") -> String:
	var display_name := String(summary.get("display_name", "Save File"))
	if not bool(summary.get("exists", false)):
		return "%s - %s" % [display_name, empty_label]
	if not bool(summary.get("valid", false)):
		return "%s - Unreadable save" % display_name

	var scene_name := String(summary.get("scene_name", ""))
	if scene_name.is_empty():
		scene_name = "Unknown scene"

	var progress_text := _format_progression_summary(summary)
	var saved_at := _format_saved_time(float(summary.get("saved_at_unix_time", 0.0)))
	if not progress_text.is_empty():
		if saved_at.is_empty():
			return "%s - %s - %s" % [display_name, progress_text, scene_name]

		return "%s - %s - %s - %s" % [display_name, progress_text, scene_name, saved_at]

	if saved_at.is_empty():
		return "%s - %s" % [display_name, scene_name]

	return "%s - %s - %s" % [display_name, scene_name, saved_at]


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
	_apply_system_save_data(WORLD_TIME_PATH, {})
	_apply_system_save_data(RELATIONSHIPS_PATH, {})
	_apply_system_save_data(PROGRESSION_PATH, {})
	_apply_system_save_data(NPC_WORLD_SIMULATION_PATH, {})
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
		"world_time": _encode_value(_get_system_save_data(WORLD_TIME_PATH)),
		"npc_locations": _encode_value(_get_system_save_data(NPC_LOCATIONS_PATH)),
		"npc_world_simulation": _encode_value(_get_system_save_data(NPC_WORLD_SIMULATION_PATH)),
		"relationships": _encode_value(_get_system_save_data(RELATIONSHIPS_PATH)),
		"progression": _encode_value(_get_system_save_data(PROGRESSION_PATH)),
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


func _change_scene_with_loader_for_save(scene_path: String, save_path: String) -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false
	if not scene_loader.has_signal(&"scene_load_finished"):
		return false

	var started := bool(scene_loader.call("change_scene", scene_path))
	if not started:
		return false

	var callback := Callable(self, "_on_save_scene_loaded").bind(save_path)
	scene_loader.connect(&"scene_load_finished", callback, CONNECT_ONE_SHOT)
	return true


func _on_save_scene_loaded(success: bool, _scene_path: String, save_path: String) -> void:
	if not success:
		pending_save_data.clear()
		load_finished.emit(false, save_path)
		return

	call_deferred("_apply_pending_save_data")


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
	var system_data: Dictionary = {}
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
			push_warning("Could not create save directory: %s (error %d)" % [SAVE_DIR, dir_error])
			return false

	var temporary_path := _get_temporary_save_path(save_path)
	var backup_path := _get_backup_save_path(save_path)
	var serialized_save := JSON.stringify(save_data, "\t")

	if not _remove_save_file_if_exists(temporary_path):
		return false

	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		push_warning(
			"Could not open temporary save file for writing: %s (error %d)"
			% [temporary_path, FileAccess.get_open_error()]
		)
		_remove_save_file_if_exists(temporary_path)
		return false

	file.store_string(serialized_save)
	file.flush()
	var write_error := file.get_error()
	file = null
	if write_error != OK:
		push_warning("Could not write temporary save file: %s (error %d)" % [temporary_path, write_error])
		_remove_save_file_if_exists(temporary_path)
		return false

	if not _temporary_save_file_is_valid(temporary_path):
		_remove_save_file_if_exists(temporary_path)
		return false

	if not _remove_save_file_if_exists(backup_path):
		_remove_save_file_if_exists(temporary_path)
		return false

	var had_primary := FileAccess.file_exists(save_path)
	if had_primary and not _rename_save_file(save_path, backup_path, "back up previous save"):
		_remove_save_file_if_exists(temporary_path)
		return false

	if _rename_save_file(temporary_path, save_path, "promote temporary save"):
		return true

	if had_primary:
		_rename_save_file(backup_path, save_path, "restore previous save")

	_remove_save_file_if_exists(temporary_path)
	return false


func _get_temporary_save_path(save_path: String) -> String:
	return "%s.tmp" % save_path


func _get_backup_save_path(save_path: String) -> String:
	return "%s.bak" % save_path


func _temporary_save_file_is_valid(save_path: String) -> bool:
	var result := _read_save_file_result(save_path)
	if _save_file_read_result_is_valid(result):
		return true

	push_warning(
		"Temporary save file failed validation: %s (%s, error %d)"
		% [
			save_path,
			_save_file_read_status_text(int(result.get("status", SaveFileReadStatus.MISSING))),
			int(result.get("error", FAILED)),
		]
	)
	return false


func _remove_save_file_if_exists(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return true

	var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if error != OK:
		push_warning("Could not remove save file: %s (error %d)" % [path, error])
		return false

	return true


func _rename_save_file(from_path: String, to_path: String, action: String) -> bool:
	var error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(from_path),
		ProjectSettings.globalize_path(to_path)
	)
	if error != OK:
		push_warning(
			"Could not %s from %s to %s (error %d)"
			% [action, from_path, to_path, error]
		)
		return false

	return true


func _read_save_file(save_path: String) -> Dictionary:
	var primary_result := _read_save_file_result(save_path)
	if _save_file_read_result_is_valid(primary_result):
		var primary_data = primary_result.get("data", {})
		if primary_data is Dictionary:
			return primary_data

	var backup_path := _get_backup_save_path(save_path)
	push_warning(
		"Primary save failed, attempting backup: %s (%s, error %d); backup: %s"
		% [
			save_path,
			_save_file_read_status_text(int(primary_result.get("status", SaveFileReadStatus.MISSING))),
			int(primary_result.get("error", FAILED)),
			backup_path,
		]
	)

	var backup_result := _read_save_file_result(backup_path)
	if not _save_file_read_result_is_valid(backup_result):
		push_warning(
			"Backup save is not available for failed primary: %s (%s, error %d); backup: %s (%s, error %d)"
			% [
				save_path,
				_save_file_read_status_text(int(primary_result.get("status", SaveFileReadStatus.MISSING))),
				int(primary_result.get("error", FAILED)),
				backup_path,
				_save_file_read_status_text(int(backup_result.get("status", SaveFileReadStatus.MISSING))),
				int(backup_result.get("error", FAILED)),
			]
		)
		return {}

	var restored := _restore_backup_to_primary(save_path, backup_path)
	if restored:
		push_warning("Recovered save from backup and restored primary: %s from %s" % [save_path, backup_path])
	else:
		push_warning("Recovered save from backup but could not restore primary: %s from %s" % [save_path, backup_path])

	var backup_data = backup_result.get("data", {})
	if backup_data is Dictionary:
		return backup_data

	return {}


func _read_save_file_result(save_path: String) -> Dictionary:
	if not FileAccess.file_exists(save_path):
		return {
			"status": SaveFileReadStatus.MISSING,
			"data": {},
			"text": "",
			"error": ERR_FILE_NOT_FOUND,
		}

	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null:
		return {
			"status": SaveFileReadStatus.OPEN_FAILED,
			"data": {},
			"text": "",
			"error": FileAccess.get_open_error(),
		}

	var save_text := file.get_as_text()
	var read_error := file.get_error()
	file = null
	if read_error != OK:
		return {
			"status": SaveFileReadStatus.READ_FAILED,
			"data": {},
			"text": "",
			"error": read_error,
		}

	var json := JSON.new()
	var parse_error := json.parse(save_text)
	if parse_error != OK:
		return {
			"status": SaveFileReadStatus.INVALID_JSON,
			"data": {},
			"text": save_text,
			"error": parse_error,
		}

	if not (json.data is Dictionary):
		return {
			"status": SaveFileReadStatus.NOT_DICTIONARY,
			"data": {},
			"text": save_text,
			"error": ERR_INVALID_DATA,
		}

	return {
		"status": SaveFileReadStatus.VALID,
		"data": json.data,
		"text": save_text,
		"error": OK,
	}


func _save_file_read_result_is_valid(result: Dictionary) -> bool:
	return int(result.get("status", SaveFileReadStatus.MISSING)) == SaveFileReadStatus.VALID


func _save_file_read_status_text(status: int) -> String:
	match status:
		SaveFileReadStatus.VALID:
			return "valid"
		SaveFileReadStatus.MISSING:
			return "missing"
		SaveFileReadStatus.OPEN_FAILED:
			return "open failed"
		SaveFileReadStatus.READ_FAILED:
			return "read failed"
		SaveFileReadStatus.INVALID_JSON:
			return "invalid JSON"
		SaveFileReadStatus.NOT_DICTIONARY:
			return "not a Dictionary"

	return "unknown"


func _restore_backup_to_primary(primary_path: String, backup_path: String) -> bool:
	var backup_result := _read_save_file_result(backup_path)
	if not _save_file_read_result_is_valid(backup_result):
		push_warning(
			"Could not restore primary save because backup is not valid: %s (%s, error %d)"
			% [
				backup_path,
				_save_file_read_status_text(int(backup_result.get("status", SaveFileReadStatus.MISSING))),
				int(backup_result.get("error", FAILED)),
			]
		)
		return false

	var temporary_path := _get_temporary_save_path(primary_path)
	if not _remove_save_file_if_exists(temporary_path):
		return false

	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		push_warning(
			"Could not open temporary save file for backup recovery: %s (error %d)"
			% [temporary_path, FileAccess.get_open_error()]
		)
		_remove_save_file_if_exists(temporary_path)
		return false

	file.store_string(String(backup_result.get("text", "")))
	file.flush()
	var write_error := file.get_error()
	file = null
	if write_error != OK:
		push_warning("Could not write temporary backup recovery file: %s (error %d)" % [temporary_path, write_error])
		_remove_save_file_if_exists(temporary_path)
		return false

	if not _temporary_save_file_is_valid(temporary_path):
		_remove_save_file_if_exists(temporary_path)
		return false

	if FileAccess.file_exists(primary_path) and not _remove_save_file_if_exists(primary_path):
		_remove_save_file_if_exists(temporary_path)
		return false

	if _rename_save_file(temporary_path, primary_path, "restore backup save"):
		return true

	_remove_save_file_if_exists(temporary_path)
	return false


func _normalize_slot(slot: String = "") -> String:
	var normalized_slot := slot.strip_edges()
	if normalized_slot.is_empty():
		normalized_slot = active_slot.strip_edges()
	if normalized_slot.is_empty():
		normalized_slot = DEFAULT_SLOT

	if not _is_safe_slot_name(normalized_slot):
		push_warning("Unsafe save slot name ignored: %s" % normalized_slot)
		return DEFAULT_SLOT

	return normalized_slot


func _is_safe_slot_name(slot: String) -> bool:
	return (
		not slot.is_empty()
		and slot.find("/") == -1
		and slot.find("\\") == -1
		and slot.find("..") == -1
		and slot.get_extension().is_empty()
	)


func _get_scene_display_name(scene_path: String) -> String:
	if scene_path.is_empty():
		return ""

	return scene_path.get_file().get_basename().replace("_", " ").capitalize()


func _get_progression_summary_from_save_data(save_data: Dictionary) -> Dictionary:
	var progression_data = _decode_value(save_data.get("progression", {}))
	if not (progression_data is Dictionary):
		return {}

	var progression: Dictionary = progression_data
	if progression.is_empty():
		return {}

	var summary = progression.get("summary", {})
	var progression_summary: Dictionary = summary.duplicate(true) if summary is Dictionary else {}
	progression_summary["has_progression"] = true
	progression_summary["global_level"] = maxi(
		int(progression_summary.get("global_level", progression.get("global_level", 1))),
		1
	)
	progression_summary["global_xp"] = maxi(
		int(progression_summary.get("global_xp", progression.get("global_xp", 0))),
		0
	)
	return progression_summary


func _format_progression_summary(summary: Dictionary) -> String:
	if not bool(summary.get("has_progression", false)):
		return ""

	var level := maxi(int(summary.get("global_level", 1)), 1)
	var progression = summary.get("progression", {})
	var xp_text := ""
	if progression is Dictionary:
		var xp_into_level := int(progression.get("xp_into_level", -1))
		var xp_for_next_level := int(progression.get("xp_for_next_level", -1))
		if xp_into_level >= 0 and xp_for_next_level > 0:
			xp_text = " %d/%d XP" % [xp_into_level, xp_for_next_level]

	return "Lv %d%s" % [level, xp_text]


func _format_saved_time(unix_time: float) -> String:
	if unix_time <= 0.0:
		return ""

	var datetime := Time.get_datetime_dict_from_unix_time(int(unix_time))
	return "%04d-%02d-%02d %02d:%02d" % [
		int(datetime.get("year", 0)),
		int(datetime.get("month", 0)),
		int(datetime.get("day", 0)),
		int(datetime.get("hour", 0)),
		int(datetime.get("minute", 0)),
	]


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
