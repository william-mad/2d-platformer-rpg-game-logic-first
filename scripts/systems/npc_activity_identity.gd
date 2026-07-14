class_name NpcActivityIdentity extends RefCounted

const TARGETED_SPOT_ACTIONS := {
	"Work": true,
	"Eat": true,
	"Sleep": true,
	"Rest": true,
	"Recreation": true,
	"RoutineTask": true,
	"InvitePlayer": true,
}

const TARGETED_NPC_ACTIONS := {
	"Talk": true,
	"LookForTalkTarget": true,
}


static func describe(
	action_kind: StringName,
	target: Node2D = null,
	spot_id: StringName = &"",
	scene_path: String = "",
	activity_id: String = "",
	request_id: String = "",
	target_npc_id: String = ""
) -> Dictionary:
	var descriptor := {
		"action_kind": String(_canonical_action_kind(action_kind)),
	}
	var normalized_scene_path := scene_path.strip_edges()
	if not normalized_scene_path.is_empty():
		descriptor["scene_path"] = normalized_scene_path
	if not activity_id.strip_edges().is_empty():
		descriptor["activity_id"] = activity_id.strip_edges()
	if not request_id.strip_edges().is_empty():
		descriptor["request_id"] = request_id.strip_edges()

	var normalized_target_npc_id := target_npc_id.strip_edges()
	if normalized_target_npc_id.is_empty():
		normalized_target_npc_id = get_persistent_npc_id(target)
	if not normalized_target_npc_id.is_empty():
		descriptor["target_npc_id"] = normalized_target_npc_id

	var normalized_spot_id := String(spot_id).strip_edges()
	if normalized_spot_id.is_empty():
		normalized_spot_id = get_persistent_spot_id(target, action_kind)
	if not normalized_spot_id.is_empty():
		descriptor["spot_id"] = normalized_spot_id

	if target != null and is_instance_valid(target):
		descriptor["target_node"] = target
		if not descriptor.has("scene_path"):
			var target_scene_path := get_node_scene_path(target)
			if not target_scene_path.is_empty():
				descriptor["scene_path"] = target_scene_path

	return descriptor


static func matches(current: Dictionary, requested: Dictionary) -> bool:
	if current.is_empty() or requested.is_empty():
		return false

	var current_action := _canonical_action_kind(
		StringName(String(current.get("action_kind", current.get("state_name", ""))))
	)
	var requested_action := _canonical_action_kind(
		StringName(String(requested.get("action_kind", requested.get("state_name", ""))))
	)
	if current_action == &"" or current_action != requested_action:
		return false

	var current_scene := String(current.get("scene_path", "")).strip_edges()
	var requested_scene := String(requested.get("scene_path", "")).strip_edges()
	if not current_scene.is_empty() and not requested_scene.is_empty() and current_scene != requested_scene:
		return false

	for id_key in ["session_id", "action_session_id", "activity_id", "request_id"]:
		var current_id := String(current.get(id_key, "")).strip_edges()
		var requested_id := String(requested.get(id_key, "")).strip_edges()
		if not current_id.is_empty() and not requested_id.is_empty() and current_id != requested_id:
			return false

	if TARGETED_NPC_ACTIONS.has(String(requested_action)):
		return _target_identity_matches(current, requested, "target_npc_id")
	if TARGETED_SPOT_ACTIONS.has(String(requested_action)):
		return _target_identity_matches(current, requested, "spot_id")

	var requested_has_identity := _has_any_identity(requested)
	if requested_has_identity:
		return _target_identity_matches(current, requested, "")
	return true


static func has_target_identity(descriptor: Dictionary) -> bool:
	for key in ["target_npc_id", "spot_id"]:
		if not String(descriptor.get(key, "")).strip_edges().is_empty():
			return true
	var target = descriptor.get("target_node", null)
	return target is Node and is_instance_valid(target)


static func get_persistent_npc_id(target: Node) -> String:
	if target == null or not is_instance_valid(target):
		return ""
	if target.is_in_group("player"):
		return "__player__"
	if target.has_method("get_npc_location_id"):
		var method_id := String(target.call("get_npc_location_id")).strip_edges()
		if not method_id.is_empty():
			return method_id
	if target.has_meta("npc_location_id"):
		var meta_id := String(target.get_meta("npc_location_id")).strip_edges()
		if not meta_id.is_empty():
			return meta_id
	return ""


static func get_persistent_spot_id(target: Node, action_kind: StringName = &"") -> String:
	if target == null or not is_instance_valid(target):
		return ""

	# A work spot can expose a distinct simulated food source on the same live node.
	if String(_canonical_action_kind(action_kind)) == "Eat" and _has_property(target, &"eat_world_definition"):
		var eat_definition = target.get("eat_world_definition")
		var eat_spot_id := _get_definition_spot_id(eat_definition)
		if not eat_spot_id.is_empty():
			return eat_spot_id

	if target.has_method("get_world_spot_id"):
		var method_id := String(target.call("get_world_spot_id")).strip_edges()
		if not method_id.is_empty():
			return method_id
	if _has_property(target, &"spot_id"):
		var property_id := String(target.get("spot_id")).strip_edges()
		if not property_id.is_empty():
			return property_id
	if _has_property(target, &"world_definition"):
		var definition_id := _get_definition_spot_id(target.get("world_definition"))
		if not definition_id.is_empty():
			return definition_id
	return ""


static func get_node_scene_path(target: Node) -> String:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return ""
	var scene_tree := target.get_tree()
	if scene_tree == null or scene_tree.current_scene == null:
		return ""
	return String(scene_tree.current_scene.scene_file_path).strip_edges()


static func _target_identity_matches(
	current: Dictionary,
	requested: Dictionary,
	preferred_id_key: String
) -> bool:
	if not preferred_id_key.is_empty():
		var requested_id := String(requested.get(preferred_id_key, "")).strip_edges()
		var current_id := String(current.get(preferred_id_key, "")).strip_edges()
		if not requested_id.is_empty():
			if not current_id.is_empty():
				return requested_id == current_id
			return _same_live_target(current, requested)

	if _same_live_target(current, requested):
		return true

	# Targeted actions without a stable ID or an exact live node are ambiguous.
	# Old save records remain readable, but are not assumed to match by state alone.
	return false


static func _same_live_target(current: Dictionary, requested: Dictionary) -> bool:
	var current_target = current.get("target_node", null)
	var requested_target = requested.get("target_node", null)
	return (
		current_target is Node
		and requested_target is Node
		and is_instance_valid(current_target)
		and is_instance_valid(requested_target)
		and current_target == requested_target
	)


static func _has_any_identity(descriptor: Dictionary) -> bool:
	for key in [
		"target_npc_id", "spot_id", "session_id", "action_session_id",
		"activity_id", "request_id", "target_node"
	]:
		if descriptor.has(key):
			return true
	return false


static func _canonical_action_kind(action_kind: StringName) -> StringName:
	match String(action_kind):
		"routine_task", "Routine Task":
			return &"RoutineTask"
	return action_kind


static func _get_definition_spot_id(definition) -> String:
	if definition == null:
		return ""
	if definition is Dictionary:
		return String(definition.get("spot_id", "")).strip_edges()
	if _has_property(definition, &"spot_id"):
		return String(definition.get("spot_id")).strip_edges()
	return ""


static func _has_property(object: Object, property_name: StringName) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false
