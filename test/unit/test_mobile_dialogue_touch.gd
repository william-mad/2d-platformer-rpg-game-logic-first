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
