class_name InteractiveActivityLaunchOptions
extends Resource

enum SelectionPolicy {
	AUTO,
	ALWAYS_SHOW,
	DIRECT_IF_SINGLE,
}

@export var selection_policy: SelectionPolicy = SelectionPolicy.AUTO
@export var menu_title: String = "Choose an activity"
@export var menu_prompt: String = ""
@export var confirm_text: String = "Attack: Begin"


func should_show_selection(definition_count: int) -> bool:
	if definition_count <= 0:
		return false
	match selection_policy:
		SelectionPolicy.ALWAYS_SHOW:
			return true
		SelectionPolicy.DIRECT_IF_SINGLE, SelectionPolicy.AUTO:
			return definition_count > 1
	return definition_count > 1


func get_menu_title() -> String:
	var normalized := menu_title.strip_edges()
	return normalized if not normalized.is_empty() else "Choose an activity"


func get_confirm_text() -> String:
	var normalized := confirm_text.strip_edges()
	return normalized if not normalized.is_empty() else "Attack: Begin"
