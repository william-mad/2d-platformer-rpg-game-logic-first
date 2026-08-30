class_name ModalDialogueUI
extends CanvasLayer

signal choice_requested(session_id: StringName, choice_id: StringName)
signal advance_requested(session_id: StringName)
signal cancel_requested(session_id: StringName)

const MOBILE_PORTRAIT_EDGE_MARGIN := 12.0
const MOBILE_PORTRAIT_WIDTH_TO_SCREEN_HEIGHT := 0.94
const MOBILE_PORTRAIT_MIN_WIDTH := 360.0
const MOBILE_PORTRAIT_MAX_WIDTH := 520.0
const MOBILE_PORTRAIT_FACE_CENTER_X_RATIO := 0.68
const MOBILE_PORTRAIT_FACE_TOP_RATIO := 0.09
const MOBILE_PORTRAIT_CHEST_CUTOFF_RATIO := 0.34

@export_range(1.0, 120.0, 1.0, "suffix: chars/s") var characters_per_second: float = 36.0
@export_range(1.0, 10.0, 0.25, "suffix:x") var held_advance_speed_multiplier: float = 4.0
@export var advance_action: StringName = &"attack"

@onready var panel: PanelContainer = %Panel
@onready var speaker_label: Label = %SpeakerName
@onready var dialogue_label: Label = %DialogueText
@onready var choice_container: VBoxContainer = %Choices
@onready var portrait_presenter: IntroMemoryPortraitPresenter = %AutonomousPortraitPresentation
@onready var portrait_slot: Control = $AutonomousPortraitPresentation/PortraitSlot
@onready var portrait_texture: TextureRect = %MemoryDialoguePortrait
@onready var portrait_blink_overlay: TextureRect = %DialoguePortraitBlinkOverlay
@onready var portrait_talk_overlay: TextureRect = %DialoguePortraitTalkOverlay
@onready var relationship_change_cue: Control = %RelationshipChangeCue

var active_session_id: StringName = &""
var input_enabled: bool = false
var _revealed_characters: float = 0.0
var _text_character_count: int = 0
var _portrait_revealed_session_id: StringName = &""
var _portrait_layout_refresh_queued: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)
	set_process_unhandled_input(true)
	if not get_viewport().size_changed.is_connected(_on_viewport_size_changed):
		get_viewport().size_changed.connect(_on_viewport_size_changed)
	if panel != null and not panel.resized.is_connected(_on_dialogue_panel_resized):
		panel.resized.connect(_on_dialogue_panel_resized)
	# Dialogue text/choices keep their authored layout. Only the portrait gets a
	# separate phone-aware presentation size.
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
	_queue_mobile_portrait_layout_refresh()

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
	_configure_mobile_portrait_layout(texture)


func _on_viewport_size_changed() -> void:
	_queue_mobile_portrait_layout_refresh()


func _on_dialogue_panel_resized() -> void:
	_queue_mobile_portrait_layout_refresh()


func _queue_mobile_portrait_layout_refresh() -> void:
	if _portrait_layout_refresh_queued:
		return
	_portrait_layout_refresh_queued = true
	call_deferred("_apply_queued_mobile_portrait_layout")


func _apply_queued_mobile_portrait_layout() -> void:
	_portrait_layout_refresh_queued = false
	if portrait_texture != null and portrait_texture.texture != null:
		_configure_mobile_portrait_layout(portrait_texture.texture)


func _get_phone_canvas_rect() -> Rect2:
	# The expanded game viewport is the phone/game surface. Using the Android
	# process window here also includes the Godot editor chrome when running the
	# project inside the mobile editor, which pushed portraits and controls beyond
	# the embedded game view.
	return get_viewport().get_visible_rect()


func _configure_mobile_portrait_layout(texture: Texture2D) -> void:
	if not OS.has_feature("mobile") or portrait_slot == null or texture == null:
		return
	var screen_rect := _get_phone_canvas_rect()
	var texture_size := texture.get_size()
	if (
		screen_rect.size.x <= 0.0
		or screen_rect.size.y <= 0.0
		or texture_size.x <= 0
		or texture_size.y <= 0
	):
		return

	var panel_top := panel.get_global_rect().position.y if panel != null else screen_rect.end.y
	var layout := calculate_mobile_portrait_layout(texture_size, screen_rect, panel_top)
	if layout.is_empty():
		return
	var slot_rect: Rect2 = layout["slot_rect"]
	var portrait_rect: Rect2 = layout["portrait_rect"]

	portrait_slot.anchor_left = 0.0
	portrait_slot.anchor_top = 0.0
	portrait_slot.anchor_right = 0.0
	portrait_slot.anchor_bottom = 0.0
	portrait_slot.offset_left = slot_rect.position.x
	portrait_slot.offset_top = slot_rect.position.y
	portrait_slot.offset_right = slot_rect.end.x
	portrait_slot.offset_bottom = slot_rect.end.y
	portrait_slot.clip_contents = true

	# The image is deliberately allowed to begin above the game surface. The slot
	# clips the hair at the screen edge and the body at the live dialogue-panel
	# edge, keeping the complete face and most of the chest above every panel size.
	# Blink/talk overlays remain children of this rect and therefore keep the same
	# framing, scale, clipping and presenter motion as the base portrait.
	var current_motion_x := portrait_texture.position.x
	portrait_texture.anchor_left = 0.0
	portrait_texture.anchor_top = 0.0
	portrait_texture.anchor_right = 0.0
	portrait_texture.anchor_bottom = 0.0
	portrait_texture.offset_left = current_motion_x + portrait_rect.position.x
	portrait_texture.offset_top = portrait_rect.position.y
	portrait_texture.offset_right = current_motion_x + portrait_rect.end.x
	portrait_texture.offset_bottom = portrait_rect.end.y
	portrait_texture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	portrait_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	for overlay in [portrait_blink_overlay, portrait_talk_overlay]:
		if overlay != null:
			overlay.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			overlay.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT


static func calculate_mobile_portrait_layout(
	texture_size: Vector2,
	screen_rect: Rect2,
	dialogue_panel_top: float
) -> Dictionary:
	if (
		texture_size.x <= 0.0
		or texture_size.y <= 0.0
		or screen_rect.size.x <= 0.0
		or screen_rect.size.y <= 0.0
	):
		return {}

	var screen_top := screen_rect.position.y
	var screen_right := screen_rect.end.x
	var clip_bottom := clampf(dialogue_panel_top, screen_top + 1.0, screen_rect.end.y)
	var portrait_space_height := maxf(clip_bottom - screen_top, 1.0)
	var texture_aspect := texture_size.x / texture_size.y
	var available_width := maxf(
		screen_rect.size.x - MOBILE_PORTRAIT_EDGE_MARGIN * 2.0,
		1.0
	)
	var desired_width := clampf(
		screen_rect.size.y * MOBILE_PORTRAIT_WIDTH_TO_SCREEN_HEIGHT,
		MOBILE_PORTRAIT_MIN_WIDTH,
		MOBILE_PORTRAIT_MAX_WIDTH
	)
	# Keep the authored face-top point on screen even when a choice list makes the
	# panel grow upward. This changes scale only when the remaining space demands it.
	var visible_source_ratio := maxf(
		MOBILE_PORTRAIT_CHEST_CUTOFF_RATIO - MOBILE_PORTRAIT_FACE_TOP_RATIO,
		0.01
	)
	var face_fit_width := (
		portrait_space_height * texture_aspect / visible_source_ratio
	)
	var target_width := maxf(
		minf(desired_width, minf(available_width, face_fit_width)),
		1.0
	)
	var target_height := target_width / texture_aspect
	var face_center_x := (
		screen_rect.position.x
		+ screen_rect.size.x * MOBILE_PORTRAIT_FACE_CENTER_X_RATIO
	)
	var slot_left := clampf(
		face_center_x - target_width * 0.5,
		screen_rect.position.x,
		screen_right - target_width
	)
	var portrait_top := (
		portrait_space_height
		- target_height * MOBILE_PORTRAIT_CHEST_CUTOFF_RATIO
	)

	return {
		"slot_rect": Rect2(
			Vector2(slot_left, screen_top),
			Vector2(target_width, portrait_space_height)
		),
		"portrait_rect": Rect2(
			Vector2(0.0, portrait_top),
			Vector2(target_width, target_height)
		),
	}


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
	visible = (
		relationship_change_cue != null
		and bool(relationship_change_cue.call("is_showing"))
	)
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
	_queue_mobile_portrait_layout_refresh()
	if first_button != null and input_enabled:
		call_deferred(
			"_focus_first_choice", active_session_id, weakref(first_button)
		)
