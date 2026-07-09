class_name GlobalLevelCurve extends Resource

@export_group("Levels")
@export_range(1, 999, 1) var starting_level: int = 1
@export_range(1, 999, 1) var max_level: int = 50
@export var use_generated_level_curve: bool = true
@export_range(1, 999999, 1) var first_level_up_xp: int = 50
@export_range(1.0, 100.0, 0.01) var level_up_xp_multiplier: float = 2.0
# Total global XP required for each level. Index 0 is level 1, index 1 is level 2, and so on.
@export var xp_required_by_level: Array[int] = [
	0,
	50,
	125,
	240,
	400,
	620,
	900,
	1250,
	1680,
	2200,
]
@export_range(1, 999999, 1) var fallback_level_xp_step: int = 650
@export_range(0, 999999, 1) var fallback_level_xp_step_growth: int = 125

@export_group("Derived Stats")
@export_range(0.0, 100.0, 0.01) var base_damage_multiplier: float = 1.0
@export_range(0.0, 10.0, 0.01) var damage_multiplier_per_level: float = 0.08
@export_range(0, 9999, 1) var max_hp_bonus_per_level: int = 5
@export_range(0, 9999, 1) var max_mana_bonus_per_level: int = 15


func get_xp_required_for_level(level: int) -> int:
	var safe_level := clampi(level, starting_level, max_level)
	if use_generated_level_curve:
		return _get_generated_xp_required_for_level(safe_level)

	var index := safe_level - 1
	if index >= 0 and index < xp_required_by_level.size():
		return maxi(xp_required_by_level[index], 0)

	var last_known_index := maxi(xp_required_by_level.size() - 1, 0)
	var required_xp := 0
	if last_known_index < xp_required_by_level.size():
		required_xp = maxi(xp_required_by_level[last_known_index], 0)

	var step := maxi(fallback_level_xp_step, 1)
	for generated_index in range(last_known_index + 1, index + 1):
		required_xp += step
		step += maxi(fallback_level_xp_step_growth, 0)

	return required_xp


func _get_generated_xp_required_for_level(level: int) -> int:
	if level <= starting_level:
		return 0

	var required_xp := 0
	var step := float(maxi(first_level_up_xp, 1))
	for _next_level in range(starting_level + 1, level + 1):
		required_xp += int(round(step))
		step *= maxf(level_up_xp_multiplier, 1.0)

	return required_xp


func get_level_for_xp(global_xp: int) -> int:
	var safe_xp := maxi(global_xp, 0)
	var level := starting_level
	while level < max_level:
		var next_level := level + 1
		if safe_xp < get_xp_required_for_level(next_level):
			break
		level = next_level

	return level


func get_damage_multiplier(level: int) -> float:
	var level_delta := maxi(level - starting_level, 0)
	return base_damage_multiplier + float(level_delta) * damage_multiplier_per_level


func get_max_hp_bonus(level: int) -> int:
	return maxi(level - starting_level, 0) * max_hp_bonus_per_level


func get_max_mana_bonus(level: int) -> int:
	return maxi(level - starting_level, 0) * max_mana_bonus_per_level
