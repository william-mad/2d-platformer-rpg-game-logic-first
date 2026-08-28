class_name TitleScreen extends Control

const FOCUS_COLOR := Color(0.721569, 0.368627, 0.262745, 1.0)
const OPTION_LABEL_COLOR := Color(0.14902, 0.192157, 0.180392, 1.0)
const FILLED_FOCUS_COLOR := Color(1.0, 0.945098, 0.823529, 1.0)

@export_file("*.tscn") var start_scene_path: String = "res://scenes/levels/start_game_intro.tscn"
@export var preload_scenes_on_title: bool = false

@onready var start_button: Button = %StartButton
@onready var load_button: Button = _get_load_button()
@onready var options_button: Button = %OptionsButton
@onready var save_file_menu: Control = get_node_or_null("%SaveFileMenu") as Control
@onready var no_saves_label: Label = get_node_or_null("%NoSavesLabel") as Label
@onready var close_load_menu_button: Button = get_node_or_null("%CloseLoadMenuButton") as Button
@onready var options_menu: Control = %OptionsMenu
@onready var volume_label: Label = %VolumeLabel
@onready var master_volume_slider: HSlider = %MasterVolumeSlider
@onready var master_volume_value: Label = %MasterVolumeValue
@onready var fullscreen_toggle: CheckButton = %FullscreenToggle
@onready var back_options_button: Button = %BackOptionsButton

var save_slot_buttons: Array[Button] = []
var _syncing_options := false


func _ready() -> void:
	if has_node("/root/PlayerHud"):
		get_node("/root/PlayerHud").set("visible", false)

	if preload_scenes_on_title:
		_preload_scene(start_scene_path)

	start_button.pressed.connect(_on_start_button_pressed)
	_configure_load_menu()
	_refresh_load_button()

	options_button.pressed.connect(_show_options_menu)
	master_volume_slider.value_changed.connect(_on_master_volume_changed)
	fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	back_options_button.pressed.connect(_hide_options_menu)
	_sync_options_controls()
	_configure_focus_cues()
	start_button.grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return
	var wants_to_close := event.is_action_pressed(&"ui_cancel")
	if InputMap.has_action(&"pause"):
		wants_to_close = wants_to_close or event.is_action_pressed(&"pause")
	if not wants_to_close:
		return
	if options_menu.visible:
		_hide_options_menu()
		get_viewport().set_input_as_handled()
	elif save_file_menu != null and save_file_menu.visible:
		_hide_save_file_menu()
		get_viewport().set_input_as_handled()


func _configure_focus_cues() -> void:
	for button in [start_button, load_button, options_button]:
		_register_focus_button(button)
	_register_focus_button(close_load_menu_button)
	_register_focus_button(fullscreen_toggle)
	_register_focus_button(back_options_button)
	master_volume_slider.focus_entered.connect(_on_volume_focus_entered)
	master_volume_slider.focus_exited.connect(_on_volume_focus_exited)


func _register_focus_button(button: Button) -> void:
	if button == null or button.has_meta("focus_cue_registered"):
		return
	button.set_meta("focus_cue_registered", true)
	var cue := Label.new()
	cue.name = "FocusCue"
	cue.text = "▶"
	cue.visible = false
	cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cue.z_index = 1
	cue.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	cue.offset_left = 7.0
	cue.offset_right = 23.0
	cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cue.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cue.add_theme_color_override(
		"font_color",
		FOCUS_COLOR if button is CheckButton else FILLED_FOCUS_COLOR
	)
	button.add_child(cue)
	button.set_meta("focus_cue_label", cue)
	button.focus_entered.connect(_on_focus_button_entered.bind(button))
	button.focus_exited.connect(_on_focus_button_exited.bind(button))


func _on_focus_button_entered(button: Button) -> void:
	var cue := button.get_meta("focus_cue_label") as Label
	if cue != null:
		cue.visible = true


func _on_focus_button_exited(button: Button) -> void:
	var cue := button.get_meta("focus_cue_label") as Label
	if cue != null:
		cue.visible = false


func _on_volume_focus_entered() -> void:
	volume_label.text = "▶  MASTER VOLUME"
	volume_label.add_theme_color_override("font_color", FOCUS_COLOR)


func _on_volume_focus_exited() -> void:
	volume_label.text = "MASTER VOLUME"
	volume_label.add_theme_color_override("font_color", OPTION_LABEL_COLOR)


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

	options_menu.visible = false
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


func _show_options_menu() -> void:
	if save_file_menu != null:
		save_file_menu.visible = false
	_sync_options_controls()
	options_menu.visible = true
	master_volume_slider.grab_focus.call_deferred()


func _hide_options_menu() -> void:
	options_menu.visible = false
	options_button.grab_focus()


func _sync_options_controls() -> void:
	_syncing_options = true
	var game_settings := get_node_or_null("/root/GameSettings")
	if game_settings != null:
		if game_settings.has_method("get_master_volume"):
			master_volume_slider.value = float(
				game_settings.call("get_master_volume")
			) * 100.0
		if game_settings.has_method("is_fullscreen"):
			fullscreen_toggle.button_pressed = bool(
				game_settings.call("is_fullscreen")
			)
	master_volume_value.text = "%d%%" % roundi(master_volume_slider.value)
	_syncing_options = false


func _on_master_volume_changed(value: float) -> void:
	master_volume_value.text = "%d%%" % roundi(value)
	if _syncing_options:
		return
	var game_settings := get_node_or_null("/root/GameSettings")
	if game_settings != null and game_settings.has_method("set_master_volume"):
		game_settings.call("set_master_volume", value / 100.0)


func _on_fullscreen_toggled(enabled: bool) -> void:
	if _syncing_options:
		return
	var game_settings := get_node_or_null("/root/GameSettings")
	if game_settings != null and game_settings.has_method("set_fullscreen"):
		game_settings.call("set_fullscreen", enabled)


func _refresh_save_file_menu() -> void:
	var loadable_count := 0
	if not has_node("/root/SaveSystem"):
		for button in save_slot_buttons:
			button.text = "No SaveSystem"
			button.disabled = true
		if no_saves_label != null:
			no_saves_label.visible = true
			no_saves_label.text = "No save system found."
		_configure_load_menu_focus()
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
	_configure_load_menu_focus()


func _configure_load_menu_focus() -> void:
	if close_load_menu_button == null:
		return
	var controls: Array[Button] = []
	for button in save_slot_buttons:
		if button.visible and not button.disabled:
			controls.append(button)
	controls.append(close_load_menu_button)
	for index in controls.size():
		var button := controls[index]
		var previous := controls[wrapi(index - 1, 0, controls.size())]
		var next := controls[wrapi(index + 1, 0, controls.size())]
		button.focus_neighbor_top = button.get_path_to(previous)
		button.focus_neighbor_bottom = button.get_path_to(next)


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
