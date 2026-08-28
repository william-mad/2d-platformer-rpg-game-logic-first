extends CanvasLayer

const TITLE_FONT := preload("res://fonts/theme_showcase/AlegreyaSC-Bold.ttf")

# Autoload that listens for the player's player_defeated signal and shows a
# minimal game-over overlay. Load Game reloads the last save; Title returns to
# the main menu. Both reuse the existing SceneLoader + SaveSystem autoloads.
#
# The overlay is built entirely in code (mirroring SceneLoader's overlay) so no
# scene file needs to be wired up. It runs with PROCESS_MODE_ALWAYS so it stays
# interactive while the world is paused.

@export var title_scene_path: String = "res://scenes/levels/title_screen.tscn"

var root: Control
var overlay: ColorRect
var title_label: Label
var continue_button: Button
var title_button: Button
var center: VBoxContainer

var is_showing: bool = false
var connected_player: Node


func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_overlay()
	visible = false
	set_process_unhandled_input(false)
	# Connect lazily once the player is in the tree; re-checked each frame below.
	call_deferred("_connect_to_player")


func _process(_delta: float) -> void:
	# The player enters per-scene, so reconnect when it shows up after a scene load.
	if connected_player == null or not is_instance_valid(connected_player):
		_connect_to_player()


func _exit_tree() -> void:
	_disconnect_from_player()


func show_game_over() -> void:
	if is_showing:
		return

	is_showing = true

	# Pause the world (and the clock) but keep this overlay interactive.
	var pause_system := get_node_or_null("/root/PauseSystem")
	if pause_system != null and pause_system.has_method("set_paused"):
		pause_system.call("set_paused", true)
	else:
		get_tree().paused = true

	var can_continue := has_node("/root/SaveSystem") and bool(SaveSystem.save_exists())
	if continue_button != null:
		continue_button.disabled = not can_continue
		continue_button.text = "LOAD GAME" if can_continue else "NO SAVE"

	visible = true
	if continue_button != null:
		continue_button.grab_focus()


func is_game_over_active() -> bool:
	return is_showing


func hide_game_over_and_continue() -> void:
	# Reload the last save slot, which restores scene + player position + stats.
	if not has_node("/root/SaveSystem"):
		return

	is_showing = false
	visible = false
	# Unpause first: SaveSystem awaits process_frame during load, which never
	# advances while the tree is paused.
	_unpause_world()
	SaveSystem.load_game()


func hide_game_over_and_return_to_title() -> void:
	is_showing = false
	visible = false

	# Drop the dead player's runtime state so a fresh Start behaves cleanly.
	if has_node("/root/SaveSystem") and SaveSystem.has_method("clear_runtime_values"):
		SaveSystem.call("clear_runtime_values")

	_unpause_world()

	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("change_scene"):
		if bool(scene_loader.call("change_scene", title_scene_path)):
			return

	get_tree().change_scene_to_file(title_scene_path)


func _unpause_world() -> void:
	# Restore both the tree and the WorldTime auto-advance that PauseSystem saved off.
	var pause_system := get_node_or_null("/root/PauseSystem")
	if pause_system != null and pause_system.has_method("set_paused"):
		pause_system.call("set_paused", false)
		return

	if get_tree().paused:
		get_tree().paused = false


func _connect_to_player() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node
	if player == null or not is_instance_valid(player):
		return

	if player == connected_player and player.is_connected("player_defeated", _on_player_defeated):
		return

	_disconnect_from_player()

	if not player.has_signal("player_defeated"):
		# Older player scene without the signal; nothing to wire up.
		return

	connected_player = player
	if not player.is_connected("player_defeated", _on_player_defeated):
		player.connect("player_defeated", _on_player_defeated)


func _disconnect_from_player() -> void:
	if (
		connected_player != null
		and is_instance_valid(connected_player)
		and connected_player.is_connected("player_defeated", _on_player_defeated)
	):
		connected_player.disconnect("player_defeated", _on_player_defeated)

	connected_player = null


func _on_player_defeated() -> void:
	show_game_over()


func _build_overlay() -> void:
	root = Control.new()
	root.name = "GameOverRoot"
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	overlay = ColorRect.new()
	overlay.name = "GameOverOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.14902, 0.192157, 0.180392, 0.84)
	root.add_child(overlay)

	var wrapper := CenterContainer.new()
	wrapper.name = "GameOverCenter"
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(wrapper)

	center = VBoxContainer.new()
	center.name = "GameOverColumn"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.custom_minimum_size = Vector2(320.0, 0.0)
	center.add_theme_constant_override("separation", 18)
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	wrapper.add_child(center)

	title_label = Label.new()
	title_label.name = "GameOverTitle"
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_override("font", TITLE_FONT)
	title_label.add_theme_font_size_override("font_size", 40)
	title_label.add_theme_color_override("font_color", Color(0.772549, 0.415686, 0.290196, 1.0))
	title_label.add_theme_color_override("font_shadow_color", Color(0.501961, 0.4, 0.278431, 0.45))
	title_label.add_theme_constant_override("shadow_offset_x", 2)
	title_label.add_theme_constant_override("shadow_offset_y", 2)
	title_label.text = "YOU DIED"
	center.add_child(title_label)

	continue_button = _create_button("LOAD GAME")
	continue_button.pressed.connect(hide_game_over_and_continue)
	center.add_child(continue_button)

	title_button = _create_button("TITLE")
	title_button.pressed.connect(hide_game_over_and_return_to_title)
	center.add_child(title_button)


func _create_button(label_text: String) -> Button:
	var button := Button.new()
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.add_theme_font_size_override("font_size", 20)
	button.custom_minimum_size = Vector2(240.0, 0)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.text = label_text
	return button
