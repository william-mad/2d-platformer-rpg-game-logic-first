class_name TitleScreen extends Control

@export_file("*.tscn") var start_scene_path: String = "res://scenes/levels/start_game_intro.tscn"
@export_file("*.tscn") var playground_scene_path: String = "res://scenes/levels/playground.tscn"
@export var preload_scenes_on_title: bool = false

@onready var start_button: Button = %StartButton
@onready var load_button: Button = _get_load_button()
@onready var playground_button: Button = %PlaygroundButton
@onready var save_file_menu: Control = get_node_or_null("%SaveFileMenu") as Control
@onready var no_saves_label: Label = get_node_or_null("%NoSavesLabel") as Label
@onready var close_load_menu_button: Button = get_node_or_null("%CloseLoadMenuButton") as Button

var save_slot_buttons: Array[Button] = []


func _ready() -> void:
	if has_node("/root/PlayerHud"):
		PlayerHud.visible = false

	if preload_scenes_on_title:
		_preload_scene(start_scene_path)
		_preload_scene(playground_scene_path)

	start_button.pressed.connect(_on_start_button_pressed)
	_configure_load_menu()
	_refresh_load_button()

	playground_button.pressed.connect(_on_playground_button_pressed)


func _on_start_button_pressed() -> void:
	if has_node("/root/SaveSystem"):
		SaveSystem.clear_runtime_values()
	var memory_repository := get_node_or_null(
		"/root/NpcMemoryRuntimeRepository"
	)
	if memory_repository != null:
		memory_repository.call("clear_all_runtime_memory", &"new_game")

	load_scene(start_scene_path)


func _on_load_button_pressed() -> void:
	if not has_node("/root/SaveSystem"):
		return

	_show_save_file_menu()


func _on_playground_button_pressed() -> void:
	load_scene(playground_scene_path)


func load_scene(scene_path: String) -> void:
	if scene_path.is_empty():
		push_warning("TitleScreen target scene path is empty.")
		return

	if _change_scene_with_loader(scene_path):
		return

	get_tree().change_scene_to_file(scene_path)


func _configure_load_menu() -> void:
	save_slot_buttons.clear()
	for button_name in ["%SaveSlot1Button", "%SaveSlot2Button", "%SaveSlot3Button"]:
		var button := get_node_or_null(button_name) as Button
		if button == null:
			continue

		var slot_index := save_slot_buttons.size()
		save_slot_buttons.append(button)
		button.pressed.connect(_on_save_slot_button_pressed.bind(slot_index))

	if load_button != null:
		load_button.text = "LOAD GAME"
		load_button.pressed.connect(_on_load_button_pressed)

	if close_load_menu_button != null:
		close_load_menu_button.pressed.connect(_hide_save_file_menu)

	if save_file_menu != null:
		save_file_menu.visible = false


func _refresh_load_button() -> void:
	if load_button == null:
		return

	load_button.disabled = not has_node("/root/SaveSystem")


func _show_save_file_menu() -> void:
	_refresh_save_file_menu()
	if save_file_menu == null:
		return

	save_file_menu.visible = true
	var focus_button := _get_first_enabled_slot_button()
	if focus_button != null:
		focus_button.grab_focus()
	elif close_load_menu_button != null:
		close_load_menu_button.grab_focus()


func _hide_save_file_menu() -> void:
	if save_file_menu != null:
		save_file_menu.visible = false

	if load_button != null:
		load_button.grab_focus()


func _refresh_save_file_menu() -> void:
	var loadable_count := 0
	if not has_node("/root/SaveSystem"):
		for button in save_slot_buttons:
			button.text = "No SaveSystem"
			button.disabled = true
		if no_saves_label != null:
			no_saves_label.visible = true
			no_saves_label.text = "No save system found."
		return

	var summaries: Array = SaveSystem.get_save_summaries()
	for index in range(save_slot_buttons.size()):
		var button := save_slot_buttons[index]
		if index >= summaries.size():
			button.visible = false
			continue

		var summary: Dictionary = summaries[index]
		var can_load := bool(summary.get("exists", false)) and bool(summary.get("valid", false))
		button.visible = true
		button.text = SaveSystem.format_save_summary(summary, "Empty")
		button.disabled = not can_load
		if can_load:
			loadable_count += 1

	if no_saves_label != null:
		no_saves_label.visible = loadable_count == 0
		no_saves_label.text = "No saved games yet." if loadable_count == 0 else ""


func _on_save_slot_button_pressed(slot_index: int) -> void:
	if not has_node("/root/SaveSystem"):
		return

	var slots: Array = SaveSystem.get_save_slots()
	if slot_index < 0 or slot_index >= slots.size():
		return

	var slot := String(slots[slot_index])
	if not SaveSystem.save_exists(slot):
		return

	_hide_save_file_menu()
	SaveSystem.load_game(slot)


func _get_first_enabled_slot_button() -> Button:
	for button in save_slot_buttons:
		if button.visible and not button.disabled:
			return button

	return null


func _get_load_button() -> Button:
	var button := get_node_or_null("%LoadButton") as Button
	if button == null:
		button = get_node_or_null("%ContinueButton") as Button

	return button


func _preload_scene(scene_path: String) -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", scene_path)


func _change_scene_with_loader(scene_path: String) -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false

	return bool(scene_loader.call("change_scene", scene_path))
