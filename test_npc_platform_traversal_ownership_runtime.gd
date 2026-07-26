extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var fixture := await _create_fixture()
	var world: Node2D = fixture["world"]
	var npc: CharacterBody2D = fixture["npc"]
	var machine: NpcStateMachine = fixture["machine"]
	var traversal: NpcPlatformTraversal = fixture["traversal"]
	var initial_state := String(machine.current_state.name)
	var options := NpcPlatformTraversal.TraversalOptions.new()

	var owner_a := NpcStateTravelFollow.new()
	owner_a.name = "OwnerA"
	world.add_child(owner_a)
	var owner_b := Node.new()
	owner_b.name = "OwnerB"
	world.add_child(owner_b)
	var target_a := Node2D.new()
	target_a.position = Vector2(240.0, 0.0)
	world.add_child(target_a)
	var target_b := Node2D.new()
	target_b.position = Vector2(-240.0, 0.0)
	world.add_child(target_b)

	var session_a := traversal.acquire(owner_a, &"owner_a_started")
	owner_a.set("_traversal", traversal)
	owner_a.set("_traversal_session_id", session_a)
	_expect(session_a > 0, "first owner receives a traversal session")
	_expect(
		traversal.is_owned_by(owner_a, session_a),
		"the matching owner and session are authorized"
	)
	_expect(
		traversal.set_target_actor(owner_a, session_a, target_a),
		"the matching owner can assign a target"
	)
	var owner_a_result := traversal.physics_update(owner_a, session_a, 0.016, options)
	_expect(
		owner_a_result.movement_active and npc.velocity.x > 0.0,
		"the authorized owner writes pursuit velocity"
	)

	_expect(
		not traversal.set_target_actor(owner_b, session_a, target_b)
		and traversal.get_target_actor() == target_a,
		"a wrong owner cannot replace the active target"
	)
	_expect(
		not traversal.set_target_position(owner_a, session_a - 1, Vector2.ZERO)
		and traversal.get_target_actor() == target_a,
		"a stale session cannot mutate the active target"
	)

	npc.velocity = Vector2(130.0, -410.0)
	traversal.set("_transition_phase", NpcPlatformTraversal.TransitionPhase.EXECUTING_JUMP)
	traversal.set("_transition_plan", {
		"velocity": npc.velocity,
		"flight_time": 0.8,
		"landing_position": Vector2(300.0, 0.0),
	})
	var session_b := traversal.acquire(owner_b, &"owner_b_superseded_a")
	_expect(
		session_b > session_a and traversal.is_owned_by(owner_b, session_b),
		"a new acquisition supersedes the old session monotonically"
	)
	_expect(
		is_zero_approx(npc.velocity.x)
		and is_equal_approx(npc.velocity.y, -410.0)
		and not traversal.is_traversal_committed(),
		"supersession clears horizontal commitment but preserves vertical settling velocity"
	)
	_expect(
		traversal.set_target_actor(owner_b, session_b, target_b),
		"the superseding owner starts with a clean target context"
	)
	owner_a.exit()
	_expect(
		traversal.get_target_actor() == target_b
		and traversal.is_owned_by(owner_b, session_b),
		"a stale TravelFollow exit cannot cancel the newer pursuit"
	)

	var same_frame_velocity := npc.velocity.x
	var same_frame_result := traversal.physics_update(owner_b, session_b, 0.016, options)
	_expect(
		same_frame_result.status == NpcPlatformTraversal.TraversalStatus.SUPERSEDED
		and same_frame_result.reason == &"owner_changed_during_physics_frame"
		and is_equal_approx(npc.velocity.x, same_frame_velocity),
		"two different owner sessions cannot write traversal velocity in one physics frame"
	)
	await physics_frame
	var owner_b_result := traversal.physics_update(owner_b, session_b, 0.016, options)
	_expect(
		owner_b_result.movement_active and npc.velocity.x < 0.0,
		"the newer owner can update on the next physics frame"
	)

	_expect(
		traversal.release(owner_b, session_b, &"owner_b_finished"),
		"the matching owner can release traversal"
	)
	_expect(
		not traversal.release(owner_b, session_b, &"duplicate_release")
		and not traversal.has_owner(),
		"duplicate release is harmless"
	)
	_expect(
		traversal.reset_for_context(owner_b, &"scene_restore_reset"),
		"an unowned traversal accepts a lifecycle reset"
	)
	_expect(
		not traversal.set_target_actor(owner_b, session_b, target_b),
		"context reset invalidates every older traversal session"
	)

	var restored_session := traversal.acquire(owner_a, &"restored_context")
	_expect(
		restored_session > session_b,
		"the next restored context receives a fresh session"
	)
	_expect(
		not traversal.reset_for_context(owner_b, &"stale_context_reset")
		and traversal.is_owned_by(owner_a, restored_session),
		"a lifecycle reset cannot erase an actively owned behavior"
	)
	traversal.release(owner_a, restored_session, &"prepare_freed_owner")

	var temporary_owner := Node.new()
	temporary_owner.name = "TemporaryOwner"
	world.add_child(temporary_owner)
	var temporary_session := traversal.acquire(temporary_owner, &"freed_owner_test")
	traversal.set_target_actor(temporary_owner, temporary_session, target_a)
	temporary_owner.queue_free()
	await physics_frame
	_expect(
		not traversal.has_owner()
		and not traversal.has_target()
		and traversal.get_debug_snapshot()["failure_reason"] == &"owner_freed",
		"a freed owner is detected and its traversal context is cleaned"
	)

	var snapshot := traversal.get_debug_snapshot()
	_expect(
		snapshot.has("owner_description")
		and snapshot.has("session_id")
		and snapshot.has("acquisition_reason")
		and snapshot.has("last_rejected_operation")
		and snapshot.has("target_type"),
		"debug data exposes concise ownership and target context"
	)
	_expect(
		machine.current_state != null and String(machine.current_state.name) == initial_state,
		"ownership handling never changes the NPC primary state"
	)

	var bare_npc := CharacterBody2D.new()
	bare_npc.name = "NpcWithoutTraversal"
	var bare_machine := NpcStateMachine.new()
	bare_machine.name = "NpcStateMachine"
	bare_machine.active = false
	var bare_follow := NpcStateTravelFollow.new()
	bare_follow.name = "TravelFollow"
	bare_machine.add_child(bare_follow)
	bare_npc.add_child(bare_machine)
	world.add_child(bare_npc)
	await process_frame
	bare_follow.enter()
	_expect(
		bare_machine.get_platform_traversal() == null
		and bare_follow.get_traversal_session_id() == 0,
		"states fail safely when an NPC has no authored traversal component"
	)

	world.queue_free()
	await process_frame
	_finish()


func _create_fixture() -> Dictionary:
	var world := Node2D.new()
	world.name = "TraversalOwnershipWorld"
	root.add_child(world)

	var floor := StaticBody2D.new()
	floor.position = Vector2(0.0, 10.0)
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(2000.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor.add_child(floor_shape)
	world.add_child(floor)

	var npc := CharacterBody2D.new()
	npc.name = "OwnershipNpc"
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
	machine.request_state(&"Idle", null, "ownership_test_initial", 100)
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
		print("NPC_PLATFORM_TRAVERSAL_OWNERSHIP_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
