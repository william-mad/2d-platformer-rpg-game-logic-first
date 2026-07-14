extends SceneTree

const ActivityIdentity = preload("res://scripts/systems/npc_activity_identity.gd")
const LocationsScript = preload("res://scripts/systems/npc_locations.gd")
const WorldSimulationScript = preload("res://scripts/systems/npc_world_simulation.gd")

var _failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	var persistent_id: String = ""

	func _init(new_id: String = "") -> void:
		persistent_id = new_id

	func get_npc_location_id() -> StringName:
		return StringName(persistent_id)


class TestSpot:
	extends Node2D

	var persistent_spot_id: StringName = &""

	func _init(new_id: StringName = &"") -> void:
		persistent_spot_id = new_id

	func get_world_spot_id() -> StringName:
		return persistent_spot_id


func _initialize() -> void:
	await process_frame
	_test_descriptor_identity()
	_test_machine_same_state_identity_and_retarget()
	_test_locations_require_identity_for_same_state()
	_test_world_activity_and_social_identity()
	await process_frame

	if _failures.is_empty():
		print("NPC activity identity runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_descriptor_identity() -> void:
	var work_a := ActivityIdentity.describe(&"Work", null, &"work_a", "res://town.tscn")
	var work_b := ActivityIdentity.describe(&"Work", null, &"work_b", "res://town.tscn")
	_expect(ActivityIdentity.matches(work_a, work_a), "same work spot matches")
	_expect(not ActivityIdentity.matches(work_a, work_b), "work spot A does not match work spot B")

	var source_a := Node2D.new()
	var source_b := Node2D.new()
	_expect(
		ActivityIdentity.matches(
			ActivityIdentity.describe(&"Eat", source_a),
			ActivityIdentity.describe(&"Eat", source_a)
		),
		"legacy eat source can match by exact live node"
	)
	_expect(
		not ActivityIdentity.matches(
			ActivityIdentity.describe(&"Eat", source_a),
			ActivityIdentity.describe(&"Eat", source_b)
		),
		"one eat source does not match another"
	)
	_expect(
		not ActivityIdentity.matches(
			ActivityIdentity.describe(&"Eat", source_a),
			ActivityIdentity.describe(&"Eat")
		),
		"ambiguous legacy eat record is not assumed to match"
	)
	source_a.free()
	source_b.free()

	var person_a := TestNpc.new("person_a")
	var person_b := TestNpc.new("person_b")
	_expect(
		ActivityIdentity.matches(
			ActivityIdentity.describe(&"Talk", person_a),
			ActivityIdentity.describe(&"Talk", person_a)
		),
		"talking to the requested person matches"
	)
	_expect(
		not ActivityIdentity.matches(
			ActivityIdentity.describe(&"Talk", person_a),
			ActivityIdentity.describe(&"Talk", person_b)
		),
		"talking to person A does not satisfy person B"
	)
	person_a.free()
	person_b.free()

	var same_spot_other_scene := ActivityIdentity.describe(
		&"Work", null, &"work_a", "res://other_scene.tscn"
	)
	_expect(
		not ActivityIdentity.matches(work_a, same_spot_other_scene),
		"scene identity is compared when both descriptors have it"
	)
	var request_one := ActivityIdentity.describe(
		&"Work", null, &"work_a", "", "activity_one", "request_one"
	)
	var request_two := ActivityIdentity.describe(
		&"Work", null, &"work_a", "", "activity_one", "request_two"
	)
	_expect(
		not ActivityIdentity.matches(request_one, request_two),
		"existing request IDs distinguish otherwise identical activities"
	)


func _test_machine_same_state_identity_and_retarget() -> void:
	var setup := _create_machine_in_state(&"Work", "worker")
	var npc: TestNpc = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var spot_a := TestSpot.new(&"work_a")
	var spot_b := TestSpot.new(&"work_b")
	npc.add_child(spot_a)
	npc.add_child(spot_b)
	machine.work_target = spot_a

	_expect(
		machine.is_following_activity_descriptor(ActivityIdentity.describe(&"Work", spot_a)),
		"machine reports the active work spot"
	)
	_expect(
		not machine.is_following_activity_descriptor(ActivityIdentity.describe(&"Work", spot_b)),
		"machine rejects a different spot with the same state"
	)
	_expect(machine.assign_work_target(spot_a, 20), "same work target is already satisfied")
	_expect(machine.assign_work_target(spot_b, 20), "same-state work request can retarget")
	_expect(machine.work_target == spot_b, "accepted same-state request commits the new work target")
	_expect(machine.state_history.size() == 1, "same-state retarget does not duplicate state history")
	_expect(
		not machine.request_state(&"Work", null, "ambiguous_legacy_work", 20),
		"same-state request without target identity is rejected"
	)
	_expect(machine.work_target == spot_b, "ambiguous rejection leaves the active target unchanged")
	npc.queue_free()


func _test_locations_require_identity_for_same_state() -> void:
	var setup := _create_machine_in_state(&"Work", "worker_locations")
	var npc: TestNpc = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var spot_a := TestSpot.new(&"work_a")
	var spot_b := TestSpot.new(&"work_b")
	npc.add_child(spot_a)
	npc.add_child(spot_b)
	machine.work_target = spot_a

	var locations := LocationsScript.new()
	root.add_child(locations)
	locations.live_npcs["worker_locations"] = npc
	_expect(
		locations.is_npc_available_for_scheduled_activity(
			"worker_locations", &"Work", 20, ActivityIdentity.describe(&"Work", spot_a)
		),
		"availability accepts an exact same-state activity"
	)
	_expect(
		not locations.is_npc_available_for_scheduled_activity(
			"worker_locations", &"Work", 20, ActivityIdentity.describe(&"Work", spot_b)
		),
		"availability does not treat another work spot as already active"
	)
	_expect(
		not locations.is_npc_available_for_scheduled_activity("worker_locations", &"Work", 20),
		"legacy same-state availability without identity is conservative"
	)
	locations.queue_free()
	npc.queue_free()


func _test_world_activity_and_social_identity() -> void:
	var setup := _create_machine_in_state(&"Work", "world_worker")
	var npc: TestNpc = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var spot_a := TestSpot.new(&"work_a")
	var spot_b := TestSpot.new(&"work_b")
	npc.add_child(spot_a)
	npc.add_child(spot_b)
	machine.work_target = spot_a

	var world := WorldSimulationScript.new()
	root.add_child(world)
	var definition_a := NpcSpotDefinition.new()
	definition_a.spot_id = &"work_a"
	definition_a.scene_path = "res://town.tscn"
	definition_a.state_name = &"Work"
	var definition_b := NpcSpotDefinition.new()
	definition_b.spot_id = &"work_b"
	definition_b.scene_path = "res://town.tscn"
	definition_b.state_name = &"Work"
	_expect(
		bool(world.call("_npc_is_following_activity", machine, definition_a, spot_a)),
		"world simulation recognizes the exact live activity"
	)
	_expect(
		not bool(world.call("_npc_is_following_activity", machine, definition_b, spot_b)),
		"world simulation distinguishes same-state spots"
	)

	var person_a := TestNpc.new("person_a")
	var person_b := TestNpc.new("person_b")
	root.add_child(person_a)
	root.add_child(person_b)
	var talk_state := NpcState.new()
	talk_state.name = "Talk"
	talk_state.npc = npc
	talk_state.machine = machine
	machine.add_child(talk_state)
	machine.state_history = [talk_state]
	machine.talk_target = person_a

	var locations := LocationsScript.new()
	root.add_child(locations)
	locations.live_npcs["world_worker"] = npc
	_expect(
		bool(world.call(
			"_request_live_social_seek", &"world_worker", npc, person_a, 60, locations
		)),
		"talking to the planned person satisfies live social seeking"
	)
	_expect(
		not bool(world.call(
			"_request_live_social_seek", &"world_worker", npc, person_b, 60, locations
		)),
		"talking to another person does not satisfy the social plan"
	)

	locations.queue_free()
	world.queue_free()
	person_a.queue_free()
	person_b.queue_free()
	npc.queue_free()


func _create_machine_in_state(state_name: StringName, npc_id: String) -> Dictionary:
	var npc := TestNpc.new(npc_id)
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var state := NpcState.new()
	state.name = String(state_name)
	machine.add_child(state)
	npc.add_child(machine)
	root.add_child(npc)
	machine.bind_npc(npc)
	machine.initialize_states()
	machine.state_history = [state]
	return {"npc": npc, "machine": machine, "state": state}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
