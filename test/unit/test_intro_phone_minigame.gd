extends "res://test/native_scene_tree_test.gd"

const INTRO_SCENE := preload("res://scenes/levels/start_game_intro.tscn")


func test_phone_panel_rotates_left_and_fills_most_of_landscape_screen() -> void:
	var viewport_size := Vector2(1188.0, 496.0)
	var panel_size := Vector2(248.0, 600.0)
	var layout := IntroPhoneMinigame.calculate_phone_panel_layout(
		panel_size,
		viewport_size,
		0.94
	)
	var panel_scale: Vector2 = layout["scale"]
	var displayed_size := Vector2(panel_size.y, panel_size.x) * panel_scale
	var screen_slider_travel := Vector2(80.0, 0.0).rotated(
		float(layout["rotation"])
	) * panel_scale

	assert_true(
		is_equal_approx(float(layout["rotation"]), -PI * 0.5),
		"phone picture and slider should turn ninety degrees left"
	)
	assert_true(
		is_equal_approx(displayed_size.x, viewport_size.x * 0.94),
		"phone layout should occupy nearly all available screen width"
	)
	assert_true(
		displayed_size.y > viewport_size.y * 0.9,
		"phone layout should also occupy nearly all available screen height"
	)
	assert_true(
		is_equal_approx(panel_scale.x, panel_scale.y),
		"phone pixel art should scale uniformly without stretching"
	)
	assert_true(
		is_zero_approx(screen_slider_travel.x) and screen_slider_travel.y < 0.0,
		"answer slider should travel upward after the left turn"
	)


func test_phone_scene_uses_dark_backdrop_and_keeps_effect_layers() -> void:
	var intro := INTRO_SCENE.instantiate()
	var host := intro.get_node("PhoneInteractionLayer/PhoneMinigameHost")
	var backdrop := host.get_node("PhoneInteractionBackdrop") as ColorRect
	var panel_frame := host.get_node("PhonePanelCenter/PhoneInteractionPanel") as Control
	var panel := panel_frame.get_node("PhoneTransformRoot") as Control
	var background_frame := panel.get_node("PhoneBackgroundFrameA") as TextureRect
	var background_flash_frame := panel.get_node("PhoneBackgroundFrameB") as TextureRect
	var slider_frame := panel.get_node("SliderTrackFrameA") as TextureRect
	var slider_flash_frame := panel.get_node("SliderTrackFrameB") as TextureRect
	var caller_name := panel.get_node("CallerNameArt") as TextureRect
	var slider_pill := panel.get_node("SliderPill") as Panel
	var answer_handle := panel.get_node("AnswerHandle") as Sprite2D
	var blur_overlay := host.get_node("PhoneBlurOverlay") as ColorRect
	var ringing := intro.get_node("Audio/PhoneRinging") as AudioStreamPlayer

	assert_not_null(backdrop, "phone interaction needs a dedicated backdrop")
	assert_eq(backdrop.color, Color(0.14, 0.15, 0.17, 1.0), "backdrop should be dark charcoal")
	assert_false(
		panel.get_parent() is Container,
		"rotated content must not be a direct Container child that resets its transform"
	)
	assert_true(
		is_equal_approx(panel.rotation, -PI * 0.5) and panel.scale.x > 1.5,
		"scene fallback should already be visibly rotated and enlarged"
	)
	assert_eq(panel.size, Vector2(248.0, 600.0), "phone layout should use a tall call-screen canvas")
	assert_same(background_frame.get_parent(), panel, "caller picture rotates with phone panel")
	assert_true(
		background_frame.size.y >= 420.0,
		"caller portrait should dominate the phone screen instead of using the old square crop"
	)
	assert_true(
		background_frame.texture.resource_path.ends_with("story_caller_mom_clean.png"),
		"phone should use the clean full-bust caller portrait without embedded controls"
	)
	assert_not_null(caller_name.texture, "caller name should remain visible below the portrait")
	assert_true(
		slider_pill.position.y > background_frame.get_rect().end.y,
		"answer slider should sit below the caller portrait instead of covering it"
	)
	assert_not_null(background_flash_frame.texture, "ringing picture flash frame should remain configured")
	assert_same(slider_frame.get_parent(), panel, "flashing slider rotates with phone panel")
	assert_not_null(slider_flash_frame.texture, "ringing slider flash frame should remain configured")
	assert_same(answer_handle.get_parent(), panel, "answer handle rotates with phone panel")
	assert_not_null(blur_overlay.material, "existing ringing blur effect should remain configured")
	assert_not_null(ringing.stream, "existing ringing audio should remain configured")
	intro.free()


func test_live_minigame_applies_transform_to_non_container_content_root() -> void:
	var intro := INTRO_SCENE.instantiate()
	var sequence_controller := intro.get_node("IntroSequenceController")
	intro.remove_child(sequence_controller)
	sequence_controller.free()
	add_child_autofree(intro)
	var host := intro.get_node(
		"PhoneInteractionLayer/PhoneMinigameHost"
	) as IntroPhoneMinigame
	host.call("_apply_phone_panel_layout")
	var transform_root := host.get_node(
		"PhonePanelCenter/PhoneInteractionPanel/PhoneTransformRoot"
	) as Control
	var expected_layout := IntroPhoneMinigame.calculate_phone_panel_layout(
		transform_root.size,
		host.get_viewport().get_visible_rect().size,
		host.phone_screen_fill_ratio
	)
	var expected_scale: Vector2 = expected_layout["scale"]

	assert_same(host.phone_panel, transform_root, "runtime should transform the inner content root")
	assert_true(
		is_equal_approx(transform_root.rotation, -PI * 0.5),
		"live phone content should remain turned left"
	)
	assert_true(
		is_equal_approx(transform_root.scale.x, expected_scale.x) and is_equal_approx(
			transform_root.scale.x,
			transform_root.scale.y
		),
		"live phone content should apply its responsive scale without distortion"
	)
