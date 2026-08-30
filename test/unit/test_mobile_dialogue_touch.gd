extends "res://test/native_scene_tree_test.gd"

const DIALOGUE_UI_SCENE := preload("res://scenes/ui/modal_dialogue_ui.tscn")

var ui: ModalDialogueUI
var advance_count := 0
var choice_count := 0
var last_choice_id: StringName = &""


func before_each() -> void:
	advance_count = 0
	choice_count = 0
	last_choice_id = &""
	ui = DIALOGUE_UI_SCENE.instantiate() as ModalDialogueUI
	add_child_autofree(ui)
	ui.advance_requested.connect(_on_advance_requested)
	ui.choice_requested.connect(_on_choice_requested)


func after_each() -> void:
	if ui != null and is_instance_valid(ui):
		ui.hide_and_clear()


func test_first_touch_anywhere_finishes_current_line() -> void:
	var node := _plain_node("This line is still typing.")
	assert_true(ui.display_node(&"touch_session", "Mom", node))
	assert_eq(ui.dialogue_label.visible_characters, 0)

	ui.call("_input", _touch(Vector2(700.0, 80.0)))

	assert_eq(
		ui.dialogue_label.visible_characters,
		node.speaker_text.length(),
		"a touchscreen press anywhere should finish the current dialogue line"
	)
	assert_eq(advance_count, 0, "finishing text should not also skip the node")


func test_second_touch_anywhere_advances_dialogue_without_choices() -> void:
	var node := _plain_node("Tap to continue.")
	assert_true(ui.display_node(&"touch_session", "Mom", node))
	ui.call("_finish_text_reveal")

	ui.call("_input", _touch(Vector2(40.0, 40.0)))

	assert_eq(advance_count, 1, "touch outside the dialogue panel should behave like Z")


func test_choice_touch_commits_the_touched_option_not_the_focused_default() -> void:
	var node := DialogueNode.new()
	node.speaker_text = "Pick one."
	var first := DialogueChoice.new()
	first.choice_id = &"first"
	first.text = "First option"
	first.terminal = true
	var second := DialogueChoice.new()
	second.choice_id = &"second"
	second.text = "Second option"
	second.terminal = true
	node.choices = [first, second]
	assert_true(ui.display_node(&"choice_session", "Mom", node))
	ui.call("_finish_text_reveal")

	var first_button := ui.choice_container.get_child(0) as Button
	var second_button := ui.choice_container.get_child(1) as Button
	first_button.position = Vector2(80.0, 20.0)
	first_button.size = Vector2(300.0, 60.0)
	second_button.position = Vector2(80.0, 100.0)
	second_button.size = Vector2(300.0, 60.0)
	ui.call("_input", _touch(second_button.get_global_rect().get_center()))

	assert_eq(choice_count, 1, "touching a choice should commit exactly one choice")
	assert_eq(last_choice_id, &"second", "touch should select the option under the finger")
	assert_eq(advance_count, 0, "choice touch must not also advance the dialogue")


func test_touch_outside_visible_choices_does_not_pick_first_option() -> void:
	var node := DialogueNode.new()
	node.speaker_text = "Choose carefully."
	var choice := DialogueChoice.new()
	choice.choice_id = &"only"
	choice.text = "Only option"
	choice.terminal = true
	node.choices = [choice]
	assert_true(ui.display_node(&"choice_session", "Mom", node))
	ui.call("_finish_text_reveal")

	ui.call("_input", _touch(Vector2(740.0, 20.0)))

	assert_eq(choice_count, 0, "an unrelated screen tap must not auto-pick the focused choice")
	assert_eq(advance_count, 0, "choice nodes require touching an actual option")


func test_relationship_cue_survives_dialogue_close_without_consuming_touch() -> void:
	var cue := ui.relationship_change_cue
	var cue_group := cue.get_node("CueGroup") as Control
	var heart_icon := cue.get_node("CueGroup/HeartIcon") as TextureRect
	assert_eq(cue.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_eq(cue_group.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_eq(heart_icon.mouse_filter, Control.MOUSE_FILTER_IGNORE)

	cue.call("show_love_change", 1.0)
	assert_true(bool(cue.call("is_showing")))
	assert_true(
		ui.get_viewport().get_visible_rect().intersects(heart_icon.get_global_rect()),
		"the heart cue should remain inside the mobile game viewport"
	)

	ui.hide_and_clear()
	assert_true(ui.visible, "the CanvasLayer should remain visible while the heart fades")
	assert_false(ui.panel.visible, "closing dialogue should still hide the dialogue panel")
	ui.call("_input", _touch(heart_icon.get_global_rect().get_center()))
	assert_eq(advance_count, 0, "a fading heart must not advance a closed dialogue")
	assert_eq(choice_count, 0, "a fading heart must not select a closed dialogue choice")

	cue.call("_finish_cue")
	assert_false(ui.visible, "the idle CanvasLayer should hide after the heart finishes")


func test_mobile_portrait_frames_face_and_chest_above_choice_panel() -> void:
	var screen_rect := Rect2(Vector2.ZERO, Vector2(1188.0, 496.0))
	var panel_top := 234.0
	var layout := ModalDialogueUI.calculate_mobile_portrait_layout(
		Vector2(248.0, 496.0),
		screen_rect,
		panel_top
	)
	var slot_rect: Rect2 = layout["slot_rect"]
	var portrait_rect: Rect2 = layout["portrait_rect"]
	var face_top := (
		portrait_rect.position.y
		+ portrait_rect.size.y * ModalDialogueUI.MOBILE_PORTRAIT_FACE_TOP_RATIO
	)
	var chest_cutoff := (
		portrait_rect.position.y
		+ portrait_rect.size.y * ModalDialogueUI.MOBILE_PORTRAIT_CHEST_CUTOFF_RATIO
	)

	assert_true(is_equal_approx(slot_rect.position.y, 0.0), "portrait clip starts at game top")
	assert_true(is_equal_approx(slot_rect.end.y, panel_top), "portrait stops above choice panel")
	assert_true(face_top >= -0.01, "the complete face should remain inside the game surface")
	assert_true(
		is_equal_approx(chest_cutoff, slot_rect.size.y),
		"the authored upper-chest cutoff should meet the panel edge"
	)
	assert_true(
		portrait_rect.position.y < 0.0,
		"only the upper hair should be allowed to extend beyond the game surface"
	)
	assert_true(
		is_equal_approx(slot_rect.get_center().x, screen_rect.size.x * 0.68),
		"portrait face remains in its established right-side position"
	)


func test_plain_dialogue_uses_same_scale_with_more_upper_space() -> void:
	var screen_rect := Rect2(Vector2.ZERO, Vector2(1188.0, 496.0))
	var choice_layout := ModalDialogueUI.calculate_mobile_portrait_layout(
		Vector2(248.0, 496.0), screen_rect, 234.0
	)
	var plain_layout := ModalDialogueUI.calculate_mobile_portrait_layout(
		Vector2(248.0, 496.0), screen_rect, 306.0
	)
	var choice_portrait: Rect2 = choice_layout["portrait_rect"]
	var plain_portrait: Rect2 = plain_layout["portrait_rect"]
	var plain_slot: Rect2 = plain_layout["slot_rect"]

	assert_true(
		is_equal_approx(choice_portrait.size.x, plain_portrait.size.x),
		"portrait should not jump in scale when choices appear"
	)
	assert_true(is_equal_approx(plain_slot.end.y, 306.0), "plain portrait stops above panel")
	assert_true(
		plain_portrait.position.y > choice_portrait.position.y,
		"plain dialogue uses its extra space instead of hiding the chest behind the panel"
	)
	assert_same(
		ui.portrait_blink_overlay.get_parent(),
		ui.portrait_texture,
		"blink animation must inherit the reframed portrait transform"
	)
	assert_same(
		ui.portrait_talk_overlay.get_parent(),
		ui.portrait_texture,
		"talk animation must inherit the reframed portrait transform"
	)


func _plain_node(text: String) -> DialogueNode:
	var node := DialogueNode.new()
	node.speaker_text = text
	return node


func _touch(position: Vector2) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 7
	event.position = position
	event.pressed = true
	return event


func _on_advance_requested(_session_id: StringName) -> void:
	advance_count += 1


func _on_choice_requested(_session_id: StringName, choice_id: StringName) -> void:
	choice_count += 1
	last_choice_id = choice_id
