class_name InteractiveActivityDefinition extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var module_scene: PackedScene
@export var input_profile: InteractiveActivityInputProfile
@export var module_config: Resource
@export var metadata: Dictionary = {}


func is_valid_definition() -> bool:
	return id != &"" and not display_name.strip_edges().is_empty() and module_scene != null


func get_input_profile() -> InteractiveActivityInputProfile:
	if input_profile != null:
		return input_profile
	return InteractiveActivityInputProfile.new()
