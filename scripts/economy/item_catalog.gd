class_name ItemCatalog
extends RefCounted

const DEFAULT_ITEMS_DIR: String = "res://data/items"

var _definitions: Dictionary = {}
var _validation_errors: PackedStringArray = PackedStringArray()


func clear() -> void:
	_definitions.clear()
	_validation_errors.clear()


func load_definitions(directory_path: String = DEFAULT_ITEMS_DIR) -> bool:
	clear()
	var directory := DirAccess.open(directory_path)
	if directory == null:
		_validation_errors.append("Item directory is not readable: %s" % directory_path)
		return false
	_scan_directory(directory_path)
	return _validation_errors.is_empty()


func register_definition(definition: ItemDefinition) -> bool:
	if definition == null:
		_validation_errors.append("Cannot register a null item definition.")
		return false
	if not definition.is_valid_definition():
		_validation_errors.append("Invalid item definition with ID '%s'." % String(definition.id))
		return false
	var key := _normalize_id(definition.id)
	if _definitions.has(key):
		_validation_errors.append("Duplicate item ID '%s'; the first definition was kept." % key)
		return false
	_definitions[key] = definition
	return true


func has_item(item_id: StringName) -> bool:
	return _definitions.has(_normalize_id(item_id))


func get_definition(item_id: StringName) -> ItemDefinition:
	return _definitions.get(_normalize_id(item_id)) as ItemDefinition


func get_all_item_ids() -> Array[StringName]:
	var keys: Array = _definitions.keys()
	keys.sort()
	var result: Array[StringName] = []
	for key: String in keys:
		result.append(StringName(key))
	return result


func get_definitions_with_tag(tag: StringName) -> Array[ItemDefinition]:
	var result: Array[ItemDefinition] = []
	for item_id: StringName in get_all_item_ids():
		var definition := get_definition(item_id)
		if definition.has_tag(tag):
			result.append(definition)
	return result


func is_food(item_id: StringName) -> bool:
	var definition := get_definition(item_id)
	return definition != null and definition.edible and definition.hunger_reduction > 0.0


func get_food_value(item_id: StringName) -> float:
	var definition := get_definition(item_id)
	return definition.hunger_reduction if definition != null and definition.edible else 0.0


func get_validation_errors() -> PackedStringArray:
	return _validation_errors.duplicate()


func _scan_directory(directory_path: String) -> void:
	var directory := DirAccess.open(directory_path)
	if directory == null:
		_validation_errors.append("Item subdirectory is not readable: %s" % directory_path)
		return
	var entries := directory.get_files()
	entries.sort()
	for file_name: String in entries:
		var extension := file_name.get_extension().to_lower()
		if extension != "tres" and extension != "res":
			continue
		var resource_path := directory_path.path_join(file_name)
		var resource := ResourceLoader.load(resource_path)
		if resource == null:
			_validation_errors.append("Could not load resource: %s" % resource_path)
		elif resource is ItemDefinition:
			if not register_definition(resource as ItemDefinition):
				_validation_errors[_validation_errors.size() - 1] += " Source: %s" % resource_path
	var subdirectories := directory.get_directories()
	subdirectories.sort()
	for subdirectory: String in subdirectories:
		_scan_directory(directory_path.path_join(subdirectory))


func _normalize_id(item_id: StringName) -> String:
	return String(item_id).strip_edges()
