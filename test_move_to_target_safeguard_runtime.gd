extends SceneTree

var _failures: Array[String] = []


class TestTravelDoor:
	extends Area2D

	func try_travel_npc(_body: Node2D) -> bool:
		return false


func _initialize() -> void:
	await process_frame
	_test_generic_target_arrival_is_unchanged()
	_test_actual_progress_resets_stuck_time()
	_test_oscillation_does_not_count_as_progress()
	_test_stuck_movement_fails_once()
	_test_travel_door_owns_arrival_commit()
	_test_route_retry_wait_reconciles_to_idle()
	_test_session_refresh_and_target_change_reset_stuck_time()

	if _failures.is_empty():
		print("MoveToTarget safeguard runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_generic_target_arrival_is_unchanged() -> void:
	var target := Node2D.new()
	target.position = Vector2(6.0, 0.0)
	var fixture := _make_fixture(target, "generic-arrival")
	var move_state: NpcStateMoveToTarget = fixture["move_state"]
	var idle_state: NpcState = fixture["idle_state"]
	var machine: NpcStateMachine = fixture["machine"]
	var npc: CharacterBody2D = fixture["npc"]

	var result := move_state.physics_process(0.1)
	_expect(result == idle_state, "generic X-proximity still returns the configured arrival state")
	var descriptor := machine.get_active_action_descriptor()
	_expect(
		String(descriptor.get("status", "")) == "completed",
		"generic X-proximity still completes its movement action"
	)
	npc.velocity.x = 40.0
	move_state.exit()
	_expect(is_zero_approx(npc.velocity.x), "exiting MoveToTarget always stops horizontal velocity")
	_free_fixture(fixture)


func _test_actual_progress_resets_stuck_time() -> void:
	var target := Node2D.new()
	target.position = Vector2(1000.0, 0.0)
	var fixture := _make_fixture(target, "progress-reset")
	var npc: CharacterBody2D = fixture["npc"]
	var move_state: NpcStateMoveToTarget = fixture["move_state"]
	var machine: NpcStateMachine = fixture["machine"]
	_configure_fast_watchdog(move_state)

	move_state.physics_process(0.2)
	npc.position.x += 8.0
	move_state.physics_process(0.2)
	move_state.physics_process(0.2)
	npc.position.x += 8.0
	var result := move_state.physics_process(0.2)

	_expect(result == null, "sampled X displacement prevents a false stuck transition")
	_expect(
		String(machine.get_active_action_descriptor().get("status", "")) == "active",
		"sampled X displacement keeps the exact movement session active"
	)
	_free_fixture(fixture)


func _test_oscillation_does_not_count_as_progress() -> void:
	var target := Node2D.new()
	target.position = Vector2(1000.0, 0.0)
	var fixture := _make_fixture(target, "oscillation-stuck")
	var npc: CharacterBody2D = fixture["npc"]
	var move_state: NpcStateMoveToTarget = fixture["move_state"]
	var idle_state: NpcState = fixture["idle_state"]
	_configure_fast_watchdog(move_state)

	var result: NpcState
	for sample in range(5):
		npc.position.x = 8.0 if sample % 2 == 0 else 0.0
		result = move_state.physics_process(0.2)

	_expect(result == idle_state, "back-and-forth displacement cannot keep an unreachable move alive")
	_free_fixture(fixture)


func _test_stuck_movement_fails_once() -> void:
	var target := Node2D.new()
	target.position = Vector2(1000.0, 0.0)
	var fixture := _make_fixture(target, "stuck-once")
	var npc: CharacterBody2D = fixture["npc"]
	var move_state: NpcStateMoveToTarget = fixture["move_state"]
	var idle_state: NpcState = fixture["idle_state"]
	var machine: NpcStateMachine = fixture["machine"]
	_configure_fast_watchdog(move_state)
	var stuck_publications: Array[Dictionary] = []
	machine.action_session_changed.connect(func(descriptor: Dictionary) -> void:
		if (
			String(descriptor.get("status", "")) == "failed"
			and String(descriptor.get("reason", "")) == "movement_stuck"
		):
			stuck_publications.append(descriptor)
	)

	var result: NpcState
	for sample in range(3):
		result = move_state.physics_process(0.2)

	_expect(result == idle_state, "bounded zero progress returns Idle")
	var descriptor := machine.get_active_action_descriptor()
	_expect(String(descriptor.get("session_id", "")) == "stuck-once", "stuck failure keeps exact session identity")
	_expect(String(descriptor.get("status", "")) == "failed", "stuck movement fails the active session")
	_expect(String(descriptor.get("reason", "")) == "movement_stuck", "stuck movement records a stable reason")
	_expect(is_zero_approx(npc.velocity.x), "stuck failure stops horizontal velocity")
	move_state.physics_process(0.2)
	_expect(stuck_publications.size() == 1, "stuck movement reports its terminal failure only once")
	_free_fixture(fixture)


func _test_travel_door_owns_arrival_commit() -> void:
	var door := TestTravelDoor.new()
	door.position = Vector2(6.0, 0.0)
	door.add_to_group(&"npc_travel_door")
	var fixture := _make_fixture(door, "door-arrival")
	var move_state: NpcStateMoveToTarget = fixture["move_state"]
	var machine: NpcStateMachine = fixture["machine"]
	_configure_fast_watchdog(move_state)

	var result := move_state.physics_process(0.2)
	var descriptor := machine.get_active_action_descriptor()
	_expect(result == null, "travel-door X-proximity holds MoveToTarget for the Area2D handoff")
	_expect(String(descriptor.get("status", "")) == "active", "travel-door X-proximity does not complete the action")
	_expect(String(descriptor.get("phase", "")) == "moving_to_target", "travel-door handoff preserves movement phase")
	_free_fixture(fixture)


func _test_route_retry_wait_reconciles_to_idle() -> void:
	var target := Node2D.new()
	target.position = Vector2(1000.0, 0.0)
	var fixture := _make_fixture(target, "route-retry-idle")
	var machine: NpcStateMachine = fixture["machine"]
	_expect(
		machine.pause_active_action_movement_for_retry(
			"route-retry-idle", "route_manager_disabled"
		),
		"route recovery pauses its exact movement action"
	)
	_expect(
		String(machine.call("_get_active_action_execution_state_name")) == "Idle",
		"route retry wait resolves to Idle instead of executing at the stale door"
	)
	machine.call("_reconcile_current_state_action_session_if_needed")
	_expect(
		machine.current_state != null and String(machine.current_state.name) == "Idle",
		"the next state reconciliation settles a paused route in Idle"
	)
	_free_fixture(fixture)


func _test_session_refresh_and_target_change_reset_stuck_time() -> void:
	var target := Node2D.new()
	target.position = Vector2(1000.0, 0.0)
	var fixture := _make_fixture(target, "watchdog-resets")
	var move_state: NpcStateMoveToTarget = fixture["move_state"]
	var machine: NpcStateMachine = fixture["machine"]
	_configure_fast_watchdog(move_state)

	move_state.physics_process(0.2)
	move_state.physics_process(0.2)
	move_state.on_action_session_refreshed()
	var after_session_refresh := move_state.physics_process(0.2)
	move_state.physics_process(0.2)
	target.position.x += 50.0
	move_state.refresh_timer = 0.0
	var after_target_change := move_state.physics_process(0.2)

	_expect(after_session_refresh == null, "same-session refresh resets accumulated stuck time")
	_expect(after_target_change == null, "meaningful target movement resets accumulated stuck time")
	_expect(
		String(machine.get_active_action_descriptor().get("status", "")) == "active",
		"watchdog resets preserve the active session"
	)
	_free_fixture(fixture)


func _make_fixture(target: Node2D, session_id: String) -> Dictionary:
	var scene := Node2D.new()
	root.add_child(scene)
	var npc := CharacterBody2D.new()
	npc.name = "SafeguardNpc"
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	machine.auto_move_and_slide = false
	var idle_state := NpcState.new()
	idle_state.name = "Idle"
	var move_state := NpcStateMoveToTarget.new()
	move_state.name = "MoveToTarget"
	machine.add_child(idle_state)
	machine.add_child(move_state)
	npc.add_child(machine)
	scene.add_child(npc)
	scene.add_child(target)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [idle_state]
	var accepted := machine.request_action_movement_from_descriptor(
		{
			"session_id": session_id,
			"action_kind": "MoveToTarget",
			"source": "manual",
			"status": "proposed",
		},
		target,
		&"Idle"
	)
	_expect(accepted, "fixture accepts movement session %s" % session_id)
	return {
		"scene": scene,
		"npc": npc,
		"machine": machine,
		"idle_state": idle_state,
		"move_state": move_state,
	}


func _configure_fast_watchdog(move_state: NpcStateMoveToTarget) -> void:
	move_state.progress_sample_seconds = 0.1
	move_state.minimum_progress_distance = 5.0
	move_state.no_progress_timeout_seconds = 0.5
	move_state.meaningful_target_change_distance = 24.0


func _free_fixture(fixture: Dictionary) -> void:
	var scene := fixture.get("scene") as Node
	if scene != null:
		scene.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
