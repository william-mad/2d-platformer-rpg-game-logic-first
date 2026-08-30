extends "res://test/native_scene_tree_test.gd"

const MobileControlsClass := preload("res://scripts/ui/mobile_gameplay_controls.gd")

var controls: MobileGameplayControls


func before_each() -> void:
	controls = MobileControlsClass.new()
	controls.force_enabled = true
	controls.set_deferred("size", Vector2(754.0, 496.0))
	add_child_autofree(controls)
	controls.size = Vector2(754.0, 496.0)
	controls.refresh_for_platform()


func after_each() -> void:
	controls.call("_release_all_actions")


func test_force_enabled_exposes_controls_for_headless_verification() -> void:
	assert_true(controls.visible, "forced mobile controls should be visible in headless tests")
	assert_eq(controls.get_action_button_center(&"attack"), Vector2(56.0, 430.0))
	assert_eq(controls.get_action_button_center(&"attach_rope"), Vector2(142.0, 430.0))
	assert_eq(controls.get_action_button_center(&"charm"), Vector2(99.0, 344.0))
	assert_eq(controls.get_joystick_center(), Vector2(658.0, 392.0))
	assert_eq(controls.get_menu_button_center(), Vector2(377.0, 34.0))


func test_player_hud_contains_mobile_control_overlay() -> void:
	var hud_scene := load("res://00 _global/player_hud/player hud.tscn") as PackedScene
	assert_not_null(hud_scene, "player HUD scene should load")
	var hud := hud_scene.instantiate()
	add_child_autofree(hud)
	assert_not_null(
		hud.get_node_or_null("MobileGameplayControls"),
		"player HUD should include the mobile controls overlay"
	)


func test_menu_touch_target_is_centered_without_adding_a_panel() -> void:
	assert_true(
		bool(controls.call("_is_menu_touch", controls.get_menu_button_center())),
		"MENU label center should be a valid touch target"
	)
	assert_false(
		bool(controls.call("_is_menu_touch", Vector2(377.0, 150.0))),
		"MENU touch target should stay compact near the top edge"
	)


func test_unowned_touch_is_left_for_other_mobile_ui() -> void:
	assert_false(
		bool(controls.call("_begin_touch", 99, Vector2(377.0, 150.0))),
		"touches away from gameplay controls must remain available to dialogue and menus"
	)
	assert_false(bool(controls.call("_end_touch", 99)))


func test_z_button_presses_and_releases_attack() -> void:
	controls.call("_input", _touch(1, controls.get_action_button_center(&"attack"), true))
	assert_true(Input.is_action_pressed(&"attack"), "Z touch should press attack")
	controls.call("_input", _touch(1, controls.get_action_button_center(&"attack"), false))
	assert_false(Input.is_action_pressed(&"attack"), "lifting Z touch should release attack")


func test_x_and_c_buttons_support_simultaneous_touches() -> void:
	controls.call("_input", _touch(2, controls.get_action_button_center(&"attach_rope"), true))
	controls.call("_input", _touch(3, controls.get_action_button_center(&"charm"), true))
	assert_true(Input.is_action_pressed(&"attach_rope"), "X touch should press rope")
	assert_true(Input.is_action_pressed(&"charm"), "C touch should press interaction")
	controls.call("_input", _touch(2, controls.get_action_button_center(&"attach_rope"), false))
	assert_false(Input.is_action_pressed(&"attach_rope"), "X releases independently")
	assert_true(Input.is_action_pressed(&"charm"), "C remains held by its own finger")
	controls.call("_input", _touch(3, controls.get_action_button_center(&"charm"), false))


func test_joystick_translates_horizontal_drag_to_actions() -> void:
	var center := controls.get_joystick_center()
	controls.call("_input", _touch(4, center + Vector2(60.0, 0.0), true))
	assert_true(Input.is_action_pressed(&"right"), "rightward joystick touch should press right")
	controls.call("_input", _drag(4, center + Vector2(-60.0, 0.0)))
	assert_false(Input.is_action_pressed(&"right"), "crossing the joystick should release right")
	assert_true(Input.is_action_pressed(&"left"), "crossing the joystick should press left")
	controls.call("_input", _touch(4, center + Vector2(-60.0, 0.0), false))
	assert_false(Input.is_action_pressed(&"left"), "lifting joystick touch should release movement")


func test_joystick_up_provides_platformer_jump_and_up_actions() -> void:
	var center := controls.get_joystick_center()
	controls.call("_input", _touch(5, center + Vector2(0.0, -60.0), true))
	assert_true(Input.is_action_pressed(&"up"), "upward joystick touch should press up")
	assert_true(Input.is_action_pressed(&"jump"), "upward joystick touch should press jump")
	controls.call("_input", _touch(5, center + Vector2(0.0, -60.0), false))
	assert_false(Input.is_action_pressed(&"up"), "lifting joystick touch should release up")
	assert_false(Input.is_action_pressed(&"jump"), "lifting joystick touch should release jump")


func _touch(index: int, position: Vector2, pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = position
	event.pressed = pressed
	return event


func _drag(index: int, position: Vector2) -> InputEventScreenDrag:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = position
	return event
