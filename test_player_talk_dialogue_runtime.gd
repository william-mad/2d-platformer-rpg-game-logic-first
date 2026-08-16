extends SceneTree

const MemoryPolicy = preload("res://scripts/systems/npc_behavior/npc_memory_policy.gd")

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var controller := root.get_node("DialogueController")
	if bool(controller.call("is_dialogue_active")):
		controller.call("cancel_dialogue", "player_talk_test_setup")

	var world := Node2D.new()
	world.name = "PlayerTalkDialogueRuntimeWorld"
	root.add_child(world)
	current_scene = world
	_add_floor(world)
	var player := _spawn_player(world)
	await _settle_player(player)
	var mom := _spawn_mom(world)
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	_force_primary_state(machine, &"Idle")
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk
	talk_state.talk_duration = 0.05
	talk_state.talk_range = 40.0
	talk_state.show_talk_limits = false
	mom.position = Vector2(90.0, 0.0)

	var profile := mom.player_talk_dialogue_profile as NpcPlayerTalkDialogueProfile
	_expect(profile != null, "Mom has a player-facing Talk dialogue profile")
	_expect(profile != null and profile.get_validation_error().is_empty(), "player Talk profile validates")
	_test_profile_content(profile)

	var interactor := player.get_node("NpcTalkInteractor") as PlayerNpcTalkInteractor
	interactor.nearby_npcs.append(mom)
	interactor.call("_try_open_interaction_menu")
	_expect(interactor.active_menu == &"interaction", "NPC interaction menu opens")
	_expect(interactor.interaction_menu_actions[0] == &"talk", "Talk is the first NPC action")
	_expect(
		interactor.interaction_menu_actions.size() > 1
		and interactor.interaction_menu_actions[1] == &"actions",
		"Actions is the second NPC interaction"
	)
	_expect(
		not interactor.interaction_menu_actions.has(&"dialogue"),
		"Special Dialogue is removed from the player interaction menu"
	)
	interactor.call("_handle_interaction_option", 1)
	_expect(
		interactor.active_menu == &"interaction"
		and interactor.menu_feedback_label.visible
		and interactor.menu_feedback_label.text == "Actions: To be implemented.",
		"Actions displays its implementation placeholder"
	)
	interactor.call("_handle_interaction_option", 0)
	_expect(interactor.active_menu == &"talk", "Talk opens its category submenu")
	var expected_labels := ["Casual", "Compliment", "Flirt", "Insult", "Gossip"]
	for index in expected_labels.size():
		_expect(
			String(interactor.menu_option_labels[index].text).contains(expected_labels[index]),
			"Talk category %d is %s" % [index + 1, expected_labels[index]]
		)

	machine.values["talk_need"] = 80.0
	machine.values["boredom"] = 55.0
	var relationships := root.get_node("Relationships")
	relationships.call("meet", mom, player)
	var trust_before := float(relationships.call(
		"get_opinion_metric", mom, player, &"trust", 50.0
	))
	var memories_before := machine.short_term_memory.find_recent(
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED
	).size()
	interactor.call("_handle_talk_option", 0)
	_expect(
		not bool(controller.call("is_dialogue_active")),
		"dialogue waits while the existing Talk action approaches"
	)
	_expect(machine.interaction_overlay == talk_state, "Talk owns the approach")
	mom.position = Vector2(24.0, 0.0)
	machine._physics_process(0.01)
	_expect(bool(controller.call("is_dialogue_active")), "Casual opens real dialogue")
	_expect(machine.interaction_overlay == talk_state, "existing Talk overlay owns the conversation")
	_expect(talk_state.is_waiting_for_external_completion(), "Talk waits for dialogue")
	var report: Dictionary = controller.call("dump_active_dialogue")
	_expect(StringName(report.get("session_mode", &"")) == &"player_talk", "player Talk uses its modal mode")
	_expect(int(report.get("npc_claim_token", -1)) == 0, "player Talk does not claim ScriptedHold")
	_expect_close(machine.get_value(&"talk_need"), 80.0, "effects wait for dialogue success")
	_expect_close(machine.get_value(&"boredom"), 55.0, "boredom reward waits for dialogue success")
	var timer_before := talk_state.talk_timer
	talk_state.physics_process(1.0)
	_expect_close(talk_state.talk_timer, timer_before, "Talk timer pauses below dialogue")
	var dialogue_ui := controller.get_node("ModalDialogueUI") as ModalDialogueUI
	_expect(
		dialogue_ui.portrait_presenter.visible
		and dialogue_ui.portrait_texture.texture == profile.portrait,
		"Mom's existing portrait slides in for her response"
	)
	_complete_current_dialogue(controller)
	_expect(talk_state.talk_completed_successfully, "dialogue completion completes normal Talk")
	_expect_close(machine.get_value(&"talk_need"), 40.0, "normal Talk owns talk-need reward")
	_expect_close(machine.get_value(&"boredom"), 45.0, "normal Talk owns boredom reward")
	_expect_close(
		float(relationships.call("get_opinion_metric", mom, player, &"trust", 50.0)),
		trust_before + 1.0,
		"Casual's category effect commits after successful dialogue"
	)
	machine._physics_process(0.01)
	_expect(machine.interaction_overlay == null, "successful Talk closes normally")
	_expect(
		machine.short_term_memory.find_recent(
			MemoryPolicy.EVENT_CONVERSATION_COMPLETED
		).size() == memories_before + 1,
		"successful player dialogue records normal conversation memory"
	)

	# Cancellation must not grant category effects or normal Talk rewards.
	_clear_interaction_cooldowns(interactor, machine)
	machine.short_term_memory.clear_all(&"player_talk_test_next_case")
	machine.values["talk_need"] = 70.0
	machine.values["boredom"] = 50.0
	var anger_before := float(relationships.call(
		"get_opinion_metric", mom, player, &"anger", 0.0
	))
	_open_talk_category_menu(interactor)
	interactor.call("_handle_talk_option", 3)
	_expect(bool(controller.call("is_dialogue_active")), "Insult opens a response dialogue")
	controller.call("cancel_dialogue", "test_cancelled")
	_expect_close(machine.get_value(&"talk_need"), 70.0, "cancelled response grants no talk reward")
	_expect_close(machine.get_value(&"boredom"), 50.0, "cancelled response grants no boredom reward")
	_expect_close(
		float(relationships.call("get_opinion_metric", mom, player, &"anger", 0.0)),
		anger_before,
		"cancelled Insult grants no category effect"
	)
	_expect(not talk_state.talk_completed_successfully, "cancelled response cancels Talk")
	machine._physics_process(0.01)

	# Gossip preserves the existing modular target selection and substitutes its name.
	_clear_interaction_cooldowns(interactor, machine)
	machine.short_term_memory.clear_all(&"player_talk_test_next_case")
	var gossip_target := Node2D.new()
	gossip_target.name = "Mara"
	gossip_target.set_meta(&"npc_location_id", "mara")
	gossip_target.add_to_group("npc")
	world.add_child(gossip_target)
	relationships.call(
		"meet", mom, gossip_target, 50.0, 0.0, {"other_name": "Mara"}
	)
	_open_talk_category_menu(interactor)
	interactor.call("_handle_talk_option", 4)
	_expect(interactor.active_menu == &"gossip", "Gossip opens the known-NPC target menu")
	_expect(
		String(interactor.menu_option_labels[0].text).contains("Mara"),
		"gossip target menu shows the modular NPC name"
	)
	interactor.call("_handle_gossip_option", 0)
	_expect(bool(controller.call("is_dialogue_active")), "choosing a gossip target opens dialogue")
	var gossip_node := controller.get("current_node") as DialogueNode
	_expect(
		gossip_node != null
		and gossip_node.speaker_text.contains("Mara")
		and not gossip_node.speaker_text.contains("{target_name}"),
		"gossip dialogue instantiates the selected NPC name"
	)
	_complete_current_dialogue(controller)
	machine._physics_process(0.01)

	world.queue_free()
	await process_frame
	_finish()


func _test_profile_content(profile: NpcPlayerTalkDialogueProfile) -> void:
	if profile == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 9451
	for category in NpcPlayerTalkDialogueProfile.REQUIRED_CATEGORIES:
		_expect(profile.get_responses(category).size() == 2, "%s has two Mom responses" % String(category))
		var previous_id: StringName = &""
		for selection_index in 12:
			var definition := profile.choose_response(category, rng, previous_id)
			_expect(definition != null, "%s response selection succeeds" % String(category))
			if definition == null:
				break
			if previous_id != &"":
				_expect(
					definition.dialogue_id != previous_id,
					"%s avoids immediate response repetition" % String(category)
				)
			previous_id = definition.dialogue_id
			for node in definition.nodes:
				_expect(node.speaker_id == &"mom", "%s remains a one-sided Mom response" % String(category))


func _open_talk_category_menu(interactor: PlayerNpcTalkInteractor) -> void:
	interactor.call("_try_open_interaction_menu")
	interactor.call("_handle_interaction_option", 0)


func _clear_interaction_cooldowns(
	interactor: PlayerNpcTalkInteractor,
	machine: NpcStateMachine
) -> void:
	interactor.cooldown = 0.0
	machine.player_interaction_cooldown_timer = 0.0
	machine.player_interaction_cooldown_actor = null


func _complete_current_dialogue(controller: Node) -> void:
	var safety := 0
	while bool(controller.call("is_dialogue_active")) and safety < 20:
		safety += 1
		var node := controller.get("current_node") as DialogueNode
		if node == null:
			break
		if not node.choices.is_empty():
			controller.call("choose", node.choices[0].choice_id)
		else:
			controller.call("advance")
	_expect(safety < 20, "dialogue traversal reaches a terminal response")


func _spawn_player(world: Node2D) -> CharacterBody2D:
	var scene := load("res://player/player.tscn") as PackedScene
	var player := scene.instantiate() as CharacterBody2D
	player.name = "PlayerTalkPlayer"
	player.position = Vector2(0.0, -8.0)
	world.add_child(player)
	return player


func _spawn_mom(world: Node2D) -> SocialNpc:
	var scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := scene.instantiate() as SocialNpc
	mom.name = "PlayerTalkMom"
	mom.position = Vector2(24.0, 0.0)
	mom.use_npc_location_tracking = false
	mom.listen_to_event_bus = false
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	machine.value_reactions_enabled = false
	world.add_child(mom)
	return mom


func _force_primary_state(machine: NpcStateMachine, state_name: StringName) -> void:
	var state := machine.get_state(state_name)
	if state != null and StringName(machine.current_state.name) != state_name:
		machine.call("_commit_state_change", state, "player_talk_dialogue_test", 10000)


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
		print("PLAYER_TALK_DIALOGUE_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
