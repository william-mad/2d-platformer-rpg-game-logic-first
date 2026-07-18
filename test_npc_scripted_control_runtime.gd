extends SceneTree

var failures: Array[String] = []
var observed_states: Array[StringName] = []


func _initialize() -> void:
	await process_frame
	var gameplay_flow := root.get_node("GameplayFlow")
	var world := Node2D.new()
	world.name = "ScriptedControlRuntimeWorld"
	root.add_child(world)
	current_scene = world

	var mom_scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := mom_scene.instantiate() as CharacterBody2D
	world.add_child(mom)
	var machine := mom.get_node("NpcStateMachine") as NpcStateMachine
	var animation_player := mom.get_node("AnimationPlayer") as AnimationPlayer
	machine.value_reactions_enabled = false
	machine.state_changed.connect(_on_state_changed)

	var owner := Node.new()
	owner.name = "ScriptedEventOwner"
	root.add_child(owner)
	var competing_owner := Node.new()
	competing_owner.name = "CompetingScriptedEventOwner"
	root.add_child(competing_owner)

	var token := int(gameplay_flow.call(
		"acquire_npc_control_claim", owner, mom, &"runtime_scripted_event", false
	))
	_expect(token != 0, "claim returns a nonzero token")
	_expect(
		int(gameplay_flow.call(
			"acquire_npc_control_claim", owner, mom, &"duplicate_same_owner", false
		)) == token,
		"the same owner receives the existing token"
	)
	_expect(
		int(gameplay_flow.call(
			"acquire_npc_control_claim", competing_owner, mom, &"competing_owner", false
		)) == 0,
		"a second owner cannot claim Mom"
	)
	_expect(_state_name(machine) == &"ScriptedHold", "claiming idle Mom enters ScriptedHold")
	_expect(machine.scripted_control_claim_token == token, "machine stores the active claim token")
	var inspected_claim: Dictionary = gameplay_flow.call("get_npc_control_claim", mom)
	_expect(
		StringName(inspected_claim.get("npc_persistent_id", &"")) == &"mom",
		"claim diagnostics store Mom's persistent ID"
	)

	var facing_target := Marker2D.new()
	facing_target.position = Vector2(-40.0, 0.0)
	world.add_child(facing_target)
	_expect(
		machine.set_scripted_hold_animation(token, &"idle"),
		"the current token can assign a hold animation"
	)
	_expect(
		machine.set_scripted_facing_target(token, facing_target),
		"the current token can assign a facing target"
	)

	var passive_elapsed_before := machine.passive_need_elapsed_seconds
	var hunger_before := machine.get_value(&"hunger")
	machine._update_passive_needs(30.0)
	_expect_close(
		machine.passive_need_elapsed_seconds,
		passive_elapsed_before,
		"claimed NPC passive timer does not advance"
	)
	_expect_close(machine.get_value(&"hunger"), hunger_before, "claimed NPC hunger does not advance")

	var original_target := machine.target
	var original_move_target := machine.move_target
	var original_action: Dictionary = machine.get_active_action_descriptor()
	_expect(
		not machine.request_state(&"LookForTalkTarget", facing_target, "social_ai", 50),
		"social search is blocked"
	)
	_expect(
		not machine.request_state(&"Rest", facing_target, "passive_need", 50),
		"Rest need request is blocked"
	)
	_expect(
		not machine.request_action_from_descriptor({
			"action_kind": "RoutineTask",
			"source": "schedule",
			"priority": 80,
		}, facing_target),
		"schedule request is blocked"
	)
	_expect(_state_name(machine) == &"ScriptedHold", "autonomous requests preserve ScriptedHold")
	_expect(machine.target == original_target, "blocked requests do not change the primary target")
	_expect(machine.move_target == original_move_target, "blocked requests do not change the move target")
	_expect(
		machine.get_active_action_descriptor() == original_action,
		"blocked requests do not create an action session"
	)
	_expect(
		not machine.request_state(&"Collapse", null, "damage_emergency", 1000),
		"emergency replacement is blocked when policy is false"
	)

	var stale_token := token + 100000
	_expect(
		not machine.set_scripted_hold_animation(stale_token, &"walk"),
		"stale animation command is rejected"
	)
	_expect(
		not machine.request_scripted_state(
			stale_token, &"MoveToTarget", facing_target
		),
		"stale scripted state request is rejected"
	)
	_expect(_state_name(machine) == &"ScriptedHold", "stale commands have no state side effects")

	mom.velocity = Vector2.ZERO
	machine._physics_process(0.1)
	_expect(mom.velocity.y > 0.0, "gravity continues in ScriptedHold")
	_expect(animation_player.current_animation == "idle", "hold animation continues")

	var movement_target := Marker2D.new()
	movement_target.position = Vector2(mom.position.x + 64.0, mom.position.y)
	world.add_child(movement_target)
	_expect(
		machine.request_scripted_state(token, &"MoveToTarget", movement_target),
		"valid token starts scripted MoveToTarget"
	)
	_expect(_state_name(machine) == &"MoveToTarget", "scripted movement uses MoveToTarget")
	_expect(
		StringName(machine.get_active_action_descriptor().get("source", &"")) == &"scripted_event",
		"scripted movement records an explicit scripted_event source"
	)
	_expect(
		animation_player.current_animation in ["walk", "walk_1"],
		"scripted movement plays the walk animation"
	)

	var movement_frames := 0
	while _state_name(machine) == &"MoveToTarget" and movement_frames < 180:
		await physics_frame
		movement_frames += 1
	_expect(_state_name(machine) == &"ScriptedHold", "scripted arrival returns to ScriptedHold")
	_expect(
		bool(gameplay_flow.call("is_npc_control_claimed", mom)),
		"scripted arrival preserves the claim"
	)
	_expect(machine.scripted_control_claim_token == token, "arrival preserves the machine token")

	var state_count_before_release := observed_states.size()
	_expect(
		not bool(gameplay_flow.call("release_npc_control_claim", token, competing_owner)),
		"expected-owner validation rejects another owner"
	)
	_expect(
		bool(gameplay_flow.call("release_npc_control_claim", token, owner)),
		"matching owner releases the claim"
	)
	_expect(_state_name(machine) == &"Idle", "release returns Mom to Idle")
	_expect(
		observed_states.size() == state_count_before_release + 1,
		"release performs one immediate state transition"
	)
	_expect(
		not bool(gameplay_flow.call("release_npc_control_claim", token, owner)),
		"repeated claim release is harmless"
	)
	_expect(
		not machine.request_scripted_state(token, &"MoveToTarget", movement_target),
		"released token cannot issue late commands"
	)
	_expect(_state_name(machine) == &"Idle", "late callback leaves released Mom unchanged")

	_expect(
		machine.request_state(&"ReactToEvent", facing_target, "autonomy_resumed", 100),
		"ordinary state requests resume after release"
	)
	_expect(_state_name(machine) == &"ReactToEvent", "post-release autonomy can change state")
	machine.request_state(&"Idle", null, "runtime_reset", 1000)

	var orphan_owner := Node.new()
	orphan_owner.name = "OrphanedScriptedEventOwner"
	root.add_child(orphan_owner)
	var emergency_token := int(gameplay_flow.call(
		"acquire_npc_control_claim", orphan_owner, mom, &"emergency_runtime_event", true
	))
	_expect(emergency_token != 0, "a new owner can claim after release")
	_expect(_state_name(machine) == &"ScriptedHold", "new claim re-enters ScriptedHold")
	_expect(
		machine.request_state(&"Collapse", null, "damage_emergency", 1000),
		"emergency policy allows the existing Collapse equivalent"
	)
	_expect(_state_name(machine) == &"Collapse", "allowed emergency interrupts ScriptedHold")
	_expect(
		machine.scripted_control_claim_token == emergency_token,
		"emergency interruption preserves claim ownership"
	)

	orphan_owner.queue_free()
	await process_frame
	await process_frame
	_expect(
		not bool(gameplay_flow.call("is_npc_control_claimed", mom)),
		"freeing the owner cleans up the claim"
	)
	_expect(_state_name(machine) == &"Idle", "orphan cleanup safely returns Mom to Idle")

	_finish()


func _state_name(machine: NpcStateMachine) -> StringName:
	return StringName(machine.current_state.name) if machine.current_state != null else &""


func _on_state_changed(state_name: StringName, _previous_state_name: StringName) -> void:
	observed_states.append(state_name)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		failures.append("%s: expected %.4f, got %.4f" % [label, expected, actual])


func _finish() -> void:
	if failures.is_empty():
		print("NPC_SCRIPTED_CONTROL_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
