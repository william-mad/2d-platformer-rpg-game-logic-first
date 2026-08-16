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


## Creates a session-local copy with simple {key} substitutions. Shared authored
## resources are never mutated, so one template can safely mention different NPCs.
func instantiate_with_context(context: Dictionary = {}) -> DialogueDefinition:
	var instance := DialogueDefinition.new()
	instance.dialogue_id = dialogue_id
	instance.entry_node_id = entry_node_id
	for source_node in nodes:
		if source_node == null:
			continue
		var node_copy := DialogueNode.new()
		node_copy.node_id = source_node.node_id
		node_copy.speaker_id = source_node.speaker_id
		node_copy.speaker_text = _substitute_context(source_node.speaker_text, context)
		node_copy.next_node_id = source_node.next_node_id
		node_copy.terminal = source_node.terminal
		for source_choice in source_node.choices:
			if source_choice == null:
				continue
			var choice_copy := DialogueChoice.new()
			choice_copy.choice_id = source_choice.choice_id
			choice_copy.text = _substitute_context(source_choice.text, context)
			choice_copy.next_node_id = source_choice.next_node_id
			choice_copy.favor_delta = source_choice.favor_delta
			choice_copy.consequences = source_choice.consequences.duplicate(true)
			choice_copy.terminal = source_choice.terminal
			node_copy.choices.append(choice_copy)
		instance.nodes.append(node_copy)
	return instance


func _substitute_context(source_text: String, context: Dictionary) -> String:
	var result := source_text
	for context_key in context.keys():
		result = result.replace(
			"{%s}" % String(context_key),
			String(context[context_key])
		)
	return result


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
		if (
			dialogue_node.choices.is_empty()
			and not dialogue_node.terminal
			and not node_ids.has(dialogue_node.next_node_id)
		):
			return "node_next_node_missing"
		for choice in dialogue_node.choices:
			if not choice.terminal and not node_ids.has(choice.next_node_id):
				return "choice_next_node_missing"
	return ""
