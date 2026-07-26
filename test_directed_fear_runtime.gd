extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var relationships := root.get_node_or_null("Relationships")
	var damage_events := root.get_node_or_null("DamageEvents")
	_expect(relationships != null, "Relationships autoload is available")
	_expect(damage_events != null, "DamageEvents autoload is available")
	if relationships == null or damage_events == null:
		_finish()
		return

	var original_relationships: Dictionary = relationships.call("get_save_data")
	relationships.call("clear_relationships")

	var world := Node2D.new()
	world.name = "DirectedFearRuntimeWorld"
	root.add_child(world)

	var player := CharacterBody2D.new()
	player.name = "DirectedFearPlayer"
	world.add_child(player)
	player.add_to_group(&"player")

	var monster := CharacterBody2D.new()
	monster.name = "DirectedFearMonster"
	world.add_child(monster)
	monster.add_to_group(&"monster")

	var player_damaged_mom := await _spawn_mom(world, &"fear_test_player_damage")
	player_damaged_mom.take_damage(
		60.0,
		player.global_position,
		player,
		0.0
	)
	var player_relationship: Dictionary = relationships.call(
		"get_relationship",
		player_damaged_mom,
		player
	)
	_expect(
		not player_damaged_mom.social_stats.has("fear"),
		"player damage never recreates the removed global fear value"
	)
	_expect(
		float(player_relationship.get("fear", 0.0)) > 0.0
		and String(player_relationship.get("last_reason", "")) == "damaged_by_player",
		"low-health player damage records directed Mom-to-player fear"
	)

	var monster_damaged_mom := await _spawn_mom(world, &"fear_test_monster_damage")
	monster_damaged_mom.take_damage(
		60.0,
		monster.global_position,
		monster,
		0.0
	)
	_expect(
		not monster_damaged_mom.social_stats.has("fear"),
		"monster damage does not add global fear"
	)
	_expect(
		is_zero_approx(float(relationships.call(
			"get_fear",
			monster_damaged_mom,
			player,
			0.0
		))),
		"monster damage is never reassigned to the player relationship"
	)

	var observing_mom := await _spawn_mom(world, &"fear_test_observer")
	observing_mom.global_position = Vector2.ZERO
	player.global_position = Vector2(20.0, 0.0)
	monster.global_position = Vector2(40.0, 0.0)
	damage_events.call("emit_damage_dealt", 5.0, monster, player)
	_expect(
		not observing_mom.social_stats.has("fear"),
		"observing nearby combat does not add ambiguous global fear"
	)
	_expect(
		is_zero_approx(float(relationships.call(
			"get_fear",
			observing_mom,
			player,
			0.0
		))),
		"seeing a monster hit the player does not invent Mom-to-player fear"
	)

	var sight_mom := await _spawn_mom(world, &"fear_test_player_sight")
	var sight_machine := sight_mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	relationships.call("set_fear", sight_mom, player, 80.0, "test_setup")
	if sight_machine != null:
		sight_machine.request_state(&"Idle", null, "test_setup", 1000)
		sight_machine.notify_target_seen(player)
	_expect(
		sight_machine != null
		and sight_machine.current_state != null
		and String(sight_machine.current_state.name) == "Flee"
		and sight_machine.get_active_target() == player,
		"directed player fear makes player sight select Flee with the player target"
	)

	var calm_mom := await _spawn_mom(world, &"fear_test_deprecated_global")
	var calm_machine := calm_mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	if calm_machine != null:
		calm_machine.request_state(&"Idle", null, "test_setup", 1000)
		calm_machine.apply_value_delta({"fear": 100.0}, player, true)
		calm_machine.notify_target_seen(player)
	_expect(
		calm_machine != null
		and not calm_machine.values.has("fear")
		and calm_machine.current_state != null
		and String(calm_machine.current_state.name) == "Idle",
		"legacy global fear input is discarded and cannot target the player"
	)

	world.queue_free()
	await process_frame
	relationships.call("apply_save_data", original_relationships)
	_finish()


func _spawn_mom(world: Node2D, relationship_key: StringName) -> SocialNpc:
	var packed := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := packed.instantiate() as SocialNpc
	mom.use_npc_location_tracking = false
	mom.location_id = &""
	mom.relationship_id = relationship_key
	mom.show_name_tag = false
	world.add_child(mom)
	await process_frame
	return mom


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("DIRECTED_FEAR_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
