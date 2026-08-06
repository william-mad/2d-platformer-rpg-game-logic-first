extends Node

@export var pause_action: StringName = &"pause"
@export var pause_menu_scene: PackedScene = preload("res://ui/pause/pause_menu.tscn")
@export var stats_overlay_scene: PackedScene = preload("res://scenes/ui/character_stats_overlay.tscn")
@export_file("*.tscn") var title_scene_path: String = "res://scenes/levels/title_screen.tscn"

var pause_menu: PauseMenu
var stats_overlay: CharacterStatsOverlay
var world_progression_lock_token: int = 0


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

	if is_pause_menu_open():
		get_viewport().set_input_as_handled()
		close_pause_menu()
		return
	# A paused tree without this menu belongs to inventory, cooking, dialogue,
	# or another modal owner. Escape must never unpause behind that UI.
	if get_tree().paused or not _is_gameplay_available():
		return

	get_viewport().set_input_as_handled()
	open_pause_menu()


func set_paused(should_pause: bool, show_ui: bool = true) -> void:
	_set_world_progression_paused(should_pause)
	get_tree().paused = should_pause
	_clear_legacy_pause_presentation()
	if should_pause and show_ui and not _is_game_over_active():
		# Keep the independent P-key inspector lazily available without using it
		# as the Escape presentation.
		_ensure_stats_overlay()
		_clear_legacy_pause_presentation()
		_ensure_pause_menu()
		if pause_menu != null:
			pause_menu.show_menu()
	else:
		_hide_pause_menu()


func open_pause_menu() -> void:
	if _is_game_over_active() or not _is_gameplay_available():
		return
	set_paused(true, true)


func close_pause_menu() -> void:
	set_paused(false, false)


func is_pause_menu_open() -> bool:
	return (
		pause_menu != null
		and is_instance_valid(pause_menu)
		and pause_menu.is_open()
	)


func get_pause_menu() -> PauseMenu:
	_ensure_pause_menu()
	return pause_menu


func _ensure_pause_menu() -> void:
	if pause_menu != null and is_instance_valid(pause_menu):
		return
	if pause_menu_scene == null:
		return
	pause_menu = pause_menu_scene.instantiate() as PauseMenu
	if pause_menu == null:
		return
	pause_menu.name = "PauseMenu"
	get_tree().root.add_child(pause_menu)
	pause_menu.resume_requested.connect(close_pause_menu)
	pause_menu.load_slot_requested.connect(_on_load_slot_requested)
	pause_menu.return_to_title_requested.connect(_on_return_to_title_requested)


func _hide_pause_menu() -> void:
	if pause_menu != null and is_instance_valid(pause_menu):
		pause_menu.hide_menu()


func _on_load_slot_requested(slot: String) -> void:
	close_pause_menu()
	var save_system := get_node_or_null("/root/SaveSystem")
	if save_system == null or not save_system.has_method("load_game"):
		return
	if not bool(save_system.call("load_game", slot)):
		open_pause_menu()
		if pause_menu != null:
			pause_menu.show_load_page()


func _on_return_to_title_requested() -> void:
	close_pause_menu()
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("change_scene"):
		if bool(scene_loader.call("change_scene", title_scene_path)):
			return
	get_tree().change_scene_to_file(title_scene_path)


func _clear_legacy_pause_presentation() -> void:
	# Only unwind the overlay's old pause-owned mode. A developer who toggled the
	# independent P-key inspector keeps that choice; the new menu simply renders
	# above it on a higher CanvasLayer.
	if (
		stats_overlay != null
		and is_instance_valid(stats_overlay)
		and stats_overlay.has_method("hide_pause_overlay")
	):
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


func _set_world_progression_paused(should_pause: bool) -> void:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null:
		return

	if should_pause:
		if world_progression_lock_token == 0:
			world_progression_lock_token = int(gameplay_flow.call(
				"acquire_world_progression_lock", self, &"pause_system"
			))
		return

	if world_progression_lock_token != 0:
		gameplay_flow.call(
			"release_world_progression_lock", world_progression_lock_token, self
		)
		world_progression_lock_token = 0


func _is_game_over_active() -> bool:
	var game_over_screen := get_node_or_null("/root/GameOverScreen")
	return (
		game_over_screen != null
		and game_over_screen.has_method("is_game_over_active")
		and bool(game_over_screen.call("is_game_over_active"))
	)


func _is_gameplay_available() -> bool:
	var player := get_tree().get_first_node_in_group("player")
	return player != null and is_instance_valid(player) and not player.is_queued_for_deletion()


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
