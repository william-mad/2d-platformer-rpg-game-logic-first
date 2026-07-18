class_name ModalDialogueUI
extends CanvasLayer

signal choice_requested(session_id: StringName, choice_id: StringName)
signal cancel_requested(session_id: StringName)

@onready var panel: PanelContainer = %Panel
@onready var speaker_label: Label = %SpeakerName
@onready var dialogue_label: Label = %DialogueText
@onready var choice_container: VBoxContainer = %Choices

var active_session_id: StringName = &""
var input_enabled: bool = false


func _ready() -> void:
	hide_and_clear()


func display_node(
	session_id: StringName,
	speaker_name: String,
	dialogue_node: DialogueNode
) -> bool:
	if session_id == &"" or dialogue_node == null or dialogue_node.choices.is_empty():
		return false

	_clear_choices()
	active_session_id = session_id
	speaker_label.text = speaker_name
	dialogue_label.text = dialogue_node.speaker_text
	input_enabled = true
	visible = true
	panel.visible = true

	var first_button: Button
	for choice in dialogue_node.choices:
		if choice == null:
			continue
		var button := Button.new()
		button.name = "Choice_%s" % String(choice.choice_id)
		button.text = choice.text
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_ALL
		button.pressed.connect(
			_on_choice_button_pressed.bind(session_id, choice.choice_id)
		)
		choice_container.add_child(button)
		if first_button == null:
			first_button = button

	if first_button == null:
		hide_and_clear()
		return false
	call_deferred("_focus_first_choice", session_id, weakref(first_button))
	return true


func disable_input() -> void:
	input_enabled = false
	for child in choice_container.get_children():
		var button := child as Button
		if button != null:
			button.disabled = true


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
	_clear_choices()


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or active_session_id == &"":
		return
	# Escape belongs to PauseSystem in this project. A separate ui_cancel binding may
	# still cancel dialogue without competing with the pause action.
	if event.is_action_pressed(&"pause"):
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
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
