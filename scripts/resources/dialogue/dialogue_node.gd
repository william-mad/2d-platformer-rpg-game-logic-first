class_name DialogueNode
extends Resource

@export var node_id: StringName = &""
@export_multiline var speaker_text: String = ""
@export var choices: Array[DialogueChoice] = []


func get_choice(choice_id: StringName) -> DialogueChoice:
	for choice in choices:
		if choice != null and choice.choice_id == choice_id:
			return choice
	return null


func get_validation_error() -> String:
	if String(node_id).strip_edges().is_empty():
		return "node_id_empty"
	if speaker_text.strip_edges().is_empty():
		return "node_text_empty"
	if choices.is_empty():
		return "node_choices_empty"
	var choice_ids: Dictionary = {}
	for choice in choices:
		if choice == null:
			return "node_choice_missing"
		var choice_error := choice.get_validation_error()
		if not choice_error.is_empty():
			return choice_error
		if choice_ids.has(choice.choice_id):
			return "duplicate_choice_id"
		choice_ids[choice.choice_id] = true
	return ""
