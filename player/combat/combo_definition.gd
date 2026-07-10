class_name ComboDefinition
extends Resource

@export var combo_id: StringName = &""
@export var attacks: Array[Resource] = []


func get_attack(index: int) -> AttackDefinition:
	if index < 0 or index >= attacks.size():
		return null

	return attacks[index] as AttackDefinition


func has_attack(index: int) -> bool:
	return get_attack(index) != null
