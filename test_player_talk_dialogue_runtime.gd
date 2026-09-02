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
	_test_flirt_choice_content(profile, "Mom")
	_test_other_npc_dialogue_profiles()

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
	_test_mom_portrait_animation(dialogue_ui, profile)
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
	_test_flirt_choice_effects(
		interactor,
		controller,
		dialogue_ui,
		mom,
		player,
		machine,
		talk_state,
		relationships
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
	_test_insult_fight_escalation(
		interactor,
		controller,
		mom,
		player,
		machine,
		relationships
	)

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


func _test_flirt_choice_content(
	profile: NpcPlayerTalkDialogueProfile,
	label: String
) -> void:
	if profile == null:
		return
	var expected_love_deltas := [1.0, -1.0, 0.0, 2.0]
	for definition in profile.flirt_responses:
		var entry := definition.get_node(definition.entry_node_id)
		_expect(entry != null, "%s Flirt has an entry node" % label)
		if entry == null:
			continue
		_expect(entry.choices.size() == 4, "%s Flirt offers four contextual choices" % label)
		for index in mini(entry.choices.size(), expected_love_deltas.size()):
			var choice := entry.choices[index]
			var opinion_delta = choice.consequences.get(
				&"player_talk_opinion_delta", {}
			)
			_expect(opinion_delta is Dictionary, "%s Flirt choice %d has an opinion consequence" % [label, index])
			if opinion_delta is Dictionary:
				_expect_close(
					float(opinion_delta.get("love", 999.0)),
					expected_love_deltas[index],
					"%s Flirt choice %d has its authored love result" % [label, index]
				)
			var follow_up := definition.get_node(choice.next_node_id)
			_expect(
				follow_up != null
				and follow_up.terminal
				and not follow_up.speaker_text.strip_edges().is_empty(),
				"%s Flirt choice %d leads to a visible follow-up line" % [label, index]
			)


func _test_flirt_choice_effects(
	interactor: PlayerNpcTalkInteractor,
	controller: Node,
	dialogue_ui: ModalDialogueUI,
	mom: SocialNpc,
	player: CharacterBody2D,
	machine: NpcStateMachine,
	talk_state: NpcStateTalk,
	relationships: Node
) -> void:
	relationships.call(
		"set_opinion_metric", mom, player, &"love", 57.0, "flirt_choice_test_setup"
	)
	var choice_ids: Array[StringName] = [&"sincere", &"dismissive", &"cautious", &"bold"]
	var expected_after_choice := [58.0, 57.0, 57.0, 59.0]
	var expected_cue_text := ["+1", "-1", "", "+2"]
	for choice_index in 4:
		_clear_interaction_cooldowns(interactor, machine)
		machine.short_term_memory.clear_all(&"player_talk_flirt_choice_test")
		var cue := dialogue_ui.relationship_change_cue
		if bool(cue.call("is_showing")):
			cue.call("_finish_cue")
		_open_talk_category_menu(interactor)
		interactor.call("_handle_talk_option", 2)
		_expect(bool(controller.call("is_dialogue_active")), "Flirt choice case %d opens dialogue" % choice_index)
		var entry := controller.get("current_node") as DialogueNode
		_expect(entry != null and entry.choices.size() == 4, "Flirt choice case %d exposes all outcomes" % choice_index)
		if entry == null:
			continue
		var selected_choice := entry.get_choice(choice_ids[choice_index])
		_expect(selected_choice != null, "Flirt choice case %d remains available after shuffling" % choice_index)
		if selected_choice == null:
			continue
		var love_before := float(relationships.call(
			"get_opinion_metric", mom, player, &"love", 0.0
		))
		controller.call("choose", selected_choice.choice_id)
		_expect_close(
			float(relationships.call("get_opinion_metric", mom, player, &"love", 0.0)),
			expected_after_choice[choice_index],
			"Flirt choice %d applies love immediately" % choice_index
		)
		var follow_up := controller.get("current_node") as DialogueNode
		_expect(
			bool(controller.call("is_dialogue_active"))
			and follow_up != null
			and follow_up.terminal
			and dialogue_ui.panel.visible,
			"Flirt choice %d keeps its follow-up line visible" % choice_index
		)
		if expected_cue_text[choice_index].is_empty():
			_expect(not bool(cue.call("is_showing")), "neutral Flirt choice shows no false heart")
			_expect_close(
				float(relationships.call("get_opinion_metric", mom, player, &"love", 0.0)),
				love_before,
				"neutral Flirt choice leaves love unchanged"
			)
		else:
			var delta_label := cue.get_node("CueGroup/DeltaLabel") as Label
			var heart_icon := cue.get_node("CueGroup/HeartIcon") as TextureRect
			var heart_echo_2 := cue.get_node("CueGroup/HeartEcho2") as TextureRect
			_expect(bool(cue.call("is_showing")), "Flirt choice %d shows the heart immediately" % choice_index)
			_expect(delta_label.text == expected_cue_text[choice_index], "Flirt choice %d shows its actual delta" % choice_index)
			_expect(
				heart_echo_2.visible == (choice_index == 3),
				"Flirt +2 uses a second softer heart only for its larger change"
			)
			if choice_index == 3:
				_expect(
					heart_echo_2.modulate.a < heart_icon.modulate.a,
					"Flirt +2 secondary heart starts at lower alpha"
				)
			_expect(
				dialogue_ui.get_viewport().get_visible_rect().intersects(
					heart_icon.get_global_rect()
				),
				"Flirt choice %d heart is inside the visible viewport" % choice_index
			)
		_complete_current_dialogue(controller)
		_expect_close(
			float(relationships.call("get_opinion_metric", mom, player, &"love", 0.0)),
			expected_after_choice[choice_index],
			"Flirt choice %d is not paid again at dialogue completion" % choice_index
		)
		machine._physics_process(0.01)
		_expect(machine.interaction_overlay == null, "Flirt choice %d closes normal Talk" % choice_index)


func _test_insult_fight_escalation(
	interactor: PlayerNpcTalkInteractor,
	controller: Node,
	mom: SocialNpc,
	player: CharacterBody2D,
	machine: NpcStateMachine,
	relationships: Node
) -> void:
	_force_primary_state(machine, &"Idle")
	_clear_interaction_cooldowns(interactor, machine)
	machine.short_term_memory.clear_all(&"player_insult_challenge_test")
	relationships.call(
		"set_opinion_metric",
		mom,
		player,
		&"anger",
		80.0,
		"player_insult_challenge_test"
	)
	relationships.call(
		"set_opinion_metric",
		mom,
		player,
		&"favor",
		50.0,
		"player_insult_challenge_test"
	)
	_open_talk_category_menu(interactor)
	_expect(interactor.menu_confrontation_only, "high anger opens the restricted confrontation menu")
	_expect(
		interactor.current_menu_option_count == 1
		and String(interactor.menu_option_labels[0].text).contains("Insult"),
		"restricted Talk exposes only Insult"
	)
	interactor.call("_handle_talk_option", 0)
	_expect(bool(controller.call("is_dialogue_active")), "80 anger still opens the gated insult dialogue")
	var entry := controller.get("current_node") as DialogueNode
	var challenge_choice: DialogueChoice = null
	if entry != null:
		for choice in entry.choices:
			if StringName(choice.consequences.get("player_talk_insult_action", &"")) == &"challenge_fight":
				challenge_choice = choice
				break
	_expect(challenge_choice != null, "80 anger offers an explicit Fight challenge")
	if challenge_choice != null:
		controller.call("choose", challenge_choice.choice_id)
		_complete_current_dialogue(controller)
	_expect(
		machine.is_primary_state(&"Fight"),
		"the NPC accepts the 80+ anger Fight challenge"
	)

	_force_primary_state(machine, &"Idle")
	_clear_interaction_cooldowns(interactor, machine)
	machine.short_term_memory.clear_all(&"player_insult_auto_fight_test")
	relationships.call(
		"set_opinion_metric",
		mom,
		player,
		&"anger",
		95.0,
		"player_insult_auto_fight_test"
	)
	relationships.call(
		"set_opinion_metric",
		mom,
		player,
		&"favor",
		50.0,
		"player_insult_auto_fight_test"
	)
	_open_talk_category_menu(interactor)
	_expect(interactor.menu_confrontation_only, "95 anger keeps only the confrontation path")
	interactor.call("_handle_talk_option", 0)
	_expect(
		not bool(controller.call("is_dialogue_active")),
		"95 anger skips insult dialogue"
	)
	_expect(machine.is_primary_state(&"Fight"), "95 anger immediately starts Fight")


func _test_other_npc_dialogue_profiles() -> void:
	var npc_cases: Array[Dictionary] = [
		{
			"name": "Dad",
			"prefix": "dad_",
			"scene": "res://scenes/creatures/dad_npc.tscn",
		},
		{
			"name": "Maid",
			"prefix": "maid_",
			"scene": "res://scenes/creatures/maid_npc.tscn",
		},
		{
			"name": "Bob",
			"prefix": "bob_",
			"scene": "res://scenes/creatures/bob_npc.tscn",
		},
	]
	for npc_case in npc_cases:
		var scene := load(String(npc_case["scene"])) as PackedScene
		_expect(scene != null, "%s scene loads" % String(npc_case["name"]))
		if scene == null:
			continue
		var npc := scene.instantiate() as SocialNpc
		_expect(npc != null, "%s scene instantiates as a social NPC" % String(npc_case["name"]))
		if npc == null:
			continue

		var player_profile := npc.player_talk_dialogue_profile as NpcPlayerTalkDialogueProfile
		_expect(player_profile != null, "%s has an authored player Talk profile" % String(npc_case["name"]))
		_expect(
			player_profile != null and player_profile.get_validation_error().is_empty(),
			"%s player Talk profile validates" % String(npc_case["name"])
		)
		if player_profile != null:
			_expect(
				player_profile.speaker_name == String(npc_case["name"]),
				"%s responses use the NPC's name" % String(npc_case["name"])
			)
			var has_authored_response := false
			var has_shared_response := false
			for category in NpcPlayerTalkDialogueProfile.REQUIRED_CATEGORIES:
				for definition in player_profile.get_responses(category):
					var dialogue_id := String(definition.dialogue_id)
					has_authored_response = (
						has_authored_response
						or dialogue_id.begins_with(String(npc_case["prefix"]))
					)
					has_shared_response = has_shared_response or dialogue_id.begins_with("generic_")
			_expect(has_authored_response, "%s has character-authored player responses" % String(npc_case["name"]))
			_expect(has_shared_response, "%s reuses neutral player responses" % String(npc_case["name"]))
			if String(npc_case["name"]) == "Maid":
				_test_flirt_choice_content(player_profile, "Maid")

		var autonomous_profile := npc.autonomous_dialogue_profile as NpcAutonomousDialogueProfile
		_expect(autonomous_profile != null, "%s has an autonomous dialogue profile" % String(npc_case["name"]))
		_expect(
			autonomous_profile != null and autonomous_profile.get_validation_error().is_empty(),
			"%s autonomous dialogue profile validates" % String(npc_case["name"])
		)
		if autonomous_profile != null:
			_expect(
				autonomous_profile.conversations.size() == 3,
				"%s has three approach conversations" % String(npc_case["name"])
			)
			var has_authored_conversation := false
			var has_shared_conversation := false
			for definition in autonomous_profile.conversations:
				var dialogue_id := String(definition.dialogue_id)
				has_authored_conversation = (
					has_authored_conversation
					or dialogue_id.begins_with(String(npc_case["prefix"]))
				)
				has_shared_conversation = (
					has_shared_conversation
					or dialogue_id.begins_with("generic_")
				)
			_expect(has_authored_conversation, "%s has an authored approach conversation" % String(npc_case["name"]))
			_expect(has_shared_conversation, "%s reuses neutral approach conversations" % String(npc_case["name"]))
		npc.free()


func _test_mom_portrait_animation(
	dialogue_ui: ModalDialogueUI,
	profile: NpcPlayerTalkDialogueProfile
) -> void:
	if dialogue_ui == null or profile == null:
		return
	var animation := profile.portrait_animation
	_expect(animation != null, "Mom has a layered portrait animation profile")
	if animation == null:
		return
	_expect(animation.get_validation_error().is_empty(), "Mom portrait animation validates")
	_expect(
		animation.blink_sequence == PackedInt32Array([0, 1, 2, 3, 4, 3, 2, 1, 0]),
		"Mom blink uses the authored 1-2-3-4-5-4-3-2-1 order"
	)
	_expect(
		animation.talk_sequence == PackedInt32Array([0, 1, 2, 1, 3, 4, -1]),
		"Mom mouth uses the authored 1-2-3-2-4-5-disappear order"
	)
	_expect_close(animation.blink_interval_seconds, 2.0, "Mom blink starts every two seconds")
	_expect_close(animation.talk_duration_seconds, 1.5, "Mom mouth animation uses the shorter speaking window")

	var presenter := dialogue_ui.portrait_presenter
	_expect(presenter.blink_overlay != null, "dialogue UI has a blink overlay")
	_expect(presenter.talk_overlay != null, "dialogue UI has a mouth overlay")
	if presenter.blink_overlay == null or presenter.talk_overlay == null:
		return
	_expect(
		presenter.blink_overlay.get_parent() == dialogue_ui.portrait_texture,
		"blink overlay moves with the sliding portrait"
	)
	_expect(
		presenter.talk_overlay.get_parent() == dialogue_ui.portrait_texture,
		"mouth overlay moves with the sliding portrait"
	)
	var animation_report := presenter.get_portrait_animation_report()
	_expect(bool(animation_report.get("talking", false)), "Mom starts speaking animation on her line")
	_expect(
		animation_report.get("talk_texture", null) == animation.talk_frames[0],
		"Mom mouth starts on frame one"
	)
	presenter._process(animation.talk_frame_seconds + 0.001)
	animation_report = presenter.get_portrait_animation_report()
	_expect(
		animation_report.get("talk_texture", null) == animation.talk_frames[1],
		"Mom mouth advances to frame two"
	)
	presenter._process(animation.blink_interval_seconds)
	animation_report = presenter.get_portrait_animation_report()
	_expect(
		int(animation_report.get("blink_sequence_index", -1)) == 0,
		"Mom begins a blink after the configured interval"
	)
	presenter._process(animation.blink_frame_seconds + 0.001)
	animation_report = presenter.get_portrait_animation_report()
	_expect(
		animation_report.get("blink_texture", null) == animation.blink_frames[1],
		"Mom blink advances to frame two"
	)
	presenter._process(animation.talk_duration_seconds)
	animation_report = presenter.get_portrait_animation_report()
	_expect(not bool(animation_report.get("talking", true)), "Mom stops mouth animation after three seconds")
	_expect(animation_report.get("talk_texture", null) == null, "Mom's mouth overlay disappears after speaking")


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
