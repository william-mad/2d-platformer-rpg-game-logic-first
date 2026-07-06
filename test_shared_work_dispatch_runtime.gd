extends SceneTree

var _failures: Array[String] = []
var _previous_real_seconds_per_day: float = 0.0


func _initialize() -> void:
	await process_frame
	_configure_world_time()
	_run_tests()
	_restore_world_time()
	if _failures.is_empty():
		print("Shared work dispatch runtime tests passed.")
		quit(0)
		return

	for failure in _failures:
		push_error(failure)
	quit(1)


func _configure_world_time() -> void:
	var world_time := root.get_node_or_null("WorldTime")
	if world_time == null:
		return

	_previous_real_seconds_per_day = float(world_time.get("real_seconds_per_day"))
	world_time.set("auto_advance", false)
	world_time.set("real_seconds_per_day", 240.0)


func _restore_world_time() -> void:
	var world_time := root.get_node_or_null("WorldTime")
	if world_time == null or _previous_real_seconds_per_day <= 0.0:
		return

	world_time.set("real_seconds_per_day", _previous_real_seconds_per_day)


func _run_tests() -> void:
	_test_single_player_matches_one_worker_rate()
	_test_single_npc_matches_one_worker_rate()
	_test_player_and_npc_progress_is_additive()
	_test_player_work_respects_meal_stage()
	_test_player_work_respects_cleanup_owner()


func _test_single_player_matches_one_worker_rate() -> void:
	var setup := _create_work_setup()
	var spot: NpcWorkSpot = setup["spot"]
	var player: Node2D = setup["player"]

	_expect_approx(spot.get_full_work_real_seconds(), 10.0, 0.001, "full work seconds use world rate")
	var actual_delta := spot.apply_worker_work_progress(player, 1.0, 1.0)
	_expect_approx(actual_delta, -10.0, 0.001, "player contributes one worker-second")
	_expect_approx(spot.get_work_needed(), 90.0, 0.001, "player progress changes shared work")
	_free_setup(setup)


func _test_single_npc_matches_one_worker_rate() -> void:
	var setup := _create_work_setup()
	var spot: NpcWorkSpot = setup["spot"]
	var npc: Node2D = setup["npc"]

	var actual_delta := spot.apply_worker_work_progress(npc, 1.0, 1.0)
	_expect_approx(actual_delta, -10.0, 0.001, "npc contributes one worker-second")
	_expect_approx(spot.get_work_needed(), 90.0, 0.001, "npc progress changes shared work")
	_free_setup(setup)


func _test_player_and_npc_progress_is_additive() -> void:
	var setup := _create_work_setup()
	var spot: NpcWorkSpot = setup["spot"]
	var player: Node2D = setup["player"]
	var npc: Node2D = setup["npc"]

	var player_delta := spot.apply_worker_work_progress(player, 1.0, 1.0)
	var npc_delta := spot.apply_worker_work_progress(npc, 1.0, 1.0)
	_expect_approx(player_delta + npc_delta, -20.0, 0.001, "two workers add their progress")
	_expect_approx(spot.get_work_needed(), 80.0, 0.001, "shared work drops by two worker-seconds")
	_free_setup(setup)


func _test_player_work_respects_meal_stage() -> void:
	var setup := _create_work_setup()
	var spot: NpcWorkSpot = setup["spot"]
	var player: Node2D = setup["player"]

	spot.meal_cycle_enabled = true
	spot.meal_cycle_stage = "food"
	spot.meal_cycle_work_call_active = true
	spot.meal_cycle_prep_owner_ids = [&"player"]
	spot.meal_cycle_cleanup_owner_ids = [&"player"]

	_expect_false(spot.can_player_work(player), "player cannot work during food phase")
	_expect_approx(
		spot.apply_worker_work_progress(player, 1.0, 1.0),
		0.0,
		0.001,
		"food phase blocks player progress"
	)
	_free_setup(setup)


func _test_player_work_respects_cleanup_owner() -> void:
	var setup := _create_work_setup()
	var spot: NpcWorkSpot = setup["spot"]
	var player: Node2D = setup["player"]

	spot.meal_cycle_enabled = true
	spot.meal_cycle_stage = "cleanup_work"
	spot.meal_cycle_work_call_active = true
	spot.meal_cycle_cleanup_owner_ids = [&"mom"]

	_expect_false(spot.can_player_work(player), "player cannot work cleanup when not a cleanup owner")
	_expect_approx(
		spot.apply_worker_work_progress(player, 1.0, 1.0),
		0.0,
		0.001,
		"cleanup owner gate blocks player progress"
	)
	_free_setup(setup)


func _create_work_setup() -> Dictionary:
	var spot := NpcWorkSpot.new()
	spot.name = "SharedWorkSpot"
	spot.world_definition = _make_work_definition()
	root.add_child(spot)
	spot.set_work_needed(100.0)

	var player := CharacterBody2D.new()
	player.name = "Player"
	player.add_to_group("player")
	root.add_child(player)

	var npc := CharacterBody2D.new()
	npc.name = "Mom"
	npc.add_to_group("npc")
	root.add_child(npc)

	return {
		"spot": spot,
		"player": player,
		"npc": npc,
	}


func _make_work_definition() -> NpcSpotDefinition:
	var definition := NpcSpotDefinition.new()
	definition.spot_id = &"test_shared_work"
	definition.scene_path = "res://test_shared_work_dispatch_runtime.gd"
	definition.state_name = &"Work"
	definition.value_name = &"boredom"
	definition.require_npc_value_threshold = false
	definition.finish_when_npc_value_sated = false
	definition.spot_value_name = &"work_needed"
	definition.spot_value_initial = 100.0
	definition.spot_value_minimum = 0.0
	definition.spot_value_maximum = 100.0
	definition.spot_value_done_threshold = 0.0
	definition.spot_value_delta_per_game_hour = -100.0
	return definition


func _free_setup(setup: Dictionary) -> void:
	for key in ["spot", "player", "npc"]:
		var node = setup.get(key, null) as Node
		if node != null and is_instance_valid(node):
			node.free()


func _expect_false(value: bool, label: String) -> void:
	if value:
		_fail("%s: expected false" % label)


func _expect_approx(actual: float, expected: float, tolerance: float, label: String) -> void:
	if absf(actual - expected) > tolerance:
		_fail("%s: expected %.4f, got %.4f" % [label, expected, actual])


func _fail(message: String) -> void:
	_failures.append(message)
