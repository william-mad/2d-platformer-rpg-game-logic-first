extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var fixture := await _create_fixture()
	var world: Node2D = fixture["world"]
	var npc: CharacterBody2D = fixture["npc"]
	var machine: NpcStateMachine = fixture["machine"]
	var traversal: NpcPlatformTraversal = fixture["traversal"]
	var traversal_owner := Node.new()
	traversal_owner.name = "TraversalTestOwner"
	world.add_child(traversal_owner)
	var traversal_session := traversal.acquire(traversal_owner, &"component_runtime_test")
	_expect(traversal_session > 0, "component runtime fixture acquires traversal ownership")
	var options := NpcPlatformTraversal.TraversalOptions.new()
	options.desired_stop_distance = 64.0
	var initial_state := String(machine.current_state.name)

	var actor_a := Node2D.new()
	actor_a.position = Vector2(220.0, 0.0)
	world.add_child(actor_a)
	traversal.set_target_actor(traversal_owner, traversal_session, actor_a)
	_expect(traversal.get_target_actor() == actor_a, "target actor assignment is retained")

	traversal.set_target_position(traversal_owner, traversal_session, Vector2(180.0, 0.0))
	_expect(
		traversal.get_target_actor() == null
		and traversal.get_debug_snapshot()["target_position"] == Vector2(180.0, 0.0),
		"fixed-position assignment replaces the actor target"
	)
	var direct_result := traversal.physics_update(
		traversal_owner, traversal_session, 0.016, options
	)
	_expect(
		direct_result.movement_active and not direct_result.navigation_failed,
		"fixed-position traversal operates without a breadcrumb provider"
	)

	var actor_b := Node2D.new()
	actor_b.position = Vector2(-220.0, 0.0)
	world.add_child(actor_b)
	traversal.set("_transition_plan", {"takeoff_position": Vector2(40.0, 0.0)})
	traversal.set_target_actor(traversal_owner, traversal_session, actor_b)
	_expect(
		traversal.get_target_actor() == actor_b
		and (traversal.get("_transition_plan") as Dictionary).is_empty(),
		"changing targets clears the previous route commitment"
	)
	actor_b.queue_free()
	await process_frame
	var freed_result := traversal.physics_update(
		traversal_owner, traversal_session, 0.016, options
	)
	_expect(
		freed_result.navigation_failed
		and freed_result.reason == &"target_freed"
		and not traversal.has_pending_traversal(),
		"a freed target fails safely and clears traversal debt"
	)

	_settle_on_floor(npc)
	traversal.set_target_position(
		traversal_owner,
		traversal_session,
		npc.global_position + Vector2(20.0, 0.0)
	)
	var settled_result := traversal.physics_update(
		traversal_owner, traversal_session, 0.016, options
	)
	_expect(
		settled_result.target_reached
		and settled_result.status == NpcPlatformTraversal.TraversalStatus.SETTLED
		and traversal.is_settled()
		and traversal.can_release_target(),
		"arrival reports a settled releasable target"
	)

	var trail_actor := CharacterBody2D.new()
	trail_actor.position = Vector2(120.0, 0.0)
	var recorder := PlayerBreadcrumbRecorder.new()
	trail_actor.add_child(recorder)
	world.add_child(trail_actor)
	await process_frame
	traversal.set_target_actor(traversal_owner, traversal_session, trail_actor)
	traversal.set_breadcrumb_provider(traversal_owner, traversal_session, recorder)
	recorder.set("_pending_traversal", {
		"takeoff_position": trail_actor.global_position,
		"traversal_type": "jump",
	})
	_expect(traversal.has_pending_traversal(), "pending breadcrumb traversal is reported")

	recorder.set("_pending_traversal", {})
	traversal.set_target_position(traversal_owner, traversal_session, Vector2(260.0, 0.0))
	traversal.clear_breadcrumb_provider(traversal_owner, traversal_session)
	traversal.set("_transition_phase", NpcPlatformTraversal.TransitionPhase.EXECUTING_JUMP)
	traversal.set("_transition_plan", {
		"velocity": Vector2(180.0, -420.0),
		"flight_time": 0.8,
		"landing_position": Vector2(260.0, 0.0),
	})
	traversal.set("_committed_jump_was_airborne", false)
	var jump_result := traversal.physics_update(
		traversal_owner, traversal_session, 0.016, options
	)
	_expect(
		jump_result.status == NpcPlatformTraversal.TraversalStatus.COMMITTED_JUMP
		and jump_result.traversal_committed
		and traversal.is_traversal_committed(),
		"a committed jump is exposed in the traversal result"
	)
	traversal.cancel(traversal_owner, traversal_session, &"test_cancel_committed")
	_expect(
		not traversal.is_traversal_committed()
		and not traversal.has_pending_traversal()
		and is_zero_approx(npc.velocity.x),
		"cancelling a committed jump clears flags and horizontal motion safely"
	)

	traversal.set_target_position(traversal_owner, traversal_session, Vector2(260.0, 0.0))
	traversal.set("_transition_phase", NpcPlatformTraversal.TransitionPhase.APPROACHING_TRANSITION)
	traversal.set("_transition_plan", {"takeoff_position": Vector2(80.0, 0.0)})
	traversal.cancel(traversal_owner, traversal_session, &"test_cancel_approach")
	_expect(
		not traversal.is_traversal_committed()
		and (traversal.get("_transition_plan") as Dictionary).is_empty(),
		"cancelling an approach clears its transition plan"
	)

	traversal.set_target_position(traversal_owner, traversal_session, Vector2(260.0, 0.0))
	traversal.set("_transition_phase", NpcPlatformTraversal.TransitionPhase.REPOSITIONING_AFTER_FAILURE)
	traversal.set("_failure_reposition_plan", {"position": Vector2(100.0, 0.0)})
	var reposition_result := traversal.physics_update(
		traversal_owner, traversal_session, 0.016, options
	)
	_expect(
		reposition_result.status == NpcPlatformTraversal.TraversalStatus.REPOSITIONING
		and reposition_result.recovery_active
		and traversal.is_recovering(),
		"failed traversal repositioning is reported as recovery"
	)

	traversal.set("_transition_phase", NpcPlatformTraversal.TransitionPhase.STUCK_RECOVERY)
	_expect(traversal.is_recovering(), "stuck recovery phase is publicly visible")
	traversal.cancel(traversal_owner, traversal_session, &"test_stuck_cancel")

	traversal.set_target_position(traversal_owner, traversal_session, Vector2(260.0, 0.0))
	traversal.set("_active_traversal", {"sequence": 9, "traversal_type": "jump"})
	_expect(traversal.has_pending_traversal(), "active traversal debt is visible")
	traversal.cancel(traversal_owner, traversal_session, &"test_clear_stale_debt")
	_expect(
		not traversal.has_pending_traversal() and not traversal.has_target(),
		"cancellation clears stale debt and target references"
	)

	traversal.set_target_position(traversal_owner, traversal_session, Vector2(30.0, 0.0))
	traversal.cancel(traversal_owner, traversal_session, &"test_cancel_idle")
	_expect(
		traversal.get_last_result().status == NpcPlatformTraversal.TraversalStatus.CANCELLED,
		"idle cancellation reports a cancelled result"
	)

	var camera := Camera2D.new()
	camera.position = Vector2.ZERO
	camera.enabled = true
	world.add_child(camera)
	traversal.set_target_actor(traversal_owner, traversal_session, trail_actor)
	traversal.set_breadcrumb_provider(traversal_owner, traversal_session, recorder)
	recorder.set("_breadcrumbs", [])
	recorder.call("_append_breadcrumb", {
		"position": Vector2.ZERO,
		"on_floor": true,
		"completed_traversal": false,
		"recorded_msec": Time.get_ticks_msec(),
	})
	npc.global_position = Vector2(2200.0, 0.0)
	traversal.hard_recovery_requires_offscreen = false
	traversal.set("_stuck_seconds", traversal.stuck_recovery_seconds)
	traversal.call("_process_extreme_recovery", 2200.0)
	_expect(
		npc.global_position.is_equal_approx(Vector2.ZERO),
		"hard-distance stuck recovery uses the supplied safe breadcrumb"
	)

	_expect(
		machine.current_state != null and String(machine.current_state.name) == initial_state,
		"the traversal component never changes the NPC primary state"
	)

	world.queue_free()
	await process_frame
	_finish()


func _create_fixture() -> Dictionary:
	var world := Node2D.new()
	world.name = "NpcPlatformTraversalTestWorld"
	root.add_child(world)
	var floor := StaticBody2D.new()
	floor.position = Vector2(0.0, 10.0)
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(5000.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor.add_child(floor_shape)
	world.add_child(floor)

	var npc := CharacterBody2D.new()
	npc.name = "TraversalNpc"
	var npc_shape := CollisionShape2D.new()
	npc_shape.name = "CollisionShape2D"
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
	machine.request_state(&"Idle", null, "test_initial", 100)
	_settle_on_floor(npc)
	_expect(traversal.bind_character(npc, machine), "traversal binds to its NPC and state machine")
	return {
		"world": world,
		"npc": npc,
		"machine": machine,
		"traversal": traversal,
	}


func _settle_on_floor(npc: CharacterBody2D) -> void:
	npc.velocity = Vector2(0.0, 20.0)
	npc.move_and_slide()
	npc.velocity = Vector2.ZERO


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("NPC_PLATFORM_TRAVERSAL_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
