class_name NpcSceneRouteEdge extends Resource

@export var edge_id: StringName = &""
@export_file("*.tscn") var source_scene_path: String = ""
@export_file("*.tscn") var target_scene_path: String = ""
@export var target_arrival_position: Vector2 = Vector2.ZERO
@export var enabled: bool = true

@export_group("NPC Permissions")
@export var allowed_npc_ids: Array[StringName] = []
@export var blocked_npc_ids: Array[StringName] = []


func allows_npc(npc_id: StringName) -> bool:
	var normalized_id := String(npc_id).strip_edges()
	if normalized_id.is_empty():
		return false
	for blocked_id in blocked_npc_ids:
		if String(blocked_id).strip_edges() == normalized_id:
			return false

	if allowed_npc_ids.is_empty():
		return true

	for allowed_id in allowed_npc_ids:
		if String(allowed_id).strip_edges() == normalized_id:
			return true
	return false


func get_validation_errors() -> Array[String]:
	var errors: Array[String] = []
	var raw_edge_id := String(edge_id)
	var normalized_edge_id := raw_edge_id.strip_edges()
	if normalized_edge_id.is_empty():
		errors.append("edge_id is empty")
	elif raw_edge_id != normalized_edge_id:
		errors.append("edge_id must not have leading or trailing whitespace")
	_validate_scene_path(source_scene_path, "source_scene_path", errors)
	_validate_scene_path(target_scene_path, "target_scene_path", errors)
	if (
		not source_scene_path.is_empty()
		and source_scene_path == target_scene_path
	):
		errors.append("source_scene_path and target_scene_path must differ")
	if (
		not is_finite(target_arrival_position.x)
		or not is_finite(target_arrival_position.y)
	):
		errors.append("target_arrival_position must be finite")
	_validate_permission_ids(allowed_npc_ids, "allowed_npc_ids", errors)
	_validate_permission_ids(blocked_npc_ids, "blocked_npc_ids", errors)
	return errors


func to_descriptor() -> Dictionary:
	return {
		"edge_id": String(edge_id),
		"source_scene_path": source_scene_path,
		"target_scene_path": target_scene_path,
		"target_arrival_position": target_arrival_position,
		"enabled": enabled,
		"allowed_npc_ids": _string_names_to_strings(allowed_npc_ids),
		"blocked_npc_ids": _string_names_to_strings(blocked_npc_ids),
	}


func _validate_scene_path(path: String, field_name: String, errors: Array[String]) -> void:
	if path.is_empty():
		errors.append("%s is empty" % field_name)
		return
	if not path.begins_with("res://") or path.get_extension().to_lower() != "tscn":
		errors.append("%s is not a res:// .tscn path: %s" % [field_name, path])
		return
	if not ResourceLoader.exists(path):
		errors.append("%s does not exist: %s" % [field_name, path])


func _validate_permission_ids(
	values: Array[StringName],
	field_name: String,
	errors: Array[String]
) -> void:
	var seen: Dictionary = {}
	for value in values:
		var normalized := String(value).strip_edges()
		if normalized.is_empty():
			errors.append("%s contains an empty NPC id" % field_name)
			continue
		if seen.has(normalized):
			errors.append("%s contains duplicate NPC id '%s'" % [field_name, normalized])
			continue
		seen[normalized] = true


func _string_names_to_strings(values: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	return result
