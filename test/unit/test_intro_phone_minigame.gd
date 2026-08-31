extends "res://test/native_scene_tree_test.gd"

const INTRO_SCENE := preload("res://scenes/levels/start_game_intro.tscn")


func test_phone_panel_rotates_left_and_fills_most_of_landscape_screen() -> void:
	var viewport_size := Vector2(1188.0, 496.0)
	var layout := IntroPhoneMinigame.calculate_phone_panel_layout(
		Vector2(248.0, 248.0),
		viewport_size,
		0.94
	)
	var panel_scale: Vector2 = layout["scale"]
	var displayed_size := Vector2(248.0, 248.0) * panel_scale
	var screen_slider_travel := Vector2(80.0, 0.0).rotated(
		float(layout["rotation"])
	) * panel_scale

	assert_true(
		is_equal_approx(float(layout["rotation"]), -PI * 0.5),
		"phone picture and slider should turn ninety degrees left"
	)
	assert_true(
		is_equal_approx(displayed_size.y, viewport_size.y * 0.94),
		"phone presentation should occupy nearly all available screen height"
	)
	assert_true(
		is_equal_approx(panel_scale.x, panel_scale.y),
		"phone pixel art should scale uniformly without stretching"
	)
	assert_true(
		is_zero_approx(screen_slider_travel.x) and screen_slider_travel.y < 0.0,
		"answer slider should travel upward after the left turn"
	)


func test_phone_scene_uses_light_grey_backdrop_and_keeps_effect_layers() -> void:
	var intro := INTRO_SCENE.instantiate()
	var host := intro.get_node("PhoneInteractionLayer/PhoneMinigameHost")
	var backdrop := host.get_node("PhoneInteractionBackdrop") as ColorRect
	var panel := host.get_node("PhonePanelCenter/PhoneInteractionPanel") as Control
	var background_frame := panel.get_node("PhoneBackgroundFrameA") as TextureRect
	var background_flash_frame := panel.get_node("PhoneBackgroundFrameB") as TextureRect
	var slider_frame := panel.get_node("SliderTrackFrameA") as TextureRect
	var slider_flash_frame := panel.get_node("SliderTrackFrameB") as TextureRect
	var answer_handle := panel.get_node("AnswerHandle") as Sprite2D
	var blur_overlay := host.get_node("PhoneBlurOverlay") as ColorRect
	var ringing := intro.get_node("Audio/PhoneRinging") as AudioStreamPlayer

	assert_not_null(backdrop, "phone interaction needs a dedicated backdrop")
	assert_eq(backdrop.color, Color(0.82, 0.82, 0.82, 1.0), "backdrop should be light grey")
	assert_same(background_frame.get_parent(), panel, "caller picture rotates with phone panel")
	assert_not_null(background_flash_frame.texture, "ringing picture flash frame should remain configured")
	assert_same(slider_frame.get_parent(), panel, "flashing slider rotates with phone panel")
	assert_not_null(slider_flash_frame.texture, "ringing slider flash frame should remain configured")
	assert_same(answer_handle.get_parent(), panel, "answer handle rotates with phone panel")
	assert_not_null(blur_overlay.material, "existing ringing blur effect should remain configured")
	assert_not_null(ringing.stream, "existing ringing audio should remain configured")
	intro.free()
