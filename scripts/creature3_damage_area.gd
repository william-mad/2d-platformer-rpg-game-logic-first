extends Damage_Area


func take_damage(attack) -> void:
	super.take_damage(attack)

	var creature := get_parent() as Creature3
	if creature != null and not creature.is_queued_for_deletion():
		creature.take_damage_from_player(attack)
