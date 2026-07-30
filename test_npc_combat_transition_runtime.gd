extends "res://test/native_scene_tree_test.gd"


func test_damage_does_not_resubmit_blocked_or_terminal_combat_states() -> void:
	var fixture := _create_combat_fixture("DamageTransitionProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return

	machine.set_value(&"anger", 100.0, attacker, false)
	assert_true(
		machine.request_state(&"Fight", attacker, "probe_start", 94),
		"healthy angry NPC starts Fight"
	)
	var rejected_requests: Array[String] = []
	machine.state_request_failed.connect(
		func(state_name: StringName, reason: String) -> void:
			rejected_requests.append("%s:%s" % [String(state_name), reason])
	)

	npc.take_damage(1.0, attacker.global_position, attacker)
	machine.notify_target_seen(attacker)
	assert_true(
		rejected_requests.is_empty(),
		"damage and repeated sight do not re-request an already-active Fight"
	)

	machine.set_value(&"hp", 49.0, attacker, false)
	npc.change_relationship_fear_for(attacker, 100.0, "probe_setup")
	npc.take_damage(1.0, attacker.global_position, attacker)
	assert_true(
		machine.is_primary_state(&"Fight"),
		"healthy Fight keeps control when a Flee request cannot interrupt it"
	)
	assert_true(
		rejected_requests.is_empty(),
		"blocked fear reaction is filtered before it becomes cannot_exit_Fight"
	)

	machine.set_value(&"hp", 10.0, attacker, false)
	assert_true(
		machine.can_transition_to_state(&"Flee", 90),
		"low-health Fight still permits the directed-fear Flee transition"
	)
	machine.set_value(&"hp", 48.0, attacker, false)
	npc.take_damage(100.0, attacker.global_position, attacker)
	assert_true(
		machine.is_primary_state(&"DisabledDead"),
		"lethal damage commits DisabledDead"
	)
	assert_true(
		rejected_requests.is_empty(),
		"lethal damage does not request Flee or DisabledDead again"
	)


func test_low_health_fight_does_not_reenter_every_physics_step() -> void:
	var fixture := _create_combat_fixture("LowHealthFightProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return

	machine.set_value(&"anger", 100.0, attacker, false)
	assert_true(
		machine.request_state(&"Fight", attacker, "probe_start", 94),
		"healthy angry NPC starts Fight"
	)
	var state_changes: Array[String] = []
	var active_session_ids: Dictionary = {}
	var rejection_count := {"value": 0}
	machine.state_changed.connect(
		func(state_name: StringName, previous_name: StringName) -> void:
			state_changes.append("%s>%s" % [
				String(previous_name),
				String(state_name),
			])
	)
	machine.action_session_changed.connect(func(descriptor: Dictionary) -> void:
		var session_id := String(descriptor.get("session_id", "")).strip_edges()
		if (
			not session_id.is_empty()
			and String(descriptor.get("status", "")) == "active"
		):
			active_session_ids[session_id] = true
	)
	machine.state_request_failed.connect(
		func(_state_name: StringName, _reason: String) -> void:
			rejection_count.value += 1
	)

	machine.set_value(&"hp", 10.0, attacker, true)
	for _step in 8:
		var state_at_start := machine.current_state
		var requested := state_at_start.physics_process(1.0 / 60.0)
		if requested != null and machine.current_state == state_at_start:
			machine.change_state(requested, "state_tick")
		if machine.is_primary_state(&"Idle"):
			machine._run_idle_value_reaction_check()

	print(
		"LOW_HEALTH_FIGHT_PROBE state_changes=%d active_sessions=%d rejections=%d current=%s"
		% [
			state_changes.size(),
			active_session_ids.size(),
			rejection_count.value,
			String(machine.current_state.name),
		]
	)
	assert_false(
		machine.is_primary_state(&"Fight"),
		"NPC below the Fight health stop remains out of Fight"
	)
	assert_true(
		state_changes.size() <= 2,
		"low-health handling does not oscillate states every physics step"
	)
	assert_true(
		active_session_ids.size() <= 1,
		"low-health handling does not create replacement Fight sessions"
	)


func _create_combat_fixture(label: String) -> Dictionary:
	var packed := load(
		"res://scenes/creatures/npc/stateful_social_npc.tscn"
	) as PackedScene
	assert_not_null(packed, "stateful combat NPC scene loads")
	if packed == null:
		return {}
	var npc := packed.instantiate() as SocialNpc
	npc.name = label
	npc.relationship_id = StringName(label)
	npc.location_id = &""
	npc.use_npc_location_tracking = false
	npc.listen_to_event_bus = false
	add_child_autofree(npc)
	var machine := npc.get_node_or_null(
		"NpcStateMachine"
	) as NpcStateMachine
	assert_not_null(machine, "combat NPC has a state machine")
	if machine == null:
		return {}
	var attacker := CharacterBody2D.new()
	attacker.name = "%sAttacker" % label
	attacker.add_to_group("player")
	attacker.set_collision_layer_value(2, true)
	attacker.global_position = npc.global_position + Vector2(48.0, 0.0)
	add_child_autofree(attacker)
	return {
		"npc": npc,
		"machine": machine,
		"attacker": attacker,
	}
