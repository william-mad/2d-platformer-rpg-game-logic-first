class_name AbilityDefinition extends Resource

@export_group("Identity")
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var category: StringName = &""
@export var tags: Array[StringName] = []
@export var icon: Texture2D

@export_group("Requirements")
@export_range(1, 999, 1) var required_global_level: int = 1
@export_range(0, 999999, 1) var required_global_xp: int = 0
@export var required_skill_xp: Dictionary = {}
@export var prerequisite_ability_ids: Array[StringName] = []

@export_group("Unlock")
@export var auto_unlock: bool = false
@export var action_id: StringName = &""
@export var player_state_name: StringName = &""


func is_valid_definition() -> bool:
	return id != &""
