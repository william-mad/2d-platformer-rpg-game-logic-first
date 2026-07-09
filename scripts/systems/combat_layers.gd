class_name CombatLayers
extends RefCounted

const ATTACK_SPELL_DETECTION_LAYER_INDEX := 11
const ATTACK_SPELL_DETECTION_LAYER := 1 << (ATTACK_SPELL_DETECTION_LAYER_INDEX - 1)


static func mark_attack_spell(collision_object: CollisionObject2D) -> void:
	if collision_object == null:
		return

	collision_object.collision_layer = collision_object.collision_layer | ATTACK_SPELL_DETECTION_LAYER
