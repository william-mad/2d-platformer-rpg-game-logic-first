extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
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
	_finish()


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

