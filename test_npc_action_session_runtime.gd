extends SceneTree

const ActionSession = preload("res://scripts/systems/npc_action_session.gd")

var _failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	var persistent_id: String = "action_test_npc"

	func get_npc_location_id() -> StringName:
		return StringName(persistent_id)


class TestSpot:
	extends Node2D

	var persistent_spot_id: StringName

	func _init(new_id: StringName) -> void:
		persistent_spot_id = new_id

	func get_world_spot_id() -> StringName:
		return persistent_spot_id


class BlockingState:
	extends NpcState

	func can_exit_to(_new_state: NpcState, _request_priority: int) -> bool:
		return false


func _initialize() -> void:
	await process_frame
	_test_session_resource_round_trip()
	_test_machine_authority_and_stale_callbacks()
	await process_frame
	if _failures.is_empty():
		print("NPC action session runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_session_resource_round_trip() -> void:
	var spot := TestSpot.new(&"round_trip_spot")
	root.add_child(spot)
	var session := ActionSession.create("npc_a", &"Work", &"schedule", spot, {
		"session_id": "session-round-trip",
		"spot_id": "round_trip_spot",
		"scene_path": "res://town.tscn",
		"priority": 42,
		"status": "active",
		"start_world_time": 12.5,
		"reservation_ids": ["session-round-trip|round_trip_spot|activity"],
	})
	var descriptor := session.to_descriptor()
	var restored := ActionSession.create("npc_a", &"Work", &"schedule", null, descriptor)
	_expect(restored.session_id == session.session_id, "session ID survives serialization")
	_expect(restored.spot_id == &"round_trip_spot", "spot ID survives serialization")
	_expect(restored.scene_path == "res://town.tscn", "scene path survives serialization")
	_expect(restored.claim_reservation_release("session-round-trip|round_trip_spot|activity"), "reservation releases once")
	_expect(
		not restored.claim_reservation_release("session-round-trip|round_trip_spot|activity"),
		"duplicate reservation release is rejected"
	)
	var legacy := ActionSession.from_legacy_activity("old_npc", {
		"state_name": "Eat",
		"spot_id": "old_food",
		"target_scene_path": "res://old_scene.tscn",
	})
	_expect(legacy != null and legacy.session_id.begins_with("legacy:"), "old activity translates to a stable session")
	spot.queue_free()


func _test_machine_authority_and_stale_callbacks() -> void:
	var npc := TestNpc.new()
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var idle := NpcState.new()
	idle.name = "Idle"
	var work := NpcState.new()
	work.name = "Work"
	var blocked := BlockingState.new()
	blocked.name = "Blocked"
	machine.add_child(idle)
	machine.add_child(work)
	machine.add_child(blocked)
	npc.add_child(machine)
	root.add_child(npc)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [idle]

	var spot_a := TestSpot.new(&"spot_a")
	var spot_b := TestSpot.new(&"spot_b")
	npc.add_child(spot_a)
	npc.add_child(spot_b)
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if simulator == null:
		_expect(false, "spot reservation service is available")
		npc.queue_free()
		return
	simulator.call("register_live_spot", &"spot_a", spot_a)
	simulator.call("register_live_spot", &"spot_b", spot_b)
	var first := {
		"session_id": "action-a",
		"action_kind": "Work",
		"source": "schedule",
		"spot_id": "spot_a",
		"priority": 20,
		"status": "proposed",
	}
	_expect(machine.request_action_from_descriptor(first, spot_a), "first action is accepted")
	_expect(machine.get_active_action_session_id() == "action-a", "first action becomes authoritative")
	_expect(machine.get_work_target() == spot_a, "session target is preferred")
	_expect(
		int(simulator.spot_claim_counts.get(&"spot_a", 0)) == 1,
		"first action owns exactly one spot"
	)
	_expect(
		machine.set_action_target(&"Work", spot_b, "action-a"),
		"same-session target transfer is accepted"
	)
	_expect(
		int(simulator.spot_claim_counts.get(&"spot_a", 0)) == 0
		and int(simulator.spot_claim_counts.get(&"spot_b", 0)) == 1,
		"same-session transfer claims B before releasing A without leaking"
	)
	_expect(
		machine.set_action_target(&"Work", spot_a, "action-a"),
		"same-session target can transfer back"
	)

	var second := first.duplicate(true)
	second["session_id"] = "action-b"
	second["spot_id"] = "spot_b"
	_expect(machine.request_action_from_descriptor(second, spot_b), "replacement action is accepted")
	_expect(machine.get_active_action_session_id() == "action-b", "replacement has one active authority")
	_expect(machine.get_work_target() == spot_b, "replacement updates the authoritative target")
	_expect(not machine.complete_active_action("action-a", "late_callback"), "stale completion is rejected")
	_expect(machine.get_active_action_session_id() == "action-b", "stale completion leaves newer action active")

	machine.state_history = [blocked]
	var rejected := second.duplicate(true)
	rejected["session_id"] = "action-rejected"
	rejected["spot_id"] = "spot_a"
	_expect(not machine.request_action_from_descriptor(rejected, spot_a), "blocked transition is rejected")
	_expect(machine.get_active_action_session_id() == "action-b", "rejection preserves active session")
	_expect(machine.get_work_target() == spot_b, "rejection preserves active target")

	machine.work_target = spot_a
	_expect(machine.get_work_target() == spot_b, "active session wins over a legacy target mirror")
	_expect(machine.complete_active_action("action-b", "done"), "current action can complete")
	_expect(machine.clear_terminal_action("action-b"), "terminal action can be cleared")
	machine.work_target = spot_a
	_expect(machine.get_work_target() == spot_a, "legacy target remains a compatibility fallback")
	simulator.call("unregister_live_spot", &"spot_a", spot_a)
	simulator.call("unregister_live_spot", &"spot_b", spot_b)
	npc.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
