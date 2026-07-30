extends "res://test/native_scene_tree_test.gd"

var NpcWorldSimulationClass := preload("res://scripts/systems/npc_world_simulation.gd")
var NpcSpotDefinitionClass := preload("res://scripts/resources/npc_spot_definition.gd")


func _make_simulator() -> Node:
	var simulator := NpcWorldSimulationClass.new()
	add_child_autofree(simulator)
	simulator.spot_definitions.clear()
	return simulator


func _make_spot(
	spot_id: StringName,
	state_name: StringName,
	scene_path: String,
	position: Vector2
) -> NpcSpotDefinition:
	var definition := NpcSpotDefinitionClass.new()
	definition.spot_id = spot_id
	definition.state_name = state_name
	definition.scene_path = scene_path
	definition.position = position
	return definition


func test_sleep_skip_routes_sleep_activity_to_saved_home_position() -> void:
	var simulator := _make_simulator()
	var bed := _make_spot(&"bed", &"Sleep", "res://bedroom.tscn", Vector2(20.0, 30.0))
	simulator.spot_definitions[&"bed"] = bed

	var record := {
		"home_scene_path": "res://yard.tscn",
		"home_position": Vector2(5.0, 6.0),
		"scene_path": "res://bedroom.tscn",
		"last_position": Vector2(20.0, 30.0),
		"activity": {
			"state_name": "Sleep",
			"spot_id": "bed",
			"return_scene_path": "res://old_return.tscn",
			"return_position": Vector2(1.0, 2.0),
		},
		"pending_travel": {},
		"previous_scene_path": "res://somewhere_else.tscn",
	}

	simulator._clear_sleep_activity_after_skip(record)

	assert_eq(record["scene_path"], "res://yard.tscn", "wake destination uses saved home scene")
	assert_eq(record["last_position"], Vector2(5.0, 6.0), "wake destination uses saved home position")
	assert_true(record["activity"].is_empty(), "sleep activity is cleared after skip")
	assert_eq(record["previous_scene_path"], "", "wake destination should not keep return travel pending")


func test_sleep_skip_can_wake_at_configured_spot_definition() -> void:
	var simulator := _make_simulator()
	var bed := _make_spot(&"bed", &"Sleep", "res://bedroom.tscn", Vector2(20.0, 30.0))
	bed.wake_spot_id = &"kitchen"
	simulator.spot_definitions[&"bed"] = bed
	simulator.spot_definitions[&"kitchen"] = _make_spot(
		&"kitchen",
		&"Idle",
		"res://home.tscn",
		Vector2(100.0, 200.0)
	)

	var record := {
		"home_scene_path": "res://yard.tscn",
		"home_position": Vector2(5.0, 6.0),
		"scene_path": "res://bedroom.tscn",
		"last_position": Vector2(20.0, 30.0),
		"activity": {
			"state_name": "Sleep",
			"spot_id": "bed",
		},
		"pending_travel": {},
	}

	simulator._clear_sleep_activity_after_skip(record)

	assert_eq(record["scene_path"], "res://home.tscn", "configured wake spot controls the scene")
	assert_eq(record["last_position"], Vector2(100.0, 200.0), "configured wake spot controls the position")


func test_sleep_skip_can_wake_at_sleep_activity_spot() -> void:
	var simulator := _make_simulator()
	var bed := _make_spot(&"bed", &"Sleep", "res://bedroom.tscn", Vector2(20.0, 30.0))
	bed.wake_at_home_position = false
	simulator.spot_definitions[&"bed"] = bed

	var record := {
		"home_scene_path": "res://yard.tscn",
		"home_position": Vector2(5.0, 6.0),
		"scene_path": "res://bedroom.tscn",
		"last_position": Vector2(20.0, 30.0),
		"activity": {
			"state_name": "Sleep",
			"spot_id": "bed",
			"target_scene_path": "res://bedroom.tscn",
			"target_position": Vector2(20.0, 30.0),
		},
		"pending_travel": {},
	}

	simulator._clear_sleep_activity_after_skip(record)

	assert_eq(record["scene_path"], "res://bedroom.tscn", "sleep spot wake route keeps the sleep scene")
	assert_eq(record["last_position"], Vector2(20.0, 30.0), "sleep spot wake route keeps the bed position")


func test_sleep_skip_without_home_position_falls_back_to_activity_return() -> void:
	var simulator := _make_simulator()

	var record := {
		"home_scene_path": "",
		"scene_path": "res://bedroom.tscn",
		"last_position": Vector2(20.0, 30.0),
		"activity": {
			"state_name": "Sleep",
			"spot_id": "bed",
			"return_scene_path": "res://old_return.tscn",
			"return_position": Vector2(1.0, 2.0),
		},
		"pending_travel": {},
	}

	simulator._clear_sleep_activity_after_skip(record)

	assert_eq(record["scene_path"], "res://old_return.tscn", "old records fall back to activity return scene")
	assert_eq(record["last_position"], Vector2(1.0, 2.0), "old records fall back to activity return position")


func test_sleep_skip_routes_location_even_without_saved_body_stats() -> void:
	var simulator := _make_simulator()
	simulator.spot_definitions[&"bed"] = _make_spot(
		&"bed",
		&"Sleep",
		"res://bedroom.tscn",
		Vector2(20.0, 30.0)
	)

	var record := {
		"home_scene_path": "res://yard.tscn",
		"home_position": Vector2(5.0, 6.0),
		"scene_path": "res://bedroom.tscn",
		"last_position": Vector2(20.0, 30.0),
		"node_state": {},
		"activity": {
			"state_name": "Sleep",
			"spot_id": "bed",
		},
		"pending_travel": {},
	}

	simulator._apply_sleep_skip_body_values("mom", record, 22.0, 8.0, 30.0, {})

	assert_eq(record["scene_path"], "res://yard.tscn", "location-only NPCs still route home")
	assert_eq(record["last_position"], Vector2(5.0, 6.0), "location-only NPCs still use home position")
	assert_true(record["activity"].is_empty(), "sleep activity is cleared without body stats")
	assert_eq(float(record["last_simulated_total_hours"]), 30.0, "simulation timestamp is still updated")


func test_sleep_skip_caps_wake_hunger_at_sixty() -> void:
	var simulator := _make_simulator()
	var record := {
		"node_state": {
			"social_stats": {
				"hp": 25.0,
				"disabled": 0.0,
				"hunger": 50.0,
				"sleep_need": 80.0,
				"tired": 20.0,
			},
			"world_simulation_profile": {
				"rates_per_game_hour": {
					"hunger": 7.0,
				},
			},
		},
		"activity": {},
		"pending_travel": {},
	}

	simulator._apply_sleep_skip_body_values("mom", record, 22.0, 10.0, 32.0, {})

	var social_stats: Dictionary = record["node_state"]["social_stats"]
	assert_eq(float(social_stats["hp"]), 100.0, "overnight sleep restores health")
	assert_eq(float(social_stats["hunger"]), 60.0, "wake hunger should never exceed the sleep-skip cap")
	assert_eq(float(social_stats["sleep_need"]), 0.0, "sleep still clears sleep need")
	assert_eq(float(social_stats["tired"]), 0.0, "sleep still clears tired")


func test_sleep_skip_routes_to_sleep_spot_when_sleep_window_was_skipped() -> void:
	var simulator := _make_simulator()
	var bed := _make_spot(
		&"bed",
		&"Sleep",
		"res://bedroom.tscn",
		Vector2(20.0, 30.0)
	)
	bed.owner_npc_ids = [&"mom"]
	bed.active_time_windows = [{"start_hour": 22.0, "end_hour": 6.0}]
	simulator.spot_definitions[&"bed"] = bed

	var record := {
		"npc_id": "mom",
		"home_scene_path": "res://yard.tscn",
		"home_position": Vector2(5.0, 6.0),
		"scene_path": "res://yard.tscn",
		"last_position": Vector2(5.0, 6.0),
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"sleep_need": 80.0,
			},
		},
		"activity": {},
		"pending_travel": {},
	}

	var slept: bool = simulator._apply_sleep_skip_body_values(
		"mom", record, 20.0, 10.0, 30.0, {}
	)

	assert_true(slept, "skipping over the sleep window counts as overnight sleep")
	assert_eq(record["scene_path"], "res://bedroom.tscn", "skipped sleep window routes to the sleep room")
	assert_eq(record["last_position"], Vector2(20.0, 30.0), "skipped sleep window routes to the bed")
	assert_true(record["activity"].is_empty(), "NPC is awake after the skip")
	assert_true(bool(record["skip_next_activity_start_after_sleep"]), "wake dispatch pauses immediate routines")
