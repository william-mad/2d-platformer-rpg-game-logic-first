class_name TitleScreen extends Control

@export_file("*.tscn") var start_scene_path: String = "res://scenes/levels/level_1.tscn"
@export_file("*.tscn") var playground_scene_path: String = "res://scenes/levels/playground.tscn"
@export var preload_scenes_on_title: bool = false

@onready var start_button: Button = %StartButton
@onready var continue_button: Button = get_node_or_null("%ContinueButton") as Button
@onready var playground_button: Button = %PlaygroundButton


func _ready() -> void:
	if has_node("/root/PlayerHud"):
		PlayerHud.visible = false

	if preload_scenes_on_title:
		_preload_scene(start_scene_path)
		_preload_scene(playground_scene_path)

	start_button.pressed.connect(_on_start_button_pressed)
	if continue_button != null:
		continue_button.pressed.connect(_on_continue_button_pressed)
		continue_button.disabled = not _can_continue_game()

	playground_button.pressed.connect(_on_playground_button_pressed)


func _on_start_button_pressed() -> void:
	if has_node("/root/SaveSystem"):
		SaveSystem.clear_runtime_values()

	load_scene(start_scene_path)


func _on_continue_button_pressed() -> void:
	if not _can_continue_game():
		return

	SaveSystem.load_game()


func _on_playground_button_pressed() -> void:
	load_scene(playground_scene_path)


func load_scene(scene_path: String) -> void:
	if scene_path.is_empty():
		push_warning("TitleScreen target scene path is empty.")
		return

	if _change_scene_with_loader(scene_path):
		return

	get_tree().change_scene_to_file(scene_path)


func _can_continue_game() -> bool:
	return has_node("/root/SaveSystem") and SaveSystem.save_exists()


func _preload_scene(scene_path: String) -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", scene_path)


func _change_scene_with_loader(scene_path: String) -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false

	return bool(scene_loader.call("change_scene", scene_path))
