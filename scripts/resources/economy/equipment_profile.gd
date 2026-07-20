class_name EquipmentProfile
extends Resource

@export var slot_id: StringName = &""
@export var damage_multiplier: float = 1.0
@export var knockout_multiplier: float = 1.0
@export var applicable_attack_tags: Array[StringName] = []


func is_valid_profile() -> bool:
	return not String(slot_id).strip_edges().is_empty() \
		and is_finite(damage_multiplier) \
		and damage_multiplier >= 0.0 \
		and is_finite(knockout_multiplier) \
		and knockout_multiplier >= 0.0


func applies_to_attack(attack_tags: Array[StringName]) -> bool:
	if applicable_attack_tags.is_empty():
		return true
	for tag: StringName in applicable_attack_tags:
		if tag in attack_tags:
			return true
	return false
