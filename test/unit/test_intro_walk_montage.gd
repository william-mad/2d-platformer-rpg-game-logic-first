extends "res://test/native_scene_tree_test.gd"

const INTRO_WALK_SCENE := preload("res://scenes/levels/intro_walk_interlude.tscn")


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
	intro.free()
