class_name SaveSpot extends Area2D

@export var save_slot: String = "slot_1"
@export var choose_slot_on_save: bool = true
@export var save_action: StringName = &"charm"
@export var ready_text: String = "C: SAVE"
@export var saved_text: String = "SAVED"
@export var missing_system_text: String = "No SaveSystem"
@export var save_menu_title: String = "CHOOSE SAVE FILE"
@export var save_menu_cancel_text: String = "BACK"
@export var feedback_seconds: float = 1.4
@export var interaction_priority: int = 80

@onready var label: Label = get_node_or_null("%Label") as Label
@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D

var feedback_timer: float = 0.0
var player_inside: bool = false
var save_menu_open: bool = false
var save_menu_layer: CanvasLayer
var save_menu_title_label: Label
var save_menu_slot_buttons: Array[Button] = []
var save_menu_cancel_button: Button
var active_player: Node2D
var player_control_claim_token: int = 0
var interaction_focused: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_update_label(ready_text)
	set_process(false)
	call_deferred("_refresh_player_inside")


func _process(delta: float) -> void:
	if feedback_timer > 0.0:
		feedback_timer = maxf(feedback_timer - delta, 0.0)
		if is_zero_approx(feedback_timer):
			_update_label(ready_text)

	if save_menu_open:
		_process_save_menu_shortcuts()
		return

	if not save_menu_open and is_zero_approx(feedback_timer):
		set_process(false)


func can_interact(actor: Node) -> bool:
	return (
		actor != null
		and is_instance_valid(actor)
		and actor == active_player
		and player_inside
		and not save_menu_open
	)


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	return _save_here(actor as Node2D)


func get_interaction_action(_actor: Node) -> StringName:
	return save_action


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return ready_text


func set_interaction_focused(_actor: Node, focused: bool) -> void:
	interaction_focused = focused
	_update_label_visibility()


func consume_player_interaction_input(actor: Node) -> bool:
	return save_menu_open and actor == active_player


func _save_here(player: Node2D) -> bool:
	# This is the only line a save point really needs: it asks the global save system to store the current scene.
	if not has_node("/root/SaveSystem"):
		_show_feedback(missing_system_text, false)
		return true

	if choose_slot_on_save:
		return _open_save_menu(player)

	_save_to_slot(save_slot)
	return true


func _save_to_slot(slot: String) -> void:
	_close_save_menu()
	save_slot = slot

	var success: bool = SaveSystem.save_current_game(slot)
	_show_feedback(saved_text if success else "Save failed", success)


func _show_feedback(message: String, success: bool) -> void:
	feedback_timer = feedback_seconds
	set_process(true)
	_update_label(message)
	_update_label_visibility()

	if zone_visual == null:
		return

	zone_visual.color = Color(0.26, 0.82, 0.43, 0.48) if success else Color(0.9, 0.14, 0.1, 0.48)


func _update_label(message: String) -> void:
	if label != null:
		label.text = message

	if zone_visual != null and message == ready_text:
		zone_visual.color = Color(0.25, 0.68, 0.95, 0.38)
	_update_label_visibility()


func _update_label_visibility() -> void:
	if label != null:
		label.visible = interaction_focused or feedback_timer > 0.0


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player_inside = true
		active_player = body
		if body.has_method("register_interaction_candidate"):
			body.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group("player"):
		if body.has_method("unregister_interaction_candidate"):
			body.call("unregister_interaction_candidate", self)
		player_inside = false
		_close_save_menu()
		if body == active_player:
			active_player = null


func _refresh_player_inside() -> void:
	if (
		active_player != null
		and is_instance_valid(active_player)
		and active_player.has_method("unregister_interaction_candidate")
	):
		active_player.call("unregister_interaction_candidate", self)
	player_inside = false
	active_player = null
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			player_inside = true
			active_player = body
			if body.has_method("register_interaction_candidate"):
				body.call("register_interaction_candidate", self)
			break

	set_process(feedback_timer > 0.0 or save_menu_open)


func _open_save_menu(player: Node2D) -> bool:
	if not has_node("/root/SaveSystem"):
		_show_feedback(missing_system_text, false)
		return true
	if not _acquire_player_control_claim(player):
		return false

	_ensure_save_menu()
	_refresh_save_menu()
	save_menu_open = true
	save_menu_layer.visible = true
	set_process(true)
	_focus_first_save_menu_button()
	return true


func _close_save_menu() -> void:
	if save_menu_layer != null:
		save_menu_layer.visible = false

	save_menu_open = false
	_release_player_control_claim()
	if is_zero_approx(feedback_timer):
		set_process(false)


func _exit_tree() -> void:
	_release_player_control_claim()


func _acquire_player_control_claim(player: Node2D) -> bool:
	if player_control_claim_token != 0:
		return player == active_player
	if not is_inside_tree():
		return false
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_method("acquire_player_control_claim"):
		return false
	player_control_claim_token = int(gameplay_flow.call(
		"acquire_player_control_claim", self, player, &"save_menu", &"ui_only"
	))
	return player_control_claim_token != 0


func _release_player_control_claim() -> void:
	if player_control_claim_token == 0:
		return
	if not is_inside_tree():
		player_control_claim_token = 0
		return
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow != null and gameplay_flow.has_method("release_player_control_claim"):
		gameplay_flow.call("release_player_control_claim", player_control_claim_token, self)
	player_control_claim_token = 0


func _process_save_menu_shortcuts() -> void:
	if has_node("/root/SaveSystem"):
		var slots: Array = SaveSystem.get_save_slots()
		for index in range(save_menu_slot_buttons.size()):
			var action := StringName("option%d" % [index + 1])
			if InputMap.has_action(action) and Input.is_action_just_pressed(action):
				if index < slots.size():
					_save_to_slot(String(slots[index]))
				return

	if _is_cancel_pressed():
		_close_save_menu()


func _is_cancel_pressed() -> bool:
	return (
		(InputMap.has_action(&"ui_cancel") and Input.is_action_just_pressed(&"ui_cancel"))
		or (InputMap.has_action(&"pause") and Input.is_action_just_pressed(&"pause"))
	)


func _ensure_save_menu() -> void:
	if save_menu_layer != null:
		return

	save_menu_layer = CanvasLayer.new()
	save_menu_layer.name = "SaveFileMenu"
	save_menu_layer.layer = 95
	save_menu_layer.visible = false
	add_child(save_menu_layer)

	var root := Control.new()
	root.name = "SaveFileMenuRoot"
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	save_menu_layer.add_child(root)

	var shade := ColorRect.new()
	shade.name = "SaveFileMenuShade"
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.01, 0.012, 0.014, 0.82)
	root.add_child(shade)

	var center := CenterContainer.new()
	center.name = "SaveFileMenuCenter"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var stack := VBoxContainer.new()
	stack.name = "SaveFileMenuStack"
	stack.custom_minimum_size = Vector2(390.0, 0.0)
	stack.add_theme_constant_override("separation", 12)
	center.add_child(stack)

	save_menu_title_label = Label.new()
	save_menu_title_label.name = "SaveFileMenuTitle"
	save_menu_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	save_menu_title_label.add_theme_font_size_override("font_size", 26)
	save_menu_title_label.add_theme_color_override("font_color", Color(0.98, 0.94, 0.82, 1.0))
	save_menu_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	save_menu_title_label.add_theme_constant_override("shadow_offset_x", 2)
	save_menu_title_label.add_theme_constant_override("shadow_offset_y", 2)
	stack.add_child(save_menu_title_label)

	for index in range(3):
		var button := _create_save_menu_button("File %d - Empty" % [index + 1])
		button.pressed.connect(_on_save_menu_slot_pressed.bind(index))
		save_menu_slot_buttons.append(button)
		stack.add_child(button)

	save_menu_cancel_button = _create_save_menu_button(save_menu_cancel_text)
	save_menu_cancel_button.pressed.connect(_close_save_menu)
	stack.add_child(save_menu_cancel_button)


func _refresh_save_menu() -> void:
	if save_menu_title_label != null:
		save_menu_title_label.text = save_menu_title

	if not has_node("/root/SaveSystem"):
		for button in save_menu_slot_buttons:
			button.text = missing_system_text
			button.disabled = true
		return

	var summaries: Array = SaveSystem.get_save_summaries()
	for index in range(save_menu_slot_buttons.size()):
		var button := save_menu_slot_buttons[index]
		if index >= summaries.size():
			button.visible = false
			continue

		var summary: Dictionary = summaries[index]
		button.visible = true
		button.disabled = false
		button.text = "%d: %s" % [
			index + 1,
			SaveSystem.format_save_summary(summary, "Empty"),
		]

	if save_menu_cancel_button != null:
		save_menu_cancel_button.text = save_menu_cancel_text


func _on_save_menu_slot_pressed(slot_index: int) -> void:
	if not has_node("/root/SaveSystem"):
		_show_feedback(missing_system_text, false)
		return

	var slots: Array = SaveSystem.get_save_slots()
	if slot_index < 0 or slot_index >= slots.size():
		return

	_save_to_slot(String(slots[slot_index]))


func _focus_first_save_menu_button() -> void:
	for button in save_menu_slot_buttons:
		if button.visible and not button.disabled:
			button.grab_focus()
			return

	if save_menu_cancel_button != null:
		save_menu_cancel_button.grab_focus()


func _create_save_menu_button(button_text: String) -> Button:
	var button := Button.new()
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.custom_minimum_size = Vector2(390.0, 52.0)
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", Color(0.98, 0.94, 0.82, 1.0))
	button.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.78, 1.0))
	button.add_theme_color_override("font_pressed_color", Color(0.54, 0.87, 0.68, 1.0))
	button.add_theme_color_override("font_disabled_color", Color(0.48, 0.5, 0.5, 1.0))
	button.text = button_text
	return button
