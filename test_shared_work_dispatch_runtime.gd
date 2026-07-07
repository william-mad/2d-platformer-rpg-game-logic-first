extends SceneTree

var _failures: Array[String] = []
var _previous_real_seconds_per_day: float = 0.0
var _damage_events_seen: int = 0


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
	_test_practice_dummy_player_hit_updates_counters()
	_test_practice_dummy_practice_times_out()
	_test_practice_dummy_npc_hit_does_not_count_as_player_practice()
	_test_practice_dummy_resets_after_zero_health()
	_test_practice_dummy_scene_wiring()
	_test_practice_dummy_fight_target_filter()
	_test_practice_dummy_damage_does_not_emit_social_damage_event()


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


func _test_practice_dummy_player_hit_updates_counters() -> void:
	var setup := _create_practice_dummy_setup()
	var dummy: PracticeDummy = setup["dummy"]
	var player: Node2D = setup["player"]

	dummy.take_damage(12.0, player.global_position, player, 0.0)
	dummy._process(1.25)

	_expect_equal(dummy.get_player_practice_hits_total(), 1, "player hit increments practice hits")
	_expect_approx(dummy.player_practice_damage_total, 12.0, 0.001, "player damage is tracked")
	_expect_true(dummy.player_practice_active, "player hit starts a practice session")
	_expect_approx(dummy.get_player_practice_total_seconds(), 1.25, 0.001, "active practice time accumulates")
	_expect_approx(dummy.get_player_practice_today_seconds(), 1.25, 0.001, "today practice time accumulates")
	_free_setup(setup)


func _test_practice_dummy_practice_times_out() -> void:
	var setup := _create_practice_dummy_setup()
	var dummy: PracticeDummy = setup["dummy"]
	var player: Node2D = setup["player"]
	dummy.practice_session_timeout_seconds = 2.0

	dummy.take_damage(4.0, player.global_position, player, 0.0)
	dummy._process(0.75)
	dummy._process(2.0)

	_expect_false(dummy.player_practice_active, "practice session closes after timeout")
	_expect_approx(dummy.get_player_practice_total_seconds(), 2.0, 0.001, "practice time is capped at timeout")
	_free_setup(setup)


func _test_practice_dummy_npc_hit_does_not_count_as_player_practice() -> void:
	var setup := _create_practice_dummy_setup()
	var dummy: PracticeDummy = setup["dummy"]
	var npc: Node2D = setup["npc"]

	dummy.take_damage(8.0, npc.global_position, npc, 0.0)

	_expect_equal(dummy.get_player_practice_hits_total(), 0, "npc hit does not increment player hits")
	_expect_approx(dummy.player_practice_damage_total, 0.0, 0.001, "npc hit does not count player damage")
	_expect_false(dummy.player_practice_active, "npc hit does not start player practice")
	_expect_approx(dummy.get_current_health(), 92.0, 0.001, "npc hit still damages dummy")
	_free_setup(setup)


func _test_practice_dummy_resets_after_zero_health() -> void:
	var setup := _create_practice_dummy_setup(10.0)
	var dummy: PracticeDummy = setup["dummy"]
	var player: Node2D = setup["player"]
	dummy.reset_after_seconds = 0.5

	dummy.take_damage(12.0, player.global_position, player, 0.0)
	_expect_approx(dummy.get_current_health(), 0.0, 0.001, "dummy reaches zero health")
	_expect_true(dummy.is_knocked_down(), "dummy marks knocked down at zero health")

	dummy._process(0.6)
	_expect_approx(dummy.get_current_health(), 10.0, 0.001, "dummy restores health after reset")
	_expect_false(dummy.is_knocked_down(), "dummy clears knocked down on reset")
	_free_setup(setup)


func _test_practice_dummy_scene_wiring() -> void:
	var packed_dummy := load("res://scenes/instances/practice_dummy.tscn") as PackedScene
	_expect_true(packed_dummy != null, "practice dummy scene loads")
	if packed_dummy == null:
		return

	var dummy := packed_dummy.instantiate() as Node2D
	_expect_true(dummy.is_in_group("training_dummy"), "dummy scene uses training_dummy group")
	_expect_true(dummy.is_in_group("attack_target"), "dummy scene uses attack_target group")
	_expect_false(dummy.is_in_group("npc"), "dummy scene is not an npc")

	var damage_area := dummy.get_node_or_null("Damage_Area") as Area2D
	_expect_true(damage_area != null, "dummy scene has a damage area")
	if damage_area != null:
		_expect_true(damage_area.has_method("take_damage"), "damage area uses the existing damage bridge")
		_expect_true((damage_area.collision_layer & 128) != 0, "damage area is on the hittable layer")

	var home_scene := load("res://scenes/testscenes/realhometest.tscn") as PackedScene
	_expect_true(home_scene != null, "realhometest scene loads")
	if home_scene != null:
		var home := home_scene.instantiate()
		_expect_true(home.get_node_or_null("PracticeDummy") == null, "realhometest keeps the dummy outside")
		home.free()

	var outside_scene := load("res://scenes/testscenes/realtest1.tscn") as PackedScene
	_expect_true(outside_scene != null, "realtest1 scene loads")
	if outside_scene != null:
		var outside := outside_scene.instantiate()
		_expect_true(outside.get_node_or_null("PracticeDummy") != null, "realtest1 includes the outside practice dummy")
		outside.free()

	dummy.free()


func _test_practice_dummy_fight_target_filter() -> void:
	var setup := _create_practice_dummy_setup()
	var dummy: PracticeDummy = setup["dummy"]
	var npc: CharacterBody2D = setup["npc"]

	var machine := NpcStateMachine.new()
	machine.values = {"anger": 0.0}
	root.add_child(machine)

	var fight := NpcStateFight.new()
	fight.npc = npc
	fight.machine = machine
	fight.target_groups = [&"training_dummy"]
	fight.fight_target = dummy

	_expect_true(
		bool(fight.call("_can_target_for_fight", dummy)),
		"configured Fight state can target training dummy"
	)
	_expect_false(
		bool(fight.call("_anger_is_calm")),
		"training dummy target does not immediately calm-exit Fight"
	)

	fight.free()
	machine.free()
	_free_setup(setup)


func _test_practice_dummy_damage_does_not_emit_social_damage_event() -> void:
	_damage_events_seen = 0
	var damage_events := root.get_node_or_null("DamageEvents")
	if damage_events != null and damage_events.has_signal(&"damage_dealt"):
		var callback := Callable(self, "_on_damage_dealt")
		if not damage_events.is_connected(&"damage_dealt", callback):
			damage_events.connect(&"damage_dealt", callback)

	var setup := _create_practice_dummy_setup()
	var dummy: PracticeDummy = setup["dummy"]
	var player: Node2D = setup["player"]
	dummy.take_damage(3.0, player.global_position, player, 0.0)

	_expect_equal(_damage_events_seen, 0, "dummy damage does not emit global social damage event")
	_free_setup(setup)
	if damage_events != null and damage_events.has_signal(&"damage_dealt"):
		var callback := Callable(self, "_on_damage_dealt")
		if damage_events.is_connected(&"damage_dealt", callback):
			damage_events.disconnect(&"damage_dealt", callback)


func _on_damage_dealt(_amount: float, _attacker: Node, _target: Node) -> void:
	_damage_events_seen += 1


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


func _create_practice_dummy_setup(dummy_health: float = 100.0) -> Dictionary:
	var dummy := PracticeDummy.new()
	dummy.max_health = dummy_health
	dummy.reset_after_seconds = 100.0
	root.add_child(dummy)

	var player := Node2D.new()
	player.name = "Player"
	player.add_to_group("player")
	player.global_position = Vector2(-24.0, 0.0)
	root.add_child(player)

	var npc := CharacterBody2D.new()
	npc.name = "Mom"
	npc.add_to_group("npc")
	npc.global_position = Vector2(24.0, 0.0)
	root.add_child(npc)

	return {
		"dummy": dummy,
		"player": player,
		"npc": npc,
	}


func _free_setup(setup: Dictionary) -> void:
	for key in ["spot", "dummy", "player", "npc"]:
		var node = setup.get(key, null) as Node
		if node != null and is_instance_valid(node):
			node.free()


func _expect_true(value: bool, label: String) -> void:
	if not value:
		_fail("%s: expected true" % label)


func _expect_false(value: bool, label: String) -> void:
	if value:
		_fail("%s: expected false" % label)


func _expect_equal(actual, expected, label: String) -> void:
	if actual != expected:
		_fail("%s: expected %s, got %s" % [label, str(expected), str(actual)])


func _expect_approx(actual: float, expected: float, tolerance: float, label: String) -> void:
	if absf(actual - expected) > tolerance:
		_fail("%s: expected %.4f, got %.4f" % [label, expected, actual])


func _fail(message: String) -> void:
	_failures.append(message)
