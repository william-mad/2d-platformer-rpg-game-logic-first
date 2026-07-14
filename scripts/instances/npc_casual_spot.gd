class_name NpcCasualSpot extends Node2D

@export_group("Activity")
@export var activity_state_name: StringName = &"Recreation"

@export_group("Reservation")
@export var spot_id: StringName = &""
@export_range(0, 32, 1) var reservation_capacity: int = 1

@export_group("Serving")
# Empty owner and tag lists mean any NPC can use this casual spot.
@export var owner_npc_ids: Array[StringName] = []
@export var required_npc_tags: Array[StringName] = []

@export_group("Preference")
@export_range(0.0, 100.0, 0.1) var default_preference_weight: float = 1.0
@export var npc_preference_weights: Dictionary = {}

var registered_world_spot_id: StringName = &""


func _ready() -> void:
	add_to_group("npc_casual_spot")
	_register_world_spot()


func _exit_tree() -> void:
	_unregister_world_spot()


func get_persistent_spot_id() -> StringName:
	if spot_id != &"":
		return spot_id
	return StringName(String(get_path())) if is_inside_tree() else &""


func can_serve_npc_casual_activity(
	npc_node: Node2D,
	requested_state_name: StringName
) -> bool:
	if npc_node == null or not is_instance_valid(npc_node):
		return false
	if requested_state_name != &"" and activity_state_name != requested_state_name:
		return false
	if not _owner_allows_npc(npc_node):
		return false

	return _npc_has_required_tags(npc_node)


func get_npc_preference_weight(npc_node: Node2D) -> float:
	# Weight changes probability only; it never creates a need or requests an activity.
	if npc_node == null or not is_instance_valid(npc_node):
		return 0.0
	var npc_id := String(_get_npc_id(npc_node))
	if npc_preference_weights.has(npc_id):
		return maxf(float(npc_preference_weights[npc_id]), 0.0)
	var npc_id_name := StringName(npc_id)
	if npc_preference_weights.has(npc_id_name):
		return maxf(float(npc_preference_weights[npc_id_name]), 0.0)

	return maxf(default_preference_weight, 0.0)


func _owner_allows_npc(npc_node: Node2D) -> bool:
	if owner_npc_ids.is_empty():
		return true

	var npc_id := _get_npc_id(npc_node)
	for owner_id in owner_npc_ids:
		if String(owner_id) == String(npc_id):
			return true

	return false


func _npc_has_required_tags(npc_node: Node2D) -> bool:
	if required_npc_tags.is_empty():
		return true

	for required_tag in required_npc_tags:
		var tag_text := String(required_tag)
		if npc_node.is_in_group(tag_text):
			continue
		var tags = npc_node.get_meta("npc_tags", [])
		if tags is Array:
			var found_tag := false
			for npc_tag in tags:
				if String(npc_tag) == tag_text:
					found_tag = true
					break
			if found_tag:
				continue
		return false

	return true


func _get_npc_id(npc_node: Node2D) -> StringName:
	if npc_node.has_method("get_npc_location_id"):
		return StringName(String(npc_node.call("get_npc_location_id")))
	if npc_node.has_meta("npc_location_id"):
		return StringName(String(npc_node.get_meta("npc_location_id")))

	return StringName(String(npc_node.name))


func _register_world_spot() -> void:
	var effective_spot_id := get_persistent_spot_id()
	if effective_spot_id == &"":
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("register_live_spot"):
		simulator.call("register_live_spot", effective_spot_id, self)
		registered_world_spot_id = effective_spot_id


func _unregister_world_spot() -> void:
	var effective_spot_id := registered_world_spot_id
	if effective_spot_id == &"":
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("unregister_live_spot"):
		simulator.call("unregister_live_spot", effective_spot_id, self)
	registered_world_spot_id = &""
