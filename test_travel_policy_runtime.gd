extends SceneTree

var failures: Array[String] = []

class TestTravelNpc:
	extends CharacterBody2D

	func get_npc_location_id() -> StringName:
		return &"travel_policy_state_test"


func _initialize() -> void:
	await process_frame
	var simulator := NpcNeedsSimulator.new()
	var policy := load("res://data/travel_policies/default_companion.tres") as TravelPolicy
	var record := _record(10.0, 20.0, 30.0, 40.0, 50.0)
	var before: Dictionary = record["node_state"]["social_stats"].duplicate(true)
	simulator.advance_needs(record, 2.0, &"", policy.get_need_multipliers())
	var after: Dictionary = record["node_state"]["social_stats"]
	_expect_close(float(after["sleep_need"]), float(before["sleep_need"]) + 5.1 * 2.0 * 0.35, "sleep uses 0.35 travel multiplier")
	_expect_close(float(after["hunger"]), float(before["hunger"]) + 7.0 * 2.0, "hunger progresses normally")
	_expect_close(float(after["boredom"]), float(before["boredom"]), "boredom is frozen")
	_expect_close(float(after["talk_need"]), float(before["talk_need"]), "talk need is frozen")
	_expect_close(float(after["lonely"]), float(before["lonely"]), "loneliness is frozen")
	await _test_live_policy_is_primary_state_independent(policy)
	_finish()


func _test_live_policy_is_primary_state_independent(policy: TravelPolicy) -> void:
	var runtime := root.get_node_or_null("PlayerRuntime")
	_expect(runtime != null, "PlayerRuntime is available for live travel policy checks")
	if runtime == null:
		return
	var original_session: Dictionary = runtime.travel_session.duplicate(true)
	var npc := TestTravelNpc.new()
	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	npc.add_child(machine)
	root.add_child(npc)
	await process_frame
	machine.bind_npc(npc)
	runtime.travel_session = {
		"active": true,
		"companion_npc_id": "travel_policy_state_test",
		"origin_scene_path": "",
		"origin_spawn_id": "",
		"destination_scene_path": "",
		"departure_total_hours": 0.0,
		"travel_policy_id": String(policy.policy_id),
		"ending": false,
	}
	for state_name in [&"Idle", &"TravelFollow", &"Fight"]:
		var state := NpcState.new()
		state.name = state_name
		machine.state_history.clear()
		machine.state_history.push_front(state)
		var multipliers: Dictionary = machine.call("_get_travel_need_multipliers")
		_expect_close(
			float(multipliers.get("sleep_need", -1.0)),
			0.35,
			"live %s keeps the travel sleep multiplier" % String(state_name)
		)
		_expect_close(
			float(multipliers.get("talk_need", -1.0)),
			0.0,
			"live %s keeps the travel talk multiplier" % String(state_name)
		)
	runtime.travel_session = original_session
	npc.queue_free()
	await process_frame


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _record(sleep: float, hunger: float, boredom: float, talk: float, lonely: float) -> Dictionary:
	return {"node_state": {"social_stats": {"sleep_need": sleep, "hunger": hunger, "boredom": boredom, "talk_need": talk, "lonely": lonely, "hp": 100.0, "disabled": 0.0}, "world_simulation_profile": {"rates_per_game_hour": {"sleep_need": 5.1, "hunger": 7.0, "boredom": 8.0, "talk_need": 24.0}, "tired": {"value_name": "tired"}}}}


func _expect_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		failures.append("%s: expected %.3f, got %.3f" % [label, expected, actual])


func _finish() -> void:
	if failures.is_empty():
		print("TRAVEL_POLICY_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
