class_name TitleScreen extends Control

@export_file("*.tscn") var start_scene_path: String = "res://scenes/levels/level_1.tscn"
@export_file("*.tscn") var playground_scene_path: String = "res://scenes/levels/playground.tscn"

@onready var start_button: Button = %StartButton
@onready var playground_button: Button = %PlaygroundButton


func _ready() -> void:
	if has_node("/root/PlayerHud"):
		PlayerHud.visible = false

	start_button.pressed.connect(_on_start_button_pressed)
	playground_button.pressed.connect(_on_playground_button_pressed)


func _on_start_button_pressed() -> void:
	load_scene(start_scene_path)


func _on_playground_button_pressed() -> void:
	load_scene(playground_scene_path)


func load_scene(scene_path: String) -> void:
	if scene_path.is_empty():
		push_warning("TitleScreen target scene path is empty.")
		return

	get_tree().change_scene_to_file(scene_path)
