extends Node

var pending_player_data: Dictionary = {}
var pending_target_spawn_id: StringName = &""


func capture_player(player: Node, target_spawn_id: StringName = &"") -> void:
	pending_player_data.clear()
	pending_target_spawn_id = target_spawn_id

	if player == null or not is_instance_valid(player):
		return
	if not player.has_method("get_save_data"):
		return

	var data = player.call("get_save_data")
	if not (data is Dictionary):
		return

	pending_player_data = data.duplicate(true)
	pending_player_data.erase("global_position")


func apply_to_player(player: Node) -> bool:
	if player == null or not is_instance_valid(player):
		return false
	if pending_player_data.is_empty():
		return false

	var data := pending_player_data.duplicate(true)
	var target_spawn_id := pending_target_spawn_id
	pending_player_data.clear()
	pending_target_spawn_id = &""

	if player.has_method("apply_save_data"):
		player.call("apply_save_data", data)

	_move_player_to_spawn(player, target_spawn_id)
	return true


func has_pending_player_data() -> bool:
	return not pending_player_data.is_empty()


func _move_player_to_spawn(player: Node, target_spawn_id: StringName) -> void:
	if target_spawn_id == &"" or not (player is Node2D):
		return

	var spawn := _find_spawn(target_spawn_id)
	if spawn == null:
		return

	(player as Node2D).global_position = spawn.global_position


func _find_spawn(target_spawn_id: StringName) -> Node2D:
	var tree := get_tree()
	if tree == null:
		return null

	for spawn_node in tree.get_nodes_in_group(&"player_spawn"):
		var spawn := spawn_node as Node2D
		if spawn == null or not is_instance_valid(spawn):
			continue
		if String(_get_spawn_id(spawn)) == String(target_spawn_id):
			return spawn

	return null


func _get_spawn_id(spawn: Node) -> StringName:
	if spawn.has_method("get_spawn_id"):
		return StringName(spawn.call("get_spawn_id"))

	var property_value = _get_property_if_present(spawn, &"spawn_id")
	if property_value != null:
		return StringName(String(property_value))

	return &""


func _get_property_if_present(object: Object, property_name: StringName):
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return object.get(property_name)

	return null
