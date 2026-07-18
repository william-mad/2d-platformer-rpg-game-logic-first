extends SceneTree

const DIALOGUE_CONTROLLER_SCRIPT := preload("res://scripts/systems/dialogue_controller.gd")

var failures: Array[String] = []
var old_interaction_effect_count: int = 0


func _initialize() -> void:
	await process_frame
	var gameplay_flow := root.get_node("GameplayFlow")
	var controller := root.get_node("DialogueController")
	var world_time := root.get_node("WorldTime")
	var pause_system := root.get_node("PauseSystem")

	var world := Node2D.new()
	world.name = "ModalDialogueRuntimeWorld"
	root.add_child(world)
	current_scene = world
	_add_floor(world)

	var player := _spawn_player(world, "DialoguePlayer")
	await _settle_player(player)
	_expect(player.is_on_floor(), "dialogue player starts grounded")
	var mom := _spawn_mom(world, "DialogueMom")
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	_force_primary_state(machine, &"Idle")
	var definition := mom.get_meta(&"default_dialogue_definition") as DialogueDefinition
	_expect(definition != null, "Mom explicitly exposes her dialogue definition")
	_expect(definition != null and definition.get_validation_error().is_empty(), "Mom dialogue resource validates")

	# Start through the actual interaction option to cover the clean menu handoff.
	var interactor = player.get_node("NpcTalkInteractor")
	interactor.nearby_npcs.append(mom)
	interactor.interaction_applied.connect(_on_old_interaction_applied)
	interactor.call("_try_open_interaction_menu")
	_expect(interactor.active_menu == &"interaction", "normal interaction menu opens")
	_expect(
		interactor.menu_option_labels.size() > 0
		and String(interactor.menu_option_labels[0].text).contains("Dialogue"),
		"Mom's first interaction option is resource-backed Dialogue"
	)
	interactor.call("_handle_interaction_option", 0)
	_expect(bool(controller.call("is_dialogue_active")), "interaction option starts modal dialogue")
	_expect(interactor.active_menu == &"", "old interaction menu closes for handoff")
	_expect(is_zero_approx(interactor.cooldown), "modal handoff adds no local cooldown")
	_expect(old_interaction_effect_count == 0, "modal handoff applies no old timed Talk effect")

	var first_report: Dictionary = controller.call("dump_active_dialogue")
	var first_session := StringName(first_report.get("session_id", &""))
	var first_world_token := int(first_report.get("world_lock_token", 0))
	var first_npc_token := int(first_report.get("npc_claim_token", 0))
	var first_player_token := int(first_report.get("player_claim_token", 0))
	_expect(first_session != &"", "dialogue owns a unique session ID")
	_expect(first_world_token != 0, "dialogue owns a world-progression token")
	_expect(first_npc_token != 0, "dialogue owns Mom's NPC token")
	_expect(first_player_token != 0, "dialogue owns the player's ui_only token")
	_expect(bool(gameplay_flow.call("is_world_progression_locked")), "world progression is locked")
	_expect(bool(gameplay_flow.call("is_npc_control_claimed", mom)), "Mom remains claimed")
	_expect(bool(gameplay_flow.call("is_player_control_claimed", player)), "player remains claimed")
	_expect(_state_name(machine) == &"ScriptedHold", "Mom enters ScriptedHold")
	_expect(machine.get_scripted_facing_target() == player, "Mom faces the player")
	_expect(machine.get_scripted_hold_animation() == &"talk", "Mom uses the existing Talk presentation")
	_expect(machine.interaction_overlay == null, "autonomous Talk overlay is not created")
	_expect(not paused, "modal dialogue does not pause SceneTree")

	var dialogue_ui := controller.get_node("ModalDialogueUI") as ModalDialogueUI
	_expect(dialogue_ui.visible and dialogue_ui.input_enabled, "dialogue UI is visible and accepts input")
	await process_frame
	var focus_owner := root.gui_get_focus_owner()
	_expect(focus_owner is Button, "first dialogue choice receives keyboard/gamepad focus")

	var world_hours_before := float(world_time.call("get_total_hours"))
	var player_hunger_before := float(player.hunger)
	var player_sleep_before := float(player.sleep_need)
	var mom_hunger_before := float(machine.get_value(&"hunger"))
	var mom_passive_elapsed_before := float(machine.passive_need_elapsed_seconds)
	world_time.call("_process", 2.0)
	player.call("update_player_needs", 2.0)
	machine.call("_update_passive_needs", 2.0)
	_expect_close(float(world_time.call("get_total_hours")), world_hours_before, "clock stops during dialogue")
	_expect_close(float(player.hunger), player_hunger_before, "player hunger stops during dialogue")
	_expect_close(float(player.sleep_need), player_sleep_before, "player sleep need stops during dialogue")
	_expect_close(float(machine.get_value(&"hunger")), mom_hunger_before, "Mom passive hunger stops")
	_expect_close(
		float(machine.passive_need_elapsed_seconds),
		mom_passive_elapsed_before,
		"Mom passive-needs timer stops"
	)

	Input.action_press(&"right")
	player.call("_process", 0.1)
	_expect(is_zero_approx(player.velocity.x), "player gameplay movement input is blocked")
	Input.action_release(&"right")

	pause_system.call("set_paused", true, false)
	_expect(paused, "PauseSystem still pauses SceneTree during dialogue")
	_expect(not dialogue_ui.can_process(), "dialogue UI input processing pauses with SceneTree")
	_expect(bool(controller.call("is_dialogue_active")), "pause preserves the active dialogue")
	_expect(bool(gameplay_flow.call("is_world_progression_locked")), "world remains locked while paused")
	pause_system.call("set_paused", false, false)
	_expect(not paused and dialogue_ui.can_process(), "closing pause resumes the same dialogue UI")
	_expect(StringName(controller.call("dump_active_dialogue").get("session_id", &"")) == first_session, "pause preserves session identity")

	var favor_before := float(mom.call("get_relationship_favor_for", player, 50.0))
	var first_button := dialogue_ui.choice_container.get_child(0) as Button
	_expect(first_button != null, "first authored choice button exists")
	if first_button != null:
		first_button.pressed.emit()
	_expect(not bool(controller.call("is_dialogue_active")), "terminal choice closes dialogue")
	_expect_close(
		float(mom.call("get_relationship_favor_for", player, 50.0)),
		favor_before + 2.0,
		"positive choice applies favor through the relationship API once"
	)
	_expect(not bool(controller.call("choose", &"ready_for_day")), "repeated choice input is ignored")
	_expect_close(
		float(mom.call("get_relationship_favor_for", player, 50.0)),
		favor_before + 2.0,
		"repeated input cannot apply favor twice"
	)
	_expect(_dialogue_tokens_are_clear(gameplay_flow, mom, player), "first terminal choice releases all tokens")
	_expect(_state_name(machine) == &"Idle", "Mom returns to Idle after terminal cleanup")
	_expect(not player.is_gameplay_control_claimed(), "player returns to normal control")

	# Exercise the second authored terminal choice independently.
	var second_result: Dictionary = controller.call("begin_dialogue", player, mom, definition)
	_expect(bool(second_result.get("accepted", false)), "second Mom dialogue starts")
	var neutral_favor_before := float(mom.call("get_relationship_favor_for", player, 50.0))
	_expect(bool(controller.call("choose", &"still_tired")), "neutral terminal choice commits")
	_expect_close(
		float(mom.call("get_relationship_favor_for", player, 50.0)),
		neutral_favor_before,
		"neutral choice applies no favor change"
	)
	_expect(_dialogue_tokens_are_clear(gameplay_flow, mom, player), "second terminal choice releases all tokens")

	# Disallowed NPC states reject before claims and remain untouched.
	for rejected_state in [&"Work", &"Eat", &"Fight"]:
		_force_primary_state(machine, rejected_state)
		var state_before := _state_name(machine)
		var rejected: Dictionary = controller.call("begin_dialogue", player, mom, definition)
		_expect(not bool(rejected.get("accepted", false)), "%s dialogue rejects" % String(rejected_state))
		_expect(_state_name(machine) == state_before, "%s rejection preserves current behavior" % String(rejected_state))
		_expect(_dialogue_tokens_are_clear(gameplay_flow, mom, player), "%s rejection leaks no tokens" % String(rejected_state))
		_force_primary_state(machine, &"Idle")

	player.position.y -= 80.0
	player.velocity = Vector2(0.0, 1.0)
	player.move_and_slide()
	_expect(not player.is_on_floor(), "airborne rejection setup is valid")
	var airborne_result: Dictionary = controller.call("begin_dialogue", player, mom, definition)
	_expect(not bool(airborne_result.get("accepted", false)), "airborne player dialogue rejects")
	_expect(_dialogue_tokens_are_clear(gameplay_flow, mom, player), "airborne rejection leaks no tokens")
	if bool(controller.call("is_dialogue_active")):
		controller.call("cancel_dialogue", "airborne_test_recovery")
	await _settle_player(player)
	player.call("change_state", player.get_node("States/Idle"))

	# Removing Mom must preserve the surviving player and release every token.
	_expect(bool(controller.call("begin_dialogue", player, mom, definition).get("accepted", false)), "dialogue starts before NPC removal")
	mom.queue_free()
	await process_frame
	await process_frame
	_expect(not bool(controller.call("is_dialogue_active")), "NPC removal cancels dialogue")
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "NPC removal releases world lock")
	_expect(not bool(gameplay_flow.call("is_player_control_claimed", player)), "NPC removal releases player claim")

	var mom_two := _spawn_mom(world, "DialogueMomPlayerRemoval")
	var machine_two := mom_two.get_node("NpcStateMachine") as NpcStateMachine
	_force_primary_state(machine_two, &"Idle")
	var definition_two := mom_two.get_meta(&"default_dialogue_definition") as DialogueDefinition
	_expect(bool(controller.call("begin_dialogue", player, mom_two, definition_two).get("accepted", false)), "dialogue starts before player removal")
	player.queue_free()
	await process_frame
	await process_frame
	_expect(not bool(controller.call("is_dialogue_active")), "player removal cancels dialogue")
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "player removal releases world lock")
	_expect(not bool(gameplay_flow.call("is_npc_control_claimed", mom_two)), "player removal releases Mom's claim")
	_expect(_state_name(machine_two) == &"Idle", "surviving Mom returns to Idle after player removal")

	# A separately-instanced controller validates owner exit cleanup without disturbing
	# the persistent autoload used by the rest of the project.
	var player_two := _spawn_player(world, "DialogueOwnerExitPlayer")
	await _settle_player(player_two)
	var owner_controller := DIALOGUE_CONTROLLER_SCRIPT.new()
	owner_controller.name = "DisposableDialogueController"
	world.add_child(owner_controller)
	await process_frame
	_expect(
		bool(owner_controller.call("begin_dialogue", player_two, mom_two, definition_two).get("accepted", false)),
		"disposable dialogue owner starts a session"
	)
	owner_controller.queue_free()
	await process_frame
	await process_frame
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "controller exit releases world lock")
	_expect(not bool(gameplay_flow.call("is_npc_control_claimed", mom_two)), "controller exit releases NPC claim")
	_expect(not bool(gameplay_flow.call("is_player_control_claimed", player_two)), "controller exit releases player claim")
	_expect(_state_name(machine_two) == &"Idle", "controller exit restores Mom to Idle")

	Input.action_release(&"right")
	_finish()


func _spawn_player(world: Node2D, player_name: String) -> CharacterBody2D:
	var scene := load("res://player/player.tscn") as PackedScene
	var player := scene.instantiate() as CharacterBody2D
	player.name = player_name
	player.position = Vector2(0.0, -8.0)
	world.add_child(player)
	return player


func _spawn_mom(world: Node2D, mom_name: String) -> CharacterBody2D:
	var scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := scene.instantiate() as CharacterBody2D
	mom.name = mom_name
	mom.position = Vector2(64.0, 0.0)
	mom.set("use_npc_location_tracking", false)
	mom.set("listen_to_event_bus", false)
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	machine.value_reactions_enabled = false
	world.add_child(mom)
	return mom


func _force_primary_state(machine: NpcStateMachine, state_name: StringName) -> void:
	var state := machine.get_state(state_name)
	if state == null or _state_name(machine) == state_name:
		return
	machine.call("_commit_state_change", state, "modal_dialogue_runtime_test", 10000)


func _state_name(machine: NpcStateMachine) -> StringName:
	return StringName(machine.current_state.name) if machine != null and machine.current_state != null else &""


func _dialogue_tokens_are_clear(gameplay_flow: Node, mom: Node, player: Node) -> bool:
	return (
		not bool(gameplay_flow.call("is_world_progression_locked"))
		and not bool(gameplay_flow.call("is_npc_control_claimed", mom))
		and not bool(gameplay_flow.call("is_player_control_claimed", player))
	)


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


func _on_old_interaction_applied(_player: Node2D, _npc: Node2D, _id: StringName) -> void:
	old_interaction_effect_count += 1


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		failures.append("%s: expected %.4f, got %.4f" % [label, expected, actual])


func _finish() -> void:
	if failures.is_empty():
		print("MODAL_DIALOGUE_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
