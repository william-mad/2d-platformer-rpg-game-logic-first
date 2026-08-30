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
@onready var portrait_presenter: IntroMemoryPortraitPresenter = %AutonomousPortraitPresentation
@onready var portrait_texture: TextureRect = %MemoryDialoguePortrait

var active_session_id: StringName = &""
var input_enabled: bool = false
var _revealed_characters: float = 0.0
var _text_character_count: int = 0
var _portrait_revealed_session_id: StringName = &""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)
	set_process_unhandled_input(true)
	# Keep the dialogue presentation at the scene's original desktop-sized
	# layout on mobile. Touch support must not resize the dialogue box.
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
	_reveal_choices_if_text_finished()


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
	choice_container.visible = false

	for choice in dialogue_node.choices:
		if choice == null:
			continue
		var button := Button.new()
		button.name = "Choice_%s" % String(choice.choice_id)
		button.set_meta(&"choice_id", choice.choice_id)
		button.text = choice.text
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_ALL
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.disabled = true
		button.pressed.connect(
			_on_choice_button_pressed.bind(session_id, choice.choice_id)
		)
		# Keep normal GUI handling as a fallback for mouse-emulated touch and
		# desktop clicks. Raw touchscreen input is handled earlier in _input().
		button.gui_input.connect(
			_on_choice_button_gui_input.bind(session_id, choice.choice_id)
		)
		choice_container.add_child(button)

	_reveal_choices_if_text_finished()
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
	_reveal_choices_if_text_finished()
	return true


func set_session_visible(session_id: StringName, should_show: bool) -> bool:
	if session_id == &"" or session_id != active_session_id:
		return false
	visible = should_show
	if panel != null:
		panel.visible = should_show
	return true


func configure_portrait_presentation(
	dialogue_id: StringName,
	presentation: Dictionary
) -> void:
	if portrait_presenter == null or portrait_texture == null:
		return
	_portrait_revealed_session_id = &""
	var texture := presentation.get("portrait", null) as Texture2D
	if dialogue_id == &"" or texture == null:
		portrait_presenter.dialogue_id = &""
		portrait_presenter.configure_portrait_animation(null)
		portrait_presenter.visible = false
		portrait_texture.texture = null
		return

	portrait_presenter.dialogue_id = dialogue_id
	portrait_presenter.portrait_speaker_id = StringName(
		presentation.get("speaker_id", &"npc")
	)
	portrait_presenter.player_speaker_id = StringName(
		presentation.get("player_speaker_id", &"player")
	)
	portrait_presenter.configure_portrait_animation(
		presentation.get("portrait_animation", null) as DialoguePortraitAnimationProfile
	)
	portrait_texture.texture = texture


func reveal_portrait_presentation(session_id: StringName) -> bool:
	if portrait_presenter == null or portrait_texture == null:
		return false
	if portrait_texture.texture == null:
		return false
	if _portrait_revealed_session_id == session_id:
		return true
	var revealed := portrait_presenter.reveal_session(session_id)
	if revealed:
		_portrait_revealed_session_id = session_id
	return revealed


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
	if choice_container != null:
		choice_container.visible = false
	_revealed_characters = 0.0
	_text_character_count = 0
	_clear_choices()


func _input(event: InputEvent) -> void:
	if not input_enabled or active_session_id == &"" or not visible:
		return
	var touch := event as InputEventScreenTouch
	if touch == null or not touch.pressed:
		return

	# Dialogue owns every touchscreen press before the gameplay overlay can see
	# it. During ordinary dialogue, tapping anywhere behaves like the Z/advance
	# action. Once choices are visible, taps must land on a specific choice so an
	# accidental tap never commits the focused/first response.
	get_viewport().set_input_as_handled()
	if not _is_text_fully_revealed():
		_finish_text_reveal()
		return

	var touched_choice := _get_choice_button_at_position(touch.position)
	if touched_choice != null:
		_on_choice_button_pressed(
			active_session_id,
			StringName(touched_choice.get_meta(&"choice_id", &""))
		)
		return
	if _has_visible_choices():
		return
	_emit_advance_requested()


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
		_handle_advance_press(true)
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return
	var session_id := active_session_id
	disable_input()
	get_viewport().set_input_as_handled()
	cancel_requested.emit(session_id)


func _handle_advance_press(allow_choice_fallback: bool) -> void:
	if not _is_text_fully_revealed():
		_finish_text_reveal()
		return

	var session_id := active_session_id
	if _has_visible_choices():
		var focused_button := get_viewport().gui_get_focus_owner() as Button
		if focused_button != null and focused_button.get_parent() == choice_container:
			_on_choice_button_pressed(
				session_id,
				StringName(focused_button.get_meta(&"choice_id", &""))
			)
			return
		if allow_choice_fallback:
			var first_button := _get_first_choice_button()
			if first_button != null:
				_on_choice_button_pressed(
					session_id,
					StringName(first_button.get_meta(&"choice_id", &""))
				)
		return

	_emit_advance_requested()


func _finish_text_reveal() -> void:
	if dialogue_label == null:
		return
	_revealed_characters = float(_text_character_count)
	dialogue_label.visible_characters = _text_character_count
	_reveal_choices_if_text_finished()


func _emit_advance_requested() -> void:
	var session_id := active_session_id
	if session_id == &"":
		return
	disable_input()
	advance_requested.emit(session_id)


func _on_choice_button_gui_input(
	event: InputEvent,
	session_id: StringName,
	choice_id: StringName
) -> void:
	var touch := event as InputEventScreenTouch
	if touch == null or not touch.pressed:
		return
	_on_choice_button_pressed(session_id, choice_id)


func _on_choice_button_pressed(session_id: StringName, choice_id: StringName) -> void:
	if (
		not input_enabled
		or not _is_text_fully_revealed()
		or session_id == &""
		or session_id != active_session_id
	):
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
	choice_container.visible = false
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


func _has_visible_choices() -> bool:
	return choice_container != null and choice_container.visible and _get_first_choice_button() != null


func _get_choice_button_at_position(position: Vector2) -> Button:
	if choice_container == null or not choice_container.visible:
		return null
	for child in choice_container.get_children():
		var button := child as Button
		if (
			button != null
			and button.visible
			and not button.disabled
			and button.get_global_rect().has_point(position)
		):
			return button
	return null


func _reveal_choices_if_text_finished() -> void:
	if choice_container == null or not _is_text_fully_revealed():
		return
	var first_button: Button
	for child in choice_container.get_children():
		var button := child as Button
		if button == null:
			continue
		button.disabled = not input_enabled
		if first_button == null:
			first_button = button
	choice_container.visible = first_button != null
	if first_button != null and input_enabled:
		call_deferred(
			"_focus_first_choice", active_session_id, weakref(first_button)
		)
