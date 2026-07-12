class_name TravelPolicy
extends Resource

@export var policy_id: StringName = &"default_companion"
@export_range(0.0, 1.0, 0.01) var sleep_progression_multiplier: float = 0.35
@export_range(0.0, 2.0, 0.01) var hunger_progression_multiplier: float = 1.0
@export_range(0.0, 1.0, 0.01) var social_need_progression_multiplier: float = 0.0
@export_range(0.0, 1.0, 0.01) var relationship_progression_multiplier: float = 0.0
@export var social_planning_enabled: bool = false
@export var combat_enabled: bool = true
@export var inventory_eating_enabled: bool = true


func get_need_multipliers() -> Dictionary:
	return {
		"sleep_need": sleep_progression_multiplier,
		"hunger": hunger_progression_multiplier,
		"boredom": social_need_progression_multiplier,
		"talk_need": social_need_progression_multiplier,
		"lonely": social_need_progression_multiplier,
	}

