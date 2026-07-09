class_name XPRewardDefinition extends Resource

@export_group("Identity")
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var source_type: StringName = &""
@export var tags: Array[StringName] = []

@export_group("XP")
@export_range(0, 999999, 1) var global_xp_amount: int = 0
@export var skill_xp_amounts: Dictionary = {}
# Example: { "magic": { "magic": 3 } } adds magic XP when context tags include "magic".
@export var tagged_skill_xp_amounts: Dictionary = {}

@export_group("Timing")
@export var per_second: bool = false
@export var per_minute: bool = false
@export var once_per_save: bool = false
@export_range(0.0, 86400.0, 0.1, "suffix:s") var cooldown_seconds: float = 0.0


func is_valid_definition() -> bool:
	return id != &""


func is_time_based() -> bool:
	return per_second or per_minute


func get_time_unit_seconds() -> float:
	if per_second:
		return 1.0
	if per_minute:
		return 60.0
	return 0.0
