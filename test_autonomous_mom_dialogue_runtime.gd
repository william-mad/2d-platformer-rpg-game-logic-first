extends SceneTree

const MemoryPolicy = preload("res://scripts/systems/npc_behavior/npc_memory_policy.gd")

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var controller := root.get_node("DialogueController")
	if bool(controller.call("is_dialogue_active")):
		controller.call("cancel_dialogue", "autonomous_mom_test_setup")

	var world := Node2D.new()
	world.name = "AutonomousMomDialogueRuntimeWorld"
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
	talk_state.talk_range = 100.0
	talk_state.show_talk_limits = false

	var profile := mom.autonomous_dialogue_profile as NpcAutonomousDialogueProfile
	_expect(profile != null, "Mom has an autonomous dialogue profile")
	_expect(profile != null and profile.get_validation_error().is_empty(), "Mom profile validates")
	_expect(profile != null and profile.conversations.size() == 7, "Mom profile contains seven conversations")
	_test_no_immediate_pool_repeat(profile)

	machine.values["talk_need"] = 80.0
	machine.values["boredom"] = 55.0
	var completed_memories_before := machine.short_term_memory.find_recent(
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED
	).size()
	var social_session_id := "autonomous-mom-dialogue-search"
	_expect(
		machine.request_action_from_descriptor({
			"session_id": social_session_id,
			"action_kind": "LookForTalkTarget",
			"source": "social_ai",
			"target_npc_id": "__player__",
			"priority": 60,
			"status": "proposed",
		}, player),
		"existing social AI starts its Talk-target search"
	)
	_expect(_primary_state_name(machine) == &"LookForTalkTarget", "social search owns the primary lane")
	machine._physics_process(0.01)
	_expect(machine.interaction_overlay == talk_state, "Talk remains the interaction overlay")
	_expect(_primary_state_name(machine) == &"Idle", "dialogue does not replace Talk with ScriptedHold")
	_expect(
		machine.get_active_interaction_session_id() == social_session_id,
		"Talk preserves the social search session identity"
	)
	var search_terminal := machine.get_active_action_descriptor()
	_expect(
		String(search_terminal.get("status", "")) == "completed"
		and String(search_terminal.get("reason", "")) == "talk_handoff_completed",
		"social search completes through its normal Talk handoff"
	)
	_expect(talk_state.is_waiting_for_external_completion(), "Talk waits for dialogue completion")
	_expect(bool(controller.call("is_dialogue_active")), "real dialogue UI is active")
	var report: Dictionary = controller.call("dump_active_dialogue")
	_expect(StringName(report.get("session_mode", &"")) == &"autonomous_talk", "dialogue uses autonomous-Talk mode")
	_expect(int(report.get("npc_claim_token", -1)) == 0, "dialogue does not claim scripted NPC control")

	var dialogue_ui := controller.get_node("ModalDialogueUI") as ModalDialogueUI
	_expect(dialogue_ui.visible and dialogue_ui.input_enabled, "modal UI owns player input")
	_expect(
		dialogue_ui.portrait_presenter != null and dialogue_ui.portrait_presenter.visible,
		"Mom portrait presentation slides into view"
	)
	_expect(
		dialogue_ui.portrait_texture.texture == profile.portrait,
		"autonomous dialogue uses Mom's existing portrait"
	)

	var timer_before := talk_state.talk_timer
	talk_state.physics_process(1.0)
	_expect_close(talk_state.talk_timer, timer_before, "Talk timer is paused beneath dialogue")
	_expect(not talk_state.talk_finished_handled, "paused timer cannot complete Talk")

	_complete_current_dialogue(controller)
	_expect(not bool(controller.call("is_dialogue_active")), "terminal dialogue node closes the UI")
	_expect(talk_state.talk_completed_successfully, "dialogue success completes normal Talk")
	_expect_close(machine.get_value(&"talk_need"), 40.0, "normal Talk applies talk-need relief")
	_expect_close(machine.get_value(&"boredom"), 45.0, "normal Talk applies boredom relief")
	machine._physics_process(0.01)
	_expect(machine.interaction_overlay == null, "successful Talk closes its interaction session")
	_expect(
		machine.short_term_memory.find_recent(
			MemoryPolicy.EVENT_CONVERSATION_COMPLETED
		).size() == completed_memories_before + 1,
		"successful dialogue records normal conversation-completed memory"
	)

	# A cancelled dialogue must cancel Talk without paying successful-Talk rewards.
	machine.values["talk_need"] = 70.0
	machine.values["boredom"] = 50.0
	var memories_before_cancel := machine.short_term_memory.find_recent(
		MemoryPolicy.EVENT_CONVERSATION_COMPLETED
	).size()
	_expect(
		machine.request_talk(player, 60, true, &"social_ai"),
		"second social-ai Talk starts for cancellation coverage"
	)
	_expect(bool(controller.call("cancel_dialogue", "test_cancelled")), "dialogue cancellation is accepted")
	_expect(not talk_state.talk_completed_successfully, "cancelled dialogue does not complete Talk")
	_expect_close(machine.get_value(&"talk_need"), 70.0, "cancelled dialogue grants no talk-need relief")
	_expect_close(machine.get_value(&"boredom"), 50.0, "cancelled dialogue grants no boredom relief")
	machine._physics_process(0.01)
	_expect(machine.interaction_overlay == null, "cancelled Talk closes its interaction session")
	_expect(
		machine.short_term_memory.find_recent(
			MemoryPolicy.EVENT_CONVERSATION_COMPLETED
		).size() == memories_before_cancel,
		"cancelled dialogue creates no completion memory"
	)

	_finish()


func _test_no_immediate_pool_repeat(profile: NpcAutonomousDialogueProfile) -> void:
	if profile == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 7321
	var previous_id: StringName = &""
	for index in range(30):
		var definition := profile.choose_conversation(rng, previous_id)
		_expect(definition != null, "pool selection %d returns a dialogue" % index)
		if definition == null:
			return
		if previous_id != &"":
			_expect(definition.dialogue_id != previous_id, "pool avoids immediate repetition %d" % index)
		previous_id = definition.dialogue_id


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
	_expect(safety < 20, "dialogue traversal reaches a terminal node")


func _spawn_player(world: Node2D) -> CharacterBody2D:
	var scene := load("res://player/player.tscn") as PackedScene
	var player := scene.instantiate() as CharacterBody2D
	player.name = "AutonomousDialoguePlayer"
	player.position = Vector2(0.0, -8.0)
	world.add_child(player)
	return player


func _spawn_mom(world: Node2D) -> SocialNpc:
	var scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := scene.instantiate() as SocialNpc
	mom.name = "AutonomousDialogueMom"
	mom.position = Vector2(24.0, 0.0)
	mom.use_npc_location_tracking = false
	mom.listen_to_event_bus = false
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	machine.value_reactions_enabled = false
	world.add_child(mom)
	return mom


func _force_primary_state(machine: NpcStateMachine, state_name: StringName) -> void:
	var state := machine.get_state(state_name)
	if state == null or _primary_state_name(machine) == state_name:
		return
	machine.call("_commit_state_change", state, "autonomous_mom_dialogue_test", 10000)


func _primary_state_name(machine: NpcStateMachine) -> StringName:
	return StringName(machine.current_state.name) if machine != null and machine.current_state != null else &""


func _add_floor(world: Node2D) -> void:
	var floor := StaticBody2D.new()
	floor.name = "Floor"
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
		print("AUTONOMOUS_MOM_DIALOGUE_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
