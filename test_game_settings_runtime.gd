extends "res://test/native_scene_tree_test.gd"

const SettingsScript = preload("res://scripts/systems/game_settings.gd")
const TEST_SETTINGS_PATH := "user://codex_game_settings_runtime_test.cfg"


func test_master_volume_and_fullscreen_persist_through_config_file() -> void:
	_remove_test_file()
	var global_settings := root.get_node_or_null("GameSettings")
	var original_volume := (
		float(global_settings.call("get_master_volume"))
		if global_settings != null
		else 1.0
	)
	var original_fullscreen := (
		bool(global_settings.call("is_fullscreen"))
		if global_settings != null
		else false
	)

	var first := SettingsScript.new()
	first.settings_path = TEST_SETTINGS_PATH
	root.add_child(first)
	first.set_master_volume(0.37)
	first.set_fullscreen(true)
	first.free()

	var restored := SettingsScript.new()
	restored.settings_path = TEST_SETTINGS_PATH
	root.add_child(restored)
	assert_true(
		is_equal_approx(restored.get_master_volume(), 0.37),
		"Master volume restores from the settings file"
	)
	assert_true(restored.is_fullscreen(), "fullscreen restores from the settings file")
	restored.free()

	if global_settings != null:
		global_settings.call("set_master_volume", original_volume, false)
		global_settings.call("set_fullscreen", original_fullscreen, false)
	_remove_test_file()


func _remove_test_file() -> void:
	var absolute_path := ProjectSettings.globalize_path(TEST_SETTINGS_PATH)
	if FileAccess.file_exists(TEST_SETTINGS_PATH):
		DirAccess.remove_absolute(absolute_path)
