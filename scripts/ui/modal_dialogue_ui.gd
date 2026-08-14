class_name ModalDialogueUI
extends CanvasLayer

signal choice_requested(session_id: StringName, choice_id: StringName)
signal advance_requested(session_id: StringName)
signal cancel_requested(session_id: StringName)

@export_range(1.0, 120.0, 1.0, "suffix: chars/s") var characters_per_second: float = 36.0
@export_range(1.0, 10.0, 0.25, "suffix:x") var held_advance_speed_multiplier: float = 4.0
@export var advance_action: StringName = &"attack"

@onready var panel: PanelContainer = %Panel
@onready var speaker_label: Label = %SpeakerName
@onready var dialogue_label: Label = %DialogueText
@onready var choice_container: VBoxContainer = %Choices

var active_session_id: StringName = &""
var input_enabled: bool = false
var _revealed_characters: float = 0.0
var _text_character_count: int = 0


func _ready() -> void:
	hide_and_clear()


func _process(delta: float) -> void:
	if (
		active_session_id == &""
		or not visible
		or dialogue_label == null
		or _is_text_fully_revealed()
	):
		return
	var speed := characters_per_second
	if Input.is_action_pressed(advance_action):
		speed *= held_advance_speed_multiplier
	_revealed_characters = minf(
		float(_text_character_count),
		_revealed_characters + speed * delta
	)
	dialogue_label.visible_characters = mini(
		_text_character_count,
		int(floor(_revealed_characters))
	)


func display_node(
	session_id: StringName,
	speaker_name: String,
	dialogue_node: DialogueNode
) -> bool:
	if session_id == &"" or dialogue_node == null:
		return false

	_clear_choices()
	active_session_id = session_id
	speaker_label.text = speaker_name
	dialogue_label.text = dialogue_node.speaker_text
	_text_character_count = dialogue_node.speaker_text.length()
	_revealed_characters = 0.0
	dialogue_label.visible_characters = 0
	input_enabled = true
	visible = true
	panel.visible = true

	var first_button: Button
	for choice in dialogue_node.choices:
		if choice == null:
			continue
		var button := Button.new()
		button.name = "Choice_%s" % String(choice.choice_id)
		button.set_meta(&"choice_id", choice.choice_id)
		button.text = choice.text
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_ALL
		button.pressed.connect(
			_on_choice_button_pressed.bind(session_id, choice.choice_id)
		)
		choice_container.add_child(button)
		if first_button == null:
			first_button = button

	if first_button != null:
		call_deferred("_focus_first_choice", session_id, weakref(first_button))
	return true


func disable_input() -> void:
	input_enabled = false
	for child in choice_container.get_children():
		var button := child as Button
		if button != null:
			button.disabled = true


func enable_input(session_id: StringName) -> bool:
	if session_id == &"" or session_id != active_session_id:
		return false
	input_enabled = true
	var first_button: Button
	for child in choice_container.get_children():
		var button := child as Button
		if button == null:
			continue
		button.disabled = false
		if first_button == null:
			first_button = button
	if first_button != null:
		call_deferred("_focus_first_choice", session_id, weakref(first_button))
	return true


func set_session_visible(session_id: StringName, should_show: bool) -> bool:
	if session_id == &"" or session_id != active_session_id:
		return false
	visible = should_show
	if panel != null:
		panel.visible = should_show
	return true


func hide_and_clear() -> void:
	disable_input()
	active_session_id = &""
	visible = false
	if panel != null:
		panel.visible = false
	if speaker_label != null:
		speaker_label.text = ""
	if dialogue_label != null:
		dialogue_label.text = ""
		dialogue_label.visible_characters = -1
	_revealed_characters = 0.0
	_text_character_count = 0
	_clear_choices()


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or active_session_id == &"":
		return
	# Escape belongs to PauseSystem in this project. A separate ui_cancel binding may
	# still cancel dialogue without competing with the pause action.
	if event.is_action_pressed(&"pause"):
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return
	if event.is_action_pressed(advance_action):
		get_viewport().set_input_as_handled()
		if not _is_text_fully_revealed():
			return
		var session_id := active_session_id
		var focused_button := get_viewport().gui_get_focus_owner() as Button
		if focused_button != null and focused_button.get_parent() == choice_container:
			_on_choice_button_pressed(
				session_id,
				StringName(focused_button.get_meta(&"choice_id", &""))
			)
			return
		var first_button := _get_first_choice_button()
		if first_button != null:
			_on_choice_button_pressed(
				session_id,
				StringName(first_button.get_meta(&"choice_id", &""))
			)
			return
		disable_input()
		advance_requested.emit(session_id)
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return
	var session_id := active_session_id
	disable_input()
	get_viewport().set_input_as_handled()
	cancel_requested.emit(session_id)


func _on_choice_button_pressed(session_id: StringName, choice_id: StringName) -> void:
	if not input_enabled or session_id == &"" or session_id != active_session_id:
		return
	disable_input()
	choice_requested.emit(session_id, choice_id)


func _focus_first_choice(session_id: StringName, button_ref: WeakRef) -> void:
	if not input_enabled or session_id != active_session_id or button_ref == null:
		return
	var button := button_ref.get_ref() as Button
	if button == null or not is_instance_valid(button) or not button.is_inside_tree():
		return
	button.grab_focus()


func _clear_choices() -> void:
	if choice_container == null:
		return
	for child in choice_container.get_children():
		choice_container.remove_child(child)
		child.queue_free()


func _is_text_fully_revealed() -> bool:
	return dialogue_label == null or dialogue_label.visible_characters >= _text_character_count


func _get_first_choice_button() -> Button:
	if choice_container == null:
		return null
	for child in choice_container.get_children():
		var button := child as Button
		if button != null:
			return button
	return null
