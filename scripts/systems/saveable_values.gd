class_name SaveableValues extends Node

@export var save_id: String = ""
@export var target_path: NodePath = ^".."
@export var saved_property_names: Array[StringName] = []


func _ready() -> void:
	add_to_group(&"saveable")


func get_save_id() -> String:
	# Set save_id in the Inspector for anything important, for example "village_chest_01".
	if not save_id.strip_edges().is_empty():
		return save_id.strip_edges()

	var target := _get_target()
	if target == null:
		return ""

	return "%s:%s" % [target.scene_file_path, target.get_path()]


func get_save_data() -> Dictionary:
	var target := _get_target()
	if target == null:
		return {}

	var data := {}
	for property_name in saved_property_names:
		# Add property names here when a simple value should be saved without custom code.
		data[String(property_name)] = target.get(property_name)

	return data


func apply_save_data(data: Dictionary) -> void:
	var target := _get_target()
	if target == null:
		return

	for property_name in saved_property_names:
		var key := String(property_name)
		if data.has(key):
			target.set(property_name, data[key])

	if target.has_method("on_save_data_applied"):
		target.call("on_save_data_applied", data)


func _get_target() -> Node:
	return get_node_or_null(target_path)
