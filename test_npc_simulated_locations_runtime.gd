extends SceneTree

const SchedulePolicy = preload("res://scripts/systems/npc_schedule_window_policy.gd")
const MAID_SLEEP_PATH := "res://data/npc_spots/maid_room_sleep.tres"
const DAD_WORK_PATH := "res://data/npc_spots/dad_workplace_work.tres"

var _failures: Array[String] = []


class LocationsStub extends Node:
	var updated_record: Dictionary = {}

	func update_simulated_record(_npc_id: String, record: Dictionary) -> void:
		updated_record = record.duplicate(true)


func _initialize() -> void:
	await process_frame
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if simulator == null:
		_fail("NpcWorldSimulation autoload is missing.")
		_finish()
		return

	_test_static_diagnostics(simulator)
	_test_dad_work_progress(simulator)
	_test_maid_sleep_progress(simulator)
	_test_schedule_end_contracts()
	_finish()


func _test_static_diagnostics(simulator: Node) -> void:
	var diagnostics := simulator.call("audit_simulated_locations") as Array
	_expect(diagnostics.size() == 2, "both simulated-only manifests are discovered")
	for diagnostic_value in diagnostics:
		var diagnostic: Dictionary = diagnostic_value
		_expect(
			bool(diagnostic.get("accepted", false)),
			"%s manifest, spot, scene, and routes validate: %s" % [
				String(diagnostic.get("location_id", "unknown")),
				"; ".join(diagnostic.get("errors", []) as Array),
			]
		)


func _test_dad_work_progress(simulator: Node) -> void:
	var definition := load(DAD_WORK_PATH) as NpcSpotDefinition
	_expect(definition != null, "Dad work definition loads")
	if definition == null:
		return
	var record := _record(10.0, {
		"boredom": 80.0,
		"hunger": 20.0,
		"sleep_need": 10.0,
		"talk_need": 0.0,
		"tired": 0.0,
	})
	simulator.call("_simulate_offscreen_passive_values", record, 11.0, &"Work", &"dad")
	var after_passive := _stats(record)
	_expect(is_equal_approx(float(after_passive.get("boredom", -1.0)), 80.0), "Work pauses passive boredom growth")
	_expect(is_equal_approx(float(after_passive.get("sleep_need", -1.0)), 15.0), "Dad's sleep need still grows at work")
	_expect(is_equal_approx(float(after_passive.get("hunger", -1.0)), 27.0), "Dad still becomes hungry at work")
	_expect(is_equal_approx(float(after_passive.get("talk_need", -1.0)), 4.0), "Dad's talk need still grows at work")
	_expect(is_equal_approx(float(after_passive.get("tired", -1.0)), 25.0), "off-screen Work adds action tiredness")

	var locations := LocationsStub.new()
	var activity := {
		"spot_id": String(definition.spot_id),
		"state_name": "Work",
		"last_total_hours": 10.0,
	}
	simulator.call(
		"_apply_offscreen_activity_progress",
		&"dad",
		record,
		activity,
		definition,
		11.0,
		locations
	)
	var after_work := _stats(record)
	_expect(is_equal_approx(float(after_work.get("boredom", -1.0)), 67.5), "Dad's work activity reduces boredom off-screen")
	_expect(not locations.updated_record.is_empty(), "Dad's progressed record is persisted")
	locations.free()


func _test_maid_sleep_progress(simulator: Node) -> void:
	var definition := load(MAID_SLEEP_PATH) as NpcSpotDefinition
	_expect(definition != null, "Maid sleep definition loads")
	if definition == null:
		return
	var record := _record(22.0, {
		"boredom": 20.0,
		"hunger": 20.0,
		"sleep_need": 80.0,
		"talk_need": 0.0,
		"tired": 10.0,
	})
	simulator.call("_simulate_offscreen_passive_values", record, 23.0, &"Sleep", &"maid")
	var after_passive := _stats(record)
	_expect(is_equal_approx(float(after_passive.get("sleep_need", -1.0)), 80.0), "Sleep pauses passive sleep-need growth")
	_expect(is_equal_approx(float(after_passive.get("hunger", -1.0)), 27.0), "Maid still becomes hungry while asleep")
	_expect(is_equal_approx(float(after_passive.get("tired", -1.0)), 10.0), "Sleep does not add action tiredness")

	var locations := LocationsStub.new()
	var activity := {
		"spot_id": String(definition.spot_id),
		"state_name": "Sleep",
		"last_total_hours": 22.0,
	}
	simulator.call(
		"_apply_offscreen_activity_progress",
		&"maid",
		record,
		activity,
		definition,
		23.0,
		locations
	)
	var after_sleep := _stats(record)
	_expect(is_equal_approx(float(after_sleep.get("sleep_need", -1.0)), 67.5), "Maid recovers sleep need in her off-screen room")
	_expect(not locations.updated_record.is_empty(), "Maid's progressed record is persisted")
	locations.free()


func _test_schedule_end_contracts() -> void:
	var maid_sleep := load(MAID_SLEEP_PATH) as NpcSpotDefinition
	var dad_work := load(DAD_WORK_PATH) as NpcSpotDefinition
	if maid_sleep != null:
		_expect(maid_sleep.is_active_at(5.99), "Maid remains asleep before 06:00")
		_expect(not maid_sleep.is_active_at(6.0), "Maid wakes and leaves at 06:00")
		var maid_end := SchedulePolicy.evaluate_definition(maid_sleep, 30.0)
		_expect(not bool(maid_end.get("eligible", true)), "Maid sleep occurrence closes exactly at 06:00")
	if dad_work != null:
		_expect(not dad_work.is_active_at(9.99), "Dad has not started work before 10:00")
		_expect(dad_work.is_active_at(10.0), "Dad starts work at 10:00")
		_expect(dad_work.is_active_at(17.99), "Dad remains at work before 18:00")
		_expect(not dad_work.is_active_at(18.0), "Dad stops work and leaves at 18:00")
		var work_end := SchedulePolicy.evaluate_definition(dad_work, 18.0)
		_expect(not bool(work_end.get("eligible", true)), "Dad work occurrence closes exactly at 18:00")


func _record(last_total_hours: float, values: Dictionary) -> Dictionary:
	var social_stats := {
		"hp": 100.0,
		"disabled": 0.0,
	}
	social_stats.merge(values, true)
	return {
		"last_simulated_total_hours": last_total_hours,
		"node_state": {
			"social_stats": social_stats,
			"world_simulation_profile": {
				"passive_needs_enabled": true,
				"rates_per_game_hour": {
					"sleep_need": 5.0,
					"hunger": 7.0,
					"boredom": 8.0,
					"talk_need": 4.0,
				},
				"tired": {
					"enabled": true,
					"value_name": "tired",
					"action_growth_per_game_hour": 25.0,
					"fight_growth_per_game_hour": 60.0,
					"rest_recovery_per_game_hour": 100.0,
					"rest_threshold": 50.0,
					"rest_floor": 40.0,
					"inactive_states": [&"Idle", &"Sleep", &"Collapse", &"DisabledDead"],
				},
			},
		},
	}


func _stats(record: Dictionary) -> Dictionary:
	return (record.get("node_state", {}) as Dictionary).get("social_stats", {}) as Dictionary


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("NPC_SIMULATED_LOCATIONS_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
