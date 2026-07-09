extends GutTest

var SaveSystemClass := preload("res://scripts/systems/save_system.gd")

var save_system: GameSaveSystem


func before_each() -> void:
	save_system = SaveSystemClass.new()
	add_child_autofree(save_system)


func test_progression_summary_formats_level_and_xp() -> void:
	var summary := {
		"display_name": "File 1",
		"exists": true,
		"valid": true,
		"scene_name": "Home 1",
		"saved_at_unix_time": 0.0,
		"has_progression": true,
		"global_level": 3,
		"progression": {
			"xp_into_level": 10,
			"xp_for_next_level": 200,
		},
	}

	assert_eq(
		save_system.format_save_summary(summary, "Empty"),
		"File 1 - Lv 3 10/200 XP - Home 1",
		"save summaries include progression when it exists"
	)


func test_old_save_summary_without_progression_keeps_legacy_format() -> void:
	var summary := {
		"display_name": "File 1",
		"exists": true,
		"valid": true,
		"scene_name": "Home 1",
		"saved_at_unix_time": 0.0,
	}

	assert_eq(
		save_system.format_save_summary(summary, "Empty"),
		"File 1 - Home 1",
		"old saves without progression still format cleanly"
	)
