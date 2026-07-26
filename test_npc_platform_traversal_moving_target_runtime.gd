extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var fixture := await _create_fixture()
	var world: Node2D = fixture["world"]
	var npc: CharacterBody2D = fixture["npc"]
	var machine: NpcStateMachine = fixture["machine"]
	var traversal: NpcPlatformTraversal = fixture["traversal"]
	var owner := Node.new()
	owner.name = "ScriptedPursuitOwner"
	world.add_child(owner)
	var session := traversal.acquire(owner, &"moving_non_player_target")
	var options := NpcPlatformTraversal.TraversalOptions.new()
	options.desired_stop_distance = 40.0
	options.allow_hard_recovery = false

	var moving_target := Node2D.new()
	moving_target.name = "MovingNonPlayerTarget"
	moving_target.position = Vector2(260.0, 0.0)
	world.add_child(moving_target)
	_expect(
		traversal.set_target_actor(owner, session, moving_target),
		"a non-player actor can be assigned without a trail provider"
	)
	var first_result := traversal.physics_update(owner, session, 0.016, options)
	_expect(
		first_result.movement_active
		and npc.velocity.x > 0.0
		and not bool(traversal.get_debug_snapshot()["breadcrumb_provider_valid"]),
		"direct pursuit moves toward a same-platform non-player target without breadcrumbs"
	)

	npc.global_position.x += 24.0
	moving_target.global_position.x += 110.0
	var moving_result := traversal.physics_update(owner, session, 0.016, options)
	_expect(
		moving_result.movement_active
		and moving_result.target_position.is_equal_approx(moving_target.global_position)
		and npc.velocity.x > 0.0,
		"the component rereads a moving actor position while the follower approaches"
	)

	moving_target.global_position.x = -260.0
	for _index in range(8):
		traversal.physics_update(owner, session, 0.05, options)
	_expect(
		npc.velocity.x < 0.0,
		"direct pursuit reverses horizontal direction when the target crosses behind"
	)

	var replacement_target := Node2D.new()
	replacement_target.name = "ReplacementTarget"
	replacement_target.position = Vector2(190.0, 0.0)
	world.add_child(replacement_target)
	_expect(
		traversal.set_target_actor(owner, session, replacement_target)
		and traversal.get_target_actor() == replacement_target,
		"a different actor replaces the previous moving target cleanly"
	)
	_expect(
		traversal.set_target_position(owner, session, Vector2(120.0, 0.0))
		and traversal.get_target_actor() == null
		and traversal.get_debug_snapshot()["target_type"] == "fixed_position",
		"a fixed position can replace an actor target"
	)

	traversal.set_target_actor(owner, session, replacement_target)
	replacement_target.queue_free()
	await process_frame
	var freed_result := traversal.physics_update(owner, session, 0.016, options)
	_expect(
		freed_result.status == NpcPlatformTraversal.TraversalStatus.TARGET_INVALID
		and freed_result.reason == &"target_freed"
		and freed_result.navigation_failed,
		"a moving target freed during pursuit fails explicitly and safely"
	)

	npc.global_position = Vector2.ZERO
	npc.velocity = Vector2.ZERO
	var raised_target := Node2D.new()
	raised_target.name = "RaisedNonPlayerTarget"
	raised_target.position = Vector2(180.0, -120.0)
	world.add_child(raised_target)
	traversal.set_target_actor(owner, session, raised_target)
	var vertical_result := traversal.physics_update(owner, session, 0.016, options)
	_expect(
		vertical_result.status in [
			NpcPlatformTraversal.TraversalStatus.APPROACHING_TRANSITION,
			NpcPlatformTraversal.TraversalStatus.COMMITTED_JUMP,
			NpcPlatformTraversal.TraversalStatus.REPOSITIONING,
			NpcPlatformTraversal.TraversalStatus.TEMPORARILY_BLOCKED,
			NpcPlatformTraversal.TraversalStatus.NO_ROUTE,
			NpcPlatformTraversal.TraversalStatus.REPEATED_FAILURE,
		],
		"vertical direct pursuit enters bounded local traversal planning without breadcrumbs"
	)

	traversal.maximum_navigation_failures = 1
	traversal.set_target_position(owner, session, Vector2(900.0, -1800.0))
	var unreachable_result := traversal.physics_update(owner, session, 0.016, options)
	_expect(
		unreachable_result.status == NpcPlatformTraversal.TraversalStatus.REPEATED_FAILURE
		and unreachable_result.navigation_failed
		and unreachable_result.reason == &"repeated_navigation_failure",
		"an unreachable direct target reports a bounded repeated-navigation failure"
	)

	var replacement_owner := Node.new()
	replacement_owner.name = "ReplacementPursuitOwner"
	world.add_child(replacement_owner)
	var replacement_session := traversal.acquire(
		replacement_owner,
		&"replacement_scripted_pursuit"
	)
	traversal.set_target_actor(replacement_owner, replacement_session, moving_target)
	_expect(
		not traversal.cancel(owner, session, &"stale_pursuit_cancel")
		and traversal.is_owned_by(replacement_owner, replacement_session)
		and traversal.get_target_actor() == moving_target,
		"a cancelled older pursuit cannot erase its newer owner or moving target"
	)
	_expect(
		machine.current_state != null and String(machine.current_state.name) == "Idle",
		"moving non-player pursuit never changes the NPC primary state"
	)

	world.queue_free()
	await process_frame
	_finish()


func _create_fixture() -> Dictionary:
	var world := Node2D.new()
	world.name = "MovingTargetTraversalWorld"
	root.add_child(world)

	var floor := StaticBody2D.new()
	floor.position = Vector2(0.0, 10.0)
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(2600.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor.add_child(floor_shape)
	world.add_child(floor)

	var raised_platform := StaticBody2D.new()
	raised_platform.position = Vector2(190.0, -90.0)
	var raised_shape := CollisionShape2D.new()
	var raised_rectangle := RectangleShape2D.new()
	raised_rectangle.size = Vector2(220.0, 20.0)
	raised_shape.shape = raised_rectangle
	raised_platform.add_child(raised_shape)
	world.add_child(raised_platform)

	var npc := CharacterBody2D.new()
	npc.name = "MovingTargetFollower"
	var npc_shape := CollisionShape2D.new()
	npc_shape.position = Vector2(0.0, -20.0)
	var npc_rectangle := RectangleShape2D.new()
	npc_rectangle.size = Vector2(20.0, 40.0)
	npc_shape.shape = npc_rectangle
	npc.add_child(npc_shape)
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var idle := NpcStateIdle.new()
	idle.name = "Idle"
	machine.add_child(idle)
	npc.add_child(machine)
	var traversal := NpcPlatformTraversal.new()
	traversal.name = "NpcPlatformTraversal"
	npc.add_child(traversal)
	world.add_child(npc)
	await process_frame
	machine.request_state(&"Idle", null, "moving_target_test_initial", 100)
	npc.velocity = Vector2(0.0, 20.0)
	npc.move_and_slide()
	npc.velocity = Vector2.ZERO
	return {
		"world": world,
		"npc": npc,
		"machine": machine,
		"traversal": traversal,
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("NPC_PLATFORM_TRAVERSAL_MOVING_TARGET_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
