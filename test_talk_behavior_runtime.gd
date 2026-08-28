extends SceneTree

var _failures: Array[String] = []


class PromptCallback:
	extends Node

	var accepted_count: int = 0
	var declined_count: int = 0
	var last_prompt_id: StringName = &""

	func accept_prompt(_npc: Node2D, _player: Node2D, prompt_id: StringName) -> void:
		accepted_count += 1
		last_prompt_id = prompt_id

	func decline_prompt(_npc: Node2D, _player: Node2D, prompt_id: StringName) -> void:
		declined_count += 1
		last_prompt_id = prompt_id


class LessonMom:
	extends CharacterBody2D

	var social_events: Array[Dictionary] = []

	func apply_social_event(delta: Dictionary, _actor: Node2D, _evaluate_reactions: bool) -> void:
		social_events.append(delta.duplicate(true))

	func get_npc_location_id() -> String:
		return "mom"


class LessonActionMachine:
	extends Node

	var descriptor: Dictionary = {}

	func get_active_action_session_id() -> String:
		return NpcActionSession._descriptor_session_id(descriptor)

	func get_active_action_descriptor() -> Dictionary:
		return descriptor.duplicate(true)

	func update_active_action_metadata(
		expected_session_id: String,
		metadata_updates: Dictionary,
		scene_path: String = "",
		_publish_change: bool = true
	) -> bool:
		if get_active_action_session_id() != expected_session_id:
			return false
		descriptor["metadata"] = metadata_updates.duplicate(true)
		if not scene_path.is_empty():
			descriptor["scene_path"] = scene_path
		return true


class EmptyFoodSpot:
	extends Node2D

	func can_serve_npc_need(
		_npc_node: Node2D,
		_requested_state_name: StringName,
		_requested_value_name: StringName = &""
	) -> bool:
		return true

	func consume_eat_amount(_requested_hunger_amount: float) -> float:
		return 0.0


class OverlayWorkSpot:
	extends Node2D

	func can_serve_npc_need(
		_npc_node: Node2D,
		_requested_state_name: StringName,
		_requested_value_name: StringName = &""
	) -> bool:
		return true

	func has_work_needed() -> bool:
		return true

	func get_routine_task_animation_name() -> StringName:
		return &"meal_prep_1"


class MealCompletionFoodSpot:
	extends Node2D

	var meal_sated_count: int = 0
	var consume_count: int = 0

	func can_serve_npc_need(
		_npc_node: Node2D,
		_requested_state_name: StringName,
		_requested_value_name: StringName = &""
	) -> bool:
		return true

	func consume_eat_amount(requested_hunger_amount: float) -> float:
		consume_count += 1
		return requested_hunger_amount

	func mark_npc_meal_sated(
		_npc_node: Node2D,
		_need_value_name: StringName = &"hunger"
	) -> bool:
		meal_sated_count += 1
		return true


class RoutineTaskTestSpot:
	extends Node2D

	var persistent_spot_id: StringName = &""
	var last_value_name: StringName = &""

	func get_world_spot_id() -> StringName:
		return persistent_spot_id

	func can_serve_npc_need(
		_npc_node: Node2D,
		_requested_state_name: StringName,
		requested_value_name: StringName = &""
	) -> bool:
		last_value_name = requested_value_name
		return true


class TestMonster:
	extends CharacterBody2D

	var hp: float = 30.0
	var dead: bool = false

	func take_damage(
		amount: float,
		_damage_source_position: Vector2 = Vector2.ZERO,
		_damage_source: Node = null,
		_knockout_damage: float = 0.0
	) -> void:
		if dead:
			return
		hp = maxf(hp - amount, 0.0)
		dead = hp <= 0.0

	func get_current_health() -> float:
		return hp


func _initialize() -> void:
	await process_frame
	if OS.get_cmdline_user_args().has("--social-search-handoff-only"):
		_test_social_search_handoff_completes_primary_action()
	elif OS.get_cmdline_user_args().has("--social-start-viability-only"):
		_test_social_search_checks_start_distance_before_talk()
	elif OS.get_cmdline_user_args().has("--casual-target-only"):
		_test_passive_casual_activities_ignore_social_actor()
	elif OS.get_cmdline_user_args().has("--talk-ring-only"):
		_test_talk_duration_and_progress_ring()
	elif OS.get_cmdline_user_args().has("--stored-only-values-only"):
		_test_stored_only_values_do_not_change_or_drive_behavior()
	elif OS.get_cmdline_user_args().has("--scheduled-sleep-only"):
		_test_scheduled_sleep_does_not_wake_when_need_is_sated()
	elif OS.get_cmdline_user_args().has("--collapse-recovery-only"):
		_test_collapse_recovers_in_place_until_sleep_need_seventy()
	elif OS.get_cmdline_user_args().has("--work-animation-only"):
		_test_work_animation_remains_primary_during_talk()
	else:
		_run_tests()
	if _failures.is_empty():
		print("NPC talk behavior runtime tests passed.")
		quit(0)
		return

	for failure in _failures:
		push_error(failure)
	quit(1)


func _run_tests() -> void:
	_test_talk_overlay_does_not_replace_primary()
	_test_talk_duration_and_progress_ring()
	_test_stored_only_values_do_not_change_or_drive_behavior()
	_test_scheduled_sleep_does_not_wake_when_need_is_sated()
	_test_collapse_recovers_in_place_until_sleep_need_seventy()
	_test_rejected_state_request_preserves_targets()
	_test_rejected_player_social_choice_applies_no_effects()
	_test_player_interaction_gate_blocks_emergency_states()
	_test_emergency_state_invalidates_open_menu_and_resumes_processing()
	_test_missing_interaction_ui_releases_player_interaction_hold()
	_test_active_talk_allows_emergency_interrupt()
	_test_emergency_cancels_both_talk_overlays_once()
	_test_eat_lifecycle_is_not_restarted_by_talk()
	_test_work_animation_remains_primary_during_talk()
	_test_sated_eat_marks_meal_without_consuming()
	_test_routine_task_exact_target_does_not_fall_back()
	_test_duplicate_talk_request_does_not_restart_talk()
	_test_duplicate_move_to_talk_request_is_ignored()
	_test_move_to_talk_arrival_opens_overlay()
	_test_far_talk_request_approaches_without_cancel_loop()
	_test_social_search_handoff_completes_primary_action()
	_test_social_search_checks_start_distance_before_talk()
	_test_passive_casual_activities_ignore_social_actor()
	_test_hungry_reaction_waits_without_usable_eat_spot()
	_test_hungry_reaction_uses_available_eat_spot()
	_test_eat_state_stops_when_food_spot_supplies_nothing()
	_test_starvation_damage_starts_at_hunger_cap()
	_test_tired_speed_scaling()
	_test_seen_monster_starts_fight()
	_test_seen_monster_can_flee_for_coward_npc()
	_test_value_signals_use_delta_and_full_sync_paths()
	_test_monster_damage_does_not_change_social_anger()
	_test_monster_fight_respects_low_health_stop()
	_test_look_for_monster_after_kill_finds_next_monster()
	_test_look_for_monster_ignores_freed_last_actor()
	_test_unrelated_fight_does_not_scan_monsters_by_default()
	_test_npc_prompt_calls_accept_once()
	_test_remote_magic_lesson_config_is_cached()
	_test_magic_lesson_accept_and_decline_paths()
	_test_title_scene_instantiates_without_crashing()


func _test_talk_overlay_does_not_replace_primary() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]

	_expect_true(machine.request_talk(setup["partner"], 60, false), "close talk starts")
	_expect_state(machine, "Talk", "is_in_state recognizes the Talk overlay")
	_expect_primary_state(machine, "Idle", "Talk leaves Idle in the primary lane")
	_expect_equal(machine.state_history.size(), 1, "Talk does not add itself to primary history")

	_expect_true(
		machine.request_state(&"RoutineTask", null, "test_routine", 30),
		"an incompatible primary request can replace the activity"
	)
	_expect_primary_state(machine, "RoutineTask", "RoutineTask becomes the primary state")
	_expect_false(machine.is_in_state(&"Talk"), "incompatible primary transition cancels Talk")
	_free_setup(setup)


func _test_talk_duration_and_progress_ring() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var npc: CharacterBody2D = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	talk_state.talk_duration = 5.0
	talk_state.show_talk_limits = true
	talk_state.maximum_talk_distance = 100000.0

	_expect_true(
		machine.request_talk(setup["partner"], 60, false),
		"five-second Talk starts"
	)
	_expect_approx(talk_state.talk_total_duration, 5.0, 0.001, "Talk duration is five seconds")
	var ring := npc.get_node_or_null("TalkProgressRing") as Control
	_expect_true(ring != null, "Talk creates its progress ring")
	if ring != null:
		_expect_true(ring.visible, "Talk progress ring is visible")
		_expect_equal(ring.size, Vector2(14.0, 14.0), "Talk progress ring stays very small")
		_expect_equal(
			ring.get("ring_color"),
			Color(0.2, 0.95, 0.35, 1.0),
			"Talk progress ring is green"
		)
		var initial_ratio := float(ring.get("progress_ratio"))
		machine._physics_process(1.0)
		_expect_true(
			float(ring.get("progress_ratio")) < initial_ratio,
			"Talk progress ring counts down"
		)
	machine._physics_process(4.1)
	_expect_true(machine.interaction_overlay == null, "five-second Talk completes normally")
	_expect_true(talk_state.talk_completed_successfully, "five-second Talk reaches successful completion")
	_expect_false(ring.visible if ring != null else true, "Talk progress ring hides on completion")
	_free_setup(setup)


func _test_stored_only_values_do_not_change_or_drive_behavior() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var player_actor: CharacterBody2D = setup["partner"]
	player_actor.add_to_group("player")
	machine.value_reactions_enabled = true
	var original_values := {
		"curiosity": float(machine.values.get("curiosity", 0.0)),
		"sadness": float(machine.values.get("sadness", 0.0)),
		"energy": float(machine.values.get("energy", 0.0)),
		"suspicion": float(machine.values.get("suspicion", 0.0)),
	}
	_expect_false(machine.apply_value_delta({
		"curiosity": 60.0,
		"sadness": 20.0,
		"energy": -50.0,
		"suspicion": 30.0,
	}, player_actor, true), "stored-only runtime deltas are ignored")
	for value_name in original_values.keys():
		_expect_equal(machine.values[value_name], original_values[value_name], "%s stays unchanged" % value_name)
	_expect_primary_state(machine, "Idle", "stored-only values do not start a state")

	machine.set_value(&"curiosity", 99.0, player_actor, true)
	_expect_equal(machine.values["curiosity"], original_values["curiosity"], "direct runtime setter ignores curiosity")

	var saved_values := machine.values.duplicate(true)
	saved_values["curiosity"] = 37.0
	saved_values["sadness"] = 12.0
	saved_values["energy"] = 81.0
	saved_values["suspicion"] = 9.0
	machine.replace_values(saved_values, player_actor, {
		"curiosity": 37.0,
		"sadness": 12.0,
		"energy": -19.0,
		"suspicion": 9.0,
	}, true)
	_expect_equal(machine.values["curiosity"], 37.0, "saved curiosity remains a numeric field")
	_expect_equal(machine.values["sadness"], 12.0, "saved sadness remains a numeric field")
	_expect_equal(machine.values["energy"], 81.0, "saved energy remains a numeric field")
	_expect_equal(machine.values["suspicion"], 9.0, "saved suspicion remains a numeric field")
	_expect_primary_state(machine, "Idle", "loading stored-only values does not start a state")

	var simulated_record := {
		"node_state": {
			"social_stats": saved_values.duplicate(true),
			"world_simulation_profile": {
				"passive_needs_enabled": true,
				"rates_per_game_hour": {
					"curiosity": 10.0,
					"sadness": 10.0,
					"energy": -10.0,
					"suspicion": 10.0,
					"hunger": 2.0,
				},
			},
		},
	}
	var hunger_before := float(saved_values.get("hunger", 0.0))
	_expect_true(NpcNeedsSimulator.new().advance_needs(simulated_record, 1.0, &"Idle"), "offscreen needs still advance")
	var simulated_values: Dictionary = simulated_record["node_state"]["social_stats"]
	for value_name in ["curiosity", "sadness", "energy", "suspicion"]:
		_expect_equal(simulated_values[value_name], saved_values[value_name], "%s ignores offscreen rates" % value_name)
	_expect_equal(simulated_values["hunger"], hunger_before + 2.0, "active needs still use offscreen rates")
	_free_setup(setup)


func _test_scheduled_sleep_does_not_wake_when_need_is_sated() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var sleep_state := machine.get_state(&"Sleep") as NpcStateSleep
	sleep_state.sleep_duration = 10.0
	machine.values["sleep_need"] = 55.0
	var bed := EmptyFoodSpot.new()
	bed.name = "ScheduledBed"
	bed.global_position = Vector2.ZERO
	root.add_child(bed)
	setup["spot"] = bed

	_expect_true(machine.request_action_from_descriptor({
		"session_id": "scheduled-sleep-session",
		"action_kind": "Sleep",
		"state_name": "Sleep",
		"source": "schedule",
		"spot_id": "mom_bed",
		"scene_path": "res://scenes/testscenes/realhometest.tscn",
		"priority": 70,
		"status": "proposed",
	}, bed), "scheduled bed sleep starts")
	_expect_primary_state(machine, "Sleep", "scheduled bed sleep is active")
	machine.values["sleep_need"] = 0.0
	machine._physics_process(0.1)
	_expect_primary_state(
		machine,
		"Sleep",
		"scheduled sleep remains active after sleep_need reaches zero"
	)
	_expect_equal(
		machine.get_active_action_session_id(),
		"scheduled-sleep-session",
		"scheduled sleep retains its action session"
	)
	var bed_definition := load("res://data/npc_spots/mom_bed.tres") as NpcSpotDefinition
	_expect_true(bed_definition != null, "Mom bed definition loads")
	if bed_definition != null:
		_expect_false(
			bed_definition.require_npc_value_threshold,
			"Mom's bedtime remains scheduled while sleep_need is below its entry threshold"
		)
		_expect_false(
			bed_definition.finish_when_npc_value_sated,
			"offscreen Mom sleep also remains scheduled after the need is sated"
		)
	_free_setup(setup)


func _test_collapse_recovers_in_place_until_sleep_need_seventy() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var collapse_state := machine.get_state(&"Collapse") as NpcStateCollapse
	collapse_state.collapse_duration = 10.0
	machine.values["sleep_need"] = 100.0

	_expect_true(
		machine.request_state(&"Collapse", null, "focused_exhaustion", 1000),
		"exhaustion starts Collapse"
	)
	_expect_primary_state(machine, "Collapse", "Collapse is the forced-sleep state")
	_expect_equal(machine.get_sleep_target(), null, "Collapse claims no bed")
	machine._physics_process(2.0)
	_expect_primary_state(machine, "Collapse", "Collapse remains active above the wake threshold")
	_expect_approx(
		machine.get_value(&"sleep_need"),
		94.0,
		0.01,
		"Collapse lowers sleep_need gradually"
	)
	machine._physics_process(7.9)
	_expect_primary_state(machine, "Collapse", "Collapse does not wake before sleep_need reaches 70")
	machine._physics_process(0.1)
	_expect_primary_state(machine, "Idle", "Collapse wakes at sleep_need 70")
	_expect_approx(machine.get_value(&"sleep_need"), 70.0, 0.01, "Collapse stops recovery at 70")
	_free_setup(setup)


func _test_rejected_state_request_preserves_targets() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]
	var rejected_target := Node2D.new()
	rejected_target.name = "RejectedTarget"
	root.add_child(rejected_target)
	setup["monster"] = rejected_target

	_expect_true(machine.request_talk(partner, 60, false), "talk starts before target-preservation check")
	var previous_actor := machine.last_actor
	var previous_target := machine.target
	var previous_talk_target := machine.talk_target
	var previous_work_target := machine.work_target
	machine.state_after_move_priority = 73

	_expect_false(
		machine.request_state(&"MissingTestState", rejected_target, "missing_state_test", 20),
		"missing state request reports failure"
	)
	_expect_state(machine, "Talk", "rejected request leaves active overlay unchanged")
	_expect_primary_state(machine, "Idle", "rejected request leaves primary state unchanged")
	_expect_true(machine.last_actor == previous_actor, "rejected request preserves last actor")
	_expect_true(machine.target == previous_target, "rejected request preserves generic target")
	_expect_true(machine.talk_target == previous_talk_target, "rejected request preserves talk target")
	_expect_true(machine.work_target == previous_work_target, "rejected request preserves specialized target")
	_expect_equal(machine.state_after_move_priority, 73, "rejected request preserves request context")
	_free_setup(setup)


func _test_rejected_player_social_choice_applies_no_effects() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var npc: CharacterBody2D = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]
	var player_node := CharacterBody2D.new()
	player_node.name = "Player"
	player_node.add_to_group("player")
	player_node.global_position = Vector2(4.0, 0.0)
	root.add_child(player_node)
	setup["player"] = player_node
	npc.add_to_group("npc")

	var interactor := PlayerNpcTalkInteractor.new()
	interactor.name = "NpcTalkInteractor"
	player_node.add_child(interactor)
	interactor.active_menu = &"talk"
	interactor.menu_target_npc = npc

	var blocked_events: Array[String] = []
	var applied_events: Array[StringName] = []
	interactor.interaction_blocked.connect(
		func(_player: Node2D, _npc: Node2D, interaction_id: StringName, reason: String) -> void:
			blocked_events.append("%s:%s" % [String(interaction_id), reason])
	)
	interactor.interaction_applied.connect(
		func(_player: Node2D, _npc: Node2D, interaction_id: StringName) -> void:
			applied_events.append(interaction_id)
	)

	_expect_true(machine.request_talk(partner, 60, false), "NPC is busy talking before player choice")
	interactor.call("_show_talk_menu", "")
	var values_before := machine.values.duplicate(true)
	interactor.call("_handle_talk_option", 0)

	_expect_equal(blocked_events.size(), 1, "rejected player social choice emits blocked once")
	_expect_equal(applied_events.size(), 0, "rejected player social choice does not emit applied")
	_expect_equal(machine.values, values_before, "rejected player social choice does not change NPC values")
	_expect_true(machine.is_talking_with(partner), "rejected player choice preserves existing conversation")
	_free_setup(setup)


func _test_player_interaction_gate_blocks_emergency_states() -> void:
	for blocked_state in [
		{"name": &"Fight", "reason": "npc_fighting"},
		{"name": &"Flee", "reason": "npc_fleeing"},
		{"name": &"Downed", "reason": "npc_downed"},
		{"name": &"DisabledDead", "reason": "npc_disabled"},
	]:
		var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
		var machine: NpcStateMachine = setup["machine"]
		var player_node := CharacterBody2D.new()
		player_node.name = "GatePlayer"
		player_node.add_to_group("player")
		root.add_child(player_node)
		setup["player"] = player_node

		_expect_true(
			machine.request_state(blocked_state["name"], player_node, "interaction_gate_test", 1000),
			"%s starts for interaction gate test" % String(blocked_state["name"])
		)
		var gate := machine.can_begin_player_interaction(player_node)
		_expect_false(bool(gate.get("accepted", true)), "%s rejects player interaction" % String(blocked_state["name"]))
		_expect_equal(
			String(gate.get("reason", "")),
			blocked_state["reason"],
			"%s reports its interaction rejection reason" % String(blocked_state["name"])
		)
		_free_setup(setup)

	var normal_setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var normal_machine: NpcStateMachine = normal_setup["machine"]
	var normal_player := CharacterBody2D.new()
	normal_player.name = "NormalInteractionPlayer"
	normal_player.add_to_group("player")
	root.add_child(normal_player)
	normal_setup["player"] = normal_player
	for allowed_state in [&"Work", &"Eat", &"Rest"]:
		_expect_true(
			normal_machine.request_state(allowed_state, null, "interaction_gate_allowed", 1000),
			"%s starts for normal interaction gate test" % String(allowed_state)
		)
		var allowed_gate := normal_machine.can_begin_player_interaction(normal_player)
		_expect_true(
			bool(allowed_gate.get("accepted", false)),
			"%s remains eligible for player interaction" % String(allowed_state)
		)
	_free_setup(normal_setup)


func _test_emergency_state_invalidates_open_menu_and_resumes_processing() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var npc: CharacterBody2D = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	npc.add_to_group("npc")
	var player_node := CharacterBody2D.new()
	player_node.name = "EmergencyMenuPlayer"
	player_node.add_to_group("player")
	player_node.global_position = Vector2(4.0, 0.0)
	root.add_child(player_node)
	setup["player"] = player_node
	var interactor := PlayerNpcTalkInteractor.new()
	interactor.name = "NpcTalkInteractor"
	player_node.add_child(interactor)
	interactor.nearby_npcs.append(npc)

	interactor.call("_try_open_interaction_menu")
	_expect_equal(String(interactor.active_menu), "interaction", "interaction menu opens for an idle NPC")
	_expect_true(machine.player_interaction_hold_timer > 0.0, "open menu enables the NPC interaction hold")

	machine.values["sleep_need"] = 100.0
	_expect_true(machine.request_state(&"Collapse", null, "emergency_during_menu", 1000), "emergency starts while menu is open")
	_expect_equal(String(interactor.active_menu), "", "emergency immediately closes the interaction menu")
	_expect_equal(machine.player_interaction_hold_timer, 0.0, "emergency immediately clears interaction hold")

	var collapse_state := machine.current_state as NpcStateCollapse
	var timer_before := collapse_state.collapse_timer
	machine._physics_process(0.25)
	_expect_true(collapse_state.collapse_timer < timer_before, "emergency state keeps processing after hold invalidation")
	_free_setup(setup)


func _test_missing_interaction_ui_releases_player_interaction_hold() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var npc: CharacterBody2D = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	npc.add_to_group("npc")
	var player_node := CharacterBody2D.new()
	player_node.name = "MissingInteractionUiPlayer"
	player_node.add_to_group("player")
	player_node.global_position = Vector2(4.0, 0.0)
	root.add_child(player_node)
	setup["player"] = player_node
	var interactor := PlayerNpcTalkInteractor.new()
	interactor.name = "NpcTalkInteractor"
	player_node.add_child(interactor)
	interactor.nearby_npcs.append(npc)

	interactor.call("_try_open_interaction_menu")
	_expect_true(machine.player_interaction_hold_timer > 0.0, "menu hold is active before UI removal")
	interactor.menu_layer.free()
	interactor._process(0.01)
	_expect_equal(machine.player_interaction_hold_timer, 0.0, "missing interaction UI releases the NPC hold")
	_expect_equal(String(interactor.active_menu), "", "missing interaction UI invalidates the menu")
	_free_setup(setup)


func _test_active_talk_allows_emergency_interrupt() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]

	_expect_true(machine.request_talk(setup["partner"], 60, false), "talk starts before emergency")
	_expect_true(machine.request_state(&"Collapse", null, "test_collapse", 95), "Collapse can interrupt Talk")
	_expect_state(machine, "Collapse", "emergency state takes control")
	_expect_true(machine.interaction_overlay == null, "emergency clears the Talk overlay immediately")
	_free_setup(setup)


func _test_eat_lifecycle_is_not_restarted_by_talk() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	machine.values["hunger"] = 75.0
	var eat_spot := EmptyFoodSpot.new()
	eat_spot.name = "OverlayEatSpot"
	eat_spot.global_position = Vector2.ZERO
	root.add_child(eat_spot)
	setup["spot"] = eat_spot

	_expect_true(machine.assign_eat_target(eat_spot, 60), "Eat starts before overlay lifecycle check")
	var eat_state := machine.current_state as NpcStateEat
	_expect_true(eat_state != null, "Eat is the primary state")
	var timer_before := eat_state.eat_timer

	_expect_true(machine.request_talk(setup["partner"], 60, false), "Talk overlays active Eat")
	_expect_primary_state(machine, "Eat", "Eat remains primary while talking")
	_expect_true(machine.interaction_overlay is NpcStateTalk, "Talk occupies the interaction overlay slot")
	_expect_equal(eat_state.eat_timer, timer_before, "Talk start does not restart the Eat timer")

	machine.cancel_talk_with(setup["partner"], "test_complete")
	_expect_primary_state(machine, "Eat", "ending Talk does not re-enter or replace Eat")
	_expect_true(machine.current_state == eat_state, "the same entered Eat instance remains authoritative")
	_expect_equal(eat_state.eat_timer, timer_before, "Talk end does not reset the Eat timer")
	_free_setup(setup)


func _test_work_animation_remains_primary_during_talk() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var npc: CharacterBody2D = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var work_state := machine.get_state(&"Work") as NpcStateWork
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	work_state.animation_name = &"work"
	talk_state.animation_name = &"talk"

	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	npc.add_child(sprite)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	npc.add_child(player)
	var library := AnimationLibrary.new()
	for animation_name in [&"meal_prep_1", &"talk", &"work"]:
		var animation := Animation.new()
		animation.length = 1.0
		animation.loop_mode = Animation.LOOP_LINEAR
		library.add_animation(animation_name, animation)
	player.add_animation_library(&"", library)
	var controller := NpcAnimationController.new()
	controller.name = "NpcAnimationController"
	npc.add_child(controller)
	machine.bind_npc(npc)

	var started: Array[StringName] = []
	player.animation_started.connect(func(animation_name: StringName) -> void:
		started.append(animation_name)
	)
	var work_spot := OverlayWorkSpot.new()
	work_spot.name = "OverlayWorkSpot"
	work_spot.global_position = Vector2.ZERO
	root.add_child(work_spot)
	setup["spot"] = work_spot

	_expect_true(machine.assign_work_target(work_spot, 60), "Work starts before Talk")
	_expect_equal(player.current_animation, &"meal_prep_1", "Work selects meal-prep presentation")
	started.clear()
	_expect_true(machine.request_talk(setup["partner"], 60, false), "Talk overlays active Work")
	_expect_primary_state(machine, "Work", "Work remains primary during Talk")
	_expect_equal(
		player.current_animation,
		&"meal_prep_1",
		"Talk keeps the primary Work presentation visible"
	)
	_expect_false(started.has(&"talk"), "Talk does not briefly take animation ownership from Work")
	_expect_equal(
		controller.get_latest_requested_animation(),
		&"meal_prep_1",
		"the centralized animation request remains the activity request"
	)
	machine.cancel_talk_with(setup["partner"], "test_complete")
	_expect_equal(
		player.current_animation,
		&"meal_prep_1",
		"ending Talk preserves the same Work presentation"
	)
	_free_setup(setup)


func _test_social_search_handoff_completes_primary_action() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var npc: CharacterBody2D = setup["npc"]
	var partner: CharacterBody2D = setup["partner"]
	var machine: NpcStateMachine = setup["machine"]
	npc.add_to_group("npc")
	partner.add_to_group("player")
	machine.values["talk_need"] = 80.0
	var session_id := "social-search-handoff-session"

	_expect_true(machine.request_action_from_descriptor({
		"session_id": session_id,
		"action_kind": "LookForTalkTarget",
		"source": "social_ai",
		"target_npc_id": "handoff-partner",
		"priority": 60,
		"status": "proposed",
	}, partner), "social search session A starts")
	_expect_primary_state(machine, "LookForTalkTarget", "social search is the primary state")

	machine._physics_process(0.01)
	_expect_primary_state(machine, "Idle", "accepted Talk hands the primary lane to Idle")
	_expect_true(machine.interaction_overlay is NpcStateTalk, "accepted Talk overlay remains active")
	_expect_true(machine.is_socially_engaged(), "accepted Talk is authoritatively socially engaged")
	_expect_equal(
		machine.get_active_interaction_session_id(),
		session_id,
		"Talk overlay preserves social search session A"
	)
	_expect_equal(
		machine.get_active_interaction_source(),
		&"social_ai",
		"autonomous Talk with the player preserves its initiating source"
	)
	_expect_false(
		machine.is_active_talk_payout_prepaid(),
		"autonomous Talk with the player is not prepaid"
	)
	_expect_false(
		machine.mark_next_talk_need_payout_applied(session_id),
		"social_ai session cannot be marked prepaid as a player interaction"
	)
	var terminal_search := machine.get_active_action_descriptor()
	_expect_equal(
		String(terminal_search.get("status", "")),
		"completed",
		"primary social search is terminal after Talk acceptance"
	)
	_expect_equal(
		String(terminal_search.get("reason", "")),
		"talk_handoff_completed",
		"primary social search records the handoff completion reason"
	)
	_expect_false(
		machine.is_action_session_current_for_execution(session_id, &"LookForTalkTarget"),
		"terminal social search is no longer executable"
	)

	machine._physics_process(0.01)
	_expect_primary_state(machine, "Idle", "action reconciliation does not restore social search")
	_expect_true(machine.interaction_overlay is NpcStateTalk, "reconciliation preserves Talk")

	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var locations := root.get_node_or_null("NpcLocations")
	for interval_index in 2:
		_expect_false(
			bool(simulator.call(
				"_request_live_social_seek", &"focused_handoff_npc", npc, partner,
				60, locations, "replacement-search-%d" % interval_index, "__player__"
			)),
			"world interval %d rejects a replacement social search" % (interval_index + 1)
		)
		_expect_true(
			machine.interaction_overlay is NpcStateTalk,
			"world interval %d preserves the accepted Talk" % (interval_index + 1)
		)
		_expect_equal(
			machine.get_active_interaction_session_id(), session_id,
			"world interval %d preserves the accepted session" % (interval_index + 1)
		)

	_expect_false(machine.request_action_from_descriptor({
		"session_id": "defensive-replacement-search",
		"action_kind": "LookForTalkTarget",
		"source": "social_ai",
		"target_npc_id": "__player__",
		"priority": 60,
		"status": "proposed",
	}, partner), "state machine defensively rejects a replacement search")
	_expect_equal(
		machine.get_last_state_request_failure_reason(),
		"already_socially_engaged",
		"defensive search rejection reports the engagement reason"
	)
	_expect_true(machine.interaction_overlay is NpcStateTalk, "defensive rejection does not cancel Talk")
	_expect_equal(
		machine.get_active_interaction_session_id(), session_id,
		"defensive rejection has no interaction-session side effect"
	)

	var talk_state := machine.interaction_overlay as NpcStateTalk
	talk_state.talk_timer = 0.0
	machine._physics_process(0.01)
	_expect_true(machine.interaction_overlay == null, "completed Talk closes its overlay")
	_expect_equal(machine.get_value(&"talk_need"), 40.0, "completed Talk applies its normal need delta")
	_expect_equal(talk_state.terminal_source, "social_ai", "terminal diagnostic retains social_ai source")

	var record := {
		"scene_path": "res://focused_social_handoff.tscn",
		"node_state": {"social_stats": {"talk_need": machine.get_value(&"talk_need")}},
		"activity": {},
		"pending_travel": {},
	}
	_expect_false(
		bool(simulator.call(
			"_try_start_social_seek", &"focused_handoff_npc", record,
			{"focused_handoff_npc": record}, locations, -1
		)),
		"immediate simulation pass rejects a new search below the Talk threshold"
	)
	_expect_primary_state(machine, "Idle", "immediate simulation pass leaves search inactive")

	var cancellation_reasons: Array[String] = []
	_expect_true(
		machine.request_talk(partner, 60, false, &"social_ai"),
		"autonomous Talk restarts before the emergency check"
	)
	var emergency_talk := machine.interaction_overlay as NpcStateTalk
	emergency_talk.talk_cancelled.connect(
		func(_talker: Node2D, _partner: Node2D, reason: String) -> void:
			cancellation_reasons.append(reason)
	)
	_expect_true(
		machine.request_state(&"Fight", partner, "social_guard_emergency", 1000),
		"Fight remains available during Talk"
	)
	_expect_primary_state(machine, "Fight", "emergency replaces the primary state")
	_expect_true(machine.interaction_overlay == null, "emergency cancels the Talk overlay")
	_expect_equal(
		cancellation_reasons,
		["primary_transition_Fight"],
		"emergency cancellation retains its primary-transition reason"
	)
	_free_setup(setup)


func _test_social_search_checks_start_distance_before_talk() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(0.0, -182.68))
	var npc: CharacterBody2D = setup["npc"]
	var partner: CharacterBody2D = setup["partner"]
	var machine: NpcStateMachine = setup["machine"]
	npc.add_to_group("npc")
	partner.add_to_group("player")
	machine.values["talk_need"] = 73.0
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	var started_count := 0
	talk_state.talk_started.connect(
		func(_talker: Node2D, _partner: Node2D) -> void:
			started_count += 1
	)
	var session_id := "social-start-distance-viability"

	_expect_true(machine.request_action_from_descriptor({
		"session_id": session_id,
		"action_kind": "LookForTalkTarget",
		"source": "social_ai",
		"target_npc_id": "__player__",
		"priority": 60,
		"status": "proposed",
	}, partner), "vertical social search starts before its distance preflight")
	_expect_primary_state(machine, "LookForTalkTarget", "vertical target enters social search")

	machine._physics_process(0.01)
	_expect_primary_state(machine, "Idle", "nonviable vertical target returns to Idle")
	_expect_true(machine.interaction_overlay == null, "nonviable target creates no Talk overlay")
	_expect_equal(started_count, 0, "nonviable target emits no conversation start")
	_expect_equal(
		String(machine.get_active_action_descriptor().get("reason", "")),
		"talk_target_outside_maximum_distance",
		"social search records the preflight failure reason"
	)
	_expect_true(
		machine.is_talk_refusal_on_cooldown(partner),
		"existing Talk retry cooldown suppresses immediate reselection"
	)
	_expect_equal(machine.get_value(&"talk_need"), 73.0, "failed preflight does not pay Talk need")
	_free_setup(setup)


func _test_passive_casual_activities_ignore_social_actor() -> void:
	var eat_setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var eat_machine: NpcStateMachine = eat_setup["machine"]
	var eat_partner: CharacterBody2D = eat_setup["partner"]
	eat_partner.add_to_group("npc")
	_expect_false(
		eat_machine.assign_eat_target(eat_partner, 20),
		"an NPC cannot be assigned as an Eat spot"
	)
	_expect_primary_state(eat_machine, "Idle", "rejected Eat person target has no state side effect")
	var eat_spot := _create_eat_spot(&"FocusedEatSpot", [])
	eat_spot.global_position = Vector2(20.0, 0.0)
	eat_setup["spot"] = eat_spot
	eat_machine.values["hunger"] = 80.0
	eat_machine.value_reactions_enabled = true
	_expect_true(
		eat_machine.evaluate_value_reactions(eat_partner, {}),
		"passive hunger starts Eat"
	)
	_expect_primary_state(eat_machine, "Eat", "passive Eat starts normally")
	_expect_true(
		eat_machine.get_active_action_target() == eat_spot,
		"passive Eat selects the authored food spot"
	)
	_expect_false(
		eat_machine.get_active_action_target() == eat_partner,
		"passive Eat does not inherit the recent social NPC"
	)
	_free_setup(eat_setup)

	var recreation_setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var recreation_machine: NpcStateMachine = recreation_setup["machine"]
	var recreation_partner: CharacterBody2D = recreation_setup["partner"]
	recreation_partner.add_to_group("npc")
	_expect_false(
		recreation_machine.assign_recreation_target(recreation_partner, 20),
		"an NPC cannot be assigned as a Recreation spot"
	)
	_expect_primary_state(
		recreation_machine, "Idle", "rejected Recreation person target has no state side effect"
	)
	var recreation_spot := NpcCasualSpot.new()
	recreation_spot.name = "FocusedRecreationSpot"
	recreation_spot.spot_id = &"focused_recreation_spot"
	recreation_spot.activity_state_name = &"Recreation"
	recreation_spot.global_position = Vector2(20.0, 0.0)
	root.add_child(recreation_spot)
	recreation_setup["spot"] = recreation_spot
	recreation_machine.values["boredom"] = 60.0
	recreation_machine.values["tired"] = 0.0
	recreation_machine.value_reactions_enabled = true
	_expect_true(
		recreation_machine.evaluate_value_reactions(recreation_partner, {}),
		"passive boredom starts Recreation"
	)
	_expect_primary_state(recreation_machine, "Recreation", "passive Recreation starts normally")
	_expect_true(
		recreation_machine.get_active_action_target() == recreation_spot,
		"passive Recreation selects the authored casual spot"
	)
	_expect_false(
		recreation_machine.get_active_action_target() == recreation_partner,
		"passive Recreation does not inherit the recent social NPC"
	)
	_free_setup(recreation_setup)

	var rest_setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var rest_machine: NpcStateMachine = rest_setup["machine"]
	var rest_partner: CharacterBody2D = rest_setup["partner"]
	rest_partner.add_to_group("player")
	_expect_false(
		rest_machine.assign_rest_target(rest_partner, 20),
		"the player cannot be assigned as a Rest spot"
	)
	_expect_primary_state(rest_machine, "Idle", "rejected Rest person target has no state side effect")
	var rest_spot := NpcCasualSpot.new()
	rest_spot.name = "FocusedRestSpot"
	rest_spot.spot_id = &"focused_rest_spot"
	rest_spot.activity_state_name = &"Rest"
	rest_spot.global_position = Vector2(20.0, 0.0)
	root.add_child(rest_spot)
	rest_setup["spot"] = rest_spot
	var rest_state := rest_machine.get_state(&"Rest") as NpcStateRest
	rest_state.rest_in_place_chance = 0.0
	rest_machine.values["tired"] = 60.0
	rest_machine.values["boredom"] = 0.0
	rest_machine.value_reactions_enabled = true
	_expect_true(
		rest_machine.evaluate_value_reactions(rest_partner, {}),
		"passive tiredness starts Rest"
	)
	_expect_primary_state(rest_machine, "Rest", "passive Rest starts normally")
	_expect_true(
		rest_machine.get_active_action_target() == rest_spot,
		"passive Rest selects the authored casual spot"
	)
	_expect_false(
		rest_machine.get_active_action_target() == rest_partner,
		"passive Rest does not inherit the recent player"
	)
	_free_setup(rest_setup)


func _test_sated_eat_marks_meal_without_consuming() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	machine.values["hunger"] = 0.0
	var eat_spot := MealCompletionFoodSpot.new()
	eat_spot.name = "AlreadySatedMealSpot"
	eat_spot.global_position = Vector2.ZERO
	root.add_child(eat_spot)
	setup["spot"] = eat_spot

	_expect_true(machine.assign_eat_target(eat_spot, 60), "already-sated Eat request is accepted")
	var eat_state := machine.current_state as NpcStateEat
	_expect_true(eat_state != null, "already-sated Eat binds its action session")
	_expect_equal(eat_spot.meal_sated_count, 1, "already-sated Eat marks meal completion on entry")
	_expect_equal(eat_spot.consume_count, 0, "already-sated Eat consumes no spot food")
	_expect_equal(eat_state.eat_timer, 0.0, "already-sated Eat starts no timer")

	machine._physics_process(0.01)
	_expect_primary_state(machine, "Idle", "already-sated Eat returns to Idle")
	_expect_equal(eat_spot.meal_sated_count, 1, "meal completion marking remains idempotent")
	machine.clear_terminal_action(machine.get_active_action_session_id())
	var freed_target := Node2D.new()
	root.add_child(freed_target)
	machine.target = freed_target
	freed_target.free()
	_expect_equal(
		machine.get_action_target(&"Work", freed_target),
		null,
		"freed legacy action targets resolve safely to null"
	)
	_expect_false(
		machine.get_current_activity_descriptor().has("target_node"),
		"current activity descriptor ignores a freed legacy target"
	)
	_free_setup(setup)

	var talk_setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var talk_machine: NpcStateMachine = talk_setup["machine"]
	talk_machine.values["hunger"] = 10.0
	var talk_eat_spot := MealCompletionFoodSpot.new()
	talk_eat_spot.name = "TalkOverlayMealSpot"
	talk_eat_spot.global_position = Vector2.ZERO
	root.add_child(talk_eat_spot)
	talk_setup["spot"] = talk_eat_spot
	_expect_true(talk_machine.assign_eat_target(talk_eat_spot, 60), "Eat starts before Talk")
	var talk_eat_state := talk_machine.current_state as NpcStateEat
	_expect_true(talk_machine.request_talk(talk_setup["partner"], 60, false), "Talk overlays Eat")
	talk_machine.values["hunger"] = 0.0
	_expect_equal(
		talk_eat_state.process_talk_overlay(0.01),
		&"Idle",
		"sated Talk-overlay Eat requests Idle"
	)
	_expect_equal(talk_eat_spot.meal_sated_count, 1, "sated Talk-overlay Eat marks meal completion")
	_expect_equal(talk_eat_spot.consume_count, 0, "sated Talk-overlay Eat consumes no additional food")
	_free_setup(talk_setup)


func _test_routine_task_exact_target_does_not_fall_back() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var shower_spot := RoutineTaskTestSpot.new()
	shower_spot.name = "ScheduledShowerSpot"
	shower_spot.persistent_spot_id = &"mom_shower"
	shower_spot.add_to_group("npc_need_spot")
	root.add_child(shower_spot)
	setup["spot"] = shower_spot
	var wrong_spot := RoutineTaskTestSpot.new()
	wrong_spot.name = "WrongRoutineSpot"
	wrong_spot.add_to_group("npc_need_spot")
	root.add_child(wrong_spot)
	setup["monster"] = wrong_spot

	_expect_true(machine.request_action_from_descriptor({
		"session_id": "scheduled-shower-session",
		"action_kind": "RoutineTask",
		"source": "schedule",
		"spot_id": "mom_shower",
		"scheduled_activity_id": "morning-shower",
		"value_name": "cleanliness",
		"priority": 85,
		"status": "proposed",
	}, shower_spot), "scheduled shower RoutineTask starts at its exact spot")
	var routine_state := machine.current_state as NpcStateRoutineTask
	_expect_true(routine_state != null, "scheduled shower enters RoutineTask")
	_expect_equal(
		shower_spot.last_value_name,
		&"cleanliness",
		"scheduled RoutineTask validation uses the action's intended value"
	)
	shower_spot.free()
	setup.erase("spot")
	machine._physics_process(0.01)
	var failed_descriptor := machine.get_active_action_descriptor()
	_expect_equal(
		String(failed_descriptor.get("reason", "")),
		"scheduled_routine_spot_missing",
		"missing exact shower spot fails the scheduled session explicitly"
	)
	_expect_true(
		routine_state.active_routine_target != wrong_spot,
		"scheduled shower never adopts another RoutineTask spot"
	)
	_free_setup(setup)

	var autonomous_setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var autonomous_machine: NpcStateMachine = autonomous_setup["machine"]
	var initial_spot := RoutineTaskTestSpot.new()
	initial_spot.name = "AutonomousInitialRoutineSpot"
	initial_spot.add_to_group("npc_need_spot")
	root.add_child(initial_spot)
	autonomous_setup["spot"] = initial_spot
	var fallback_spot := RoutineTaskTestSpot.new()
	fallback_spot.name = "AutonomousFallbackRoutineSpot"
	fallback_spot.add_to_group("npc_need_spot")
	root.add_child(fallback_spot)
	autonomous_setup["monster"] = fallback_spot
	_expect_true(
		autonomous_machine.assign_routine_task_target(initial_spot, 20),
		"identity-free autonomous RoutineTask starts"
	)
	var autonomous_state := autonomous_machine.current_state as NpcStateRoutineTask
	initial_spot.free()
	autonomous_setup.erase("spot")
	autonomous_machine._physics_process(0.01)
	_expect_true(
		autonomous_state.active_routine_target == fallback_spot,
		"identity-free autonomous RoutineTask retains nearest-spot fallback"
	)
	_free_setup(autonomous_setup)


func _test_emergency_cancels_both_talk_overlays_once() -> void:
	var first := _create_talk_setup(Vector2.ZERO, Vector2(-100.0, 0.0))
	var second := _create_talk_setup(Vector2(8.0, 0.0), Vector2(100.0, 0.0))
	var first_npc: CharacterBody2D = first["npc"]
	var second_npc: CharacterBody2D = second["npc"]
	var first_machine: NpcStateMachine = first["machine"]
	var second_machine: NpcStateMachine = second["machine"]
	first_npc.add_to_group("npc")
	second_npc.add_to_group("npc")
	first_machine.npc_talk_requires_mutual_favor = false
	second_machine.npc_talk_requires_mutual_favor = false

	var cancel_counts := [0, 0]
	(first_machine.get_state(&"Talk") as NpcStateTalk).talk_cancelled.connect(
		func(_talker: Node2D, _partner: Node2D, _reason: String) -> void:
			cancel_counts[0] += 1
	)
	(second_machine.get_state(&"Talk") as NpcStateTalk).talk_cancelled.connect(
		func(_talker: Node2D, _partner: Node2D, _reason: String) -> void:
			cancel_counts[1] += 1
	)

	_expect_true(first_machine.request_talk(second_npc, 60, true), "mutual NPC Talk starts")
	_expect_true(first_machine.is_talking_with(second_npc), "first NPC owns its Talk overlay")
	_expect_true(second_machine.is_talking_with(first_npc), "second NPC owns its Talk overlay")
	_expect_true(
		first_machine.request_state(&"Collapse", second_npc, "symmetric_overlay_test", 1000),
		"emergency primary transition is accepted"
	)
	_expect_true(first_machine.interaction_overlay == null, "emergency clears initiating overlay")
	_expect_true(second_machine.interaction_overlay == null, "emergency clears partner overlay")
	_expect_equal(cancel_counts, [1, 1], "both Talk overlays emit cancellation exactly once")

	_free_setup(first)
	_free_setup(second)


func _test_duplicate_talk_request_does_not_restart_talk() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]

	_expect_true(machine.request_talk(partner, 60, false), "initial talk starts")
	var talk_state := machine.interaction_overlay as NpcStateTalk
	talk_state.talk_timer = 0.42

	_expect_true(machine.request_talk(partner, 60, false), "duplicate talk request is accepted as already handled")
	_expect_state(machine, "Talk", "duplicate request does not leave Talk")
	_expect_equal(talk_state.talk_timer, 0.42, "duplicate request does not restart the Talk timer")
	_free_setup(setup)


func _test_duplicate_move_to_talk_request_is_ignored() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(120.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]

	machine.move_target = partner
	machine.talk_target = partner
	machine.state_after_move = &"Talk"
	_expect_true(machine.request_state(&"MoveToTarget", partner, "walk_to_talk", 60), "MoveToTarget starts")
	_expect_state(machine, "MoveToTarget", "NPC is moving toward talk target")

	_expect_true(machine.request_talk(partner, 60, false), "duplicate pending talk request returns handled")
	_expect_state(machine, "MoveToTarget", "duplicate pending talk does not restart movement")
	_expect_equal(String(machine.state_after_move), "Talk", "pending Talk handoff is preserved")
	_free_setup(setup)


func _test_move_to_talk_arrival_opens_overlay() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(120.0, 0.0))
	var npc: CharacterBody2D = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]

	machine.move_target = partner
	machine.talk_target = partner
	machine.state_after_move = &"Talk"
	_expect_true(machine.request_state(&"MoveToTarget", partner, "walk_to_talk", 60), "talk approach starts")
	npc.global_position = partner.global_position
	machine._physics_process(0.1)

	_expect_primary_state(machine, "Idle", "completed talk approach returns primary lane to Idle")
	_expect_true(machine.is_talking_with(partner), "completed talk approach opens Talk overlay")
	_free_setup(setup)


func _test_far_talk_request_approaches_without_cancel_loop() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(500.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]

	_expect_true(machine.request_talk(partner, 60, false), "far talk request enters pending Talk approach")
	_expect_state(machine, "Talk", "far request is represented as Talk approach")
	var talk_state := machine.interaction_overlay as NpcStateTalk
	_expect_false(talk_state.talk_started_handled, "far request has not started conversation effects")
	_expect_true(talk_state.approaching_partner, "far request is approaching partner")

	var requested_state := talk_state.physics_process(0.2)
	_expect_true(requested_state == null, "far approach stays in Talk without returning a cancel state")
	_expect_false(talk_state.talk_finished_handled, "far approach does not cancel just because target exceeds max talk distance")
	_expect_true(machine.request_talk(partner, 60, false), "duplicate far request is treated as already handled")
	_expect_state(machine, "Talk", "duplicate far request does not restart approach")
	_free_setup(setup)


func _test_hungry_reaction_waits_without_usable_eat_spot() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	machine.value_reactions_enabled = true
	machine.values["hunger"] = 80.0

	var rejected_spot := _create_eat_spot(&"MomOnlyFood", [&"mom"])
	setup["spot"] = rejected_spot

	var matching_rule: Dictionary = machine._find_best_matching_rule({}, null)
	_expect_true(matching_rule.is_empty(), "hungry NPC without an accepted Eat spot waits")
	_free_setup(setup)


func _test_hungry_reaction_uses_available_eat_spot() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	machine.value_reactions_enabled = true
	machine.values["hunger"] = 80.0

	var available_spot := _create_eat_spot(&"OpenFood", [])
	setup["spot"] = available_spot

	var matching_rule: Dictionary = machine._find_best_matching_rule({}, null)
	_expect_equal(String(matching_rule.get("state", "")), "Eat", "hungry NPC uses an accepted Eat spot")
	_free_setup(setup)


func _test_eat_state_stops_when_food_spot_supplies_nothing() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	machine.values["hunger"] = 50.0

	var empty_food := EmptyFoodSpot.new()
	empty_food.name = "EmptyFood"
	empty_food.global_position = Vector2.ZERO
	root.add_child(empty_food)
	setup["spot"] = empty_food

	_expect_true(machine.assign_eat_target(empty_food, 50), "empty food spot can start Eat")
	_expect_state(machine, "Eat", "NPC enters Eat before empty food is detected")
	var next_state := machine.current_state.physics_process(0.1)
	_expect_true(next_state != null and String(next_state.name) == "Idle", "Eat stops when food supplies no hunger")
	_expect_approx(machine.get_value(&"hunger"), 50.0, 0.001, "empty food does not change hunger")
	_free_setup(setup)


func _test_starvation_damage_starts_at_hunger_cap() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var world_time := root.get_node_or_null("WorldTime")
	var original_real_seconds_per_day := 0.0
	if world_time != null:
		original_real_seconds_per_day = float(world_time.get("real_seconds_per_day"))
		world_time.set("real_seconds_per_day", 24.0)

	machine.value_reactions_enabled = true
	machine.passive_healing_per_game_day = 100.0
	machine.starvation_damage_per_game_day = 24.0
	machine.values["hunger"] = 100.0
	machine.values["hp"] = 100.0
	machine.values["disabled"] = 0.0

	machine._apply_passive_need_growth(1.0)
	_expect_approx(machine.get_value(&"hp"), 99.0, 0.001, "hunger 100 drains HP instead of healing")
	_expect_equal(machine.get_value(&"hunger"), 100.0, "hunger stays capped at 100")

	if world_time != null and original_real_seconds_per_day > 0.0:
		world_time.set("real_seconds_per_day", original_real_seconds_per_day)
	_free_setup(setup)


func _test_tired_speed_scaling() -> void:
	var machine := NpcStateMachine.new()
	machine.walk_speed = 100.0
	machine.run_speed = 200.0
	machine.minimum_fatigue_speed_multiplier = 0.6
	machine.fatigue_speed_curve = 1.4
	root.add_child(machine)

	machine.set_value(&"tired", 0.0, null, false)
	_expect_approx(machine.get_fatigue_speed_multiplier(), 1.0, 0.001, "tired 0 keeps full movement speed")
	_expect_approx(machine.get_effective_walk_speed(), 100.0, 0.001, "effective walk uses full speed when fresh")

	machine.set_value(&"tired", 50.0, null, false)
	var half_tired_multiplier := machine.get_fatigue_speed_multiplier()
	_expect_true(half_tired_multiplier < 1.0, "tired 50 slows movement")
	_expect_true(half_tired_multiplier > 0.6, "tired 50 stays above minimum speed")

	machine.set_value(&"tired", 100.0, null, false)
	_expect_approx(machine.get_fatigue_speed_multiplier(), 0.6, 0.001, "tired 100 uses minimum speed")
	_expect_approx(machine.get_effective_run_speed(), 120.0, 0.001, "effective run uses minimum multiplier")

	var exhausted_walk_speed := machine.get_effective_walk_speed()
	machine.set_value(&"tired", 20.0, null, false)
	_expect_true(
		machine.get_effective_walk_speed() > exhausted_walk_speed,
		"lower tired increases effective movement speed again"
	)
	machine.free()


func _test_seen_monster_starts_fight() -> void:
	var setup := _create_combat_npc("Defender", Vector2.ZERO)
	var machine: NpcStateMachine = setup["machine"]
	var monster := _create_test_monster(Vector2(48.0, 0.0))
	setup["monster"] = monster

	machine.notify_target_seen(monster)

	_expect_state(machine, "Fight", "seeing a monster starts Fight")
	_expect_true(machine.target == monster, "seen monster is the fight target")
	_free_setup(setup)


func _test_seen_monster_can_flee_for_coward_npc() -> void:
	var setup := _create_combat_npc("CowardDefender", Vector2.ZERO)
	var machine: NpcStateMachine = setup["machine"]
	var monster := _create_test_monster(Vector2(48.0, 0.0))
	setup["monster"] = monster

	machine.seen_monster_reaction = NpcStateMachine.MonsterSightReaction.FLEE
	machine.notify_target_seen(monster)

	_expect_state(machine, "Flee", "coward monster reaction starts Flee")
	_expect_true(machine.target == monster, "coward NPC flees from the seen monster")
	_free_setup(setup)


func _test_value_signals_use_delta_and_full_sync_paths() -> void:
	var setup := _create_combat_npc("ValueSignalDefender", Vector2.ZERO)
	var npc: SocialNpc = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var changed_events: Array[Dictionary] = []
	var replaced_events: Array[Dictionary] = []
	var changed_callback := func(changed_values: Dictionary, _actor: Node2D) -> void:
		changed_events.append(changed_values)
	var replaced_callback := func(values_snapshot: Dictionary, _actor: Node2D) -> void:
		replaced_events.append(values_snapshot)

	machine.values_changed.connect(changed_callback)
	machine.values_replaced.connect(replaced_callback)
	_expect_true(npc.apply_social_event({"favor": 10.0}, null, false), "favor event is applied")
	_expect_equal(changed_events.size(), 1, "one-key event emits one changed-values signal")
	_expect_equal(replaced_events.size(), 0, "one-key event does not emit a replacement signal")
	if not changed_events.is_empty():
		var changed_snapshot: Dictionary = changed_events[0]
		_expect_equal(changed_snapshot.size(), 1, "changed-values payload contains only changed keys")
		_expect_equal(changed_snapshot.get("favor"), 60.0, "changed-values payload uses final canonical value")
		changed_snapshot["favor"] = 0.0
		_expect_equal(machine.values.get("favor"), 60.0, "changed-values payload is detached from machine values")
	_expect_equal(npc.social_stats.get("favor"), 60.0, "SocialNpc receives the final changed value")

	machine.replace_values({"favor": 80.0}, null, {}, false)
	_expect_equal(changed_events.size(), 1, "replacement does not emit changed-values")
	_expect_equal(replaced_events.size(), 1, "replacement emits one full snapshot")
	_expect_false(npc.social_stats.has("hunger"), "full sync removes obsolete SocialNpc keys")
	if not replaced_events.is_empty():
		var replacement_snapshot: Dictionary = replaced_events[0]
		replacement_snapshot["favor"] = 0.0
		_expect_equal(machine.values.get("favor"), 80.0, "replacement snapshot is detached from machine values")

	_expect_false(machine.apply_value_delta({"favor": 0.0}, null, false), "zero delta is ignored")
	_expect_equal(changed_events.size(), 1, "zero delta emits no changed-values signal")
	_expect_equal(replaced_events.size(), 1, "zero delta emits no replacement signal")
	_free_setup(setup)


func _test_monster_damage_does_not_change_social_anger() -> void:
	var setup := _create_combat_npc("DamagedDefender", Vector2.ZERO)
	var npc: SocialNpc = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var monster := _create_test_monster(Vector2(48.0, 0.0))
	setup["monster"] = monster

	var starting_favor := float(npc.social_stats.get("favor", 0.0))
	var starting_anger := float(npc.social_stats.get("anger", 0.0))
	npc.take_damage(10.0, monster.global_position, monster, 0.0)

	_expect_approx(float(npc.social_stats.get("favor", 0.0)), starting_favor, 0.001, "monster damage does not lower player-style favor")
	_expect_approx(float(npc.social_stats.get("anger", 0.0)), starting_anger, 0.001, "monster damage does not add player-style anger")
	_expect_false(machine.is_in_state(&"Fight"), "monster damage alone waits for sight")
	_free_setup(setup)


func _test_monster_fight_respects_low_health_stop() -> void:
	var setup := _create_combat_npc("LowHealthDefender", Vector2.ZERO)
	var npc: SocialNpc = setup["npc"]
	var machine: NpcStateMachine = setup["machine"]
	var monster := _create_test_monster(Vector2(48.0, 0.0))
	setup["monster"] = monster

	npc.apply_social_event({"hp": -82.0}, null, false)
	machine.notify_target_seen(monster)

	_expect_false(machine.is_in_state(&"Fight"), "monster fight does not start below the editable health stop")
	_free_setup(setup)


func _test_look_for_monster_after_kill_finds_next_monster() -> void:
	var setup := _create_combat_npc("HunterDefender", Vector2.ZERO)
	var machine: NpcStateMachine = setup["machine"]
	var first_monster := _create_test_monster(Vector2(48.0, 0.0))
	var second_monster := _create_test_monster(Vector2(96.0, 0.0))
	setup["monster"] = first_monster

	var search_state := machine.get_state(&"LookForMonster") as NpcStateLookForMonster
	_expect_true(search_state != null, "combat NPC has LookForMonster state")
	if search_state != null:
		search_state.require_visibility = false
		search_state.use_search_wander = false

	machine.notify_target_seen(first_monster)
	_expect_state(machine, "Fight", "first seen monster starts Fight")

	first_monster.dead = true
	var next_state := machine.current_state.physics_process(0.1)
	_expect_true(next_state != null and String(next_state.name) == "LookForMonster", "dead monster starts timed monster search")
	if next_state != null:
		machine.change_state(next_state, "test_monster_dead", 94)

	_expect_state(machine, "LookForMonster", "NPC is searching for another monster")
	machine.current_state.physics_process(0.1)
	_expect_state(machine, "Fight", "monster search finds the next monster")
	_expect_true(machine.target == second_monster, "monster search fights the next monster")

	_free_nodes([second_monster])
	_free_setup(setup)


func _test_look_for_monster_ignores_freed_last_actor() -> void:
	var setup := _create_combat_npc("FreedTargetHunter", Vector2.ZERO)
	var machine: NpcStateMachine = setup["machine"]
	var search_state := machine.get_state(&"LookForMonster") as NpcStateLookForMonster
	_expect_true(search_state != null, "combat NPC has freed-target-safe monster search")
	if search_state == null:
		_free_setup(setup)
		return

	search_state.require_visibility = false
	var freed_monster := _create_test_monster(Vector2(32.0, 0.0))
	var live_monster := _create_test_monster(Vector2(96.0, 0.0))
	machine.last_actor = freed_monster
	freed_monster.free()

	var found_target = search_state.call("_find_monster_target")
	_expect_true(found_target == live_monster, "monster search skips a freed last_actor and finds a live target")
	_expect_true(machine.last_actor == null, "monster search clears the stale last_actor reference")

	_free_nodes([live_monster])
	_free_setup(setup)


func _test_unrelated_fight_does_not_scan_monsters_by_default() -> void:
	var setup := _create_combat_npc("AngryDefender", Vector2.ZERO)
	var machine: NpcStateMachine = setup["machine"]
	var monster := _create_test_monster(Vector2(8.0, 0.0))
	setup["monster"] = monster

	var player := CharacterBody2D.new()
	player.name = "Player"
	player.add_to_group("player")
	player.collision_layer = 0
	player.set_collision_layer_value(2, true)
	player.global_position = Vector2(80.0, 0.0)
	root.add_child(player)
	setup["player"] = player

	machine.values["anger"] = 100.0
	_expect_true(machine.request_state(&"Fight", null, "global_anger_test", 94), "global anger can start Fight")
	var fight_state := machine.current_state as NpcStateFight
	_expect_true(fight_state != null and fight_state.fight_target == player, "default Fight search ignores unprovoked monsters")
	_free_setup(setup)


func _test_npc_prompt_calls_accept_once() -> void:
	var setup := _create_prompt_setup()
	var interactor: PlayerNpcTalkInteractor = setup["interactor"]
	var callback: PromptCallback = setup["callback"]

	_expect_true(interactor.show_npc_prompt(
		setup["npc"],
		&"test_prompt",
		"Study magic with Mom?",
		PackedStringArray(["Yes", "Not now"]),
		callback,
		&"accept_prompt",
		&"decline_prompt",
		1.0
	), "NPC prompt opens")

	interactor.call("_finish_npc_prompt", true)
	interactor.call("_finish_npc_prompt", true)
	_expect_equal(callback.accepted_count, 1, "prompt accept callback fires once")
	_expect_equal(callback.declined_count, 0, "prompt accept does not decline")
	_expect_equal(String(callback.last_prompt_id), "test_prompt", "prompt id is forwarded")
	_free_setup(setup)


func _test_remote_magic_lesson_config_is_cached() -> void:
	var setup := _create_prompt_setup()
	var player: CharacterBody2D = setup["player"]
	var mom: CharacterBody2D = setup["npc"]

	var definition := NpcSpotDefinition.new()
	definition.spot_id = &"test_remote_magic_lesson"
	definition.scene_path = "res://scenes/testscenes/realhometest.tscn"
	definition.position = Vector2(-860.0, 368.0)
	definition.state_name = &"InvitePlayer"
	definition.spot_value_name = &"lesson_available"
	definition.spot_value_initial = 1.0
	definition.spot_value_done_threshold = 0.0

	var remote := MagicLessonRemoteInvitation.new()
	remote.name = "RemoteMagicLessonInvitation"
	root.add_child(remote)
	remote.configure(definition, {
		"target_position": Vector2(12.0, 0.0),
	})
	setup["spot"] = remote

	var load_count_after_config := int(remote.get("_scene_spot_config_load_count"))
	_expect_equal(load_count_after_config, 1, "remote magic lesson reads scene spot config once on configure")
	for index in range(5):
		_expect_true(
			remote.can_start_lesson(mom, player),
			"remote magic lesson can start after cached config %d" % index
		)
	_expect_equal(
		int(remote.get("_scene_spot_config_load_count")),
		load_count_after_config,
		"remote magic lesson does not reload the class scene during repeated can_start checks"
	)

	_free_setup(setup)


func _test_magic_lesson_accept_and_decline_paths() -> void:
	var world_time := root.get_node_or_null("WorldTime")
	var original_real_seconds_per_day := 0.0
	if world_time != null:
		original_real_seconds_per_day = float(world_time.get("real_seconds_per_day"))
		world_time.set("real_seconds_per_day", 24.0)

	var accept_setup := _create_magic_lesson_setup(&"test_magic_lesson_accept")
	var accept_spot: MagicLessonSpot = accept_setup["spot"]
	var accept_interactor: PlayerNpcTalkInteractor = accept_setup["interactor"]
	var accept_player: CharacterBody2D = accept_setup["player"]
	var accept_mom: LessonMom = accept_setup["mom"]

	_expect_true(
		accept_spot.begin_invitation(accept_mom, accept_player),
		"magic lesson invitation opens"
	)
	_expect_equal(String(accept_spot.get_lesson_state()), "inviting", "lesson waits for prompt")
	accept_interactor.call("_finish_npc_prompt", true)
	_expect_equal(String(accept_spot.get_lesson_state()), "running", "accept starts lesson")
	_expect_equal(accept_player.global_position, Vector2(128.0, 64.0), "accept places player")
	_expect_equal(accept_mom.global_position, Vector2(72.0, 64.0), "accept places mom")
	var progress_before := accept_spot.get_lesson_progress()
	accept_spot._process(0.25)
	_expect_approx(accept_spot.get_lesson_progress(), progress_before + 25.0, 0.001, "lesson score counts up by game time")
	_expect_true(accept_spot.label != null, "lesson spot creates a visible label")
	if accept_spot.label != null:
		_expect_true(accept_spot.label.text.contains("25"), "lesson label shows earned score")
		_expect_true(accept_spot.label.text.contains("class"), "lesson label shows running class state")
	accept_spot.complete_lesson()
	_expect_equal(String(accept_spot.get_lesson_state()), "completed", "lesson completes")
	var lesson_result := accept_spot.get_last_lesson_result()
	_expect_approx(float(lesson_result.get("score", -1.0)), 25.0, 0.001, "lesson records final score")
	_expect_approx(float(accept_player.get_meta("last_magic_lesson_score")), 25.0, 0.001, "lesson stores player score hook")
	_expect_equal(float(accept_player.get_meta("magic_xp")), 1.0, "lesson grants player reward")
	_expect_equal(accept_mom.social_events.size(), 1, "lesson applies mom effect once")
	accept_spot.complete_lesson()
	_expect_equal(float(accept_player.get_meta("magic_xp")), 1.0, "lesson reward is one-shot")
	_expect_equal(accept_mom.social_events.size(), 1, "mom effect is one-shot")
	_free_setup(accept_setup)

	var decline_setup := _create_magic_lesson_setup(&"test_magic_lesson_decline")
	var decline_spot: MagicLessonSpot = decline_setup["spot"]
	var decline_interactor: PlayerNpcTalkInteractor = decline_setup["interactor"]
	var decline_player: CharacterBody2D = decline_setup["player"]
	var decline_mom: LessonMom = decline_setup["mom"]

	_expect_true(
		decline_spot.begin_invitation(decline_mom, decline_player),
		"magic lesson invitation opens before decline"
	)
	decline_interactor.call("_finish_npc_prompt", false)
	_expect_equal(String(decline_spot.get_lesson_state()), "declined", "decline marks lesson skipped")
	_expect_false(decline_player.has_meta("magic_xp"), "decline does not reward player")
	_expect_false(
		decline_spot.can_start_lesson(decline_mom, decline_player),
		"decline prevents another same-day lesson"
	)
	_free_setup(decline_setup)

	if world_time != null and original_real_seconds_per_day > 0.0:
		world_time.set("real_seconds_per_day", original_real_seconds_per_day)


func _test_title_scene_instantiates_without_crashing() -> void:
	var packed_scene := load("res://scenes/levels/title_screen.tscn") as PackedScene
	_expect_true(packed_scene != null, "title scene loads as packed scene")
	if packed_scene == null:
		return

	var title_scene := packed_scene.instantiate()
	_expect_true(title_scene != null, "title scene instantiates")
	if title_scene == null:
		return

	root.add_child(title_scene)
	title_scene.free()


func _create_talk_setup(npc_position: Vector2, partner_position: Vector2) -> Dictionary:
	var npc := CharacterBody2D.new()
	npc.name = "Npc"
	npc.global_position = npc_position
	root.add_child(npc)

	var partner := CharacterBody2D.new()
	partner.name = "Partner"
	partner.global_position = partner_position
	root.add_child(partner)

	var machine := NpcStateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	machine.value_reactions_enabled = false
	_add_state(machine, _make_idle_state(), "Idle")
	_add_state(machine, NpcStateMoveToTarget.new(), "MoveToTarget")
	_add_state(machine, NpcStateWork.new(), "Work")
	_add_state(machine, NpcStateEat.new(), "Eat")
	_add_state(machine, NpcStateRoutineTask.new(), "RoutineTask")
	_add_state(machine, NpcStateRest.new(), "Rest")
	_add_state(machine, NpcStateRecreation.new(), "Recreation")
	_add_state(machine, NpcStateSleep.new(), "Sleep")
	_add_state(machine, NpcStateReactToEvent.new(), "ReactToEvent")
	_add_state(machine, NpcStateLookForTalkTarget.new(), "LookForTalkTarget")
	_add_state(machine, NpcStateCollapse.new(), "Collapse")
	_add_state(machine, NpcStateFight.new(), "Fight")
	_add_state(machine, NpcStateFlee.new(), "Flee")
	_add_state(machine, NpcStateDowned.new(), "Downed")
	_add_state(machine, NpcStateDisabledDead.new(), "DisabledDead")
	_add_state(machine, _make_talk_state(), "Talk")
	npc.add_child(machine)

	machine.bind_npc(npc)
	machine.initialize_states()
	machine.active = true
	machine.request_state(&"Idle", null, "test_initial", 100)
	return {
		"npc": npc,
		"partner": partner,
		"machine": machine,
	}


func _create_combat_npc(display_name: String, npc_position: Vector2) -> Dictionary:
	var packed_scene := load("res://scenes/creatures/npc/stateful_social_npc.tscn") as PackedScene
	_expect_true(packed_scene != null, "%s combat NPC scene loads" % display_name)
	if packed_scene == null:
		return {}

	var npc := packed_scene.instantiate() as SocialNpc
	_expect_true(npc != null, "%s combat NPC instantiates" % display_name)
	if npc == null:
		return {}

	npc.name = display_name
	npc.display_name = display_name
	npc.location_id = StringName(display_name.to_snake_case())
	npc.use_npc_location_tracking = false
	npc.listen_to_event_bus = false
	npc.global_position = npc_position
	root.add_child(npc)

	var machine := npc.get_node_or_null("NpcStateMachine") as NpcStateMachine
	_expect_true(machine != null, "%s combat NPC has state machine" % display_name)
	return {
		"npc": npc,
		"machine": machine,
	}


func _create_test_monster(monster_position: Vector2) -> TestMonster:
	var monster := TestMonster.new()
	monster.name = "TestMonster"
	monster.global_position = monster_position
	monster.add_to_group("monster")
	monster.add_to_group("monsters")
	monster.add_to_group("enemy")
	monster.add_to_group("enemies")
	monster.add_to_group("attack_target")
	root.add_child(monster)
	return monster


func _create_prompt_setup() -> Dictionary:
	var player := CharacterBody2D.new()
	player.name = "Player"
	player.add_to_group("player")
	player.global_position = Vector2.ZERO
	root.add_child(player)

	var interactor := PlayerNpcTalkInteractor.new()
	interactor.name = "NpcTalkInteractor"
	interactor.menu_choice_timeout_seconds = 1.0
	player.add_child(interactor)

	var npc := CharacterBody2D.new()
	npc.name = "Mom"
	npc.add_to_group("npc")
	npc.global_position = Vector2(12.0, 0.0)
	root.add_child(npc)

	var callback := PromptCallback.new()
	callback.name = "PromptCallback"
	root.add_child(callback)

	return {
		"player": player,
		"interactor": interactor,
		"npc": npc,
		"callback": callback,
	}


func _create_magic_lesson_setup(test_lesson_id: StringName) -> Dictionary:
	var setup := _create_prompt_setup()
	var player: CharacterBody2D = setup["player"]
	var interactor: PlayerNpcTalkInteractor = setup["interactor"]
	var old_npc := setup["npc"] as Node
	if old_npc != null and is_instance_valid(old_npc):
		old_npc.free()

	var mom := LessonMom.new()
	mom.name = "Mom"
	mom.add_to_group("npc")
	mom.global_position = Vector2(12.0, 0.0)
	root.add_child(mom)
	var machine := LessonActionMachine.new()
	machine.name = "NpcStateMachine"
	mom.add_child(machine)
	var locations := root.get_node_or_null("NpcLocations")
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	if locations != null and simulator != null:
		setup["lesson_original_records"] = locations.npc_records.duplicate(true)
		setup["lesson_original_live_npcs"] = locations.live_npcs.duplicate()
		setup["lesson_original_reservations"] = simulator.spot_reservations.duplicate(true)
		setup["lesson_original_live_spots"] = simulator.live_spots.duplicate()

	var spot := MagicLessonSpot.new()
	spot.name = "MagicLessonSpot"
	spot.spot_id = test_lesson_id
	spot.lesson_id = test_lesson_id
	spot.lesson_duration_seconds = 0.1
	spot.prompt_timeout_seconds = 1.0
	spot.mark_spot_unavailable_after_attempt = false
	spot.global_position = Vector2(100.0, 64.0)
	root.add_child(spot)

	if locations != null and simulator != null:
		var lesson_session_id := "test-lesson:%s" % String(test_lesson_id)
		var claim: Dictionary = simulator.call(
			"try_claim_spot", &"mom", lesson_session_id, test_lesson_id, &"activity"
		)
		var activity := {
			"session_id": lesson_session_id,
			"action_session_id": lesson_session_id,
			"activity_id": lesson_session_id,
			"state_name": "InvitePlayer",
			"source": "schedule",
			"status": "active",
			"spot_id": String(test_lesson_id),
			"lesson_phase": "inviting",
			"target_scene_path": "res://test_magic_lesson.tscn",
			"target_position": spot.global_position,
			"return_scene_path": "res://test_magic_lesson.tscn",
			"return_position": mom.global_position,
			"reservation_ids": [String(claim.get("reservation_id", ""))],
		}
		var session := NpcActionSession.create(
			"mom", &"InvitePlayer", &"schedule", spot, activity
		)
		session.status = NpcActionSession.Status.ACTIVE
		session.phase = &"executing"
		machine.descriptor = session.to_descriptor()
		locations.npc_records["mom"] = {
			"npc_id": "mom",
			"scene_path": "res://test_magic_lesson.tscn",
			"home_scene_path": "res://test_magic_lesson.tscn",
			"home_position": mom.global_position,
			"last_position": mom.global_position,
			"activity": activity,
			"action": session.to_descriptor(),
			"pending_travel": {},
			"node_state": {},
			"inventory": {},
		}
		locations.live_npcs["mom"] = mom

	var mom_marker := Marker2D.new()
	mom_marker.name = "MomLessonPosition"
	mom_marker.position = Vector2(-28.0, 0.0)
	spot.add_child(mom_marker)

	var player_marker := Marker2D.new()
	player_marker.name = "PlayerLessonPosition"
	player_marker.position = Vector2(28.0, 0.0)
	spot.add_child(player_marker)

	player.global_position = Vector2.ZERO
	interactor.player = player
	setup["npc"] = mom
	setup["mom"] = mom
	setup["spot"] = spot
	return setup


func _make_idle_state() -> NpcStateIdle:
	var state := NpcStateIdle.new()
	state.idle_wander_enabled = false
	return state


func _make_talk_state() -> NpcStateTalk:
	var state := NpcStateTalk.new()
	state.show_talk_limits = false
	state.talk_duration = 2.0
	state.talk_range = 32.0
	state.maximum_talk_distance = 180.0
	state.maximum_talk_distance_cancel_seconds = 0.1
	state.talk_approach_timeout = 5.0
	state.talk_approach_speed = 65.0
	return state


func _add_state(machine: NpcStateMachine, state: NpcState, state_name: String) -> void:
	state.name = state_name
	machine.add_child(state)


func _create_eat_spot(spot_name: StringName, owner_ids: Array) -> NpcNeedSpot:
	var spot := NpcNeedSpot.new()
	spot.name = String(spot_name)
	spot.auto_request_when_idle = false
	spot.restrict_to_target_npc = false
	spot.request_state_name = &"Eat"
	spot.value_name = &"hunger"
	var typed_owner_ids: Array[StringName] = []
	for owner_id in owner_ids:
		typed_owner_ids.append(StringName(String(owner_id)))
	spot.owner_npc_ids = typed_owner_ids
	root.add_child(spot)
	return spot


func _free_setup(setup: Dictionary) -> void:
	var freed: Array[Node] = []
	for key in ["spot", "npc", "partner", "player", "callback", "monster"]:
		var node = setup.get(key, null) as Node
		if node == null or not is_instance_valid(node):
			continue
		if freed.has(node):
			continue
		freed.append(node)
		node.free()
	if setup.has("lesson_original_records"):
		var locations := root.get_node_or_null("NpcLocations")
		var simulator := root.get_node_or_null("NpcWorldSimulation")
		if locations != null:
			locations.npc_records = setup["lesson_original_records"]
			locations.live_npcs = setup["lesson_original_live_npcs"]
		if simulator != null:
			simulator.spot_reservations = setup["lesson_original_reservations"]
			simulator.live_spots = setup["lesson_original_live_spots"]
			simulator.call("_sync_spot_claim_count_cache")


func _free_nodes(nodes: Array) -> void:
	for node_value in nodes:
		var node := node_value as Node
		if node != null and is_instance_valid(node):
			node.free()


func _expect_state(machine: NpcStateMachine, expected_state: String, label: String) -> void:
	var in_state := machine != null and machine.is_in_state(StringName(expected_state))
	_expect_true(in_state, label)


func _expect_primary_state(machine: NpcStateMachine, expected_state: String, label: String) -> void:
	var current_name := ""
	if machine != null and machine.current_state != null:
		current_name = String(machine.current_state.name)
	_expect_equal(current_name, expected_state, label)


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
