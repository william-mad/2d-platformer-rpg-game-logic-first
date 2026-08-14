extends "res://test/native_scene_tree_test.gd"

const PLAYER_SCENE := preload("res://player/player.tscn")

var player: Player


func before_each() -> void:
	player = PLAYER_SCENE.instantiate() as Player
	add_child_autofree(player)


func test_real_damage_flashes_without_overwriting_existing_tint() -> void:
	var dark_tint := Color(0.0, 0.0, 0.0, 1.0)
	player.sprite_2d.self_modulate = dark_tint
	player.movement_sprite.self_modulate = dark_tint

	player.take_damage(1.0)

	assert_true(player.sprite_2d.material is ShaderMaterial, "standing sprite receives the damage flash")
	assert_true(player.movement_sprite.material is ShaderMaterial, "movement sprite receives the damage flash")
	assert_eq(player.sprite_2d.self_modulate, dark_tint, "standing sprite tint remains owned by the scene")
	assert_eq(player.movement_sprite.self_modulate, dark_tint, "movement sprite tint remains owned by the scene")

	player._stop_damage_flash()

	assert_null(player.sprite_2d.material, "standing sprite material is restored")
	assert_null(player.movement_sprite.material, "movement sprite material is restored")
	assert_eq(player.sprite_2d.self_modulate, dark_tint, "standing sprite returns to the dark tint")
	assert_eq(player.movement_sprite.self_modulate, dark_tint, "movement sprite returns to the dark tint")


func test_zero_damage_does_not_start_the_flash() -> void:
	player.take_damage(0.0)

	assert_null(player.sprite_2d.material, "zero damage leaves the standing sprite unchanged")
	assert_null(player.movement_sprite.material, "zero damage leaves the movement sprite unchanged")
