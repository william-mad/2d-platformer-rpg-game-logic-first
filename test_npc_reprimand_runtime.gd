extends SceneTree

const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const ConfrontationPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_confrontation_policy.gd"
)
const OutcomeResolver = preload(
	"res://scripts/systems/npc_behavior/npc_reprimand_outcome_resolver.gd"
)

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var controller := root.get_node("DialogueController")
	if bool(controller.call("is_dialogue_active")):
		controller.call("cancel_dialogue", "reprimand_test_setup")

	_test_policies()
	var world := Node2D.new()
	world.name = "NpcReprimandRuntimeWorld"
	root.add_child(world)
	current_scene = world
	_add_floor(world)
	var player := _spawn_player(world)
	await _settle_player(player)

	await _test_damage_to_reprimand_resolution(world, player, controller)
	await _test_defiant_outcome_requests_fight(world, player, controller)
	await _test_repeated_attack_interrupts_dialogue(world, player, controller)

	world.queue_free()
	await process_frame
	_finish()


func _test_policies() -> void:
	var policy := ConfrontationPolicy.new()
	var offender := Node2D.new()
	offender.add_to_group("player")
	var friend_context := {
		"reason": &"attacked_friend",
		"offender": offender,
		"severity": 15.0,
		"offense_count": 1,
		"dialogue_available": true,
	}
	var friend_result := policy.decide(friend_context, {
		"anger": 0.0,
		"fear": 0.0,
		"victim_favor": 75.0,
		"fight_threshold": 100.0,
		"flee_threshold": 70.0,
	})
	_expect(
		StringName(friend_result.get("decision", &"")) == &"reprimand",
		"a witnessed attack on a favored NPC can choose reprimand"
	)
	var stranger_result := policy.decide(friend_context, {
		"anger": 0.0,
		"fear": 0.0,
		"victim_favor": 20.0,
		"fight_threshold": 100.0,
		"flee_threshold": 70.0,
	})
	_expect(
		StringName(stranger_result.get("decision", &"")) == &"ignore",
		"a witnessed attack does not confront for an unrelated stranger"
	)
	var repeat_context := friend_context.duplicate(true)
	repeat_context["reason"] = &"repeated_offense"
	repeat_context["during_reprimand"] = true
	repeat_context["offense_count"] = 4
	var repeat_result := policy.decide(repeat_context, {
		"anger": 0.0,
		"fear": 0.0,
		"fight_threshold": 100.0,
		"flee_threshold": 70.0,
	})
	_expect(
		StringName(repeat_result.get("decision", &"")) == &"fight",
		"four hostile offenses during a reprimand escalate immediately"
	)

	var resolver := OutcomeResolver.new()
	var apology := resolver.resolve(
		{"severity": 12.0, "victim": offender, "initiator": offender},
		&"apologize"
	)
	_expect(
		StringName(apology.get("resolution", &"")) == &"resume",
		"apology resolves semantically without text inspection"
	)
	var defiant := resolver.resolve(
		{"severity": 12.0}, &"defiant"
	)
	_expect(
		StringName(defiant.get("resolution", &"")) == &"fight",
		"defiance resolves to a Fight request"
	)
	offender.free()


func _test_damage_to_reprimand_resolution(
	world: Node2D,
	player: CharacterBody2D,
	controller: Node
) -> void:
	var mom := _spawn_mom(world, "ReprimandMomResolve")
	await process_frame
	var machine := _prepare_mom(mom, player)
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	machine.values["talk_need"] = 25.0
	machine.values["boredom"] = 40.0

	var profile := mom.player_talk_dialogue_profile as NpcPlayerTalkDialogueProfile
	_expect(profile != null, "Mom has a shared dialogue profile for reprimands")
	_expect(
		profile != null and profile.get_validation_error().is_empty(),
		"Mom reprimand dialogue profile validates"
	)
	_test_reprimand_profile_selection(profile)

	mom.take_damage(1.0, player.global_position, player)
	_expect(
		StringName(machine.current_state.name) == &"ReactToEvent",
		"direct damage keeps the existing immediate ReactToEvent presentation"
	)
	_expect(
		mom._reprimand_coordinator.has_pending_reprimand(),
		"mild Player damage queues a confrontation"
	)
	var reaction := machine.get_state(&"ReactToEvent") as NpcStateReactToEvent
	reaction.reaction_timer = 0.0
	machine._physics_process(0.01)
	await process_frame
	await process_frame

	_expect(bool(controller.call("is_dialogue_active")), "ReactToEvent hands off to real dialogue")
	_expect(machine.interaction_overlay == talk_state, "Talk owns the reprimand session")
	_expect(talk_state.is_waiting_for_external_completion(), "Talk timer pauses for reprimand dialogue")
	_expect(machine.get_active_interaction_source() == &"reprimand", "Talk records reprimand as its source")
	machine.values["talk_need"] = 70.0
	var context := machine.get_active_talk_context()
	_expect(StringName(context.get("purpose", &"")) == &"reprimand", "Talk carries reprimand purpose")
	_expect(StringName(context.get("reason", &"")) == &"attacked_me", "Talk carries attacked_me reason")
	_expect(context.get("initiator", null) == mom, "Talk context carries its initiator")
	_expect(context.get("offender", null) == player, "Talk context carries its offender")
	_expect(context.get("victim", null) == mom, "Talk context carries its victim")
	_expect(context.get("source_event", {}) is Dictionary, "Talk carries a source-event snapshot")
	var timer_before := talk_state.talk_timer
	talk_state.physics_process(1.0)
	_expect_close(talk_state.talk_timer, timer_before, "reprimand dialogue replaces the Talk timer")
	var ui := controller.get_node("ModalDialogueUI") as ModalDialogueUI
	_expect(
		ui.portrait_presenter.visible and ui.portrait_texture.texture == profile.portrait,
		"reprimand reuses Mom's sliding dialogue portrait"
	)

	_advance_to_choices(controller)
	_expect(_choose_semantic_outcome(controller, &"apologize"), "apology semantic choice is authored")
	_expect(bool(controller.call("is_dialogue_active")), "Mom answers the apology before dialogue ends")
	controller.call("advance")
	_expect(not bool(controller.call("is_dialogue_active")), "Mom's answer completes the dialogue")
	_expect(talk_state.talk_completed_successfully, "resolved reprimand completes its Talk session")
	_expect_close(machine.get_value(&"talk_need"), 30.0, "Talk remains authoritative for talk-need reward")
	_expect_close(machine.get_value(&"boredom"), 30.0, "Talk remains authoritative for boredom reward")
	_expect(
		not machine.short_term_memory.find_recent(MemoryPolicy.EVENT_REPRIMAND).is_empty(),
		"semantic outcome records a reprimand memory"
	)
	machine._physics_process(0.01)
	_expect(machine.interaction_overlay == null, "resolved reprimand closes Talk normally")
	mom.queue_free()
	await process_frame


func _test_defiant_outcome_requests_fight(
	world: Node2D,
	player: CharacterBody2D,
	controller: Node
) -> void:
	var mom := _spawn_mom(world, "ReprimandMomDefiant")
	await process_frame
	var machine := _prepare_mom(mom, player)
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	machine.values["talk_need"] = 65.0
	var context := _manual_context(mom, player, &"attacked_me", 10.0, 1)
	var accepted := machine.request_talk(player, 88, false, &"reprimand", context)
	_expect(accepted, "contextual reprimand Talk request is accepted")
	_expect(bool(controller.call("is_dialogue_active")), "contextual Talk opens reprimand dialogue")
	_advance_to_choices(controller)
	_expect(_choose_semantic_outcome(controller, &"defiant"), "defiant semantic choice is authored")
	controller.call("advance")
	_expect(not bool(controller.call("is_dialogue_active")), "defiant answer closes modal dialogue")
	_expect(not talk_state.talk_completed_successfully, "defiance does not grant successful Talk rewards")
	_expect_close(machine.get_value(&"talk_need"), 65.0, "Fight escalation grants no Talk need payout")
	_expect(StringName(machine.current_state.name) == &"Fight", "defiant outcome requests existing Fight")
	_expect(machine.interaction_overlay == null, "Talk and Fight do not remain active together")
	mom.queue_free()
	await process_frame


func _test_repeated_attack_interrupts_dialogue(
	world: Node2D,
	player: CharacterBody2D,
	controller: Node
) -> void:
	var mom := _spawn_mom(world, "ReprimandMomInterrupted")
	await process_frame
	var machine := _prepare_mom(mom, player)
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	machine.values["talk_need"] = 60.0
	var accepted := machine.request_talk(
		player,
		88,
		false,
		&"reprimand",
		_manual_context(mom, player, &"attacked_me", 10.0, 1)
	)
	_expect(accepted and bool(controller.call("is_dialogue_active")), "interrupt case starts reprimand dialogue")
	mom.take_damage(1.0, player.global_position, player)
	mom.take_damage(1.0, player.global_position, player)
	_expect(bool(controller.call("is_dialogue_active")), "two further minor hits keep the confrontation active")
	mom.take_damage(1.0, player.global_position, player)
	_expect(not bool(controller.call("is_dialogue_active")), "third further hit terminates dialogue immediately")
	_expect(StringName(machine.current_state.name) == &"Fight", "repeated attacks bypass dialogue for Fight")
	_expect(machine.interaction_overlay == null, "repeated attack escalation leaves no Talk overlay")
	_expect(not talk_state.talk_completed_successfully, "interrupted reprimand grants no Talk success")
	_expect_close(machine.get_value(&"talk_need"), 60.0, "interrupted reprimand grants no Talk reward")
	mom.queue_free()
	await process_frame


func _test_reprimand_profile_selection(profile: NpcPlayerTalkDialogueProfile) -> void:
	if profile == null:
		return
	_expect(profile.get_reprimand_responses(&"attacked_me").size() == 2, "Mom has two attacked-me variants")
	_expect(
		profile.get_reprimand_responses(&"false_monster_alarm").size() == 2,
		"Mom has two false-monster-alarm variants"
	)
	for reason in [&"attacked_me", &"attacked_friend", &"repeated_offense", &"false_monster_alarm"]:
		_expect(profile.has_reprimand_response(reason), "Mom supports reprimand reason %s" % String(reason))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7113
	var previous_id: StringName = &""
	for _index in 10:
		var definition := profile.choose_reprimand_response(&"attacked_me", rng, previous_id)
		_expect(definition != null, "attacked-me reprimand selection succeeds")
		if definition == null:
			return
		if previous_id != &"":
			_expect(definition.dialogue_id != previous_id, "reprimands avoid immediate repetition")
		previous_id = definition.dialogue_id


func _advance_to_choices(controller: Node) -> void:
	var safety := 0
	while bool(controller.call("is_dialogue_active")) and safety < 10:
		safety += 1
		var node := controller.get("current_node") as DialogueNode
		if node == null or not node.choices.is_empty():
			break
		controller.call("advance")
	_expect(safety < 10, "reprimand reaches its response choices")


func _choose_semantic_outcome(controller: Node, outcome: StringName) -> bool:
	var node := controller.get("current_node") as DialogueNode
	if node == null:
		return false
	for choice in node.choices:
		if choice != null and StringName(choice.consequences.get("reprimand_outcome", &"")) == outcome:
			return bool(controller.call("choose", choice.choice_id))
	return false


func _manual_context(
	mom: SocialNpc,
	player: Node2D,
	reason: StringName,
	severity: float,
	offense_count: int
) -> Dictionary:
	return {
		"purpose": &"reprimand",
		"reason": reason,
		"initiator": mom,
		"offender": player,
		"target": player,
		"victim": mom,
		"source_event": {"event_name": "test_damage", "damage_amount": 1.0},
		"severity": severity,
		"offense_count": offense_count,
		"bypass_social_talk_refusal": true,
	}


func _prepare_mom(mom: SocialNpc, player: Node2D) -> NpcStateMachine:
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	machine.value_reactions_enabled = true
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	talk_state.talk_duration = 0.05
	talk_state.talk_range = 50.0
	talk_state.show_talk_limits = false
	_force_primary_state(machine, &"Idle")
	_reset_relationship(mom, player)
	return machine


func _reset_relationship(mom: SocialNpc, player: Node2D) -> void:
	mom.change_relationship_anger_for(
		player, -mom.get_relationship_anger_for(player, 0.0), "reprimand_test_reset"
	)
	mom.change_relationship_fear_for(
		player, -mom.get_relationship_fear_for(player, 0.0), "reprimand_test_reset"
	)


func _spawn_player(world: Node2D) -> CharacterBody2D:
	var scene := load("res://player/player.tscn") as PackedScene
	var player := scene.instantiate() as CharacterBody2D
	player.name = "ReprimandPlayer"
	player.position = Vector2(0.0, -8.0)
	world.add_child(player)
	return player


func _spawn_mom(world: Node2D, node_name: String) -> SocialNpc:
	var scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := scene.instantiate() as SocialNpc
	mom.name = node_name
	mom.position = Vector2(24.0, 0.0)
	mom.use_npc_location_tracking = false
	mom.listen_to_event_bus = false
	mom.damage_hop_enabled = false
	world.add_child(mom)
	return mom


func _force_primary_state(machine: NpcStateMachine, state_name: StringName) -> void:
	var state := machine.get_state(state_name)
	if state != null and StringName(machine.current_state.name) != state_name:
		machine.call("_commit_state_change", state, "reprimand_test", 10000)


func _add_floor(world: Node2D) -> void:
	var floor := StaticBody2D.new()
	floor.collision_layer = 1
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(800.0, 20.0)
	collision.shape = shape
	collision.position = Vector2(0.0, 10.0)
	floor.add_child(collision)
	world.add_child(floor)


func _settle_player(player: CharacterBody2D) -> void:
	var frames := 0
	while is_instance_valid(player) and not player.is_on_floor() and frames < 120:
		await physics_frame
		frames += 1


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		failures.append("%s: expected %.4f, got %.4f" % [label, expected, actual])


func _finish() -> void:
	if failures.is_empty():
		print("NPC_REPRIMAND_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
