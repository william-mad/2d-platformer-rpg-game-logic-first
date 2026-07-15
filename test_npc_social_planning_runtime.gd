extends SceneTree

const SocialPlanner = preload("res://scripts/systems/npc_social_planner.gd")
const WorldSimulation = preload("res://scripts/systems/npc_world_simulation.gd")

var _failures: Array[String] = []


class LocalLocations:
	extends Node

	var paired_updates: int = 0
	var saved_records: Dictionary = {}
	var live_npcs: Dictionary = {}

	func get_live_npc(npc_id: String) -> Node:
		return live_npcs.get(npc_id, null) as Node

	func get_current_scene_path() -> String:
		return "res://town.tscn"

	func update_simulated_social_pair(
		first_id: String,
		first_record: Dictionary,
		second_id: String,
		second_record: Dictionary
	) -> bool:
		paired_updates += 1
		saved_records[first_id] = first_record.duplicate(true)
		saved_records[second_id] = second_record.duplicate(true)
		return true


class DescriptorMachine:
	extends Node

	var current_state: Node
	var descriptor: Dictionary = {}

	func get_current_activity_descriptor() -> Dictionary:
		return descriptor


func _initialize() -> void:
	await process_frame
	_test_availability_filters()
	_test_social_candidates_stay_in_the_same_scene()
	_test_pair_reservations_last_for_the_pass()
	_test_simulated_rewards_commit_once()
	await process_frame

	if _failures.is_empty():
		print("NPC social planning runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_availability_filters() -> void:
	var planner := SocialPlanner.new()
	var locations := LocalLocations.new()
	planner.begin_simulation_pass()
	_expect_available(planner, _record("res://town.tscn"), locations, "idle NPC is available")

	var disabled := _record("res://town.tscn")
	disabled["node_state"]["social_stats"]["disabled"] = 1.0
	_expect_unavailable(planner, disabled, locations, "disabled NPC is excluded")
	var downed := _record("res://town.tscn")
	downed["node_state"]["social_stats"]["knockout"] = 100.0
	_expect_unavailable(planner, downed, locations, "knocked-out NPC is excluded")
	var sleeping := _record("res://town.tscn")
	sleeping["activity"] = {"state_name": "Sleep"}
	_expect_unavailable(planner, sleeping, locations, "sleeping NPC is excluded")
	var travelling := _record("res://town.tscn")
	travelling["pending_travel"] = {"target_scene_path": "res://road.tscn"}
	_expect_unavailable(planner, travelling, locations, "pending traveller is excluded")
	var invitation := _record("res://town.tscn")
	invitation["activity"] = {"state_name": "InvitePlayer"}
	_expect_unavailable(planner, invitation, locations, "non-interruptible activity is excluded")
	var work := _record("res://town.tscn")
	work["activity"] = {"state_name": "Work"}
	_expect_available(planner, work, locations, "ordinary work remains socially interruptible")
	var active_session := _record("res://town.tscn")
	active_session["social_session_id"] = "existing"
	_expect_unavailable(planner, active_session, locations, "existing simulated conversation is excluded")
	planner.end_simulation_pass()
	locations.free()


func _test_social_candidates_stay_in_the_same_scene() -> void:
	var planner := SocialPlanner.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var seeker := _record("res://town.tscn")
	var records := {
		"seeker": seeker,
		"local": _record("res://town.tscn"),
		"remote": _record("res://forest.tscn"),
	}
	var settings := {
		"priority": 60,
		"minimum_npc_favor": 10.0,
	}
	var local_locations := LocalLocations.new()
	planner.begin_simulation_pass()
	var selected := planner.choose_candidate(
		&"seeker", seeker, records, local_locations, settings, null, null, rng
	)
	_expect(String(selected.get("target_id", "")) == "local", "same-scene candidate is preferred")

	var remote_only := {"seeker": seeker, "remote": records["remote"]}
	selected = planner.choose_candidate(
		&"seeker", seeker, remote_only, local_locations, settings, null, null, rng
	)
	_expect(selected.is_empty(), "remote candidate cannot trigger a spontaneous scene visit")

	var player := Node2D.new()
	root.add_child(player)
	var talker := Node2D.new()
	var talk_machine := DescriptorMachine.new()
	talk_machine.name = "NpcStateMachine"
	var talk_state := Node.new()
	talk_state.name = "Talk"
	talk_machine.current_state = talk_state
	talk_machine.descriptor = {
		"action_kind": "Talk",
		"target_node": player,
		"target_npc_id": "__player__",
	}
	talker.add_child(talk_machine)
	talk_machine.add_child(talk_state)
	root.add_child(talker)
	local_locations.live_npcs["talker"] = talker
	var player_busy_records := {
		"seeker": seeker,
		"talker": _record("res://town.tscn"),
	}
	selected = planner.choose_candidate(
		&"seeker", seeker, player_busy_records, local_locations, settings, null, player, rng
	)
	_expect(selected.is_empty(), "player already in a live conversation is excluded")
	planner.end_simulation_pass()
	talker.queue_free()
	player.queue_free()
	local_locations.free()


func _test_pair_reservations_last_for_the_pass() -> void:
	var planner := SocialPlanner.new()
	var locations := LocalLocations.new()
	var a := _record("res://town.tscn")
	var b := _record("res://town.tscn")
	var c := _record("res://town.tscn")
	planner.begin_simulation_pass()
	var first := planner.reserve_pair("a", a, "b", b, locations, 60)
	_expect(bool(first.get("accepted", false)), "first social pair reserves atomically")
	var blocked := planner.reserve_pair("c", c, "b", b, locations, 60)
	_expect(not bool(blocked.get("accepted", false)), "reserved participant cannot join another pair")
	_expect(
		planner.finish_session(String(first.get("session_id", "")), true),
		"completed pair clears its active session"
	)
	blocked = planner.reserve_pair("c", c, "b", b, locations, 60)
	_expect(not bool(blocked.get("accepted", false)), "completed participant remains used for this pass")
	planner.end_simulation_pass()
	planner.begin_simulation_pass()
	var next_pass := planner.reserve_pair("c", c, "b", b, locations, 60)
	_expect(bool(next_pass.get("accepted", false)), "participant is available in the next pass")
	planner.end_simulation_pass()
	locations.free()


func _test_simulated_rewards_commit_once() -> void:
	var world := WorldSimulation.new()
	var locations := LocalLocations.new()
	var seeker := _record("res://town.tscn")
	var target := _record("res://town.tscn")
	seeker["node_state"]["social_stats"]["talk_need"] = 90.0
	seeker["node_state"]["social_stats"]["boredom"] = 50.0
	target["node_state"]["social_stats"]["talk_need"] = 80.0
	var records := {"seeker": seeker, "target": target}
	var session_id := "social:test:1"
	_expect(
		bool(world.call(
			"_complete_simulated_conversation",
			&"seeker",
			"target",
			seeker,
			records,
			locations,
			session_id
		)),
		"simulated conversation commits both records"
	)
	_expect(locations.paired_updates == 1, "simulated conversation uses one paired commit")
	_expect(_stat(seeker, "talk_need") == 50.0, "seeker talk reward is applied")
	_expect(_stat(seeker, "boredom") == 40.0, "seeker boredom reward is applied")
	_expect(_stat(target, "talk_need") == 55.0, "partner talk reward is applied")
	_expect(
		String(seeker.get("last_completed_social_session_id", "")) == session_id
		and String(target.get("last_completed_social_session_id", "")) == session_id,
		"both records share the completed social-session ID"
	)
	_expect(
		String(seeker.get("social_session_id", "")).is_empty()
		and String(target.get("social_session_id", "")).is_empty(),
		"active social-session fields clear coherently"
	)
	_expect(
		bool(world.call(
			"_complete_simulated_conversation",
			&"seeker",
			"target",
			seeker,
			records,
			locations,
			session_id
		)),
		"replaying a completed session is idempotent"
	)
	_expect(locations.paired_updates == 1, "duplicate completion does not write or reward again")
	_expect(_stat(seeker, "talk_need") == 50.0, "duplicate completion does not repeat seeker reward")
	_expect(_stat(target, "talk_need") == 55.0, "duplicate completion does not repeat partner reward")
	world.free()
	locations.free()


func _record(scene_path: String) -> Dictionary:
	return {
		"scene_path": scene_path,
		"previous_scene_path": "",
		"last_position": Vector2.ZERO,
		"activity": {},
		"pending_travel": {},
		"social_visit_target_id": "",
		"social_session_id": "",
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"knockout": 0.0,
				"talk_need": 0.0,
				"boredom": 0.0,
			},
		},
	}


func _stat(record: Dictionary, stat_name: String) -> float:
	return float(record["node_state"]["social_stats"].get(stat_name, 0.0))


func _expect_available(
	planner: RefCounted,
	record: Dictionary,
	locations: Node,
	message: String
) -> void:
	var result: Dictionary = planner.call(
		"get_participant_availability", "candidate", record, locations, 60
	)
	_expect(bool(result.get("accepted", false)), message)


func _expect_unavailable(
	planner: RefCounted,
	record: Dictionary,
	locations: Node,
	message: String
) -> void:
	var result: Dictionary = planner.call(
		"get_participant_availability", "candidate", record, locations, 60
	)
	_expect(not bool(result.get("accepted", false)), message)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
