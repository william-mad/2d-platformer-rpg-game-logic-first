extends "res://test/native_scene_tree_test.gd"

var ProgressionSystemClass := preload("res://scripts/progression/progression_system.gd")
var ProgressionIds := preload("res://scripts/progression/progression_ids.gd")

var progression: GameProgressionSystem


func before_each() -> void:
	progression = ProgressionSystemClass.new()
	add_child_autofree(progression)
	progression.load_definitions()
	progression.reset_progression(false)


func test_global_xp_increases_and_recalculates_level() -> void:
	var level_events := []
	progression.global_level_changed.connect(func(level: int, previous_level: int) -> void:
		level_events.append([level, previous_level])
	)

	assert_true(progression.add_global_xp(60, &"test.global"), "global XP can be awarded")
	assert_eq(progression.get_global_xp(), 60, "global XP stores the awarded amount")
	assert_eq(progression.get_global_level(), 2, "60 XP reaches level 2 on the default curve")
	assert_true(level_events.size() >= 1, "level change signal fires during recalculation")


func test_damage_increases_by_fifty_percent_per_level() -> void:
	assert_true(is_equal_approx(progression.get_damage_multiplier(), 1.0), "level 1 uses base damage")
	progression.add_global_xp(60, &"test.damage")
	assert_eq(progression.get_global_level(), 2, "damage check reaches level 2")
	assert_true(is_equal_approx(progression.get_damage_multiplier(), 1.5), "level 2 adds fifty percent damage")
	assert_true(is_equal_approx(progression.level_curve.get_damage_multiplier(10), 5.5), "level 10 damage is additive")


func test_dash_auto_unlocks_at_level_four() -> void:
	assert_false(progression.is_ability_unlocked(ProgressionIds.ABILITY_DASH), "dash starts locked")
	progression.add_global_xp(349, &"test.dash")
	assert_eq(progression.get_global_level(), 3, "dash remains locked below level 4")
	assert_false(progression.is_ability_unlocked(ProgressionIds.ABILITY_DASH), "level 3 cannot dash")
	progression.add_global_xp(1, &"test.dash")
	assert_eq(progression.get_global_level(), 4, "dash unlock check reaches level 4")
	assert_true(progression.is_ability_unlocked(ProgressionIds.ABILITY_DASH), "dash auto-unlocks at level 4")


func test_skill_xp_is_independent_from_global_level() -> void:
	progression.add_skill_xp(ProgressionIds.DOMAIN_MAGIC, 40, &"test.skill")

	assert_eq(progression.get_skill_xp(ProgressionIds.DOMAIN_MAGIC), 40, "magic skill XP increases")
	assert_eq(progression.get_global_level(), 1, "skill XP does not change global level")


func test_abilities_remain_locked_until_requirements_are_met() -> void:
	assert_false(progression.is_ability_unlocked(ProgressionIds.ABILITY_WORK_EFFICIENCY), "work efficiency starts locked")
	assert_false(progression.can_unlock_ability(ProgressionIds.ABILITY_WORK_EFFICIENCY), "missing work XP blocks unlock")
	assert_false(progression.get_locked_reason(ProgressionIds.ABILITY_WORK_EFFICIENCY).is_empty(), "locked reason explains the missing requirement")


func test_ability_auto_unlocks_when_skill_requirement_is_met() -> void:
	progression.add_skill_xp(ProgressionIds.DOMAIN_WORK, 200, &"test.work")

	assert_true(progression.is_ability_unlocked(ProgressionIds.ABILITY_WORK_EFFICIENCY), "work efficiency auto-unlocks at 200 work XP")


func test_manual_ability_unlock_respects_prerequisites() -> void:
	assert_true(progression.is_ability_unlocked(ProgressionIds.ABILITY_BASIC_MAGIC), "basic magic is available from the start")
	assert_false(progression.unlock_ability(ProgressionIds.ABILITY_MANA_FOCUS), "mana focus needs mana XP")

	progression.add_skill_xp(ProgressionIds.DOMAIN_MANA, 75, &"test.mana")
	assert_true(progression.unlock_ability(ProgressionIds.ABILITY_MANA_FOCUS), "manual unlock succeeds once all requirements are met")
	assert_true(progression.is_ability_unlocked(ProgressionIds.ABILITY_MANA_FOCUS), "manual unlock is stored")


func test_save_snapshot_and_restore_preserves_progression() -> void:
	progression.add_global_xp(160, &"test.save")
	progression.add_skill_xp(ProgressionIds.DOMAIN_MAGIC, 100, &"test.save")
	progression.add_time_xp(ProgressionIds.REWARD_MAGIC_CLASS_TIME, 25.0, {"tags": ["class"]})
	var snapshot := progression.get_save_data()
	var summary: Dictionary = snapshot["summary"]

	assert_eq(int(summary["global_xp"]), 160, "save summary stores global XP")
	assert_eq(int(summary["global_level"]), 3, "save summary stores level")
	assert_eq(int(summary["xp_into_level"]), 10, "save summary stores XP into the current level")
	assert_eq(int(summary["xp_for_next_level"]), 200, "save summary stores XP needed for the next level")

	var restored: GameProgressionSystem = ProgressionSystemClass.new()
	add_child_autofree(restored)
	restored.load_definitions()
	restored.apply_save_data(snapshot)

	assert_eq(restored.get_global_xp(), 160, "global XP restores")
	assert_eq(restored.get_global_level(), 3, "level restores by recalculating from XP")
	assert_eq(restored.get_skill_xp(ProgressionIds.DOMAIN_MAGIC), 100, "skill XP restores")
	assert_true(restored.is_ability_unlocked(ProgressionIds.ABILITY_BASIC_MAGIC), "unlocked abilities restore")
	assert_eq(float(restored.get_save_data()["time_reward_pending_seconds"][String(ProgressionIds.REWARD_MAGIC_CLASS_TIME)]), 25.0, "time reward remainder restores")


func test_slime_kill_reward_grants_expected_xp() -> void:
	assert_true(progression.award_reward(ProgressionIds.REWARD_SLIME_KILL, {"attack_tags": ["magic"]}), "slime reward applies")

	assert_eq(progression.get_global_xp(), 3, "slime kill gives global XP")
	assert_eq(progression.get_skill_xp(ProgressionIds.DOMAIN_COMBAT), 5, "slime kill gives combat XP")
	assert_eq(progression.get_skill_xp(ProgressionIds.DOMAIN_MAGIC), 3, "magic-tagged slime kill gives magic XP")


func test_class_time_xp_batches_by_minute() -> void:
	assert_false(progression.add_time_xp(ProgressionIds.REWARD_MAGIC_CLASS_TIME, 30.0, {"tags": ["class"]}), "partial minute only accumulates")
	assert_eq(progression.get_skill_xp(ProgressionIds.DOMAIN_CLASS), 0, "no class XP before a full minute")

	assert_true(progression.add_time_xp(ProgressionIds.REWARD_MAGIC_CLASS_TIME, 30.0, {"tags": ["class"]}), "full minute awards")
	assert_eq(progression.get_skill_xp(ProgressionIds.DOMAIN_CLASS), 2, "class XP is awarded once per minute")
	assert_eq(progression.get_skill_xp(ProgressionIds.DOMAIN_MAGIC), 3, "magic class XP is awarded once per minute")
	assert_eq(progression.get_skill_xp(ProgressionIds.DOMAIN_MANA), 1, "mana class XP is awarded once per minute")
