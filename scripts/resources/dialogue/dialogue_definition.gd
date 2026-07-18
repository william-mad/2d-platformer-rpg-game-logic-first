class_name DialogueDefinition
extends Resource

@export var dialogue_id: StringName = &""
@export var entry_node_id: StringName = &""
@export var nodes: Array[DialogueNode] = []


func get_node(node_id: StringName) -> DialogueNode:
	for dialogue_node in nodes:
		if dialogue_node != null and dialogue_node.node_id == node_id:
			return dialogue_node
	return null


func get_validation_error() -> String:
	if String(dialogue_id).strip_edges().is_empty():
		return "dialogue_id_empty"
	if String(entry_node_id).strip_edges().is_empty():
		return "entry_node_id_empty"
	if nodes.is_empty():
		return "dialogue_nodes_empty"

	var node_ids: Dictionary = {}
	for dialogue_node in nodes:
		if dialogue_node == null:
			return "dialogue_node_missing"
		var node_error := dialogue_node.get_validation_error()
		if not node_error.is_empty():
			return node_error
		if node_ids.has(dialogue_node.node_id):
			return "duplicate_node_id"
		node_ids[dialogue_node.node_id] = true

	if not node_ids.has(entry_node_id):
		return "entry_node_missing"
	for dialogue_node in nodes:
		for choice in dialogue_node.choices:
			if not choice.terminal and not node_ids.has(choice.next_node_id):
				return "choice_next_node_missing"
	return ""
