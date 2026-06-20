extends Node

@export var pause_action: StringName = &"pause"
@export var stats_overlay_scene: PackedScene = preload("res://scenes/ui/character_stats_overlay.tscn")

var stats_overlay: CharacterStatsOverlay
var saved_world_time_auto_advance: bool = true
var has_saved_world_time_auto_advance: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_unhandled_input(true)
	get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if pause_action == &"" or not event.is_action_pressed(pause_action):
		return
	if _is_game_over_active():
		return

	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return

	get_viewport().set_input_as_handled()
	set_paused(not get_tree().paused)


func set_paused(should_pause: bool) -> void:
	_set_world_time_paused(should_pause)
	get_tree().paused = should_pause
	_ensure_stats_overlay()

	if stats_overlay == null:
		return

	if should_pause:
		stats_overlay.show_pause_overlay()
	else:
		stats_overlay.hide_pause_overlay()


func _ensure_stats_overlay() -> void:
	if stats_overlay != null and is_instance_valid(stats_overlay):
		return

	stats_overlay = _find_stats_overlay(get_tree().root)
	if stats_overlay != null:
		return

	if stats_overlay_scene == null:
		return

	stats_overlay = stats_overlay_scene.instantiate() as CharacterStatsOverlay
	if stats_overlay == null:
		return

	stats_overlay.name = "PauseStatsOverlay"
	get_tree().root.add_child(stats_overlay)


func _set_world_time_paused(should_pause: bool) -> void:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not _has_property(world_time, &"auto_advance"):
		return

	if should_pause:
		if not has_saved_world_time_auto_advance:
			saved_world_time_auto_advance = bool(world_time.get(&"auto_advance"))
			has_saved_world_time_auto_advance = true
		world_time.set(&"auto_advance", false)
		return

	if has_saved_world_time_auto_advance:
		world_time.set(&"auto_advance", saved_world_time_auto_advance)
		has_saved_world_time_auto_advance = false


func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return true

	return false


func _is_game_over_active() -> bool:
	var game_over_screen := get_node_or_null("/root/GameOverScreen")
	return (
		game_over_screen != null
		and game_over_screen.has_method("is_game_over_active")
		and bool(game_over_screen.call("is_game_over_active"))
	)


func _find_stats_overlay(node: Node) -> CharacterStatsOverlay:
	if node == null or not is_instance_valid(node):
		return null

	var overlay := node as CharacterStatsOverlay
	if overlay != null:
		return overlay

	for child in node.get_children():
		var found := _find_stats_overlay(child)
		if found != null:
			return found

	return null
