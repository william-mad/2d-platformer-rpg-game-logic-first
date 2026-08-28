class_name NpcSimulatedLocationDefinition extends Resource

## Declares a scene path that exists only as an address for record-based NPC simulation.
## It must not contain playable geometry, a Player, or an NpcLocationScene.

@export_group("Identity")
@export var location_id: StringName = &""
@export_file("*.tscn") var scene_path: String = ""

@export_group("Contract")
@export var spot_ids: Array[StringName] = []
@export var npc_ids: Array[StringName] = []
@export var expected_origin_scene_paths: Array[String] = []


func get_validation_errors() -> Array[String]:
	var errors: Array[String] = []
	var normalized_id := String(location_id).strip_edges()
	if normalized_id.is_empty():
		errors.append("location_id is empty")
	elif normalized_id != String(location_id):
		errors.append("location_id must not have leading or trailing whitespace")

	_validate_scene_path(scene_path, "scene_path", errors)
	_validate_ids(spot_ids, "spot_ids", errors)
	_validate_ids(npc_ids, "npc_ids", errors)
	if spot_ids.is_empty():
		errors.append("spot_ids is empty")
	if npc_ids.is_empty():
		errors.append("npc_ids is empty")
	if expected_origin_scene_paths.is_empty():
		errors.append("expected_origin_scene_paths is empty")
	else:
		var seen_paths: Dictionary = {}
		for index in expected_origin_scene_paths.size():
			var origin_path := expected_origin_scene_paths[index]
			_validate_scene_path(
				origin_path,
				"expected_origin_scene_paths[%d]" % index,
				errors
			)
			if seen_paths.has(origin_path):
				errors.append(
					"expected_origin_scene_paths contains duplicate path '%s'" % origin_path
				)
			seen_paths[origin_path] = true
	return errors


func to_descriptor() -> Dictionary:
	return {
		"location_id": String(location_id),
		"scene_path": scene_path,
		"spot_ids": _string_names_to_strings(spot_ids),
		"npc_ids": _string_names_to_strings(npc_ids),
		"expected_origin_scene_paths": expected_origin_scene_paths.duplicate(),
	}


func _validate_scene_path(path: String, field_name: String, errors: Array[String]) -> void:
	if path.is_empty():
		errors.append("%s is empty" % field_name)
		return
	if not path.begins_with("res://") or path.get_extension().to_lower() != "tscn":
		errors.append("%s is not a res:// .tscn path: %s" % [field_name, path])
		return
	if not ResourceLoader.exists(path, "PackedScene"):
		errors.append("%s does not exist: %s" % [field_name, path])


func _validate_ids(values: Array[StringName], field_name: String, errors: Array[String]) -> void:
	var seen: Dictionary = {}
	for value in values:
		var normalized := String(value).strip_edges()
		if normalized.is_empty():
			errors.append("%s contains an empty id" % field_name)
			continue
		if seen.has(normalized):
			errors.append("%s contains duplicate id '%s'" % [field_name, normalized])
			continue
		seen[normalized] = true


func _string_names_to_strings(values: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	return result
