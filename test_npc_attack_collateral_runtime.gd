extends "res://test/native_scene_tree_test.gd"


class DamageProbe:
	extends Node2D

	var damage_calls: int = 0
	var damage_received: float = 0.0

	func take_damage(
		amount: float,
		_source_position: Vector2 = Vector2.ZERO,
		_source: Node = null,
		_knockout_damage: float = 0.0
	) -> void:
		damage_calls += 1
		damage_received += amount


func test_npc_projectile_aimed_at_monster_passes_through_people() -> void:
	var source := _make_actor("NpcProjectileSource", &"npc")
	var monster := _make_damage_actor("ProjectileMonster", &"monster")
	var npc_bystander := _make_damage_actor("ProjectileNpcBystander", &"npc")
	var player_bystander := _make_damage_actor("ProjectilePlayerBystander", &"player")
	var projectile := _launch_projectile(source, monster)

	projectile.call("_try_hit", npc_bystander)
	projectile.call("_try_hit", player_bystander)
	assert_eq(npc_bystander.damage_calls, 0, "monster-target shot ignores an NPC bystander")
	assert_eq(player_bystander.damage_calls, 0, "monster-target shot ignores the Player")
	assert_false(projectile.has_hit, "ignored people do not consume the projectile")

	projectile.call("_try_hit", monster)
	assert_eq(monster.damage_calls, 1, "the shot still damages its monster target")
	assert_true(projectile.has_hit, "the monster impact consumes the projectile")


func test_npc_projectile_against_player_ignores_other_npcs() -> void:
	var source := _make_actor("IntentionalNpcSource", &"npc")
	var player_target := _make_damage_actor("IntentionalPlayerTarget", &"player")
	var npc_bystander := _make_damage_actor("IntentionalNpcBystander", &"npc")
	var projectile := _launch_projectile(source, player_target)

	projectile.call("_try_hit", npc_bystander)
	assert_eq(npc_bystander.damage_calls, 0, "an NPC attack ignores people other than its target")
	assert_false(projectile.has_hit, "an NPC bystander does not consume a Player-targeted shot")
	projectile.call("_try_hit", player_target)
	assert_eq(player_target.damage_calls, 1, "an NPC intentionally targeting the Player still hits")


func test_player_projectile_aimed_at_monster_can_still_hit_anyone() -> void:
	var source := _make_actor("PlayerProjectileSource", &"player")
	var monster := _make_damage_actor("PlayerProjectileMonster", &"monster")
	var npc_bystander := _make_damage_actor("PlayerProjectileNpcBystander", &"npc")
	var projectile := _launch_projectile(source, monster)

	projectile.call("_try_hit", npc_bystander)
	assert_eq(npc_bystander.damage_calls, 1, "Player-originated attacks retain friendly fire")


func test_mom_melee_protects_people_except_the_intended_target() -> void:
	var source := _make_actor("MomMeleeSource", &"npc")
	var fight := MomNpcFightState.new()
	fight.name = "Fight"
	source.add_child(fight)
	fight.npc = source

	var monster := _make_damage_actor("MeleeMonster", &"monster")
	var npc_bystander := _make_damage_actor("MeleeNpcBystander", &"npc")
	var player_bystander := _make_damage_actor("MeleePlayerBystander", &"player")
	fight.fight_target = monster
	assert_true(
		bool(fight.call("_should_ignore_person_bystander", npc_bystander)),
		"monster-target melee protects NPC bystanders"
	)
	assert_true(
		bool(fight.call("_should_ignore_person_bystander", player_bystander)),
		"monster-target melee protects the Player"
	)
	assert_false(
		bool(fight.call("_should_ignore_person_bystander", monster)),
		"monster-target melee still permits monster victims"
	)

	fight.fight_target = player_bystander
	assert_true(
		bool(fight.call("_should_ignore_person_bystander", npc_bystander)),
		"Player-targeted melee protects other NPCs"
	)
	assert_false(
		bool(fight.call("_should_ignore_person_bystander", player_bystander)),
		"the intended Player target still takes the melee hit"
	)


func _make_actor(actor_name: String, group_name: StringName) -> CharacterBody2D:
	var actor := CharacterBody2D.new()
	actor.name = actor_name
	actor.add_to_group(group_name)
	add_child_autofree(actor)
	return actor


func _make_damage_actor(actor_name: String, group_name: StringName) -> DamageProbe:
	var actor := DamageProbe.new()
	actor.name = actor_name
	actor.add_to_group(group_name)
	add_child_autofree(actor)
	return actor


func _launch_projectile(source: Node, intended_target: Node) -> NpcThrownAttack:
	var projectile := NpcThrownAttack.new()
	# Successful hits queue the projectile for deletion. Keep it out of the
	# test's immediate autofree list so cleanup does not also free a queued node.
	root.add_child(projectile)
	projectile.launch(
		Vector2.ZERO,
		Vector2(100.0, 0.0),
		source,
		3.0,
		0.65,
		0.0,
		3.0,
		131,
		5.0,
		intended_target,
		8.0,
		0.0
	)
	return projectile
