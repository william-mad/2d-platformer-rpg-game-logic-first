extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	_test_jump_abandonment_expires()
	_test_stuck_sampling_is_frame_rate_independent()
	await _test_forward_floor_probe()
	await _test_recorder_reacquisition()
	await _test_late_companion_registration_restore()

	if _failures.is_empty():
		print("TRAVEL_FOLLOW_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_jump_abandonment_expires() -> void:
	var traversal = _new_traversal()
	traversal.jump_give_up_target_change_distance = 50.0
	traversal.set("_jump_give_up_target", Vector2(100.0, 0.0))
	traversal.set("_jump_give_up_until_msec", Time.get_ticks_msec() + 1000)
	_expect(
		bool(traversal.call("_jump_is_temporarily_abandoned", Vector2(120.0, 0.0))),
		"a failed target is suppressed during its retry window"
	)
	traversal.set("_jump_give_up_until_msec", Time.get_ticks_msec() - 1)
	_expect(
		not bool(traversal.call("_jump_is_temporarily_abandoned", Vector2(120.0, 0.0))),
		"the same failed target becomes retryable after the retry window"
	)
	_expect(
		traversal.get("_jump_give_up_target") == Vector2.INF,
		"expired jump suppression clears its cached target"
	)

	traversal.set("_jump_give_up_target", Vector2(100.0, 0.0))
	traversal.set("_jump_give_up_until_msec", Time.get_ticks_msec() + 1000)
	traversal.set("_abandoned_traversal_sequence", 4)
	traversal.set("_active_traversal", {"sequence": 5})
	_expect(
		not bool(traversal.call("_jump_is_temporarily_abandoned", Vector2(100.0, 0.0))),
		"a newer player traversal immediately releases old jump suppression"
	)
	traversal.free()


func _test_stuck_sampling_is_frame_rate_independent() -> void:
	var fine_step = _new_traversal()
	var coarse_step = _new_traversal()
	for traversal in [fine_step, coarse_step]:
		traversal.stop_distance = 0.0
		traversal.stuck_progress_sample_seconds = 0.4
		traversal.stuck_minimum_progress_distance = 8.0
		traversal.call("_reset_stuck_tracking", 100.0)
	for _index in range(4):
		fine_step.call("_update_stuck", 99.0, 0.1)
	for _index in range(2):
		coarse_step.call("_update_stuck", 99.0, 0.2)
	_expect(
		is_equal_approx(
			float(fine_step.get("_stuck_seconds")),
			float(coarse_step.get("_stuck_seconds"))
		),
		"stuck timing is stable across different physics frame sizes"
	)

	fine_step.call("_reset_stuck_tracking", 100.0)
	fine_step.call("_update_stuck", 90.0, 0.2)
	fine_step.call("_update_stuck", 90.0, 0.2)
	_expect(
		is_zero_approx(float(fine_step.get("_stuck_seconds"))),
		"meaningful progress resets stuck accumulation"
	)
	fine_step.free()
	coarse_step.free()


func _test_forward_floor_probe() -> void:
	var npc := CharacterBody2D.new()
	npc.name = "ProbeNpc"
	npc.collision_layer = 1
	npc.collision_mask = 1
	var npc_shape := CollisionShape2D.new()
	npc_shape.name = "CollisionShape2D"
	var npc_rectangle := RectangleShape2D.new()
	npc_rectangle.size = Vector2(20.0, 40.0)
	npc_shape.shape = npc_rectangle
	npc_shape.position = Vector2(0.0, -20.0)
	npc.add_child(npc_shape)
	root.add_child(npc)

	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(0.0, 10.0)
	floor_body.collision_layer = 1
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(200.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	await physics_frame

	var probe = (load("res://scenes/creatures/npc/npc_platform_transition_probe.gd") as Script).new()
	probe.near_foot_distance = 4.0
	probe.far_floor_distance = 40.0
	probe.floor_probe_depth = 64.0
	_expect(probe.configure(npc, 1), "forward-floor probe configures from Mom's body shape")
	var ground: Dictionary = probe.inspect_forward_floor(1.0, 100.0)
	_expect(not bool(ground.get("floor_hazard", true)), "continuous ground is classified as walkable")

	floor_rectangle.size = Vector2(45.0, 20.0)
	await physics_frame
	var ledge: Dictionary = probe.inspect_forward_floor(1.0, 100.0)
	_expect(bool(ledge.get("approaching_ledge", false)), "a disappearing forward floor is classified as a ledge")
	var short_target: Dictionary = probe.inspect_forward_floor(1.0, 5.0)
	_expect(
		not bool(short_target.get("floor_hazard", true)),
		"floor beyond a nearby target is not treated as a route hazard"
	)

	npc.queue_free()
	floor_body.queue_free()
	await process_frame


func _test_recorder_reacquisition() -> void:
	var machine := NpcStateMachine.new()
	machine.name = "RecorderTestMachine"
	machine.active = false
	var npc := CharacterBody2D.new()
	var traversal = _new_traversal()
	traversal.name = "NpcPlatformTraversal"
	npc.add_child(machine)
	npc.add_child(traversal)
	root.add_child(npc)
	await process_frame
	traversal.bind_character(npc, machine)
	var traversal_session: int = traversal.acquire(machine, &"recorder_provider_test")
	_expect(traversal_session > 0, "recorder test acquires traversal ownership")
	_expect(not bool(traversal.call("_ensure_breadcrumb_recorder")), "missing optional recorder is handled")

	var first_player := CharacterBody2D.new()
	var first_recorder = (load("res://player/scripts/player_breadcrumb_recorder.gd") as Script).new()
	first_player.add_child(first_recorder)
	root.add_child(first_player)
	await process_frame
	traversal.set_breadcrumb_provider(machine, traversal_session, first_recorder)
	_expect(bool(traversal.call("_ensure_breadcrumb_recorder")), "an explicitly supplied recorder is acquired")
	_expect(traversal.get("_recorder") == first_recorder, "the supplied recorder is cached")

	first_player.queue_free()
	await process_frame
	var second_player := CharacterBody2D.new()
	var second_recorder = (load("res://player/scripts/player_breadcrumb_recorder.gd") as Script).new()
	second_player.add_child(second_recorder)
	root.add_child(second_player)
	await process_frame
	_expect(
		not bool(traversal.call("_ensure_breadcrumb_recorder")),
		"a stale provider is cleared without hard-coded player reacquisition"
	)
	traversal.set_breadcrumb_provider(machine, traversal_session, second_recorder)
	_expect(traversal.get("_recorder") == second_recorder, "a replacement provider can be supplied")

	second_player.queue_free()
	npc.queue_free()
	await process_frame


func _test_late_companion_registration_restore() -> void:
	var runtime := root.get_node_or_null("PlayerRuntime")
	var locations := root.get_node_or_null("NpcLocations")
	_expect(runtime != null and locations != null, "companion restore autoloads are available")
	if runtime == null or locations == null:
		return
	var original_scene := current_scene
	var original_session: Dictionary = runtime.get("travel_session").duplicate(true)
	var original_live_npcs: Dictionary = locations.get("live_npcs").duplicate()

	var scene := Node2D.new()
	scene.name = "LateCompanionRegistrationScene"
	root.add_child(scene)
	current_scene = scene
	var player := Node2D.new()
	player.position = Vector2(100.0, 100.0)
	scene.add_child(player)
	runtime.set("travel_session", {
		"active": true,
		"companion_npc_id": "late_companion_test",
		"origin_scene_path": "",
		"origin_spawn_id": "",
		"destination_scene_path": "",
		"departure_total_hours": 0.0,
		"travel_policy_id": "default_companion",
		"ending": false,
	})
	runtime.call("_restore_companion_after_scene_change", player)
	for _index in range(8):
		await process_frame
	_expect(bool(runtime.get("_pending_companion_restore")), "restore remains pending past the old fixed-frame window")

	var companion := CharacterBody2D.new()
	companion.name = "LateCompanion"
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var idle := NpcStateIdle.new()
	idle.name = "Idle"
	var follow := NpcStateTravelFollow.new()
	follow.name = "TravelFollow"
	machine.add_child(idle)
	machine.add_child(follow)
	companion.add_child(machine)
	var travel_component := TravelCompanionComponent.new()
	travel_component.name = "TravelCompanion"
	companion.add_child(travel_component)
	var traversal := NpcPlatformTraversal.new()
	traversal.name = "NpcPlatformTraversal"
	companion.add_child(traversal)
	scene.add_child(companion)
	await process_frame
	machine.state_history.push_front(follow)
	var live_npcs: Dictionary = locations.get("live_npcs")
	live_npcs["late_companion_test"] = companion
	locations.set("live_npcs", live_npcs)
	locations.emit_signal(&"npc_registered", "late_companion_test", companion, "")
	await process_frame
	await process_frame
	_expect(not bool(runtime.get("_pending_companion_restore")), "matching late registration completes companion restore")
	_expect(
		companion.global_position.is_equal_approx(Vector2(28.0, 92.0)),
		"late-registered companion is positioned relative to the destination player"
	)
	_expect(
		machine.current_state != null and String(machine.current_state.name) == "Idle",
		"a restored nearby companion selects Idle instead of permanent Follow"
	)

	locations.set("live_npcs", original_live_npcs)
	runtime.call("_cancel_pending_companion_restore")
	runtime.set("travel_session", original_session)
	current_scene = original_scene
	scene.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _new_traversal():
	return (load("res://scripts/creatures/npc_platform_traversal.gd") as Script).new()
