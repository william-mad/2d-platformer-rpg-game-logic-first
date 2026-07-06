class_name CrashBreadcrumbs
extends RefCounted

const LOG_PATH := "user://crash_breadcrumbs.log"


static func mark(source: String, detail: String = "") -> void:
	if not _is_enabled():
		return

	var line := "%s | scene=%s | world=%s | %s | %s" % [
		Time.get_datetime_string_from_system(),
		_get_scene_label(),
		_get_world_time_label(),
		source,
		detail,
	]
	print(line)

	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE_READ)
	if file == null:
		return

	file.seek_end()
	file.store_line(line)
	file.flush()


static func _is_enabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_ENABLE_CRASH_BREADCRUMBS
	)


static func _get_scene_label() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return "none"

	var path := tree.current_scene.scene_file_path
	return path.get_file() if not path.is_empty() else tree.current_scene.name


static func _get_world_time_label() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return "none"

	var world_time := tree.root.get_node_or_null("WorldTime")
	if world_time == null or not world_time.has_method("get_snapshot"):
		return "none"

	var snapshot: Dictionary = world_time.call("get_snapshot")
	return "day=%d hour=%.3f" % [
		int(snapshot.get("day", 0)),
		float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0))),
	]
