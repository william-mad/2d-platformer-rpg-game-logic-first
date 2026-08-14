extends "res://test/native_scene_tree_test.gd"

const SOCIAL_NPC_SCENE := preload("res://scenes/creatures/social_npc.tscn")
const MOM_NPC_SCENE := preload("res://scenes/creatures/mom_npc.tscn")


func test_base_npc_damage_flashes_polygon_visual() -> void:
	var npc := SOCIAL_NPC_SCENE.instantiate() as SocialNpc
	npc.use_npc_location_tracking = false
	add_child_autofree(npc)

	npc.take_damage(1.0)

	assert_true(npc.body_visual.material is ShaderMaterial, "base NPC visual receives the damage flash")
	npc._stop_damage_flash()
	assert_null(npc.body_visual.material, "base NPC material is restored")


func test_mom_damage_flash_preserves_dark_room_tint() -> void:
	var mom := MOM_NPC_SCENE.instantiate() as SocialNpc
	mom.use_npc_location_tracking = false
	add_child_autofree(mom)
	var mom_sprite := mom.get_node("Sprite2D") as Sprite2D
	var dark_tint := Color(0.0, 0.0, 0.0, 1.0)
	mom_sprite.self_modulate = dark_tint

	mom.take_damage(1.0)

	assert_true(mom_sprite.material is ShaderMaterial, "Mom's sprite receives the damage flash")
	assert_eq(mom_sprite.self_modulate, dark_tint, "Mom's dark-room tint remains scene-owned")
	mom._stop_damage_flash()
	assert_null(mom_sprite.material, "Mom's original material is restored")
	assert_eq(mom_sprite.self_modulate, dark_tint, "Mom returns to the dark-room tint")
