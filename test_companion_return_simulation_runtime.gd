extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var locations := root.get_node("NpcLocations")
	var simulation := root.get_node("NpcWorldSimulation")
	var records := {
		"companion": _record("res://village.tscn", 10.0, 20.0, 30.0, 40.0),
		"villager": _record("res://village.tscn", 5.0, 10.0, 15.0, 20.0),
	}
	locations.call("apply_save_data", {"records": records})
	var policy := load("res://data/travel_policies/default_companion.tres") as TravelPolicy
	simulation.call("simulate_companion_return_skip", 10.0, 12.0, "companion", policy)
	var companion: Dictionary = locations.call("get_record_snapshot", "companion")
	var villager: Dictionary = locations.call("get_record_snapshot", "villager")
	var companion_stats: Dictionary = companion["node_state"]["social_stats"]
	var villager_stats: Dictionary = villager["node_state"]["social_stats"]
	_expect_close(float(companion_stats["sleep_need"]), 10.0 + 5.1 * 2.0 * 0.35, "companion gets one travel-policy sleep pass")
	_expect_close(float(companion_stats["talk_need"]), 40.0, "companion social need is excluded/frozen")
	_expect_close(float(villager_stats["hunger"]), 10.0 + 7.0 * 2.0, "ordinary villager needs advance")
	_expect_close(float(villager_stats["talk_need"]), 20.0 + 24.0 * 2.0, "ordinary village need schedule remains authoritative")
	_finish()


func _record(scene_path: String, sleep: float, hunger: float, boredom: float, talk: float) -> Dictionary:
	return {"scene_path": scene_path, "npc_scene_path": "", "last_position": Vector2.ZERO, "last_simulated_total_hours": 10.0, "activity": {}, "pending_travel": {}, "node_state": {"social_stats": {"sleep_need": sleep, "hunger": hunger, "boredom": boredom, "talk_need": talk, "lonely": 10.0, "hp": 100.0, "disabled": 0.0}, "world_simulation_profile": {"rates_per_game_hour": {"sleep_need": 5.1, "hunger": 7.0, "boredom": 8.0, "talk_need": 24.0}, "tired": {"value_name": "tired"}}}}


func _expect_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		failures.append("%s: expected %.3f, got %.3f" % [label, expected, actual])


func _finish() -> void:
	if failures.is_empty():
		print("COMPANION_RETURN_SIMULATION_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
