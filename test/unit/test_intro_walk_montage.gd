extends "res://test/native_scene_tree_test.gd"

const INTRO_WALK_SCENE := preload("res://scenes/levels/intro_walk_interlude.tscn")
const PHONE_DIALOGUE := preload("res://data/dialogue/intro_phone_call.tres")
const MONTAGE_DIALOGUE := preload("res://data/dialogue/intro_memory_montage.tres")
const HOME_EPILOGUE := preload("res://data/dialogue/intro_memory_home_epilogue.tres")


func test_intro_dialogue_is_complete_and_connects_the_call_to_the_new_morning() -> void:
	for definition in [PHONE_DIALOGUE, MONTAGE_DIALOGUE, HOME_EPILOGUE]:
		assert_eq(
			definition.get_validation_error(),
			"",
			"every authored intro dialogue route should be complete"
		)
		for dialogue_node in definition.nodes:
			assert_false(
				dialogue_node.speaker_text.to_lower().contains("placeholder"),
				"the playable intro should contain no placeholder dialogue"
			)

	assert_eq(
		PHONE_DIALOGUE.get_node(&"call_goodbye_go").speaker_text,
		"All right. Be careful on the way. I love you.",
		"the real-world call should end explicitly before the street sequence"
	)
	assert_eq(
		MONTAGE_DIALOGUE.get_node(&"memory_27").speaker_text,
		"Someone is waiting to wake you.",
		"the goddess should lead directly into the alternative-world wake-up"
	)
	assert_eq(
		HOME_EPILOGUE.get_node(&"home_memory_03").speaker_text,
		"Who... are you?",
		"the alternative Mom should preserve the first-contact mystery beat"
	)


func test_montage_keeps_only_the_three_goddess_frames_and_final_memory() -> void:
	var image_paths: Array[String] = []
	for texture in IntroWalkInterlude.MEMORY_IMAGES:
		image_paths.append(texture.resource_path)

	assert_eq(
		image_paths,
		[
			"res://images/backgrounds/intro/fullscreen ilustration 3 (1).png",
			"res://images/backgrounds/intro/fullscreen ilustration 3 (2).png",
			"res://images/backgrounds/intro/fullscreen ilustration 3 (3).png",
			"res://images/backgrounds/intro/fullscreen ilustration 3 (8).png",
		],
		"the unwanted illustration 3 (4-7) frames should no longer enter the montage"
	)
	assert_eq(
		IntroWalkInterlude.MEMORY_IMAGE_FIRST_BEATS,
		[1, 10, 19, 28],
		"the dialogue beats should be distributed across the four retained pictures"
	)


func test_goddess_frames_have_a_white_blue_backdrop_and_slow_final_dissolve() -> void:
	var intro := INTRO_WALK_SCENE.instantiate() as IntroWalkInterlude
	var illustration_layer := intro.get_node("IllustrationLayer")
	var goddess_backdrop := illustration_layer.get_node("GoddessBackdrop") as TextureRect
	var memory_image := illustration_layer.get_node("MemoryImage") as TextureRect
	var gradient_texture := goddess_backdrop.texture as GradientTexture2D

	assert_not_null(gradient_texture, "goddess memories should have a dedicated gradient backdrop")
	assert_not_null(gradient_texture.gradient, "goddess backdrop should define white/blue color stops")
	assert_true(
		goddess_backdrop.get_index() < memory_image.get_index(),
		"the goddess art should render above its backdrop"
	)
	assert_true(
		intro.final_image_appearance_fade_seconds >= 8.0,
		"illustration 3 (8) should dissolve into view very slowly"
	)
	assert_true(
		is_equal_approx(intro.final_image_zoom_amount, 1.55),
		"illustration 3 (8) should use the reduced zoom without changing its focus path"
	)
	assert_true(
		is_equal_approx(intro.final_image_bottom_focus_y, 0.88)
		and is_equal_approx(intro.final_image_eye_focus_y, 0.14),
		"the final illustration position and pan targets should remain unchanged"
	)
	intro.free()


func test_goddess_art_fits_without_clipping_while_final_memory_keeps_cover_mode() -> void:
	var intro := INTRO_WALK_SCENE.instantiate() as IntroWalkInterlude
	var memory_image := intro.get_node("IllustrationLayer/MemoryImage") as TextureRect

	intro.call("_apply_memory_image_framing", memory_image, 0)
	assert_eq(
		memory_image.stretch_mode,
		TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
		"goddess art should fit inside the full screen instead of exposing a cropped rectangle"
	)
	assert_true(
		is_equal_approx(memory_image.offset_top, 12.0)
		and is_equal_approx(memory_image.offset_bottom, 12.0),
		"goddess art should be lowered slightly without cutting off its head"
	)

	intro.call("_apply_memory_image_framing", memory_image, 3)
	assert_eq(
		memory_image.stretch_mode,
		TextureRect.STRETCH_KEEP_ASPECT_COVERED,
		"illustration 3 (8) should retain its full-screen cover presentation"
	)
	assert_true(
		is_zero_approx(memory_image.offset_top) and is_zero_approx(memory_image.offset_bottom),
		"illustration 3 (8) should retain its original position"
	)
	intro.free()
