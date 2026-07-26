extends SceneTree

var _failures: Array[String] = []

class TestTravelNpc:
	extends CharacterBody2D

	func get_npc_location_id() -> StringName:
		return &"coordinator_test_companion"


class CountingStateMachine:
	extends NpcStateMachine

	var travel_cleanup_count: int = 0

	func cancel_and_clear_active_action_for_override(reason: String) -> bool:
		if reason == "travel_context_activated":
			travel_cleanup_count += 1
		return super.cancel_and_clear_active_action_for_override(reason)


func _initialize() -> void:
	await process_frame
	var runtime := root.get_node_or_null("PlayerRuntime")
	_expect(runtime != null, "PlayerRuntime is available")
	if runtime == null:
		_finish()
		return
	var original_session: Dictionary = runtime.travel_session.duplicate(true)
	var fixture := await _create_fixture()
	var npc: TestTravelNpc = fixture["npc"]
	var player: CharacterBody2D = fixture["player"]
	var machine: CountingStateMachine = fixture["machine"]
	var component: TravelCompanionComponent = fixture["component"]
	var follow: NpcStateTravelFollow = fixture["follow"]
	var traversal: NpcPlatformTraversal = fixture["traversal"]
	var latest_follow_session: int = 0

	runtime.travel_session = runtime.call("_empty_travel_session")
	for activity_index in range(3):
		var activity_name: String = ["Work", "Rest", "Recreation"][activity_index]
		machine.change_state(machine.get_state(StringName(activity_name)), "test_activity_setup", 100)
		var session := NpcActionSession.create(
			"coordinator_test_companion",
			StringName(activity_name),
			&"schedule"
		)
		session.status = NpcActionSession.Status.ACTIVE
		session.phase = &"executing"
		machine.active_action = session
		player.global_position = npc.global_position + Vector2(
			240.0 if activity_index == 0 else 40.0,
			0.0
		)
		var activity_start: Dictionary = runtime.start_travel(npc, player, null)
		_expect(bool(activity_start.get("success", false)), "travel starts from %s" % activity_name)
		_expect(machine.active_action == null, "%s activity state is released at travel start" % activity_name)
		_expect(
			machine.travel_cleanup_count == activity_index + 1,
			"%s activity cleanup runs exactly once" % activity_name
		)
		if activity_index == 0:
			_expect(_state_name(machine) == "TravelFollow", "starting far selects Follow")
			latest_follow_session = follow.get_traversal_session_id()
			_expect(
				latest_follow_session > 0
				and traversal.is_owned_by(follow, latest_follow_session),
				"TravelFollow acquires traversal when far travel begins"
			)
		else:
			_expect(_state_name(machine) == "Idle", "starting close from %s selects Idle" % activity_name)
		runtime.request_stop_travel(npc)
		_expect(_state_name(machine) == "Idle", "ending the %s session leaves Idle" % activity_name)
		_expect(not traversal.has_owner(), "ending travel releases Follow traversal ownership")

	player.global_position = npc.global_position + Vector2(40.0, 0.0)
	var start_close: Dictionary = runtime.start_travel(npc, player, null)
	_expect(bool(start_close.get("success", false)), "travel starts while close")
	_expect(_state_name(machine) == "Idle", "starting close selects Idle")
	_expect(machine.travel_cleanup_count == 4, "travel-start cleanup runs once per session")

	player.global_position = npc.global_position + Vector2(220.0, 0.0)
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	_expect(_state_name(machine) == "TravelFollow", "crossing the horizontal start threshold activates Follow")
	var horizontal_follow_session := follow.get_traversal_session_id()
	_expect(
		horizontal_follow_session > latest_follow_session
		and traversal.is_owned_by(follow, horizontal_follow_session),
		"re-entering TravelFollow acquires a fresh traversal session"
	)
	latest_follow_session = horizontal_follow_session

	player.global_position = npc.global_position + Vector2(110.0, 0.0)
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	_expect(_state_name(machine) == "TravelFollow", "the hysteresis band does not oscillate")

	_settle_on_floor(npc)
	player.global_position = npc.global_position + Vector2(40.0, 0.0)
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	follow.physics_process(0.016)
	_expect(_state_name(machine) == "Idle", "catching up below the stop threshold returns to Idle")
	_expect(not traversal.has_owner(), "caught-up Follow releases traversal before Idle")

	player.global_position = npc.global_position + Vector2(0.0, -100.0)
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	_expect(_state_name(machine) == "TravelFollow", "vertical separation activates Follow")
	latest_follow_session = follow.get_traversal_session_id()

	_settle_on_floor(npc)
	player.global_position = npc.global_position + Vector2(10.0, 0.0)
	traversal.set("_active_traversal", {
		"sequence": 7,
		"completed_traversal": true,
		"traversal_type": "jump",
		"landing_position": player.global_position,
	})
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	_expect(_state_name(machine) == "TravelFollow", "pending traversal prevents premature Idle")
	traversal.call("_mark_active_traversal_complete")

	var fight := machine.get_state(&"Fight")
	var look := machine.get_state(&"LookForMonster")
	_expect(machine.change_state(fight, "test_fight_interrupt", 94), "Fight interrupts Follow normally")
	_expect(_state_name(machine) == "Fight", "Fight remains the primary state")
	_expect(
		not traversal.has_owner()
		and not traversal.has_target()
		and not traversal.is_traversal_committed(),
		"Fight interruption leaves no stale Follow traversal context"
	)
	player.global_position = npc.global_position + Vector2(20.0, 0.0)
	_expect(machine.request_state(&"Idle", null, "fight_finished", 94), "Fight can finish into Idle")
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	_expect(_state_name(machine) == "Idle", "Fight ending near the player remains Idle")

	_expect(machine.change_state(fight, "test_fight_far", 94), "a second Fight starts")
	player.global_position = npc.global_position + Vector2(240.0, 0.0)
	_expect(machine.change_state(look, "fight_finished_search", 94), "Fight can hand off to LookForMonster")
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	_expect(_state_name(machine) == "LookForMonster", "the coordinator does not interrupt monster search")
	_expect(
		machine.request_state(&"Idle", null, "monster_search_finished_far", 94),
		"LookForMonster finishes into Idle first"
	)
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	_expect(_state_name(machine) == "TravelFollow", "the coordinator follows after combat search ends far away")
	_expect(
		follow.get_traversal_session_id() > latest_follow_session
		and traversal.is_owned_by(follow, follow.get_traversal_session_id()),
		"post-combat Follow reacquires a newer traversal session"
	)
	_expect(machine.travel_cleanup_count == 4, "re-entering Follow does not repeat travel-start cleanup")

	_expect(
		machine.is_state_allowed_for_active_travel_companion(&"Idle"),
		"Idle is allowed during travel"
	)
	_expect(
		not machine.is_state_allowed_for_active_travel_companion(&"Work"),
		"village Work remains disallowed during travel"
	)

	follow.call("clear_travel_context")
	_settle_on_floor(npc)
	player.global_position = npc.global_position + Vector2(20.0, 0.0)
	component.set("_request_retry_timer", 0.0)
	component.evaluate_follow_need()
	if _state_name(machine) == "TravelFollow":
		follow.physics_process(0.016)
	runtime.request_stop_travel(npc)
	_expect(not runtime.is_travel_active(), "ending travel is independent of Follow")
	_expect(_state_name(machine) == "Idle", "ending travel in Idle preserves a passive normal state")

	runtime.travel_session = {
		"active": true,
		"companion_npc_id": "coordinator_test_companion",
		"origin_scene_path": "",
		"origin_spawn_id": "",
		"destination_scene_path": "",
		"departure_total_hours": 0.0,
		"travel_policy_id": "default_companion",
		"ending": false,
	}
	var saved: Dictionary = runtime.get_save_data()
	_expect(bool(saved["travel_session"].get("active", false)), "save data preserves the travel session")
	_expect(_state_name(machine) == "Idle", "saving travel does not require TravelFollow as primary state")

	runtime.travel_session = original_session
	fixture["world"].queue_free()
	await process_frame
	_finish()


func _create_fixture() -> Dictionary:
	var world := Node2D.new()
	world.name = "TravelCoordinatorTestWorld"
	root.add_child(world)
	var floor := StaticBody2D.new()
	floor.position = Vector2(0.0, 10.0)
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(2000.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor.add_child(floor_shape)
	world.add_child(floor)

	var player := CharacterBody2D.new()
	player.name = "CoordinatorPlayer"
	player.add_to_group(&"player")
	world.add_child(player)

	var npc := TestTravelNpc.new()
	npc.name = "CoordinatorNpc"
	var npc_shape := CollisionShape2D.new()
	var npc_rectangle := RectangleShape2D.new()
	npc_rectangle.size = Vector2(20.0, 40.0)
	npc_shape.shape = npc_rectangle
	npc_shape.position = Vector2(0.0, -20.0)
	npc.add_child(npc_shape)
	var machine := CountingStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var idle := NpcStateIdle.new()
	idle.name = "Idle"
	var follow := NpcStateTravelFollow.new()
	follow.name = "TravelFollow"
	var fight := NpcState.new()
	fight.name = "Fight"
	var look := NpcState.new()
	look.name = "LookForMonster"
	var work := NpcState.new()
	work.name = "Work"
	var rest := NpcState.new()
	rest.name = "Rest"
	var recreation := NpcState.new()
	recreation.name = "Recreation"
	machine.add_child(idle)
	machine.add_child(follow)
	machine.add_child(fight)
	machine.add_child(look)
	machine.add_child(work)
	machine.add_child(rest)
	machine.add_child(recreation)
	npc.add_child(machine)
	var component := TravelCompanionComponent.new()
	component.name = "TravelCompanion"
	npc.add_child(component)
	var traversal := NpcPlatformTraversal.new()
	traversal.name = "NpcPlatformTraversal"
	npc.add_child(traversal)
	world.add_child(npc)
	await process_frame
	machine.request_state(&"Idle", null, "test_initial", 100)
	_settle_on_floor(npc)
	return {
		"world": world,
		"player": player,
		"npc": npc,
		"machine": machine,
		"component": component,
		"follow": follow,
		"traversal": traversal,
	}


func _settle_on_floor(npc: CharacterBody2D) -> void:
	npc.velocity = Vector2(0.0, 20.0)
	npc.move_and_slide()
	npc.velocity = Vector2.ZERO


func _state_name(machine: NpcStateMachine) -> String:
	return String(machine.current_state.name) if machine.current_state != null else ""


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("TRAVEL_COMPANION_COORDINATOR_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
