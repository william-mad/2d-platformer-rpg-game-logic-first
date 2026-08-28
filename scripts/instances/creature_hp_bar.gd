class_name CreatureHpBar extends ProgressBar


func _ready() -> void:
	theme_type_variation = &"CreatureHealthBar"


func setup_hp(max_hp: float, current_hp: float) -> void:
	max_value = max_hp
	set_hp(current_hp)


func set_hp(current_hp: float) -> void:
	value = clampf(current_hp, min_value, max_value)
