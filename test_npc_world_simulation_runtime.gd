extends SceneTree

const PREP_SPOT_ID := &"mom_eat_prep"
const FOOD_SPOT_ID := &"mom_eat"
const STAGE_PREP := "prep_work"
const STAGE_FOOD := "food"
const STAGE_CLEANUP := "cleanup_work"

var _failures: Array[String] = []


class MockLocations:
	extends Node

	var finished: bool = false
	var updated_records: Dictionary = {}
	var current_scene_path: String = "res://scenes/testscenes/realtest1.tscn"

	func is_npc_live(_npc_id: String) -> bool:
		return false

	func get_live_npc(_npc_id: String) -> Node:
		return null

	func get_current_scene_path() -> String:
		return current_scene_path

	func update_simulated_record(npc_id: String, record: Dictionary) -> void:
		updated_records[npc_id] = record.duplicate(true)

	func finish_scheduled_activity(
		_npc_id: String,
		_return_scene_path: String,
		_return_position: Vector2
	) -> bool:
		finished = true
		return true


class MockLiveMachine:
	extends Node

	var values := {
		"hunger": 50.0,
	}
	var current_state: Node
	var assigned_invitation_spot: Node2D
	var assigned_priority: int = -1

	func get_value(value_name: StringName) -> float:
		return float(values.get(String(value_name), 0.0))

	func assign_invitation_spot(new_target: Node2D, request_priority: int = 75) -> bool:
		assigned_invitation_spot = new_target
		assigned_priority = request_priority
		if current_state == null:
			current_state = Node.new()
			add_child(current_state)
		current_state.name = "InvitePlayer"
		return true


class MockLiveEatSpot:
	extends Node2D

	var accepts_eat: bool = true

	func can_serve_npc_need(
		_npc_node: Node2D,
		_requested_state_name: StringName,
		_requested_value_name: StringName = &""
	) -> bool:
		return accepts_eat


class MockMagicLessonSpot:
	extends Node2D

	var active: bool = false
	var started_count: int = 0

	func is_lesson_spot_enabled() -> bool:
		return true

	func can_start_lesson(_inviter: Node2D, _player: Node2D) -> bool:
		return true

	func is_lesson_active_for(_inviter: Node2D, _player: Node2D) -> bool:
		return active

	func start_lesson(_inviter: Node2D, _player: Node2D) -> void:
		started_count += 1
		active = true


func _initialize() -> void:
	await process_frame
	_run_tests()
	if _failures.is_empty():
		print("NPC world simulation runtime tests passed.")
		quit(0)
		return

	for failure in _failures:
		push_error(failure)
	quit(1)


func _run_tests() -> void:
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var world_time := root.get_node_or_null("WorldTime")
	var locations := root.get_node_or_null("NpcLocations")
	if simulator == null:
		_fail("NpcWorldSimulation autoload is missing.")
		return
	if world_time == null:
		_fail("WorldTime autoload is missing.")
		return
	if locations == null:
		_fail("NpcLocations autoload is missing.")
		return

	world_time.set("auto_advance", false)
	_test_breakfast_stage_order(simulator, world_time)
	_test_late_food_does_not_call_eaters(simulator, world_time)
	_test_skipped_time_forces_cleanup(simulator, world_time)
	_test_cleanup_owner_filter(simulator, world_time)
	_test_cleanup_work_is_faster_than_prep(simulator, world_time)
	_test_sated_meal_owner_is_not_called_again(simulator, world_time)
	_test_offscreen_eating_consumes_food_one_to_one(simulator, world_time)
	_test_live_eat_resume_revalidates_spot_and_hunger(simulator)
	_test_activity_selector_delegate_matches_helper(simulator)
	_test_sleep_wake_delegate_routes_home(simulator)
	_test_sleep_window_skip_routes_to_bed(simulator)
	_test_magic_lesson_can_interrupt_afternoon_work(simulator)
	_test_magic_lesson_invite_targets_live_player_scene(simulator)
	_test_accepted_magic_lesson_resume_assigns_invite_state(simulator, world_time, locations)
	_test_magic_lesson_invite_waits_for_acceptance(simulator)
	_test_loaded_afternoon_save_tick_is_stable(simulator, world_time, locations)
	_test_offscreen_starvation_damages_at_hunger_cap(simulator)
	_test_needs_simulator_determinism_and_clamping()


func _reset_meal_cycle(simulator: Node, world_time: Node, total_hours: float) -> Dictionary:
	world_time.call("set_total_hours", total_hours)
	simulator.spot_runtime_states.clear()
	simulator.call("_initialize_definition_runtime_states")
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	return simulator.call("get_meal_cycle_state", PREP_SPOT_ID)


func _test_breakfast_stage_order(simulator: Node, world_time: Node) -> void:
	var state := _reset_meal_cycle(simulator, world_time, 6.0)
	_expect_equal(state.get("stage", ""), STAGE_PREP, "06:00 starts breakfast prep")
	_expect_equal(state.get("meal", ""), "breakfast", "06:00 assigns breakfast")
	_expect_true(bool(state.get("work_call_active", false)), "06:00 calls prep owners")
	_expect_equal(float(state.get("value", 0.0)), 100.0, "06:00 sets work to 100")

	simulator.call("set_spot_value", PREP_SPOT_ID, 0.0)
	state = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_equal(state.get("stage", ""), STAGE_FOOD, "prep completion switches to food")
	_expect_true(bool(state.get("food_available", false)), "prep completion makes food available")
	_expect_false(bool(state.get("meal_called", false)), "food ready does not call eaters early")
	_expect_equal(float(state.get("food_value", 0.0)), 100.0, "prep completion fills the food limit")
	_expect_equal(float(simulator.call("get_spot_value", FOOD_SPOT_ID, 0.0)), 100.0, "food flag is available")

	world_time.call("set_total_hours", 7.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	state = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_true(bool(state.get("meal_called", false)), "07:00 calls breakfast food owners")
	var owner_data = state.get("owner_meal_data", {})
	_expect_true(owner_data is Dictionary and owner_data.has("mom"), "breakfast stores mom meal data")
	_expect_true(owner_data is Dictionary and owner_data.has("player"), "breakfast stores player meal data")
	if owner_data is Dictionary and owner_data.has("mom"):
		_expect_false(bool(owner_data["mom"].get("has_had_breakfast", true)), "mom starts as not having breakfast")

	world_time.call("set_total_hours", 8.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	state = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_equal(state.get("stage", ""), STAGE_CLEANUP, "08:00 forces cleanup")
	_expect_equal(state.get("meal", ""), "breakfast", "cleanup keeps breakfast as current meal")
	_expect_equal(float(state.get("value", 0.0)), 100.0, "cleanup starts with 100 work")
	_expect_false(bool(state.get("food_available", true)), "cleanup clears food availability")

	simulator.call("set_spot_value", PREP_SPOT_ID, 0.0)
	state = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_equal(state.get("stage", ""), STAGE_PREP, "cleanup completion returns to prep stage")
	_expect_equal(float(state.get("value", 0.0)), 100.0, "cleanup completion resets prep work")
	_expect_false(bool(state.get("work_call_active", true)), "reset prep waits for next scheduled call")


func _test_late_food_does_not_call_eaters(simulator: Node, world_time: Node) -> void:
	_reset_meal_cycle(simulator, world_time, 6.0)
	world_time.call("set_total_hours", 7.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	simulator.call("set_spot_value", PREP_SPOT_ID, 0.0)

	world_time.call("set_total_hours", 7.5)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	var state: Dictionary = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_equal(state.get("stage", ""), STAGE_FOOD, "late prep completion still creates food")
	_expect_false(bool(state.get("meal_called", true)), "food becoming ready after 07:00 is not called late")


func _test_skipped_time_forces_cleanup(simulator: Node, world_time: Node) -> void:
	_reset_meal_cycle(simulator, world_time, 6.0)
	world_time.call("set_total_hours", 6.5)
	simulator.call("set_spot_value", PREP_SPOT_ID, 0.0)
	world_time.call("set_total_hours", 9.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	var state: Dictionary = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_equal(state.get("stage", ""), STAGE_CLEANUP, "skipping past 08:00 still forces cleanup")
	_expect_false(bool(state.get("food_available", true)), "skipped cleanup clears old food")


func _test_cleanup_owner_filter(simulator: Node, world_time: Node) -> void:
	_reset_meal_cycle(simulator, world_time, 6.0)
	world_time.call("set_total_hours", 8.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	var prep_definition = simulator.call("get_spot_definition", PREP_SPOT_ID)
	_expect_false(
		bool(simulator.call("_meal_cycle_definition_can_start", prep_definition, &"mom", 8.0)),
		"mom is not a cleanup owner"
	)
	_expect_true(
		bool(simulator.call("_meal_cycle_definition_can_start", prep_definition, &"player", 8.0)),
		"player is a cleanup owner"
	)


func _test_cleanup_work_is_faster_than_prep(simulator: Node, world_time: Node) -> void:
	var prep_definition = simulator.call("get_spot_definition", PREP_SPOT_ID)
	_expect_true(prep_definition != null, "meal prep definition loads for cleanup speed test")
	if prep_definition == null:
		return

	_reset_meal_cycle(simulator, world_time, 6.0)
	simulator.call("_apply_meal_cycle_work_progress", prep_definition, 0.125, 6.125)
	var state: Dictionary = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_approx(float(state.get("value", 0.0)), 75.0, 0.001, "prep keeps the base work rate")

	world_time.call("set_total_hours", 8.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	state = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_equal(state.get("stage", ""), STAGE_CLEANUP, "cleanup speed test enters cleanup")
	_expect_approx(
		float(state.get("cleanup_work_multiplier", 1.0)),
		2.0,
		0.001,
		"cleanup exposes the configured work multiplier"
	)

	simulator.call("_apply_meal_cycle_work_progress", prep_definition, 0.125, 8.125)
	state = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	_expect_approx(float(state.get("value", 0.0)), 50.0, 0.001, "cleanup work clears twice as fast")


func _test_sated_meal_owner_is_not_called_again(simulator: Node, world_time: Node) -> void:
	_reset_meal_cycle(simulator, world_time, 6.0)
	world_time.call("set_total_hours", 6.5)
	simulator.call("set_spot_value", PREP_SPOT_ID, 0.0)
	world_time.call("set_total_hours", 7.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))

	var food_definition = simulator.call("get_spot_definition", FOOD_SPOT_ID)
	_expect_true(
		bool(simulator.call("_meal_cycle_definition_can_start", food_definition, &"mom", 7.0)),
		"mom can answer breakfast call before eating"
	)

	var activity := {
		"spot_id": String(FOOD_SPOT_ID),
		"state_name": "Eat",
		"value_name": "hunger",
		"target_scene_path": "res://scenes/testscenes/realtest1.tscn",
		"target_position": Vector2.ZERO,
		"last_total_hours": 7.0,
		"return_scene_path": "res://yard.tscn",
		"return_position": Vector2(3.0, 4.0),
	}
	var record := {
		"scene_path": "res://scenes/testscenes/realtest1.tscn",
		"last_position": Vector2.ZERO,
		"node_state": {
			"social_stats": {
				"hunger": 10.0,
			},
		},
		"activity": activity.duplicate(true),
		"pending_travel": {},
	}
	var locations := MockLocations.new()
	simulator.call("_update_activity", &"mom", record, activity, 7.1, 7.1, locations)
	var offscreen_activity_finished := locations.finished
	locations.free()

	var state: Dictionary = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	var owner_data = state.get("owner_meal_data", {})
	_expect_true(offscreen_activity_finished, "offscreen eating finishes when hunger reaches zero")
	_expect_approx(
		float(simulator.call("get_spot_value", FOOD_SPOT_ID, 0.0)),
		90.0,
		0.001,
		"offscreen eating consumes only the hunger it sates"
	)
	_expect_true(
		owner_data is Dictionary
		and owner_data.has("mom")
		and bool(owner_data["mom"].get("has_had_breakfast", false)),
		"offscreen eating marks mom as having breakfast"
	)
	_expect_false(
		bool(simulator.call("_meal_cycle_definition_can_start", food_definition, &"mom", 7.2)),
		"mom is not called again after reaching hunger zero"
	)
	_expect_true(
		bool(simulator.call("_meal_cycle_definition_can_start", food_definition, &"player", 7.2)),
		"another food owner can still answer the meal call"
	)


func _test_offscreen_eating_consumes_food_one_to_one(simulator: Node, world_time: Node) -> void:
	_reset_meal_cycle(simulator, world_time, 6.0)
	world_time.call("set_total_hours", 6.5)
	simulator.call("set_spot_value", PREP_SPOT_ID, 0.0)
	world_time.call("set_total_hours", 7.0)
	simulator.call("_process_meal_cycle_schedule_until_snapshot", world_time.call("get_snapshot"))
	simulator.call("set_spot_value", FOOD_SPOT_ID, 15.0)

	var activity := {
		"spot_id": String(FOOD_SPOT_ID),
		"state_name": "Eat",
		"value_name": "hunger",
		"target_scene_path": "res://scenes/testscenes/realtest1.tscn",
		"target_position": Vector2.ZERO,
		"last_total_hours": 7.0,
		"return_scene_path": "res://yard.tscn",
		"return_position": Vector2(3.0, 4.0),
	}
	var record := {
		"scene_path": "res://scenes/testscenes/realtest1.tscn",
		"last_position": Vector2.ZERO,
		"node_state": {
			"social_stats": {
				"hunger": 30.0,
			},
		},
		"activity": activity.duplicate(true),
		"pending_travel": {},
	}
	var locations := MockLocations.new()
	simulator.call("_update_activity", &"mom", record, activity, 7.1, 7.1, locations)
	var state: Dictionary = simulator.call("get_meal_cycle_state", PREP_SPOT_ID)
	var owner_data = state.get("owner_meal_data", {})

	_expect_approx(float(record["node_state"]["social_stats"]["hunger"]), 15.0, 0.001, "offscreen eating is limited by food")
	_expect_approx(float(simulator.call("get_spot_value", FOOD_SPOT_ID, 0.0)), 0.0, 0.001, "offscreen eating can empty food")
	_expect_equal(state.get("stage", ""), STAGE_CLEANUP, "empty offscreen food starts cleanup")
	_expect_true(locations.finished, "offscreen eater leaves when food is empty")
	if owner_data is Dictionary and owner_data.has("mom"):
		_expect_false(
			bool(owner_data["mom"].get("has_had_breakfast", false)),
			"partially fed mom is not marked as having eaten"
		)
	locations.free()


func _test_live_eat_resume_revalidates_spot_and_hunger(simulator: Node) -> void:
	var definition := _make_live_resume_food_definition()
	var npc := CharacterBody2D.new()
	npc.name = "Mom"
	root.add_child(npc)

	var machine := MockLiveMachine.new()
	machine.name = "NpcStateMachine"
	npc.add_child(machine)

	var spot := MockLiveEatSpot.new()
	spot.name = "FoodSpot"
	root.add_child(spot)

	spot.accepts_eat = false
	_expect_false(
		bool(simulator.call("_live_activity_can_continue", &"mom", npc, machine, definition, spot)),
		"live Eat resume stops when the spot rejects the eater"
	)

	spot.accepts_eat = true
	_expect_true(
		bool(simulator.call("_live_activity_can_continue", &"mom", npc, machine, definition, spot)),
		"live Eat resume continues when hunger and spot are valid"
	)

	machine.values["hunger"] = 0.0
	_expect_false(
		bool(simulator.call("_live_activity_can_continue", &"mom", npc, machine, definition, spot)),
		"live Eat resume stops when the NPC is already sated"
	)

	spot.free()
	npc.free()


func _test_activity_selector_delegate_matches_helper(simulator: Node) -> void:
	var original_definitions: Dictionary = simulator.spot_definitions
	var original_claims: Dictionary = simulator.spot_claim_counts
	var original_runtime_states: Dictionary = simulator.spot_runtime_states

	var definitions := {
		&"selector_b": _make_selector_definition(&"selector_b"),
		&"selector_a": _make_selector_definition(&"selector_a"),
	}
	var record := {
		"node_state": {
			"social_stats": {
				"boredom": 80.0,
			},
		},
	}

	simulator.spot_definitions = definitions
	simulator.spot_claim_counts = {}
	simulator.spot_runtime_states = {}

	var public_result = simulator.call("_find_best_definition", &"mom", record, 12.0)
	var helper_result = NpcActivitySelector.find_best_definition(
		definitions,
		&"mom",
		record,
		12.0,
		simulator
	)

	simulator.spot_definitions = original_definitions
	simulator.spot_claim_counts = original_claims
	simulator.spot_runtime_states = original_runtime_states

	_expect_true(public_result is NpcSpotDefinition, "selector delegate returns a definition")
	_expect_true(helper_result is NpcSpotDefinition, "selector helper returns a definition")
	if public_result is NpcSpotDefinition and helper_result is NpcSpotDefinition:
		_expect_equal(
			String((public_result as NpcSpotDefinition).spot_id),
			String((helper_result as NpcSpotDefinition).spot_id),
			"selector delegate matches helper"
		)
		_expect_equal(
			String((public_result as NpcSpotDefinition).spot_id),
			"selector_a",
			"selector keeps deterministic spot id tie-break"
		)


func _make_selector_definition(spot_id: StringName) -> NpcSpotDefinition:
	var definition := NpcSpotDefinition.new()
	definition.spot_id = spot_id
	definition.scene_path = "res://scenes/testscenes/realtest1.tscn"
	definition.position = Vector2.ZERO
	definition.state_name = &"Work"
	definition.value_name = &"boredom"
	definition.need_threshold = 20.0
	definition.priority = 30
	definition.require_npc_value_threshold = true
	return definition


func _make_live_resume_food_definition() -> NpcSpotDefinition:
	var definition := NpcSpotDefinition.new()
	definition.spot_id = &"test_food"
	definition.scene_path = "res://scenes/testscenes/realtest1.tscn"
	definition.position = Vector2.ZERO
	definition.state_name = &"Eat"
	definition.value_name = &"hunger"
	definition.finish_when_npc_value_sated = true
	return definition


func _test_sleep_wake_delegate_routes_home(simulator: Node) -> void:
	var original_definitions: Dictionary = simulator.spot_definitions
	var bed := _make_sleep_definition(&"sleep_test_bed")
	simulator.spot_definitions = {bed.spot_id: bed}

	var record := {
		"home_scene_path": "res://yard.tscn",
		"home_position": Vector2(5.0, 6.0),
		"scene_path": "res://bedroom.tscn",
		"last_position": Vector2(20.0, 30.0),
		"activity": {
			"state_name": "Sleep",
			"spot_id": String(bed.spot_id),
			"return_scene_path": "res://old_return.tscn",
			"return_position": Vector2(1.0, 2.0),
		},
		"pending_travel": {},
		"previous_scene_path": "res://somewhere_else.tscn",
	}

	var slept := bool(simulator.call("_clear_sleep_activity_after_skip", record))
	simulator.spot_definitions = original_definitions

	_expect_true(slept, "sleep wake delegate reports sleep route")
	_expect_equal(record["scene_path"], "res://yard.tscn", "sleep wake route uses saved home scene")
	_expect_equal(record["last_position"], Vector2(5.0, 6.0), "sleep wake route uses saved home position")
	_expect_true(record["activity"].is_empty(), "sleep wake route clears activity")
	_expect_equal(record["previous_scene_path"], "", "sleep wake route clears previous travel")


func _test_sleep_window_skip_routes_to_bed(simulator: Node) -> void:
	var original_definitions: Dictionary = simulator.spot_definitions
	var bed := _make_sleep_definition(&"sleep_window_bed")
	bed.owner_npc_ids = [&"mom"]
	bed.active_time_windows = [{"start_hour": 22.0, "end_hour": 6.0}]
	simulator.spot_definitions = {bed.spot_id: bed}

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

	var slept := bool(simulator.call(
		"_apply_sleep_skip_body_values",
		"mom",
		record,
		20.0,
		10.0,
		30.0,
		{}
	))
	simulator.spot_definitions = original_definitions

	_expect_true(slept, "skipped sleep window still counts as sleep")
	_expect_equal(record["scene_path"], "res://bedroom.tscn", "skipped sleep routes to bed scene")
	_expect_equal(record["last_position"], Vector2(20.0, 30.0), "skipped sleep routes to bed position")
	_expect_true(record["activity"].is_empty(), "skipped sleep leaves NPC awake")
	_expect_true(
		bool(record["skip_next_activity_start_after_sleep"]),
		"skipped sleep pauses immediate routine dispatch"
	)


func _test_magic_lesson_can_interrupt_afternoon_work(simulator: Node) -> void:
	simulator.call("_initialize_definition_runtime_states")
	if simulator.has_method("set_spot_value"):
		simulator.call("set_spot_value", &"mom_magic_lesson", 1.0, false)

	var lesson_definition = simulator.call("get_spot_definition", &"mom_magic_lesson")
	var work_definition = simulator.call("get_spot_definition", &"mom_work")
	_expect_true(lesson_definition != null, "magic lesson definition is loaded")
	_expect_true(work_definition != null, "mom work definition is loaded")
	if lesson_definition == null or work_definition == null:
		return

	var record := {
		"scene_path": "res://scenes/testscenes/realtest1.tscn",
		"last_position": Vector2(1443.0, 322.0),
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"boredom": 100.0,
			},
		},
		"activity": {
			"spot_id": "mom_work",
			"state_name": "Work",
		},
		"pending_travel": {},
	}

	var best_definition = simulator.call("_find_best_definition", &"mom", record, 15.25)
	_expect_true(best_definition != null, "15:15 finds an eligible Mom activity")
	if best_definition != null:
		_expect_equal(
			String(best_definition.spot_id),
			"mom_magic_lesson",
			"15:15 chooses magic lesson over work"
		)

	var interrupt_definition = simulator.call(
		"_find_invitation_interrupt_definition",
		&"mom",
		record,
		15.25,
		work_definition
	)
	_expect_true(interrupt_definition != null, "magic lesson can interrupt afternoon work")
	if interrupt_definition != null:
		_expect_equal(
			String(interrupt_definition.spot_id),
			"mom_magic_lesson",
			"work interruption targets magic lesson"
		)


func _test_magic_lesson_invite_targets_live_player_scene(simulator: Node) -> void:
	var definition = simulator.call("get_spot_definition", &"mom_magic_lesson")
	_expect_true(definition != null, "magic lesson definition is available for invite target test")
	if definition == null:
		return

	var player := CharacterBody2D.new()
	player.name = "Player"
	player.add_to_group("player")
	player.global_position = Vector2(321.0, 44.0)
	root.add_child(player)

	var locations := MockLocations.new()
	locations.current_scene_path = "res://scenes/testscenes/realtest1.tscn"
	var record := {
		"scene_path": definition.scene_path,
		"last_position": definition.position,
	}
	var destination: Dictionary = simulator.call(
		"_get_invitation_activity_start_destination",
		record,
		definition,
		locations
	)

	_expect_equal(
		String(destination.get("scene_path", "")),
		"res://scenes/testscenes/realtest1.tscn",
		"magic lesson invite targets the live player scene first"
	)
	_expect_equal(
		destination.get("position", Vector2.ZERO),
		player.global_position,
		"magic lesson invite starts at the live player position"
	)

	player.free()
	locations.free()


func _test_accepted_magic_lesson_resume_assigns_invite_state(
	simulator: Node,
	world_time: Node,
	locations: Node
) -> void:
	var original_time := float(world_time.call("get_total_hours"))
	var original_locations: Dictionary = locations.call("get_save_data")
	var original_runtime_states: Dictionary = simulator.spot_runtime_states.duplicate(true)
	var original_live_spots: Dictionary = simulator.live_spots.duplicate()

	var definition = simulator.call("get_spot_definition", &"mom_magic_lesson")
	_expect_true(definition != null, "magic lesson definition is available for accepted resume test")
	if definition == null:
		return

	world_time.call("set_total_hours", 15.5)
	simulator.call("_initialize_definition_runtime_states")
	simulator.call("set_spot_value", &"mom_magic_lesson", 1.0, false)

	var npc := CharacterBody2D.new()
	npc.name = "Mom"
	root.add_child(npc)

	var machine := MockLiveMachine.new()
	machine.name = "NpcStateMachine"
	npc.add_child(machine)

	var player := CharacterBody2D.new()
	player.name = "Player"
	player.add_to_group("player")
	root.add_child(player)

	var spot := MockMagicLessonSpot.new()
	spot.name = "MagicLessonSpot"
	root.add_child(spot)
	simulator.live_spots[&"mom_magic_lesson"] = spot

	var activity := {
		"spot_id": "mom_magic_lesson",
		"state_name": "InvitePlayer",
		"value_name": "",
		"target_scene_path": definition.scene_path,
		"target_position": definition.position,
		"lesson_phase": "running",
		"lesson_scene_path": definition.scene_path,
		"lesson_position": definition.position,
		"last_total_hours": 15.25,
		"return_scene_path": definition.scene_path,
		"return_position": definition.position,
	}
	locations.npc_records["mom"] = {
		"npc_id": "mom",
		"node_name": "Mom",
		"npc_scene_path": "",
		"home_scene_path": definition.scene_path,
		"home_position": definition.position,
		"scene_path": definition.scene_path,
		"previous_scene_path": "",
		"last_position": definition.position,
		"node_state": {
			"social_stats": {
				"disabled": 0.0,
				"hp": 100.0,
				"tired": 85.0,
			},
		},
		"activity": activity,
		"pending_travel": {},
		"last_simulated_total_hours": 15.25,
		"spawn_random": false,
		"last_travel_msec": 0,
	}
	locations.live_npcs["mom"] = npc

	simulator.call("resume_live_activity", &"mom", npc)

	_expect_equal(
		spot.started_count,
		1,
		"accepted magic lesson resume starts the live class spot"
	)
	_expect_equal(
		machine.assigned_invitation_spot,
		spot,
		"accepted magic lesson resume still assigns Mom to InvitePlayer"
	)
	_expect_equal(
		machine.assigned_priority,
		int(definition.priority),
		"accepted magic lesson resume uses the spot priority"
	)

	locations.call("apply_save_data", original_locations)
	simulator.spot_runtime_states = original_runtime_states
	simulator.live_spots = original_live_spots
	world_time.call("set_total_hours", original_time)
	spot.free()
	player.free()
	npc.free()


func _test_magic_lesson_invite_waits_for_acceptance(simulator: Node) -> void:
	var original_runtime_states: Dictionary = simulator.spot_runtime_states.duplicate(true)
	simulator.call("_initialize_definition_runtime_states")
	simulator.call("set_spot_value", &"mom_magic_lesson", 1.0, false)

	var definition = simulator.call("get_spot_definition", &"mom_magic_lesson")
	_expect_true(definition != null, "magic lesson definition is available for progress test")
	if definition == null:
		simulator.spot_runtime_states = original_runtime_states
		return

	var activity := {
		"spot_id": "mom_magic_lesson",
		"state_name": "InvitePlayer",
		"value_name": "",
		"target_scene_path": definition.scene_path,
		"target_position": Vector2(10.0, 20.0),
		"lesson_phase": "inviting",
		"lesson_scene_path": definition.scene_path,
		"lesson_position": definition.position,
		"last_total_hours": 15.0,
		"return_scene_path": "res://yard.tscn",
		"return_position": Vector2(3.0, 4.0),
	}
	var record := {
		"scene_path": definition.scene_path,
		"last_position": Vector2(10.0, 20.0),
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
			},
		},
		"activity": activity.duplicate(true),
		"pending_travel": {},
	}
	var locations := MockLocations.new()
	simulator.call("_update_activity", &"mom", record, activity, 15.25, 15.25, locations)
	_expect_approx(
		float(simulator.call("get_spot_value", &"mom_magic_lesson", 0.0)),
		1.0,
		0.001,
		"magic lesson invite phase does not spend today's availability"
	)
	_expect_equal(
		record.get("last_position", Vector2.ZERO),
		Vector2(10.0, 20.0),
		"magic lesson invite keeps Mom at her invitation position"
	)

	var running_activity: Dictionary = record.get("activity", {}).duplicate(true)
	running_activity["lesson_phase"] = "running"
	running_activity["last_total_hours"] = 15.25
	record["activity"] = running_activity
	locations.updated_records.clear()
	simulator.call("_update_activity", &"mom", record, running_activity, 15.75, 15.75, locations)
	_expect_approx(
		float(simulator.call("get_spot_value", &"mom_magic_lesson", 0.0)),
		1.0,
		0.001,
		"magic lesson running phase leaves today's availability until class ends"
	)
	_expect_equal(
		record.get("last_position", Vector2.ZERO),
		definition.position,
		"magic lesson running phase simulates Mom at the class spot while active"
	)
	_expect_false(locations.finished, "magic lesson running phase stays active before schedule end")

	running_activity = record.get("activity", {}).duplicate(true)
	locations.updated_records.clear()
	simulator.call("_update_activity", &"mom", record, running_activity, 16.25, 16.25, locations)
	_expect_approx(
		float(simulator.call("get_spot_value", &"mom_magic_lesson", 0.0)),
		0.0,
		0.001,
		"magic lesson schedule end consumes today's lesson availability"
	)
	_expect_equal(
		record.get("last_position", Vector2.ZERO),
		definition.position,
		"magic lesson schedule end leaves Mom at the last simulated class position"
	)
	_expect_true(locations.finished, "magic lesson running phase finishes at schedule end")

	locations.free()
	simulator.spot_runtime_states = original_runtime_states
	simulator.call("_initialize_definition_runtime_states")


func _test_loaded_afternoon_save_tick_is_stable(
	simulator: Node,
	world_time: Node,
	locations: Node
) -> void:
	var original_time := float(world_time.call("get_total_hours"))
	var original_auto_advance := bool(world_time.get("auto_advance"))
	var original_locations: Dictionary = locations.call("get_save_data")
	var original_runtime_states: Dictionary = simulator.spot_runtime_states.duplicate(true)

	world_time.set("auto_advance", false)
	world_time.call("set_total_hours", 13.955)
	simulator.call("apply_save_data", {
		"spot_runtime_states": _make_loaded_afternoon_spot_states(13.906),
	})
	locations.call("apply_save_data", {
		"records": {
			"mom": _make_loaded_afternoon_mom_record(13.955, {}),
		},
	})

	simulator.call("simulate_now")
	var record: Dictionary = locations.call("get_npc_location", "mom")
	_expect_true(
		(record.get("activity", {}) as Dictionary).is_empty(),
		"13:57 loaded save does not start afternoon work early"
	)

	world_time.call("set_total_hours", 14.09)
	simulator.call("simulate_now")
	record = locations.call("get_npc_location", "mom")
	var activity: Dictionary = record.get("activity", {})
	_expect_true(
		activity.is_empty(),
		"14:05 loaded save does not start the moved afternoon work"
	)

	world_time.call("set_total_hours", 14.22)
	simulator.call("simulate_now")
	record = locations.call("get_npc_location", "mom")
	activity = record.get("activity", {})
	_expect_true(
		activity.is_empty(),
		"14:13 loaded save remains idle before the current afternoon window"
	)

	world_time.call("set_total_hours", 15.05)
	simulator.call("simulate_now")
	simulator.call("simulate_now")
	record = locations.call("get_npc_location", "mom")
	activity = record.get("activity", {})
	_expect_equal(
		String(activity.get("spot_id", "")),
		"mom_magic_lesson",
		"loaded afternoon work can hand off to the magic lesson"
	)

	locations.call("apply_save_data", original_locations)
	simulator.spot_runtime_states = original_runtime_states
	simulator.call("_initialize_definition_runtime_states")
	world_time.call("set_total_hours", original_time)
	world_time.set("auto_advance", original_auto_advance)


func _test_offscreen_starvation_damages_at_hunger_cap(simulator: Node) -> void:
	var record := {
		"last_simulated_total_hours": 10.0,
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"hunger": 100.0,
			},
			"world_simulation_profile": {
				"passive_needs_enabled": true,
				"passive_healing_per_game_day": 100.0,
				"starvation_damage_per_game_day": 24.0,
				"rates_per_game_hour": {
					"hunger": 7.0,
				},
			},
		},
	}

	simulator.call("_simulate_offscreen_passive_values", record, 11.0, &"Idle")
	var social_stats: Dictionary = record["node_state"]["social_stats"]
	_expect_approx(float(social_stats["hp"]), 99.0, 0.001, "offscreen hunger 100 drains HP")
	_expect_equal(float(social_stats["hunger"]), 100.0, "offscreen hunger stays capped")


func _test_needs_simulator_determinism_and_clamping() -> void:
	var simulator := NpcNeedsSimulator.new()
	var original := {
		"node_state": {
			"social_stats": {
				"hp": 90.0,
				"hunger": 98.0,
				"sleep_need": 20.0,
			},
			"world_simulation_profile": {
				"rates_per_game_hour": {
					"hunger": 7.0,
					"sleep_need": 5.1,
				},
			},
		},
	}
	var unchanged := original.duplicate(true)
	simulator.advance_needs(unchanged, 0.0, &"Idle")
	_expect_equal(unchanged, original, "zero elapsed needs simulation changes nothing")

	var first := original.duplicate(true)
	var second := original.duplicate(true)
	simulator.advance_needs(first, 1.0, &"Idle")
	simulator.advance_needs(second, 1.0, &"Idle")
	_expect_equal(first, second, "identical needs inputs produce identical outputs")
	var stats: Dictionary = first["node_state"]["social_stats"]
	_expect_equal(float(stats["hunger"]), 100.0, "passive hunger remains clamped")
	_expect_approx(float(stats["sleep_need"]), 25.1, 0.001, "passive need rate is preserved")


func _make_loaded_afternoon_spot_states(last_schedule_total_hours: float) -> Dictionary:
	return {
		"mom_eat": {
			"daily_growth": 0.0,
			"done_threshold": 0.0,
			"kind": "food_available",
			"maximum": 100.0,
			"meal_cycle_controller_id": "mom_eat_prep",
			"meal_cycle_id": "mom_meal_cycle",
			"minimum": 0.0,
			"value": 0.0,
		},
		"mom_eat_prep": {
			"cleanup_owner_ids": ["player"],
			"daily_growth": 0.0,
			"done_threshold": 0.0,
			"food_available": false,
			"food_owner_ids": ["mom", "player"],
			"food_ready_total_hours": -1.0,
			"food_spot_id": "mom_eat",
			"kind": "meal_cycle",
			"last_food_call_meal": "lunch",
			"last_food_call_total_hours": 12.0,
			"last_schedule_total_hours": last_schedule_total_hours,
			"maximum": 100.0,
			"meal": "lunch",
			"meal_called": false,
			"meal_cycle_enabled": true,
			"meal_cycle_id": "mom_meal_cycle",
			"minimum": 0.0,
			"owner_meal_data": {
				"mom": {
					"has_had_breakfast": false,
					"needs_breakfast": true,
				},
				"player": {
					"has_had_breakfast": false,
					"needs_breakfast": true,
				},
			},
			"prep_owner_ids": ["mom", "player"],
			"stage": STAGE_CLEANUP,
			"stage_started_total_hours": 13.0,
			"value": 19.892094,
			"work_call_active": true,
		},
		"mom_magic_lesson": {
			"daily_growth": 1.0,
			"done_threshold": 0.0,
			"kind": "lesson_available",
			"maximum": 1.0,
			"minimum": 0.0,
			"value": 1.0,
		},
		"mom_work": {
			"daily_growth": 50.0,
			"done_threshold": 0.0,
			"kind": "work",
			"maximum": 100.0,
			"minimum": 0.0,
			"value": 65.811111,
		},
	}


func _make_loaded_afternoon_mom_record(total_hours: float, activity: Dictionary) -> Dictionary:
	return {
		"activity": activity.duplicate(true),
		"home_position": Vector2(520.0, 368.0),
		"home_scene_path": "res://scenes/testscenes/realtest1.tscn",
		"last_position": Vector2(1068.499, 367.924),
		"last_simulated_total_hours": total_hours,
		"last_travel_msec": 0,
		"node_name": "MomNpc",
		"node_state": {
			"location_id": "mom",
			"relationship_id": "mom",
			"social_stats": {
				"anger": 0.0,
				"boredom": 51.935763,
				"disabled": 0.0,
				"fear": 0.0,
				"hp": 100.0,
				"hunger": 41.136205,
				"lonely": 0.0,
				"sleep_need": 48.811344,
				"talk_need": 32.004267,
				"tired": 56.666667,
			},
		},
		"npc_id": "mom",
		"npc_scene_path": "res://scenes/creatures/mom_npc.tscn",
		"pending_travel": {},
		"previous_scene_path": "",
		"scene_path": "res://scenes/testscenes/realtest1.tscn",
		"social_visit_target_id": "",
		"spawn_random": false,
	}


func _make_sleep_definition(spot_id: StringName) -> NpcSpotDefinition:
	var definition := NpcSpotDefinition.new()
	definition.spot_id = spot_id
	definition.scene_path = "res://bedroom.tscn"
	definition.position = Vector2(20.0, 30.0)
	definition.state_name = &"Sleep"
	definition.value_name = &"sleep_need"
	definition.need_threshold = 71.0
	definition.priority = 70
	return definition


func _expect_equal(actual, expected, message: String) -> void:
	if actual != expected:
		_fail("%s: expected %s, got %s" % [message, str(expected), str(actual)])


func _expect_approx(actual: float, expected: float, tolerance: float, message: String) -> void:
	if absf(actual - expected) > tolerance:
		_fail("%s: expected %.4f, got %.4f" % [message, expected, actual])


func _expect_true(value: bool, message: String) -> void:
	if not value:
		_fail(message)


func _expect_false(value: bool, message: String) -> void:
	if value:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
