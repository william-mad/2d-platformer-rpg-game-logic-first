extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var dialogue_controller := root.get_node_or_null("DialogueController")
	if dialogue_controller != null and bool(dialogue_controller.call("is_dialogue_active")):
		dialogue_controller.call("cancel_dialogue", "monster_bell_test_setup")

	var world := Node2D.new()
	world.name = "MonsterBellRuntimeWorld"
	root.add_child(world)
	current_scene = world
	_add_floor(world)

	await _test_player_false_alarm(world)
	await _test_player_alarm_with_monster(world)
	await _test_slime_touch_rings_bell(world)
	await _test_generic_radius_event_updates_directed_opinion(world)
	await _test_emitted_radius_excludes_distant_npc(world)

	world.queue_free()
	await process_frame
	_finish()


func _test_player_false_alarm(world: Node2D) -> void:
	_clear_relationships()
	var player := _spawn_player_actor(world, "FalseAlarmPlayer")
	var bell := _spawn_bell(world, "FalseAlarmBell", Vector2.ZERO)
	var mom := _spawn_mom(world, "FalseAlarmMom", Vector2(80.0, 0.0))
	await process_frame
	var machine := _prepare_mom(mom)
	_set_opinion(mom, player, &"favor", 50.0)
	_set_opinion(mom, player, &"trust", 50.0)
	_set_opinion(mom, player, &"anger", 0.0)

	bell.take_damage(1.0, player.global_position, player)
	_expect(bell.ring_count == 1, "Player damage rings the bell once")
	_expect(machine.is_primary_state(&"ReactToEvent"), "false alarm uses existing ReactToEvent")
	_expect(
		mom._reprimand_coordinator.has_pending_reprimand(),
		"Player false alarm queues the existing reprimand approach"
	)
	var context := mom._reprimand_coordinator.get_active_context()
	_expect(
		StringName(context.get("reason", &"")) == &"false_monster_alarm",
		"false alarm keeps a contextual reprimand reason"
	)
	_expect(context.get("offender", null) == player, "Player is the false-alarm offender")
	_expect_close(_get_opinion(mom, player, &"favor", 50.0), 48.0, "false alarm lowers directed favor")
	_expect_close(_get_opinion(mom, player, &"trust", 50.0), 49.0, "false alarm lowers directed trust")
	_expect_close(_get_opinion(mom, player, &"anger", 0.0), 2.0, "false alarm raises directed anger")
	_expect_close(_get_opinion(player, mom, &"favor", 50.0), 50.0, "false-alarm opinion stays directional")
	_cleanup_nodes([mom, bell, player])
	await process_frame


func _test_player_alarm_with_monster(world: Node2D) -> void:
	_clear_relationships()
	var player := _spawn_player_actor(world, "RealAlarmPlayer")
	var bell := _spawn_bell(world, "RealAlarmBell", Vector2.ZERO)
	var mom := _spawn_mom(world, "RealAlarmMom", Vector2(80.0, 0.0))
	var slime := _spawn_slime(world, "RealAlarmSlime", Vector2(900.0, 0.0))
	await process_frame
	var machine := _prepare_mom(mom)
	_set_opinion(mom, player, &"favor", 50.0)

	bell.take_damage(1.0, player.global_position, player)
	var fight := machine.get_state(&"Fight") as NpcStateFight
	_expect(machine.is_primary_state(&"Fight"), "a real monster alarm requests Mom's existing Fight")
	_expect(fight != null and fight.fight_target == slime, "Fight commits to the live alarm monster")
	_expect(
		not mom._reprimand_coordinator.has_pending_reprimand(),
		"a real monster alarm does not queue a Player reprimand"
	)
	_expect_close(_get_opinion(mom, player, &"favor", 50.0), 50.0, "a valid alarm does not penalize Player favor")
	_cleanup_nodes([mom, bell, slime, player])
	await process_frame


func _test_slime_touch_rings_bell(world: Node2D) -> void:
	_clear_relationships()
	var bell := _spawn_bell(world, "SlimeTouchBell", Vector2.ZERO)
	var mom := _spawn_mom(world, "SlimeTouchMom", Vector2(80.0, 0.0))
	# Keep sight from pre-empting the bell before this test establishes Idle.
	var slime := _spawn_slime(world, "BellTouchSlime", Vector2(900.0, 0.0))
	await process_frame
	var machine := _prepare_mom(mom)
	slime.global_position = bell.global_position

	# This is the same helper Monster.process_touch_damage() calls after detecting
	# an overlapping body/area, so it verifies the real slime damage contract.
	slime.call("_try_touch_damage", bell.get_node("Damage_Area"))
	var fight := machine.get_state(&"Fight") as NpcStateFight
	_expect(bell.ring_count == 1, "slime touch damage reaches MonsterBell.take_damage")
	_expect(
		machine.is_primary_state(&"Fight"),
		"slime-triggered bell sends Mom to Fight (got %s)" % String(machine.current_state.name)
	)
	_expect(fight != null and fight.fight_target == slime, "slime that rang the bell is the Fight target")
	_expect(
		not mom._reprimand_coordinator.has_pending_reprimand(),
		"monster-triggered bell never creates a Player reprimand"
	)
	_cleanup_nodes([mom, bell, slime])
	await process_frame


func _test_generic_radius_event_updates_directed_opinion(world: Node2D) -> void:
	_clear_relationships()
	var player := _spawn_player_actor(world, "OpinionEventPlayer")
	var source := _spawn_bell(world, "OpinionEventSource", Vector2.ZERO)
	var mom := _spawn_mom(world, "OpinionEventMom", Vector2(80.0, 0.0))
	await process_frame
	_prepare_mom(mom)
	_set_opinion(mom, player, &"anger", 0.0)
	source.event_emitter.event_name = &"test_radius_opinion_event"
	source.event_emitter.state_request = &""
	source.event_emitter.directed_opinion_delta = {"anger": 3.0}

	source.event_emitter.emit_radius_event(
		player, source, source, source.global_position
	)
	_expect_close(
		_get_opinion(mom, player, &"anger", 0.0),
		3.0,
		"generic radius event can update a directed opinion"
	)
	_expect_close(
		_get_opinion(player, mom, &"anger", 0.0),
		0.0,
		"generic radius-event opinion remains directional"
	)
	_cleanup_nodes([mom, source, player])
	await process_frame


func _test_emitted_radius_excludes_distant_npc(world: Node2D) -> void:
	_clear_relationships()
	var player := _spawn_player_actor(world, "RadiusPlayer")
	var bell := _spawn_bell(world, "RadiusBell", Vector2.ZERO)
	bell.event_emitter.radius = 120.0
	var mom := _spawn_mom(world, "RadiusMom", Vector2(180.0, 0.0))
	await process_frame
	var machine := _prepare_mom(mom)
	_set_opinion(mom, player, &"favor", 50.0)

	bell.take_damage(1.0, player.global_position, player)
	_expect(machine.is_primary_state(&"Idle"), "NPC outside emitted sound radius stays in Idle")
	_expect(
		not mom._reprimand_coordinator.has_pending_reprimand(),
		"off-radius NPC does not schedule a reprimand"
	)
	_expect_close(_get_opinion(mom, player, &"favor", 50.0), 50.0, "off-radius event does not change opinion")
	_cleanup_nodes([mom, bell, player])
	await process_frame


func _spawn_player_actor(world: Node2D, node_name: String) -> Node2D:
	var player := Node2D.new()
	player.name = node_name
	player.add_to_group("player")
	world.add_child(player)
	return player


func _spawn_bell(world: Node2D, node_name: String, spawn_position: Vector2) -> MonsterBell:
	var scene := load("res://scenes/things/monster_bell.tscn") as PackedScene
	var bell := scene.instantiate() as MonsterBell
	bell.name = node_name
	bell.position = spawn_position
	world.add_child(bell)
	return bell


func _spawn_mom(world: Node2D, node_name: String, spawn_position: Vector2) -> SocialNpc:
	var scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := scene.instantiate() as SocialNpc
	mom.name = node_name
	mom.position = spawn_position
	mom.use_npc_location_tracking = false
	mom.listen_to_event_bus = true
	mom.damage_hop_enabled = false
	world.add_child(mom)
	return mom


func _spawn_slime(world: Node2D, node_name: String, spawn_position: Vector2) -> Monster:
	var scene := load("res://scenes/monsters/slime.tscn") as PackedScene
	var slime := scene.instantiate() as Monster
	slime.name = node_name
	slime.position = spawn_position
	world.add_child(slime)
	return slime


func _prepare_mom(mom: SocialNpc) -> NpcStateMachine:
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	var idle := machine.get_state(&"Idle")
	if idle != null and not machine.is_primary_state(&"Idle"):
		machine.call("_commit_state_change", idle, "monster_bell_test", 10000)
	return machine


func _set_opinion(owner: Node, other: Node, metric: StringName, value: float) -> void:
	root.get_node("Relationships").call(
		"set_opinion_metric", owner, other, metric, value, "monster_bell_test"
	)


func _get_opinion(owner: Node, other: Node, metric: StringName, fallback: float) -> float:
	return float(root.get_node("Relationships").call(
		"get_opinion_metric", owner, other, metric, fallback
	))


func _clear_relationships() -> void:
	root.get_node("Relationships").call("clear_relationships")


func _cleanup_nodes(nodes: Array) -> void:
	for node_value in nodes:
		var node := node_value as Node
		if node != null and is_instance_valid(node):
			node.queue_free()


func _add_floor(world: Node2D) -> void:
	var floor := StaticBody2D.new()
	floor.collision_layer = 1
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(2400.0, 20.0)
	collision.shape = shape
	collision.position = Vector2(0.0, 10.0)
	floor.add_child(collision)
	world.add_child(floor)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		failures.append("%s: expected %.3f, got %.3f" % [label, expected, actual])


func _finish() -> void:
	if failures.is_empty():
		print("MONSTER_BELL_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
