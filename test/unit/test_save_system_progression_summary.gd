extends "res://test/native_scene_tree_test.gd"

var SaveSystemClass := preload("res://scripts/systems/save_system.gd")
const AVAILABILITY_TEST_SLOT := "save_availability_test"

var save_system: GameSaveSystem


func before_each() -> void:
	save_system = SaveSystemClass.new()
	add_child_autofree(save_system)
	save_system.delete_save(AVAILABILITY_TEST_SLOT)


func after_each() -> void:
	save_system.delete_save(AVAILABILITY_TEST_SLOT)


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


func test_backup_only_valid_save_is_available() -> void:
	var save_path := save_system.get_save_path(AVAILABILITY_TEST_SLOT)
	_write_test_file("%s.bak" % save_path, JSON.stringify({"version": 5}))

	assert_true(save_system.save_exists(AVAILABILITY_TEST_SLOT))


func test_backup_only_malformed_save_is_not_available() -> void:
	var save_path := save_system.get_save_path(AVAILABILITY_TEST_SLOT)
	_write_test_file("%s.bak" % save_path, "{malformed")

	assert_false(save_system.save_exists(AVAILABILITY_TEST_SLOT))


func test_temporary_only_save_is_not_available() -> void:
	var save_path := save_system.get_save_path(AVAILABILITY_TEST_SLOT)
	_write_test_file("%s.tmp" % save_path, JSON.stringify({"version": 5}))

	assert_false(save_system.save_exists(AVAILABILITY_TEST_SLOT))


func _write_test_file(path: String, contents: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file, "test save candidate can be created")
	if file == null:
		return
	file.store_string(contents)
