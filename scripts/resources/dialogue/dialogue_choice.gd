class_name DialogueChoice
extends Resource

@export var choice_id: StringName = &""
@export_multiline var text: String = ""
@export var next_node_id: StringName = &""
@export var favor_delta: float = 0.0
## Optional data for consequence systems listening to DialogueController's
## dialogue_choice_committed signal. The dialogue controller deliberately does
## not interpret arbitrary keys here.
@export var consequences: Dictionary = {}
@export var terminal: bool = false


func get_validation_error() -> String:
	if String(choice_id).strip_edges().is_empty():
		return "choice_id_empty"
	if text.strip_edges().is_empty():
		return "choice_text_empty"
	if not terminal and String(next_node_id).strip_edges().is_empty():
		return "choice_next_node_empty"
	if not is_finite(favor_delta):
		return "choice_favor_delta_invalid"
	return ""
