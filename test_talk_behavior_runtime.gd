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
	_run_tests()
	if _failures.is_empty():
		print("NPC talk behavior runtime tests passed.")
		quit(0)
		return

	for failure in _failures:
		push_error(failure)
	quit(1)


func _run_tests() -> void:
	_test_active_talk_blocks_routine_interrupts()
	_test_active_talk_allows_emergency_interrupt()
	_test_duplicate_talk_request_does_not_restart_talk()
	_test_duplicate_move_to_talk_request_is_ignored()
	_test_far_talk_request_approaches_without_cancel_loop()
	_test_hungry_reaction_waits_without_usable_eat_spot()
	_test_hungry_reaction_uses_available_eat_spot()
	_test_eat_state_stops_when_food_spot_supplies_nothing()
	_test_starvation_damage_starts_at_hunger_cap()
	_test_tired_speed_scaling()
	_test_seen_monster_starts_fight()
	_test_seen_monster_can_flee_for_coward_npc()
	_test_monster_damage_does_not_change_social_anger()
	_test_monster_fight_respects_low_health_stop()
	_test_look_for_monster_after_kill_finds_next_monster()
	_test_unrelated_fight_does_not_scan_monsters_by_default()
	_test_npc_prompt_calls_accept_once()
	_test_remote_magic_lesson_config_is_cached()
	_test_magic_lesson_accept_and_decline_paths()
	_test_title_scene_instantiates_without_crashing()


func _test_active_talk_blocks_routine_interrupts() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]

	_expect_true(machine.request_talk(setup["partner"], 60, false), "close talk starts")
	_expect_state(machine, "Talk", "NPC is in Talk before routine requests")

	_expect_false(machine.request_state(&"Work", null, "test_work", 20), "Work cannot interrupt active Talk")
	_expect_state(machine, "Talk", "Talk remains active after Work request")
	_expect_false(machine.request_state(&"Work", null, "test_work_high", 95), "high-priority Work is still routine")
	_expect_state(machine, "Talk", "Talk remains active after high-priority Work request")

	_expect_false(machine.request_state(&"Eat", null, "test_eat", 50), "Eat cannot interrupt active Talk")
	_expect_state(machine, "Talk", "Talk remains active after Eat request")

	_expect_false(
		machine.request_state(&"RoutineTask", null, "test_routine", 30),
		"RoutineTask cannot interrupt active Talk"
	)
	_expect_state(machine, "Talk", "Talk remains active after RoutineTask request")
	_free_setup(setup)


func _test_active_talk_allows_emergency_interrupt() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]

	_expect_true(machine.request_talk(setup["partner"], 60, false), "talk starts before emergency")
	_expect_true(machine.request_state(&"Collapse", null, "test_collapse", 95), "Collapse can interrupt Talk")
	_expect_state(machine, "Collapse", "emergency state takes control")
	_free_setup(setup)


func _test_duplicate_talk_request_does_not_restart_talk() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(8.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]

	_expect_true(machine.request_talk(partner, 60, false), "initial talk starts")
	var talk_state := machine.current_state as NpcStateTalk
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


func _test_far_talk_request_approaches_without_cancel_loop() -> void:
	var setup := _create_talk_setup(Vector2.ZERO, Vector2(500.0, 0.0))
	var machine: NpcStateMachine = setup["machine"]
	var partner: Node2D = setup["partner"]

	_expect_true(machine.request_talk(partner, 60, false), "far talk request enters pending Talk approach")
	_expect_state(machine, "Talk", "far request is represented as Talk approach")
	var talk_state := machine.current_state as NpcStateTalk
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
	_add_state(machine, NpcStateCollapse.new(), "Collapse")
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

	var spot := MagicLessonSpot.new()
	spot.name = "MagicLessonSpot"
	spot.spot_id = test_lesson_id
	spot.lesson_id = test_lesson_id
	spot.lesson_duration_seconds = 0.1
	spot.prompt_timeout_seconds = 1.0
	spot.mark_spot_unavailable_after_attempt = false
	spot.global_position = Vector2(100.0, 64.0)
	root.add_child(spot)

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


func _free_nodes(nodes: Array) -> void:
	for node_value in nodes:
		var node := node_value as Node
		if node != null and is_instance_valid(node):
			node.free()


func _expect_state(machine: NpcStateMachine, expected_state: String, label: String) -> void:
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
