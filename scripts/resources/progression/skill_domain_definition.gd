class_name SkillDomainDefinition extends Resource

@export_group("Identity")
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

@export_group("Presentation")
@export var tags: Array[StringName] = []
@export var icon: Texture2D


func is_valid_definition() -> bool:
	return id != &""
